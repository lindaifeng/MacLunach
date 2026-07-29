import AppKit
import FileActionServiceProtocol
import FinderSync
import OSLog
import SuperRightFeature

final class FinderSync: FIFinderSync, @unchecked Sendable {
    private static let logger = Logger(
        subsystem: "me.touch.launcher.FinderExtension",
        category: "FinderSync"
    )

    private let snapshotStore = SuperRightConfigurationSnapshotStore()
    private let moveClipboardStore = MoveClipboardStore()
    private let moveConflictRequestStore = MoveConflictRequestStore()
    private let actionDispatcher = FinderActionDispatcher()

    override init() {
        super.init()
        let monitoredURLs = SuperRightFeaturePlugin.monitoredDirectoryURLs
        FIFinderSyncController.default().directoryURLs = monitoredURLs
        Self.logger.notice("FinderSync 已初始化")
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        switch menuKind {
        case .contextualMenuForItems, .contextualMenuForContainer, .contextualMenuForSidebar:
            break
        default:
            return nil
        }

        let controller = FIFinderSyncController.default()
        let targetedURL = controller.targetedURL()
        let selectedURLs = controller.selectedItemURLs() ?? []
        Self.logger.notice("收到 Finder 菜单请求")

        let configuration = loadConfiguration()
        let descriptors = FinderMenuBuilder(
            configuration: configuration,
            pendingMove: loadPendingMove()
        ).build(
            for: .init(targetedURL: targetedURL, selectedURLs: selectedURLs)
        )
        guard !descriptors.isEmpty else { return nil }

        let menu = NSMenu(title: "超级右键")
        for descriptor in descriptors {
            menu.addItem(makeMenuItem(from: descriptor))
        }
        return menu
    }

    private func loadConfiguration() -> SuperRightFeatureConfiguration {
        do {
            return try snapshotStore.load() ?? .init()
        } catch {
            Self.logger.error("读取超级右键配置失败，使用默认配置")
            return .init()
        }
    }

    private func makeMenuItem(from descriptor: FinderMenuItemDescriptor) -> NSMenuItem {
        let action: Selector? = switch descriptor.command {
        case .newFile:
            #selector(createFile(_:))
        case .newFolder:
            #selector(createFolder(_:))
        case .cut:
            #selector(cut(_:))
        case .pasteMove:
            #selector(pasteMove(_:))
        case .copyPath:
            #selector(copyPath(_:))
        case .openTerminal:
            #selector(openTerminal(_:))
        case nil:
            nil
        }
        let item = NSMenuItem(
            title: descriptor.title,
            action: action,
            keyEquivalent: ""
        )
        // Finder 会跨进程复制扩展提供的菜单项。显式绑定当前 Finder Sync 实例，
        // 否则 Finder 会过滤没有可执行目标的扩展菜单项。
        item.target = self
        item.isEnabled = descriptor.isEnabled
        item.image = NSImage(systemSymbolName: descriptor.symbolName, accessibilityDescription: descriptor.title)

        if !descriptor.children.isEmpty {
            let submenu = NSMenu(title: descriptor.title)
            for child in descriptor.children {
                submenu.addItem(makeMenuItem(from: child))
            }
            item.submenu = submenu
        }
        return item
    }

    // Finder 会跨进程复制扩展返回的 NSMenuItem，不能依赖 representedObject 携带自定义对象。
    // 每个动作使用独立 selector，并在执行时重新读取 Finder 当前上下文和最新配置。
    @IBAction nonisolated func createFile(_ sender: Any?) {
        // Finder 从 XPC 工作队列调用 selector；先提取可发送的值，再切回主执行器。
        let title = (sender as? NSObject)?.value(forKey: "title") as? String ?? ""
        let context = Self.captureFinderContext()
        Task { @MainActor [weak self] in
            self?.performCreateFile(title: title, context: context)
        }
    }

