import AppKit
import Foundation
import MarkdownPreviewFeature
import SwiftUI
import UniformTypeIdentifiers
import WebKit

@MainActor
final class MarkdownPreviewPanelController: NSObject, NSWindowDelegate, FeaturePanelSessionController {
    private let panel: MarkdownEditingPanel
    private let model = MarkdownPreviewModel()
    private let onClose: () -> Void

    init(themeStore: ThemeStore, onClose: @escaping () -> Void) {
        self.onClose = onClose
        panel = MarkdownEditingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 740),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.identifier = NSUserInterfaceItemIdentifier("markdown.window.close")
        panel.standardWindowButton(.miniaturizeButton)?.identifier = NSUserInterfaceItemIdentifier("markdown.window.minimize")
        panel.standardWindowButton(.zoomButton)?.identifier = NSUserInterfaceItemIdentifier("markdown.window.zoom")
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = Self.featurePanelLevel
        // 窗口只由原生标题栏拖动，避免编辑区和分栏线被当作窗口拖动区域。
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(
            rootView: MarkdownPanelView(
                model: model,
                onOpenDocument: { [weak self] in self?.openDocument() },
                onSaveDocument: { [weak self] in self?.saveDocument() },
                onImportDocument: { [weak self] url in self?.loadDocument(at: url) ?? false }
            )
            .environmentObject(themeStore)
        )
        installWindowTopDragRegion(in: panel)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: NSApp
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidResignActive),
            name: NSApplication.didResignActiveNotification,
            object: NSApp
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    var sessionWindow: NSWindow { panel }

    func show() {
        cancelFeaturePanelDismissal(panel)
        panel.level = Self.featurePanelLevel
        panel.center()
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }

    func windowDidResignKey(_ notification: Notification) {
        dismissFeaturePanelAfterResigningKey(panel)
    }

    @objc private func applicationDidBecomeActive() {
        if panel.isVisible {
            panel.level = Self.featurePanelLevel
        }
    }

    @objc private func applicationDidResignActive() {
        // Finder 取焦点后保持普通功能窗口层级：仍可接收文件拖放，也不会固定在其他应用上方。
        panel.level = .floating
    }

    private static let featurePanelLevel = NSWindow.Level.floating

    private func openDocument() {
        let picker = NSOpenPanel()
        picker.allowsMultipleSelection = false
        picker.canChooseDirectories = false
        picker.canChooseFiles = true
        picker.allowedContentTypes = markdownTypes
        picker.message = "选择要编辑和预览的 Markdown 文档"
        picker.beginSheetModal(for: panel) { [weak self] response in
            guard let self else { return }
            guard response == .OK, let url = picker.url else { return }
            _ = self.loadDocument(at: url)
        }
    }

    private func loadDocument(at url: URL) -> Bool {
        let pathExtension = url.pathExtension.lowercased()
        guard pathExtension == "md" || pathExtension == "markdown" else { return false }
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess { url.stopAccessingSecurityScopedResource() }
        }
        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            model.load(content: content, from: url)
            return true
        } catch {
            model.statusMessage = "无法打开：\(error.localizedDescription)"
            return false
        }
    }

    private func saveDocument() {
        if let fileURL = model.fileURL {
            writeDocument(to: fileURL)
            return
        }

        let picker = NSSavePanel()
        picker.allowedContentTypes = markdownTypes
        picker.nameFieldStringValue = "未命名.md"
        picker.canCreateDirectories = true
        picker.message = "保存 Markdown 文档"
        picker.beginSheetModal(for: panel) { [weak self] response in
            guard response == .OK, let url = picker.url else { return }
            self?.writeDocument(to: url)
        }
    }

    private func writeDocument(to url: URL) {
        do {
            try model.source.write(to: url, atomically: true, encoding: .utf8)
            model.markSaved(at: url)
        } catch {
            model.statusMessage = "保存失败：\(error.localizedDescription)"
        }
    }

    private var markdownTypes: [UTType] {
        [UTType(filenameExtension: "md"), UTType(filenameExtension: "markdown"), .plainText].compactMap { $0 }
    }
}

private final class MarkdownEditingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
private final class MarkdownPreviewModel: ObservableObject {
    @Published var source = """
    # Markdown

    左侧编辑，右侧立即预览。

    ## 开始写作

    - 支持 **粗体** 与 *斜体*
    - 支持 `行内代码`
    - 支持链接：[一念](https://example.com)

    > 在发布前，先看见内容最终的样子。

    ```swift
    let thought = "所想即现"
    print(thought)
    ```
    """
    @Published var fileName = "未命名文档"
    @Published var fileURL: URL?
    @Published var statusMessage = "实时渲染"
    @Published private(set) var renderedHeadings: [RenderedMarkdownHeading] = []
    @Published var requestedPreviewAnchor: String?

    func load(content: String, from url: URL) {
        source = content
        fileURL = url
        fileName = url.lastPathComponent
        statusMessage = "已打开"
    }

    func markSaved(at url: URL) {
        fileURL = url
        fileName = url.lastPathComponent
        statusMessage = "已保存"
    }

    func createDocument() {
        source = ""
        fileURL = nil
        fileName = "未命名.md"
        statusMessage = "新文档"
    }

