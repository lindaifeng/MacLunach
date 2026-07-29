import AppKit
import ClipboardFeature
import SwiftUI

@MainActor
final class ClipboardPanelController: NSObject, NSWindowDelegate, FeaturePanelSessionController {
    private let panel: ClipboardPanel
    private let model: ClipboardWorkspaceModel
    private let onClose: () -> Void

    init(
        themeStore: ThemeStore,
        usesFixtureData: Bool = false,
        onClose: @escaping () -> Void
    ) {
        self.onClose = onClose
        if usesFixtureData {
            model = ClipboardWorkspaceModel(fixtureItems: ClipboardWorkspaceModel.makeFixtureItems())
        } else {
            do {
                model = ClipboardWorkspaceModel(
                    databaseURL: try ClipboardHistoryStorage.prepareDatabaseURL()
                )
            } catch {
                model = ClipboardWorkspaceModel(storageFailure: error)
            }
        }
        panel = ClipboardPanel(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = false
        panel.level = .floating
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.minSize = NSSize(width: 620, height: 500)
        panel.contentView = NSHostingView(
            rootView: ClipboardWorkspaceView(model: model)
                .environmentObject(themeStore)
        )
        installWindowTopDragRegion(in: panel)
        if !usesFixtureData {
            model.startMonitoring()
        }
    }

    var isMonitoring: Bool { model.isMonitoring }
    var sessionWindow: NSWindow { panel }

    func stopMonitoring() {
        model.stopMonitoring()
    }

    func show() {
        cancelFeaturePanelDismissal(panel)
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }

    func windowDidResignKey(_ notification: Notification) {
        dismissFeaturePanelAfterResigningKey(panel)
    }

}

enum ClipboardHistoryStorage {
    private static let pluginID = "me.touch.clipboard"

    static func prepareDatabaseURL(applicationSupportURL: URL? = nil) throws -> URL {
        let root = applicationSupportURL ?? defaultApplicationSupportURL()
        let directory = featureDirectory(applicationSupportURL: root)
        let legacyDirectory = root
            .appendingPathComponent("一念", isDirectory: true)
            .appendingPathComponent("Clipboard", isDirectory: true)
        let fileManager = FileManager.default

        if !fileManager.fileExists(atPath: directory.path),
           fileManager.fileExists(atPath: legacyDirectory.path) {
            try fileManager.createDirectory(
                at: directory.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.moveItem(at: legacyDirectory, to: directory)
        } else {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        return directory.appendingPathComponent("history.sqlite", isDirectory: false)
    }

    private static func featureDirectory(applicationSupportURL: URL) -> URL {
        applicationSupportURL
            .appendingPathComponent("Touch", isDirectory: true)
            .appendingPathComponent("Features", isDirectory: true)
            .appendingPathComponent(pluginID, isDirectory: true)
    }

    private static func defaultApplicationSupportURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
    }
}

private final class ClipboardPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
private final class ClipboardWorkspaceModel: ObservableObject {
    struct CopyConfirmation: Equatable {
        let title: String
        let detail: String
    }

    struct Item: Identifiable {
        let entry: ClipboardEntry
        let content: ClipboardContent
        var id: UUID { entry.id }

        var searchText: String {
            if case let .text(value) = content { return value }
            return "图片 image"
        }
    }

    @Published var query = "" { didSet { refresh() } }
    @Published private(set) var showsFavoritesOnly = false
    @Published private(set) var items: [Item] = []
    @Published private(set) var statusMessage: String?
    @Published private(set) var copyConfirmation: CopyConfirmation?
    private let repository: EncryptedClipboardRepository?
    private let writesToSystemPasteboard: Bool
    private var fixtureItems: [Item]?
    private var timer: Timer?
    private var changeCount: Int?
    private var refreshTask: Task<Void, Never>?
    private var copyFeedbackTask: Task<Void, Never>?

    init(databaseURL: URL) {
        writesToSystemPasteboard = true
        fixtureItems = nil
        changeCount = NSPasteboard.general.changeCount
        do {
            repository = try EncryptedClipboardRepository(
                databaseURL: databaseURL,
                keyProvider: KeychainClipboardKeyProvider()
            )
        } catch {
            repository = nil
            statusMessage = "剪贴板历史不可用：\(error.localizedDescription)"
        }
        refresh()
    }