    private func performCreateFile(title: String, context: FinderMenuContext) {
        guard let format = loadConfiguration().fileFormats.first(where: {
            $0.isEnabled && $0.displayName == title
        }), let directory = creationDirectory(for: context) else {
            Self.logger.error("新建文件失败：无法恢复格式或目标目录")
            NSSound.beep()
            return
        }

        Task { [weak self] in
            guard let self else { return }
            let result = await actionDispatcher.createFile(in: directory, format: format)
            await MainActor.run {
                switch result {
                case .success:
                    Self.logger.info("已新建文件")
                case .failure:
                    NSSound.beep()
                    Self.logger.error("新建文件动作失败")
                }
            }
        }
    }

    @IBAction nonisolated func createFolder(_ sender: Any?) {
        let context = Self.captureFinderContext()
        Task { @MainActor [weak self] in
            self?.performCreateFolder(context: context)
        }
    }

    private func performCreateFolder(context: FinderMenuContext) {
        guard let directory = creationDirectory(for: context) else {
            Self.logger.error("新建文件夹失败：无法恢复目标目录")
            NSSound.beep()
            return
        }

        Task { [weak self] in
            guard let self else { return }
            let result = await actionDispatcher.createFolder(in: directory)
            await MainActor.run {
                switch result {
                case .success:
                    Self.logger.info("已新建文件夹")
                case .failure:
                    NSSound.beep()
                    Self.logger.error("新建文件夹动作失败")
                }
            }
        }
    }

    @IBAction nonisolated func copyPath(_ sender: Any?) {
        let context = Self.captureFinderContext()
        Task { @MainActor [weak self] in
            self?.performCopyPath(context: context)
        }
    }

    private func performCopyPath(context: FinderMenuContext) {
        let urls = context.selectedURLs.isEmpty
            ? context.targetedURL.map { [$0] } ?? []
            : context.selectedURLs
        guard !urls.isEmpty else {
            Self.logger.error("复制路径失败：Finder 没有提供目标或选中项目")
            NSSound.beep()
            return
        }

        copyPaths(urls)
        Self.logger.info("已复制 \(urls.count) 个路径")
    }

    @IBAction nonisolated func openTerminal(_ sender: Any?) {
        let context = Self.captureFinderContext()
        Task { @MainActor [weak self] in
            self?.performOpenTerminal(context: context)
        }
    }

    private func performOpenTerminal(context: FinderMenuContext) {
        guard let directory = workingDirectory(for: context) else {
            Self.logger.error("打开终端失败：无法恢复工作目录")
            NSSound.beep()
            return
        }
        let preferredBundleIdentifier = loadConfiguration().terminalBundleIdentifier

        Task { [weak self] in
            guard let self else { return }
            let result = await actionDispatcher.openTerminal(
                at: directory,
                preferredBundleIdentifier: preferredBundleIdentifier
            )
            await MainActor.run {
                switch result {
                case .success:
                    Self.logger.info("已请求终端打开目录")
                case .failure:
                    NSSound.beep()
                    Self.logger.error("在终端中打开动作失败")
                }
            }
        }
    }

    @IBAction nonisolated func cut(_ sender: Any?) {
        let context = Self.captureFinderContext()
        Task { @MainActor [weak self] in
            self?.performCut(context: context)
        }
    }

    private func performCut(context: FinderMenuContext) {
        let urls = context.selectedURLs.filter(\.isFileURL)
        guard !urls.isEmpty else {
            Self.logger.error("剪切失败：Finder 没有提供选中的本地项目")
            NSSound.beep()
            return
        }
        do {
            try moveClipboardStore.save(try MoveClipboardSnapshot.capture(urls: urls))
            Self.logger.info("已暂存 \(urls.count) 个待移动项目")
        } catch {
            NSSound.beep()
            Self.logger.error("剪切状态保存失败")
        }
    }

    @IBAction nonisolated func pasteMove(_ sender: Any?) {
        let context = Self.captureFinderContext()
        Task { @MainActor [weak self] in
            self?.performPasteMove(context: context)
        }
    }