    func replaceRenderedHeadings(with headings: [RenderedMarkdownHeading]) {
        guard renderedHeadings != headings else { return }
        renderedHeadings = headings
    }

    func scrollPreview(to anchor: String) {
        requestedPreviewAnchor = anchor
    }
}

final class MarkdownOutlineDrawerModel: ObservableObject {
    @Published private(set) var isPresented = false
    @Published private(set) var state: MarkdownOutlineState = .available([])
    @Published private(set) var activeAnchor: String?

    private let builder = MarkdownOutlineBuilder()

    func toggle() {
        isPresented.toggle()
    }

    func update(mode: MarkdownPreviewFeature.MarkdownWorkspaceMode, headings: [RenderedMarkdownHeading]) {
        state = builder.build(renderedHeadings: headings, mode: mode)
        if case let .available(items) = state, !items.contains(where: { $0.id == activeAnchor }) {
            activeAnchor = nil
        }
    }

    func select(anchor: String) {
        activeAnchor = anchor
    }
}

private enum MarkdownWorkspaceMode: String, CaseIterable, Identifiable {
    case reading
    case split
    case editing

    var id: String { rawValue }

    var title: String {
        switch self {
        case .reading: "阅读"
        case .split: "分栏"
        case .editing: "编辑"
        }
    }

    var symbol: String {
        switch self {
        case .reading: "doc.text"
        case .split: "rectangle.split.2x1"
        case .editing: "square.and.pencil"
        }
    }
}