    init(storageFailure: Error) {
        repository = nil
        writesToSystemPasteboard = true
        fixtureItems = nil
        changeCount = NSPasteboard.general.changeCount
        statusMessage = "剪贴板历史不可用：\(storageFailure.localizedDescription)"
    }

    init(fixtureItems: [Item]) {
        repository = nil
        writesToSystemPasteboard = false
        self.fixtureItems = fixtureItems
        changeCount = nil
        items = fixtureItems
        statusMessage = "安全界面验收模式 · 不读取、不写入系统剪贴板"
    }

    static func makeFixtureItems() -> [Item] {
        let textID = UUID(uuidString: "10000000-0000-0000-0000-000000000001") ?? UUID()
        let imageID = UUID(uuidString: "10000000-0000-0000-0000-000000000002") ?? UUID()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let baseDate = calendar.date(
            from: DateComponents(year: 2026, month: 7, day: 23, hour: 12)
        ) ?? Date(timeIntervalSince1970: 1_774_243_200)
        return [
            Item(
                entry: .init(id: textID, createdAt: baseDate, kind: .text),
                content: .text(
                    "方案 A · 单列大卡片\n这是一条固定的安全验收文本，用于检查长内容排版、搜索和复制反馈。"
                )
            ),
            Item(
                entry: .init(
                    id: imageID,
                    createdAt: baseDate.addingTimeInterval(-120),
                    kind: .image,
                    isFavorite: true
                ),
                content: .image(makeFixtureImageData())
            )
        ]
    }

    var isMonitoring: Bool { timer != nil }

    func startMonitoring() {
        guard fixtureItems == nil else { return }
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.readPasteboardIfChanged() }
        }
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        copyFeedbackTask?.cancel()
    }

    func refresh() {
        refreshTask?.cancel()
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let showsFavoritesOnly = showsFavoritesOnly
        if let fixtureItems {
            items = fixtureItems.filter {
                (!showsFavoritesOnly || $0.entry.isFavorite)
                    && (query.isEmpty || $0.searchText.localizedCaseInsensitiveContains(query))
            }
            return
        }
        guard let repository else { return }
        refreshTask = Task { [weak self] in
            do {
                let history = try await repository.readableHistory()
                let loaded = history.entries.compactMap { historyItem -> Item? in
                    let item = Item(entry: historyItem.entry, content: historyItem.content)
                    if (!showsFavoritesOnly || item.entry.isFavorite),
                       query.isEmpty || item.searchText.localizedCaseInsensitiveContains(query) {
                        return item
                    }
                    return nil
                }
                guard !Task.isCancelled else { return }
                self?.items = loaded
                self?.statusMessage = history.discardedUnreadableCount == 0
                    ? nil
                    : "已跳过 \(history.discardedUnreadableCount) 条无法恢复的旧记录"
            } catch {
                self?.statusMessage = "读取历史失败：\(error.localizedDescription)"
            }
        }
    }

    func toggleFavoritesFilter() {
        showsFavoritesOnly.toggle()
        refresh()
    }

    func copy(_ item: Item) {
        if writesToSystemPasteboard {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            switch item.content {
            case let .text(text): pasteboard.setString(text, forType: .string)
            case let .image(data): pasteboard.setData(data, forType: .png)
            }
            changeCount = pasteboard.changeCount
        }
        statusMessage = nil
        showCopyConfirmation(for: item)
    }