    private func performPasteMove(context: FinderMenuContext) {
        guard let destination = pasteDestination(for: context) else {
            Self.logger.error("粘贴失败：目标不是文件夹")
            NSSound.beep()
            return
        }
        let snapshot: MoveClipboardSnapshot
        do {
            guard let loaded = try moveClipboardStore.loadValid() else {
                NSSound.beep()
                return
            }
            snapshot = loaded
        } catch {
            try? moveClipboardStore.clear()
            NSSound.beep()
            Self.logger.error("粘贴失败：剪切状态已失效")
            return
        }

        Task { [weak self] in
            guard let self else { return }
            let result = await actionDispatcher.move(
                sources: snapshot.items.map(\.url),
                destination: destination,
                conflictPolicy: .prompt
            )
            await MainActor.run {
                switch result {
                case let .success(move) where !move.conflicts.isEmpty:
                    let request = MoveConflictRequest(
                        snapshot: snapshot,
                        destination: destination,
                        conflicts: move.conflicts
                    )
                    do {
                        try moveConflictRequestStore.save(request)
                        FileActionServiceRelay.requestHostAttention()
                        Self.logger.notice("移动存在同名冲突，已交给主应用请求用户选择")
                    } catch {
                        NSSound.beep()
                        Self.logger.error("无法保存移动冲突请求")
                    }
                case let .success(move):
                    finishMove(snapshot: snapshot, result: move)
                case .failure:
                    NSSound.beep()
                    Self.logger.error("粘贴移动动作失败")
                }
            }
        }
    }

    private func copyPaths(_ urls: [URL]) {
        let paths = urls.map(\.path).joined(separator: "\n")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(paths, forType: .string)
    }

    private func loadPendingMove() -> MoveClipboardSnapshot? {
        do {
            return try moveClipboardStore.loadValid()
        } catch {
            try? moveClipboardStore.clear()
            Self.logger.warning("已清除失效的剪切状态")
            return nil
        }
    }

    private func finishMove(snapshot: MoveClipboardSnapshot, result: FileActionServiceMoveResult) {
        let remaining = Set(result.skippedSourceURLs.map(\.standardizedFileURL))
            .union(result.failedItems.map(\.sourceURL).map(\.standardizedFileURL))
        guard !remaining.isEmpty else {
            try? moveClipboardStore.clear()
            return
        }
        let items = snapshot.items.filter { remaining.contains($0.url.standardizedFileURL) }
        guard !items.isEmpty else {
            try? moveClipboardStore.clear()
            return
        }
        try? moveClipboardStore.save(.init(
            items: items,
            createdAt: snapshot.createdAt,
            expiresAt: snapshot.expiresAt
        ))
    }

    nonisolated private static func captureFinderContext() -> FinderMenuContext {
        let controller = FIFinderSyncController.default()
        return FinderMenuContext(
            targetedURL: controller.targetedURL(),
            selectedURLs: controller.selectedItemURLs() ?? []
        )
    }

    private func creationDirectory(for context: FinderMenuContext) -> URL? {
        if context.selectedURLs.isEmpty {
            return context.targetedURL.flatMap(directoryURL(for:))
        }
        guard context.selectedURLs.count == 1 else { return nil }
        return directoryURL(for: context.selectedURLs[0])
    }

    private func pasteDestination(for context: FinderMenuContext) -> URL? {
        if context.selectedURLs.isEmpty {
            guard let targetedURL = context.targetedURL else { return nil }
            var isDirectory = ObjCBool(false)
            guard FileManager.default.fileExists(atPath: targetedURL.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                return nil
            }
            return targetedURL.standardizedFileURL
        }
        guard context.selectedURLs.count == 1,
              let selectedURL = context.selectedURLs.first else {
            return nil
        }
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: selectedURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }
        return selectedURL.standardizedFileURL
    }

    private func workingDirectory(for context: FinderMenuContext) -> URL? {
        switch context.selectedURLs.count {
        case 0:
            return context.targetedURL.flatMap(directoryURL(for:))
        case 1:
            return directoryURL(for: context.selectedURLs[0])
        default:
            let parents = context.selectedURLs.map {
                $0.deletingLastPathComponent().standardizedFileURL
            }
            guard let first = parents.first,
                  parents.dropFirst().allSatisfy({ $0 == first }) else {
                return nil
            }
            return first
        }
    }

    private func directoryURL(for url: URL) -> URL {
        var isDirectory = ObjCBool(false)
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return url
        }
        return url.deletingLastPathComponent()
    }
}