private struct MarkdownPanelView: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ObservedObject var model: MarkdownPreviewModel
    let onOpenDocument: () -> Void
    let onSaveDocument: () -> Void
    let onImportDocument: (URL) -> Bool
    @State private var splitRatio: CGFloat = 0.5
    @State private var splitStartRatio: CGFloat?
    @State private var mode: MarkdownWorkspaceMode = .split
    @State private var splitScrollProgress: CGFloat = 0
    @State private var isDropTarget = false
    @StateObject private var outlineDrawer = MarkdownOutlineDrawerModel()

    private var theme: ThemeDefinition { ThemeRegistry.shared.definition(for: themeStore.theme) }

    var body: some View {
        ZStack {
            PanelThemeBackground(theme: theme, reduceTransparency: reduceTransparency, themeColorOpacity: 0.98)

            VStack(spacing: 0) {
                header
                Rectangle()
                    .fill(theme.card.border.color.opacity(0.42))
                    .frame(height: 1)
                workspace
                workspaceFooter
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(theme.panel.edgeBorder.color, lineWidth: 1)
        }
        .overlay {
            if isDropTarget {
                ZStack {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(theme.interactiveAccent.color.opacity(0.1))
                    Label("松开以导入 Markdown 文档", systemImage: "doc.badge.arrow.up")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.interactiveAccent.color)
                        .padding(.horizontal, 18)
                        .frame(height: 42)
                        .background(theme.card.fill.color.opacity(0.96), in: Capsule())
                }
                .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: isMarkdownDocument), onImportDocument(url) else {
                return false
            }
            mode = .editing
            return true
        } isTargeted: { isDropTarget = $0 }
        .onAppear(perform: updateOutline)
        .onChange(of: model.renderedHeadings) { _, _ in updateOutline() }
        .onChange(of: mode) { _, _ in updateOutline() }
        .ignoresSafeArea(.container, edges: .top)
    }

    private var header: some View {
        VStack(spacing: 0) {
            // 与解析工具保持一致：原生窗口按钮独占上层，工具栏紧凑排列在下层。
            Color.clear
                .frame(height: 26)
                .allowsHitTesting(false)

            ZStack {
                modeSelector

                HStack(spacing: 10) {
                    HStack(spacing: 10) {
                        brandMark

                        VStack(alignment: .leading, spacing: 1) {
                            Text("Markdown")
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                                .foregroundStyle(theme.text.primary.color)
                            Text(model.fileName)
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundStyle(theme.text.secondary.color)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 236)

                    ThemeIconButton(
                        systemName: "list.bullet.indent",
                        tooltip: "目录",
                        accessibilityLabel: "打开目录",
                        theme: theme,
                        action: outlineDrawer.toggle
                    )
                    .accessibilityIdentifier("markdown.outline.toggle")
                    toolbarButton("新建", symbol: "doc.badge.plus", action: createDocumentAndEdit)
                    toolbarButton("打开", symbol: "folder", action: onOpenDocument)
                        .accessibilityIdentifier("markdown.open-document")
                    toolbarButton("保存", symbol: "square.and.arrow.down", isProminent: true, action: onSaveDocument)
                        .accessibilityIdentifier("markdown.save-document")
                }
                .padding(.horizontal, 20)
            }
            .frame(height: 52)
        }
        .frame(height: 78)
        .background(theme.card.fill.color.opacity(0.26))
    }

    private var workspace: some View {
        ZStack(alignment: .leading) {
            switch mode {
            case .reading:
                previewPane(focused: true)

            case .editing:
                editorPane(focused: true)

            case .split:
                GeometryReader { proxy in
                    let handleWidth: CGFloat = 10
                    let contentWidth = max(1, proxy.size.width - handleWidth)
                    let editorWidth = contentWidth * splitRatio
                    let previewWidth = contentWidth - editorWidth

                    HStack(spacing: 0) {
                        if editorWidth > 1 {
                            editorPane(focused: false)
                                .frame(width: editorWidth)
                        }
                        splitHandle(contentWidth: contentWidth)
                        if previewWidth > 1 {
                            previewPane(focused: false)
                                .frame(width: previewWidth)
                        }
                    }
                }
            }

            if outlineDrawer.isPresented {
                MarkdownOutlineDrawer(
                    state: outlineDrawer.state,
                    activeAnchor: outlineDrawer.activeAnchor,
                    theme: theme,
                    reduceTransparency: reduceTransparency,
                    onSelect: { heading in
                        outlineDrawer.select(anchor: heading.id)
                        model.scrollPreview(to: heading.id)
                    }
                )
                .transition(reduceTransparency ? .opacity : .move(edge: .leading).combined(with: .opacity))
                .zIndex(1)
            }
        }
        .animation(reduceTransparency ? nil : .easeOut(duration: theme.motion.duration), value: outlineDrawer.isPresented)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func editorPane(focused: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            MarkdownSourceEditor(
                text: $model.source,
                fontSize: focused ? 14 : 13.5,
                horizontalInset: focused ? 38 : 24,
                verticalInset: 28,
                foregroundColor: theme.text.primary.color,
                accentColor: theme.interactiveAccent.color,
                lineNumberColor: markdownLineNumberColor,
                lineNumberBackgroundColor: markdownLineNumberBackgroundColor,
                onImportDocument: { url in
                    guard onImportDocument(url) else { return false }
                    mode = .editing
                    return true
                },
                onScroll: focused ? nil : { splitScrollProgress = $0 }
            )
                .background(theme.card.fill.color.opacity(0.3))
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(theme.interactiveAccent.color.opacity(0.18))
                        .frame(width: 1)
                        .offset(x: markdownLineNumberRulerWidth)
                        .allowsHitTesting(false)
                }
                .overlay(alignment: .topLeading) {
                    if model.source.isEmpty {
                        emptyEditorHint
                            .padding(.leading, markdownLineNumberRulerWidth + (focused ? 30 : 24))
                            .padding(.top, 32)
                            .allowsHitTesting(false)
                    }
                }
                .clipped()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.card.fill.color.opacity(0.18))
    }

    private func previewPane(focused: Bool) -> some View {
        return VStack(alignment: .leading, spacing: 0) {
            Group {
                if model.source.isEmpty {
                    emptyPreview
                } else {
                    MarkdownWebPreview(
                        source: model.source,
                        palette: .init(
                            primaryText: theme.text.primary.cssRGBA,
                            secondaryText: theme.text.secondary.cssRGBA,
                            weakText: theme.text.weak.cssRGBA,
                            accent: theme.interactiveAccent.cssRGBA,
                            surface: theme.card.fill.cssRGBA,
                            border: theme.card.border.cssRGBA
                        ),
                        onRenderedHeadings: model.replaceRenderedHeadings,
                        scrollAnchor: model.requestedPreviewAnchor
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(theme.card.fill.color.opacity(0.22))
            .accessibilityIdentifier("markdown.rendered")
            .accessibilityValue("已渲染：\(model.source)")
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private func splitHandle(contentWidth: CGFloat) -> some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 10)
            .overlay {
                Rectangle()
                    .fill(theme.card.border.color.opacity(0.58))
                    .frame(width: 1)
            }
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if splitStartRatio == nil { splitStartRatio = splitRatio }
                        splitRatio = min(1, max(0, (splitStartRatio ?? splitRatio) + value.translation.width / contentWidth))
                    }
                    .onEnded { _ in
                        withAnimation(.easeOut(duration: 0.16)) {
                            if splitRatio < 0.04 {
                                splitRatio = 0
                            } else if splitRatio > 0.96 {
                                splitRatio = 1
                            }
                        }
                        splitStartRatio = nil
                    }
            )
            .onTapGesture(count: 2) {
                withAnimation(.easeInOut(duration: 0.2)) { splitRatio = 0.5 }
            }
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    NSCursor.resizeLeftRight.set()
                case .ended:
                    NSCursor.arrow.set()
                }
            }
            .accessibilityIdentifier("markdown.split-divider")
            .accessibilityLabel("拖动以调整编辑与预览宽度，双击恢复等宽")
    }

    private func toolbarButton(
        _ title: String,
        symbol: String,
        isProminent: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(isProminent ? Color.white : theme.interactiveAccent.color)
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(
                    isProminent
                        ? theme.interactiveAccent.color
                        : theme.interactiveAccent.color.opacity(0.10),
                    in: Capsule()
                )
                .overlay {
                    if !isProminent {
                        Capsule().stroke(theme.interactiveAccent.color.opacity(0.24), lineWidth: 1)
                    }
                }
        }
        .buttonStyle(.plain)
    }

    private var brandMark: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(theme.icon.brandGradient.gradient)
            Image(systemName: "text.document")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.white)
        }
        .frame(width: 32, height: 32)
        .shadow(color: theme.interactiveAccent.color.opacity(0.2), radius: 7, y: 3)
    }

    private var modeSelector: some View {
        HStack(spacing: 2) {
            ForEach(MarkdownWorkspaceMode.allCases) { item in
                Button {
                    mode = item
                } label: {
                    Label(item.title, systemImage: item.symbol)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(
                            theme.interactiveAccent.color.opacity(mode == item ? 1 : 0.78)
                        )
                        .frame(width: 72, height: 31)
                        .background(
                            mode == item ? theme.interactiveAccent.color.opacity(0.12) : Color.clear,
                            in: Capsule()
                        )
                        .overlay {
                            if mode == item {
                                Capsule().stroke(theme.interactiveAccent.color.opacity(0.34), lineWidth: 1)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("markdown.mode.\(item.rawValue)")
                .accessibilityValue(mode == item ? "已选择" : "未选择")
            }
        }
        .padding(3)
        .background(theme.panel.fallback.color.opacity(0.32), in: Capsule())
    }

    /// 浅色工作台使用高对比石墨色；深色工作台使用浅蓝，避免深色背景下行号消失。
    private var markdownLineNumberColor: Color {
        switch theme.id {
        case .defaultGlass, .day:
            return theme.text.primary.color.opacity(0.82)
        case .night, .graphite:
            return theme.interactiveAccent.color.opacity(0.86)
        }
    }

    /// 覆盖 NSRulerView 的系统浅灰底，让行号栏真正融入工作台主题。
    private var markdownLineNumberBackgroundColor: Color {
        switch theme.id {
        case .defaultGlass, .day:
            return theme.interactiveAccent.color.opacity(0.08)
        case .night, .graphite:
            return theme.panel.fallback.color.opacity(0.72)
        }
    }

    private var workspaceFooter: some View {
        HStack(spacing: 12) {
            Text("\(model.source.count) 个字符")
                .accessibilityIdentifier("markdown.character-count")

            Spacer()

            HStack(spacing: 5) {
                Text("阅读时长")
                Text(readingTime)
            }
            .accessibilityIdentifier("markdown.reading-time")
        }
        .font(.system(size: 9.5, weight: .medium))
        .foregroundStyle(theme.text.weak.color)
        .padding(.horizontal, 20)
        .frame(height: 34)
        .background(theme.card.fill.color.opacity(0.24))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(theme.card.border.color.opacity(0.34))
                .frame(height: 1)
        }
    }

    private var emptyEditorHint: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("开始编辑")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.text.secondary.color)
            Text("输入 # 标题开始编辑，或拖入 .md 文件到此窗口。")
                .font(.system(size: 11))
                .foregroundStyle(theme.text.weak.color)
        }
    }

    private var emptyPreview: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(theme.interactiveAccent.color)
            Text("等待第一行内容")
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.text.primary.color)
            Text("在编辑区写下 Markdown，这张纸会实时成形。")
                .font(.system(size: 11))
                .foregroundStyle(theme.text.secondary.color)
        }
        .frame(maxWidth: .infinity, minHeight: 280)
    }

    private var readingTime: String {
        let minutes = max(1, Int(ceil(Double(model.source.count) / 500.0)))
        return "约 \(minutes) 分钟"
    }

    private func createDocumentAndEdit() {
        model.createDocument()
        mode = .editing
    }

    private func updateOutline() {
        let outlineMode: MarkdownPreviewFeature.MarkdownWorkspaceMode = switch mode {
        case .reading: .reading
        case .split: .split
        case .editing: .editing
        }
        outlineDrawer.update(mode: outlineMode, headings: model.renderedHeadings)
    }

    private func isMarkdownDocument(_ url: URL) -> Bool {
        let pathExtension = url.pathExtension.lowercased()
        return pathExtension == "md" || pathExtension == "markdown"
    }

    @ViewBuilder
    private func renderedBlock(_ block: MarkdownBlock) -> some View {
        switch block {
        case let .heading(level, text):
            Text(inlineMarkdown(text))
                .font(.system(size: headingSize(level), weight: level == 1 ? .bold : .semibold, design: .rounded))
                .foregroundStyle(theme.text.primary.color)
                .textSelection(.enabled)

        case let .paragraph(text):
            Text(inlineMarkdown(text))
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(theme.text.primary.color)
                .lineSpacing(4)
                .textSelection(.enabled)

        case let .unorderedItem(text):
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Circle()
                    .fill(theme.interactiveAccent.color)
                    .frame(width: 5, height: 5)
                Text(inlineMarkdown(text))
                    .font(.system(size: 14))
                    .foregroundStyle(theme.text.primary.color)
                    .textSelection(.enabled)
            }

        case let .orderedItem(number, text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(number).")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.interactiveAccent.color)
                    .frame(minWidth: 18, alignment: .trailing)
                Text(inlineMarkdown(text))
                    .font(.system(size: 14))
                    .foregroundStyle(theme.text.primary.color)
                    .textSelection(.enabled)
            }

        case let .quote(text):
            HStack(alignment: .top, spacing: 11) {
                Capsule()
                    .fill(theme.interactiveAccent.color.opacity(0.78))
                    .frame(width: 3)
                Text(inlineMarkdown(text))
                    .font(.system(size: 13.5, weight: .medium))
                    .italic()
                    .foregroundStyle(theme.text.secondary.color)
                    .lineSpacing(3)
                    .textSelection(.enabled)
            }
            .padding(.vertical, 4)

        case let .code(language, source):
            VStack(alignment: .leading, spacing: 8) {
                if !language.isEmpty {
                    Text(language.uppercased())
                        .font(.system(size: 8.5, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.interactiveAccent.color)
                }
                ScrollView(.horizontal) {
                    Text(source)
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundStyle(theme.text.primary.color)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.card.fill.color.opacity(0.82), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(theme.card.border.color.opacity(0.62), lineWidth: 1)
            }

        case .divider:
            Rectangle()
                .fill(theme.card.border.color.opacity(0.72))
                .frame(height: 1)
                .padding(.vertical, 3)
        }
    }

    private func inlineMarkdown(_ source: String) -> AttributedString {
        (try? AttributedString(markdown: source)) ?? AttributedString(source)
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: 25
        case 2: 19
        case 3: 16
        default: 14
        }
    }
}