    private func showCopyConfirmation(for item: Item) {
        copyFeedbackTask?.cancel()
        let detail: String
        if writesToSystemPasteboard {
            switch item.content {
            case .text:
                detail = "文本已写入剪贴板"
            case .image:
                detail = "图片已写入剪贴板"
            }
        } else {
            detail = "已预览复制反馈，未改动系统剪贴板"
        }
        copyConfirmation = .init(
            title: "已复制",
            detail: detail
        )
        copyFeedbackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled else { return }
            self?.copyConfirmation = nil
        }
    }

    func toggleFavorite(_ item: Item) {
        if fixtureItems != nil {
            fixtureItems = fixtureItems?.map { candidate in
                guard candidate.id == item.id else { return candidate }
                return Item(
                    entry: .init(
                        id: candidate.entry.id,
                        createdAt: candidate.entry.createdAt,
                        kind: candidate.entry.kind,
                        isFavorite: !candidate.entry.isFavorite
                    ),
                    content: candidate.content
                )
            }
            refresh()
            return
        }
        guard let repository else { return }
        Task { [weak self] in
            do {
                try await repository.setFavorite(!item.entry.isFavorite, id: item.id)
                self?.refresh()
            } catch {
                self?.statusMessage = "更新收藏失败：\(error.localizedDescription)"
            }
        }
    }

    func delete(_ item: Item) {
        if fixtureItems != nil {
            fixtureItems?.removeAll { $0.id == item.id }
            refresh()
            return
        }
        guard let repository else { return }
        Task { [weak self] in
            do {
                try await repository.delete(id: item.id)
                self?.refresh()
            } catch {
                self?.statusMessage = "删除失败：\(error.localizedDescription)"
            }
        }
    }

    func clearOrdinaryHistory() {
        if fixtureItems != nil {
            fixtureItems?.removeAll { !$0.entry.isFavorite }
            refresh()
            return
        }
        guard let repository else { return }
        Task { [weak self] in
            do {
                try await repository.clearOrdinaryHistory()
                self?.refresh()
            } catch {
                self?.statusMessage = "清空失败：\(error.localizedDescription)"
            }
        }
    }

    private func readPasteboardIfChanged() {
        guard fixtureItems == nil else { return }
        let pasteboard = NSPasteboard.general
        let currentChangeCount = pasteboard.changeCount
        guard currentChangeCount != changeCount else { return }
        changeCount = currentChangeCount
        guard let repository else { return }

        let content: ClipboardContent?
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            content = .text(text)
        } else if let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
            content = .image(data)
        } else {
            content = nil
        }
        guard let content else { return }
        Task { [weak self] in
            do {
                _ = try await repository.record(content)
                self?.refresh()
            } catch {
                self?.statusMessage = "保存剪贴板失败：\(error.localizedDescription)"
            }
        }
    }

    private static func makeFixtureImageData() -> Data {
        let image = NSImage(size: NSSize(width: 960, height: 540), flipped: false) { bounds in
            NSColor(calibratedRed: 0.11, green: 0.13, blue: 0.17, alpha: 1).setFill()
            bounds.fill()

            let glow = NSBezierPath(ovalIn: NSRect(x: 590, y: 170, width: 310, height: 310))
            NSColor(calibratedRed: 0.38, green: 0.46, blue: 0.98, alpha: 0.34).setFill()
            glow.fill()

            let cardRect = NSRect(x: 72, y: 78, width: 816, height: 384)
            let card = NSBezierPath(roundedRect: cardRect, xRadius: 34, yRadius: 34)
            NSColor(calibratedWhite: 1, alpha: 0.10).setFill()
            card.fill()
            NSColor(calibratedWhite: 1, alpha: 0.22).setStroke()
            card.lineWidth = 2
            card.stroke()

            let title = "一念 · 安全剪贴板预览" as NSString
            title.draw(
                in: NSRect(x: 126, y: 288, width: 700, height: 72),
                withAttributes: [
                    .font: NSFont.systemFont(ofSize: 36, weight: .bold),
                    .foregroundColor: NSColor.white
                ]
            )
            let subtitle = "固定生成的图片 fixture · 不读取真实剪贴板" as NSString
            subtitle.draw(
                in: NSRect(x: 128, y: 230, width: 690, height: 48),
                withAttributes: [
                    .font: NSFont.systemFont(ofSize: 20, weight: .medium),
                    .foregroundColor: NSColor(calibratedWhite: 1, alpha: 0.72)
                ]
            )
            return true
        }
        guard let tiffData = image.tiffRepresentation,
              let representation = NSBitmapImageRep(data: tiffData),
              let pngData = representation.representation(using: .png, properties: [:]) else {
            return Data()
        }
        return pngData
    }
}

private struct ClipboardWorkspaceView: View {
    @ObservedObject var model: ClipboardWorkspaceModel
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var theme: ThemeDefinition { ThemeRegistry.shared.definition(for: themeStore.theme) }

