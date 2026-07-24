import AppKit
import FinderSync
import OSLog
import SuperRightFeature

final class FinderSync: FIFinderSync, @unchecked Sendable {
    private static let logger = Logger(
        subsystem: "me.touch.launcher.FinderExtension",
        category: "FinderSync"
    )

    private let snapshotStore = SuperRightConfigurationSnapshotStore()
    private let actionDispatcher = FinderActionDispatcher()

    override init() {
        super.init()
        let monitoredURLs = SuperRightFeaturePlugin.monitoredDirectoryURLs
        FIFinderSyncController.default().directoryURLs = monitoredURLs
        let paths = monitoredURLs.map(\.path).joined(separator: ", ")
        Self.logger.notice("FinderSync 已初始化，监控目录：\(paths, privacy: .public)")
        NSLog("[SuperRight] FinderSync 已初始化，监控目录：%@", paths)
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
        let target = targetedURL?.path ?? "nil"
        let selected = selectedURLs.map(\.path).joined(separator: ", ")
        Self.logger.notice(
            "收到 Finder 菜单请求，kind=\(menuKind.rawValue), target=\(target, privacy: .public), selected=\(selected, privacy: .public)"
        )

        let configuration = loadConfiguration()
        let descriptors = FinderMenuBuilder(configuration: configuration).build(
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
            Self.logger.error("读取超级右键配置失败，使用默认配置：\(error.localizedDescription, privacy: .public)")
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
            Self.logger.error("新建文件失败：无法根据菜单项恢复格式或目标目录，菜单项=\(title, privacy: .public)")
            NSSound.beep()
            return
        }

        Task { [weak self] in
            guard let self else { return }
            let result = await actionDispatcher.createFile(in: directory, format: format)
            await MainActor.run {
                switch result {
                case let .success(createdURL):
                    Self.logger.info("已新建文件：\(createdURL.path, privacy: .public)")
                case let .failure(error):
                    NSSound.beep()
                    Self.logger.error("执行“\(title, privacy: .public)”失败：\(error.localizedDescription, privacy: .public)")
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
                case let .success(createdURL):
                    Self.logger.info("已新建文件夹：\(createdURL.path, privacy: .public)")
                case let .failure(error):
                    NSSound.beep()
                    Self.logger.error("执行“新建文件夹”失败：\(error.localizedDescription, privacy: .public)")
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
                case let .success(bundleIdentifier):
                    Self.logger.info("已请求终端打开目录：\(directory.path, privacy: .public)，应用=\(bundleIdentifier, privacy: .public)")
                case let .failure(error):
                    NSSound.beep()
                    Self.logger.error("执行“在终端中打开”失败：\(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    @IBAction nonisolated func cut(_ sender: Any?) {
        Task { @MainActor in
            NSSound.beep()
            Self.logger.warning("剪切入口已配置，但安全移动服务尚未接通")
        }
    }

    private func copyPaths(_ urls: [URL]) {
        let paths = urls.map(\.path).joined(separator: "\n")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(paths, forType: .string)
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