private let markdownLineNumberRulerWidth: CGFloat = 30

@MainActor
private struct MarkdownSourceEditor: NSViewRepresentable {
    @Binding var text: String
    let fontSize: CGFloat
    let horizontalInset: CGFloat
    let verticalInset: CGFloat
    let foregroundColor: Color
    let accentColor: Color
    let lineNumberColor: Color
    let lineNumberBackgroundColor: Color
    let onImportDocument: (URL) -> Bool
    let onScroll: ((CGFloat) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay

        let textView = MarkdownTextView()
        textView.onImportDocument = onImportDocument
        textView.delegate = context.coordinator
        textView.string = text
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.backgroundColor = .clear
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.minSize = NSSize(width: 0, height: scrollView.contentSize.height)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.setAccessibilityIdentifier("markdown.source")
        scrollView.documentView = textView
        let lineNumberRuler = MarkdownLineNumberRulerView(scrollView: scrollView, textView: textView)
        scrollView.hasVerticalRuler = true
        scrollView.verticalRulerView = lineNumberRuler
        scrollView.rulersVisible = true
        context.coordinator.attach(
            scrollView: scrollView,
            textView: textView,
            lineNumberRuler: lineNumberRuler
        )
        applyAppearance(to: textView)
        applyAppearance(to: lineNumberRuler)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
        if let textView = textView as? MarkdownTextView {
            textView.onImportDocument = onImportDocument
        }
        applyAppearance(to: textView)
        if let lineNumberRuler = scrollView.verticalRulerView as? MarkdownLineNumberRulerView {
            applyAppearance(to: lineNumberRuler)
            lineNumberRuler.needsDisplay = true
        }
    }