    var body: some View {
        ZStack {
            FeatureWorkspaceBackground(
                theme: theme,
                reduceTransparency: reduceTransparency,
                themeColorOpacity: themeStore.themeColorOpacity
            )
            VStack(spacing: 0) {
                Color.clear.frame(height: 26)
                header
                Rectangle().fill(theme.card.border.color.opacity(0.55)).frame(height: 1)
                content
            }

            if let confirmation = model.copyConfirmation {
                ThemeStatusToast(
                    title: confirmation.title,
                    detail: confirmation.detail,
                    systemName: "checkmark",
                    theme: theme
                )
                .accessibilityIdentifier("clipboard.copy-toast")
                .transition(reduceMotion ? .opacity : .scale(scale: 0.92).combined(with: .opacity))
                .zIndex(10)
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .preferredColorScheme(theme.preferredColorScheme)
        .tint(theme.interactiveAccent.color)
        .animation(reduceMotion ? nil : .easeOut(duration: theme.motion.duration), value: model.copyConfirmation)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "clipboard")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(theme.interactiveAccent.color)
                .frame(width: 32, height: 32)
                .background(theme.icon.container.color, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("剪贴板")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.text.primary.color)
                Text("最多保留 100 条")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(theme.text.secondary.color)
            }
            Spacer()
            HStack(spacing: 8) {
                ThemeIconButton(
                    systemName: model.showsFavoritesOnly ? "star.fill" : "star",
                    tooltip: model.showsFavoritesOnly ? "查看全部历史" : "查看收藏",
                    accessibilityLabel: model.showsFavoritesOnly ? "查看全部剪贴板历史" : "查看收藏的剪贴板历史",
                    theme: theme,
                    isSelected: model.showsFavoritesOnly,
                    action: model.toggleFavoritesFilter
                )
                .accessibilityValue(model.showsFavoritesOnly ? "仅显示收藏" : "显示全部历史")
                .accessibilityIdentifier("clipboard.favorites-filter")

                ThemeIconButton(
                    systemName: "trash",
                    tooltip: "清空非收藏历史",
                    accessibilityLabel: "清空非收藏历史",
                    theme: theme,
                    tint: theme.text.failure.color,
                    action: model.clearOrdinaryHistory
                )
                .accessibilityIdentifier("clipboard.clear")
            }
        }
        .padding(.horizontal, 22)
        .frame(height: 58)
    }

    private var content: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(theme.interactiveAccent.color)
                TextField("搜索剪贴板历史", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(theme.text.primary.color)
                    .accessibilityIdentifier("clipboard.search")
                Text("\(model.items.count) 项")
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.text.weak.color)
                    .accessibilityIdentifier("clipboard.item-count")
            }
            .padding(.horizontal, 13)
            .frame(height: 42)
            .background(theme.search.fill.color.opacity(0.88), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(theme.search.border.color, lineWidth: 1))

            if let status = model.statusMessage {
                Text(status)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.text.secondary.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("clipboard.status")
            }

            if model.items.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: emptyStateSymbol)
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(theme.icon.secondary.color)
                    Text(emptyStateTitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(theme.text.secondary.color)
                    if let detail = emptyStateDetail {
                        Text(detail)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(theme.text.weak.color)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("clipboard.empty-state")
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 12) {
                        ForEach(model.items) { item in
                            ClipboardHistoryRow(item: item, theme: theme, onCopy: { model.copy(item) }, onFavorite: { model.toggleFavorite(item) }, onDelete: { model.delete(item) })
                        }
                    }
                    .padding(.bottom, 8)
                }
                .scrollIndicators(.hidden)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 18)
    }

    private var hasSearchQuery: Bool {
        !model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var emptyStateSymbol: String {
        if hasSearchQuery { return "magnifyingglass" }
        if model.showsFavoritesOnly { return "star" }
        return "clipboard"
    }

    private var emptyStateTitle: String {
        if hasSearchQuery { return "没有找到相关历史" }
        if model.showsFavoritesOnly { return "暂无收藏" }
        return "开始复制内容，历史会自动出现在这里"
    }

    private var emptyStateDetail: String? {
        guard !hasSearchQuery, model.showsFavoritesOnly else { return nil }
        return "点击历史卡片右上角的星标即可收藏"
    }
}