    private func applyAppearance(to textView: NSTextView) {
        textView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.textColor = NSColor(foregroundColor)
        textView.insertionPointColor = NSColor(accentColor)
        textView.textContainerInset = NSSize(width: horizontalInset, height: verticalInset)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 5
        textView.defaultParagraphStyle = paragraphStyle
        textView.typingAttributes[.paragraphStyle] = paragraphStyle
    }

    private func applyAppearance(to lineNumberRuler: MarkdownLineNumberRulerView) {
        lineNumberRuler.numberColor = NSColor(lineNumberColor)
        lineNumberRuler.rulerBackgroundColor = NSColor(lineNumberBackgroundColor)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownSourceEditor
        private weak var scrollView: NSScrollView?
        private weak var textView: NSTextView?
        private weak var lineNumberRuler: MarkdownLineNumberRulerView?

        init(parent: MarkdownSourceEditor) {
            self.parent = parent
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        func attach(
            scrollView: NSScrollView,
            textView: NSTextView,
            lineNumberRuler: MarkdownLineNumberRulerView
        ) {
            self.scrollView = scrollView
            self.textView = textView
            self.lineNumberRuler = lineNumberRuler
            scrollView.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(boundsDidChange),
                name: NSView.boundsDidChangeNotification,
                object: scrollView.contentView
            )
        }

        func textDidChange(_ notification: Notification) {
            guard let textView, parent.text != textView.string else { return }
            parent.text = textView.string
            lineNumberRuler?.needsDisplay = true
        }

        @objc private func boundsDidChange() {
            guard let scrollView, let documentView = scrollView.documentView else { return }
            let maximumOffset = max(0, documentView.bounds.height - scrollView.contentView.bounds.height)
            let progress = maximumOffset > 0
                ? min(1, max(0, scrollView.contentView.bounds.origin.y / maximumOffset))
                : 0
            lineNumberRuler?.needsDisplay = true
            parent.onScroll?(progress)
        }
    }
}

@MainActor
private final class MarkdownTextView: NSTextView {
    var onImportDocument: ((URL) -> Bool)?

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        markdownURL(from: sender.draggingPasteboard) == nil ? super.draggingEntered(sender) : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        markdownURL(from: sender.draggingPasteboard) == nil ? super.draggingUpdated(sender) : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = markdownURL(from: sender.draggingPasteboard) else {
            return super.performDragOperation(sender)
        }
        return onImportDocument?(url) ?? false
    }

    private func markdownURL(from pasteboard: NSPasteboard) -> URL? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]
        return urls?.first { url in
            let pathExtension = url.pathExtension.lowercased()
            return pathExtension == "md" || pathExtension == "markdown"
        }
    }
}

@MainActor
private final class MarkdownLineNumberRulerView: NSRulerView {
    weak var textView: NSTextView?
    var numberColor = NSColor.secondaryLabelColor
    var rulerBackgroundColor = NSColor.clear

    init(scrollView: NSScrollView, textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = markdownLineNumberRulerWidth
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        rulerBackgroundColor.setFill()
        dirtyRect.fill()
        drawHashMarksAndLabels(in: dirtyRect)
    }

    override func drawHashMarksAndLabels(in dirtyRect: NSRect) {
        guard let textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }

        layoutManager.ensureLayout(for: textContainer)
        let source = textView.string as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: numberColor
        ]

        if source.length == 0 {
            let point = convert(
                NSPoint(x: 0, y: textView.textContainerOrigin.y),
                from: textView
            )
            drawLineNumber(1, y: point.y, attributes: attributes)
            return
        }

        var characterIndex = 0
        var lineNumber = 1
        while characterIndex < source.length {
            let lineRange = source.lineRange(for: NSRange(location: characterIndex, length: 0))
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: characterIndex)
            let fragment = layoutManager.lineFragmentRect(
                forGlyphAt: glyphIndex,
                effectiveRange: nil,
                withoutAdditionalLayout: true
            )
            let point = convert(
                NSPoint(x: 0, y: fragment.minY + textView.textContainerOrigin.y),
                from: textView
            )
            let y = point.y
            if y + fragment.height >= dirtyRect.minY, y <= dirtyRect.maxY {
                drawLineNumber(lineNumber, y: y, attributes: attributes)
            }
            if y > dirtyRect.maxY { break }
            characterIndex = NSMaxRange(lineRange)
            lineNumber += 1
        }

        if source.character(at: source.length - 1) == 10 {
            let extra = layoutManager.extraLineFragmentRect
            let point = convert(
                NSPoint(x: 0, y: extra.minY + textView.textContainerOrigin.y),
                from: textView
            )
            let y = point.y
            drawLineNumber(lineNumber, y: y, attributes: attributes)
        }
    }

    private func drawLineNumber(
        _ lineNumber: Int,
        y: CGFloat,
        attributes: [NSAttributedString.Key: Any]
    ) {
        let label = NSString(string: String(lineNumber))
        let size = label.size(withAttributes: attributes)
        label.draw(
            at: NSPoint(x: ruleThickness - size.width - 7, y: y + 1),
            withAttributes: attributes
        )
    }
}

private enum MarkdownBlock {
    case heading(level: Int, text: String)
    case paragraph(String)
    case unorderedItem(String)
    case orderedItem(number: Int, text: String)
    case quote(String)
    case code(language: String, source: String)
    case divider

    static func parse(_ source: String) -> [MarkdownBlock] {
        let lines = source.components(separatedBy: .newlines)
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var codeLines: [String] = []
        var codeLanguage = ""
        var isInsideCode = false

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: " ")))
            paragraph.removeAll(keepingCapacity: true)
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                if isInsideCode {
                    blocks.append(.code(language: codeLanguage, source: codeLines.joined(separator: "\n")))
                    codeLines.removeAll(keepingCapacity: true)
                    codeLanguage = ""
                    isInsideCode = false
                } else {
                    flushParagraph()
                    codeLanguage = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    isInsideCode = true
                }
                continue
            }

            if isInsideCode {
                codeLines.append(line)
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                continue
            }

            let headingMarks = trimmed.prefix { $0 == "#" }.count
            if (1...6).contains(headingMarks), trimmed.dropFirst(headingMarks).first == " " {
                flushParagraph()
                blocks.append(.heading(
                    level: headingMarks,
                    text: String(trimmed.dropFirst(headingMarks + 1))
                ))
            } else if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushParagraph()
                blocks.append(.divider)
            } else if trimmed.hasPrefix("> ") {
                flushParagraph()
                blocks.append(.quote(String(trimmed.dropFirst(2))))
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                flushParagraph()
                blocks.append(.unorderedItem(String(trimmed.dropFirst(2))))
            } else if let marker = orderedListMarker(in: trimmed) {
                flushParagraph()
                blocks.append(.orderedItem(number: marker.number, text: marker.text))
            } else {
                paragraph.append(trimmed)
            }
        }

        flushParagraph()
        if isInsideCode {
            blocks.append(.code(language: codeLanguage, source: codeLines.joined(separator: "\n")))
        }
        return blocks
    }

    private static func orderedListMarker(in line: String) -> (number: Int, text: String)? {
        guard let dot = line.firstIndex(of: "."), dot != line.startIndex else { return nil }
        let numberText = line[..<dot]
        let remainder = line[line.index(after: dot)...]
        guard let number = Int(numberText), remainder.first == " " else { return nil }
        return (number, String(remainder.dropFirst()))
    }
}

private extension ThemeColorToken {
    var cssRGBA: String {
        let cssRed = Int((self.red * 255).rounded())
        let cssGreen = Int((self.green * 255).rounded())
        let cssBlue = Int((self.blue * 255).rounded())
        return "rgba(\(cssRed), \(cssGreen), \(cssBlue), \(self.opacity))"
    }
}

private struct MarkdownWebPreviewPalette: Equatable {
    let primaryText: String
    let secondaryText: String
    let weakText: String
    let accent: String
    let surface: String
    let border: String
}