private struct ClipboardHistoryRow: View {
    let item: ClipboardWorkspaceModel.Item
    let theme: ThemeDefinition
    let onCopy: () -> Void
    let onFavorite: () -> Void
    let onDelete: () -> Void
    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: onCopy) {
                VStack(alignment: .leading, spacing: 11) {
                    HStack(spacing: 10) {
                        Image(systemName: itemSymbol)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(theme.interactiveAccent.color)
                            .frame(width: 28, height: 28)
                            .background(theme.icon.container.color, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                        Text(itemTitle)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(theme.text.secondary.color)
                        Text(chineseDateText(item.entry.createdAt))
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(theme.text.weak.color)
                            .accessibilityIdentifier(
                                "clipboard.date.\(item.id.uuidString.lowercased())"
                            )
                        Spacer(minLength: 76)
                    }

                    itemPreview
                }
                .padding(13)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
                .background(
                    (isHovered ? theme.card.hoverFill.color : theme.card.fill.color).opacity(0.96),
                    in: RoundedRectangle(cornerRadius: 17, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 17, style: .continuous)
                        .stroke(isHovered ? theme.card.hoverBorder.color : theme.card.border.color, lineWidth: 1)
                )
                .shadow(
                    color: (isHovered ? theme.card.hoverShadow.color : theme.card.shadow.color).color,
                    radius: isHovered ? theme.card.hoverShadow.radius : theme.card.shadow.radius,
                    x: isHovered ? theme.card.hoverShadow.x : theme.card.shadow.x,
                    y: isHovered ? theme.card.hoverShadow.y : theme.card.shadow.y
                )
            }
            .buttonStyle(.plain)
            .help("单击复制")
            .accessibilityLabel("复制\(itemTitle)历史项")
            .accessibilityValue(itemAccessibilityValue)
            .accessibilityIdentifier("clipboard.item.\(item.id.uuidString.lowercased())")

            if isHovered || item.entry.isFavorite {
                HStack(spacing: 3) {
                    ThemeIconButton(systemName: item.entry.isFavorite ? "star.fill" : "star", tooltip: item.entry.isFavorite ? "取消收藏" : "收藏", accessibilityLabel: item.entry.isFavorite ? "取消收藏" : "收藏", theme: theme, action: onFavorite)
                    ThemeIconButton(systemName: "trash", tooltip: "删除", accessibilityLabel: "删除历史项", theme: theme, tint: theme.text.failure.color, action: onDelete)
                }
                .padding(.top, 10)
                .padding(.trailing, 10)
                .transition(.opacity)
            }
        }
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: theme.motion.duration), value: isHovered)
    }

    private var itemSymbol: String {
        switch item.content {
        case .text: "text.alignleft"
        case .image: "photo"
        }
    }

    private var itemTitle: String {
        switch item.content {
        case .text: "文本"
        case .image: "图片"
        }
    }

    private var itemAccessibilityValue: String {
        switch item.content {
        case let .text(value):
            value
        case .image:
            "剪贴板图片预览"
        }
    }

    private func chineseDateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy年M月d日"
        return formatter.string(from: date)
    }

    @ViewBuilder
    private var itemPreview: some View {
        switch item.content {
        case let .text(value):
            Text(value)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(theme.text.primary.color)
                .lineLimit(5)
                .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
                .padding(13)
                .background(theme.panel.fallback.color.opacity(0.38), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                .accessibilityIdentifier("clipboard.text-preview.\(item.id.uuidString.lowercased())")
        case let .image(data):
            if let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, minHeight: 180, maxHeight: 240)
                    .padding(8)
                    .background(theme.panel.fallback.color.opacity(0.46), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .accessibilityLabel("剪贴板图片预览")
                    .accessibilityIdentifier("clipboard.image-preview")
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.system(size: 28, weight: .light))
                    Text("图片无法预览")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(theme.text.secondary.color)
                .frame(maxWidth: .infinity, minHeight: 180)
                .background(theme.panel.fallback.color.opacity(0.38), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            }
        }
    }
}