private struct MarkdownOutlineDrawer: View {
    let state: MarkdownOutlineState
    let activeAnchor: String?
    let theme: ThemeDefinition
    let reduceTransparency: Bool
    let onSelect: (MarkdownHeading) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "list.bullet.indent")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.interactiveAccent.color)
                Text("目录")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.text.primary.color)
                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(height: 48)

            Rectangle()
                .fill(theme.card.border.color.opacity(0.52))
                .frame(height: 1)

            Group {
                switch state {
                case let .available(headings):
                    if headings.isEmpty {
                        Text("预览中还没有可用标题")
                            .font(.system(size: 11.5))
                            .foregroundStyle(theme.text.secondary.color)
                            .padding(16)
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 4) {
                                ForEach(headings) { heading in
                                    outlineRow(heading)
                                }
                            }
                            .padding(10)
                        }
                    }

                case let .restricted(message):
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: "eye.slash")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(theme.interactiveAccent.color)
                        Text(message)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(theme.text.secondary.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(16)
                    .accessibilityIdentifier("markdown.outline.restricted")
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(width: 240)
        .background(
            (reduceTransparency ? theme.panel.fallback.color : theme.card.fill.color.opacity(0.96))
        )
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(theme.card.border.color.opacity(0.7))
                .frame(width: 1)
        }
        .shadow(color: theme.panel.shadow.color.color.opacity(reduceTransparency ? 0.12 : 0.28), radius: 18, x: 7, y: 0)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Markdown 目录")
    }

    private func outlineRow(_ heading: MarkdownHeading) -> some View {
        let isActive = activeAnchor == heading.id
        return Button {
            onSelect(heading)
        } label: {
            Text(heading.title)
                .font(.system(size: 12, weight: isActive ? .bold : .medium))
                .foregroundStyle(isActive ? theme.interactiveAccent.color : theme.text.primary.color)
                .lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                .padding(.horizontal, 9)
                .background(
                    isActive ? theme.interactiveAccent.color.opacity(0.14) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(ThemePressButtonStyle(theme: theme, reduceMotion: reduceMotion))
        .padding(.leading, CGFloat(max(0, heading.level - 1)) * 12)
        .accessibilityIdentifier("markdown.outline.item.\(heading.id)")
        .accessibilityLabel("跳转到 \(heading.title)")
        .accessibilityValue(isActive ? "当前标题" : "")
    }
}

/// WebKit 与目录状态之间的唯一桥接点。标题只从已渲染的 DOM 获取，绝不回写
/// `MarkdownPreviewModel.source`，因此目录行为不会改动用户的 Markdown 文本。
enum MarkdownPreviewOutlineBridge {
    static let messageName = "touchMarkdownOutline"

    static let collectHeadingsScript = """
    Array.from(document.querySelectorAll('h1,h2,h3,h4,h5,h6')).map((node, index) => {
      if (!node.id) node.id = `touch-heading-${index}`;
      return {
        level: Number(node.tagName.slice(1)),
        title: node.textContent || '',
        anchor: node.id || `touch-heading-${index}`
      };
    })
    """

    static let observationScript = """
    (() => {
      const publish = () => {
        const headings = \(collectHeadingsScript);
        window.webkit.messageHandlers.\(messageName).postMessage(headings);
      };
      let timer;
      const publishAfterScrollingSettles = () => {
        window.clearTimeout(timer);
        timer = window.setTimeout(publish, 120);
      };
      window.addEventListener('scroll', publishAfterScrollingSettles, { passive: true });
      document.addEventListener('scroll', publishAfterScrollingSettles, { passive: true, capture: true });
      publish();
    })();
    """

    static func headings(from messageBody: Any) -> [RenderedMarkdownHeading] {
        guard let values = messageBody as? [[String: Any]] else { return [] }
        return values.compactMap { value in
            guard let level = value["level"] as? Int,
                  let title = value["title"] as? String,
                  let anchor = value["anchor"] as? String else {
                return nil
            }
            return RenderedMarkdownHeading(level: level, title: title, anchor: anchor)
        }
    }

    static func scrollToHeadingScript(anchor: String) -> String {
        let encodedAnchor = (try? JSONEncoder().encode(anchor)) ?? Data("\"\"".utf8)
        let literal = String(data: encodedAnchor, encoding: .utf8) ?? "\"\""
        return "document.getElementById(\(literal))?.scrollIntoView({ behavior: 'smooth', block: 'start' });"
    }
}

@MainActor
private struct MarkdownWebPreview: NSViewRepresentable {
    let source: String
    let palette: MarkdownWebPreviewPalette
    let onRenderedHeadings: ([RenderedMarkdownHeading]) -> Void
    let scrollAnchor: String?

    func makeCoordinator() -> Coordinator {
        Coordinator(onRenderedHeadings: onRenderedHeadings)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(
            context.coordinator,
            name: MarkdownPreviewOutlineBridge.messageName
        )

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator
        webView.allowsMagnification = true
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onRenderedHeadings = onRenderedHeadings
        context.coordinator.requestScroll(to: scrollAnchor, in: webView)
        let html = MarkdownHTMLRenderer.document(source: source, palette: palette)
        guard context.coordinator.loadedHTML != html else { return }
        context.coordinator.loadedHTML = html
        context.coordinator.hasFinishedLoadingCurrentDocument = false
        webView.loadHTMLString(html, baseURL: nil)
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.configuration.userContentController.removeScriptMessageHandler(
            forName: MarkdownPreviewOutlineBridge.messageName
        )
        nsView.navigationDelegate = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var loadedHTML = ""
        var onRenderedHeadings: ([RenderedMarkdownHeading]) -> Void
        var requestedScrollAnchor: String?
        var hasFinishedLoadingCurrentDocument = false

        init(onRenderedHeadings: @escaping ([RenderedMarkdownHeading]) -> Void) {
            self.onRenderedHeadings = onRenderedHeadings
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == MarkdownPreviewOutlineBridge.messageName else { return }
            onRenderedHeadings(MarkdownPreviewOutlineBridge.headings(from: message.body))
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            hasFinishedLoadingCurrentDocument = true
            scrollIfNeeded(in: webView)
        }

        func requestScroll(to anchor: String?, in webView: WKWebView) {
            guard requestedScrollAnchor != anchor else { return }
            requestedScrollAnchor = anchor
            scrollIfNeeded(in: webView)
        }

        private func scrollIfNeeded(in webView: WKWebView) {
            guard hasFinishedLoadingCurrentDocument, let requestedScrollAnchor else { return }
            webView.evaluateJavaScript(
                MarkdownPreviewOutlineBridge.scrollToHeadingScript(anchor: requestedScrollAnchor)
            )
        }
    }
}

private enum MarkdownHTMLRenderer {
    static func document(source: String, palette: MarkdownWebPreviewPalette) -> String {
        let body = MarkdownBlock.parse(source).map(render).joined(separator: "\n")
        return """
        <!doctype html>
        <html lang="zh-CN">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <style>
            :root {
              color-scheme: light dark;
              --text: \(palette.primaryText);
              --secondary: \(palette.secondaryText);
              --weak: \(palette.weakText);
              --accent: \(palette.accent);
              --surface: \(palette.surface);
              --border: \(palette.border);
            }
            * { box-sizing: border-box; }
            html { scroll-behavior: smooth; }
            body {
              margin: 0;
              padding: 30px 34px 48px;
              background: transparent;
              color: var(--text);
              font: 14px -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
              line-height: 1.62;
              -webkit-font-smoothing: antialiased;
            }
            h1, h2, h3, h4, h5, h6 { scroll-margin-top: 24px; color: var(--text); line-height: 1.22; }
            h1 { font-size: 25px; margin: 0 0 22px; }
            h2 { font-size: 19px; margin: 34px 0 14px; }
            h3 { font-size: 16px; margin: 28px 0 12px; }
            h4 { font-size: 14px; margin: 24px 0 10px; }
            h5, h6 { font-size: 13px; margin: 20px 0 9px; }
            p { margin: 0 0 15px; color: var(--text); }
            ul, ol { margin: 0 0 15px; padding-left: 24px; }
            li { margin: 5px 0; }
            li::marker { color: var(--accent); }
            blockquote { margin: 18px 0; padding: 4px 0 4px 13px; border-left: 3px solid var(--accent); color: var(--secondary); font-style: italic; }
            pre { margin: 18px 0; padding: 13px; overflow-x: auto; border: 1px solid var(--border); border-radius: 10px; background: var(--surface); }
            code { font: 12.5px "SF Mono", Menlo, monospace; }
            p code, li code { padding: 2px 4px; border-radius: 4px; background: var(--surface); }
            hr { border: 0; border-top: 1px solid var(--border); margin: 22px 0; }
          </style>
        </head>
        <body>
        \(body)
        <script>\(MarkdownPreviewOutlineBridge.observationScript)</script>
        </body>
        </html>
        """
    }

    private static func render(_ block: MarkdownBlock) -> String {
        switch block {
        case let .heading(level, text):
            return "<h\(level)>\(inline(text))</h\(level)>"
        case let .paragraph(text):
            return "<p>\(inline(text))</p>"
        case let .unorderedItem(text):
            return "<ul><li>\(inline(text))</li></ul>"
        case let .orderedItem(number, text):
            return "<ol start=\"\(number)\"><li>\(inline(text))</li></ol>"
        case let .quote(text):
            return "<blockquote>\(inline(text))</blockquote>"
        case let .code(language, source):
            let className = language.isEmpty ? "" : " class=\"language-\(escapeAttribute(language))\""
            return "<pre><code\(className)>\(escapeHTML(source))</code></pre>"
        case .divider:
            return "<hr>"
        }
    }

    private static func inline(_ value: String) -> String {
        var rendered = escapeHTML(value)
        rendered = replacing("\\*\\*(.+?)\\*\\*", in: rendered, with: "<strong>$1</strong>")
        rendered = replacing("`([^`]+)`", in: rendered, with: "<code>$1</code>")
        rendered = replacing("(?<!\\*)\\*([^*]+)\\*(?!\\*)", in: rendered, with: "<em>$1</em>")
        return rendered
    }

    private static func escapeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static func escapeAttribute(_ value: String) -> String {
        escapeHTML(value)
    }

    private static func replacing(_ pattern: String, in value: String, with template: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return value }
        let range = NSRange(value.startIndex..., in: value)
        return expression.stringByReplacingMatches(in: value, range: range, withTemplate: template)
    }
}
