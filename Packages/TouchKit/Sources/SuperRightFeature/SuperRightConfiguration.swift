import Foundation

public enum SuperRightActionID: String, Codable, CaseIterable, Sendable {
    case newFile
    case newFolder
    case cut
    case copyPath
    case openTerminal
}

public struct SuperRightActionConfiguration: Codable, Equatable, Identifiable, Sendable {
    public let id: SuperRightActionID
    public var isEnabled: Bool

    public init(id: SuperRightActionID, isEnabled: Bool = true) {
        self.id = id
        self.isEnabled = isEnabled
    }
}

public struct NewFileFormatDefinition: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var displayName: String
    public var fileExtension: String
    public var initialContent: String?
    public var isEnabled: Bool
    public let isBuiltIn: Bool

    public init(
        id: String,
        displayName: String,
        fileExtension: String,
        initialContent: String? = nil,
        isEnabled: Bool = true,
        isBuiltIn: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.fileExtension = fileExtension
        self.initialContent = initialContent
        self.isEnabled = isEnabled
        self.isBuiltIn = isBuiltIn
    }
}

public struct SuperRightFeatureConfiguration: Codable, Equatable, Sendable {
    public static let defaultTerminalBundleIdentifier = "com.apple.Terminal"

    public var actions: [SuperRightActionConfiguration]
    public var fileFormats: [NewFileFormatDefinition]
    public var terminalBundleIdentifier: String

    public init(
        actions: [SuperRightActionConfiguration] = Self.defaultActions,
        fileFormats: [NewFileFormatDefinition] = Self.defaultFileFormats,
        terminalBundleIdentifier: String = Self.defaultTerminalBundleIdentifier
    ) {
        self.actions = actions
        self.fileFormats = fileFormats
        self.terminalBundleIdentifier = terminalBundleIdentifier
    }

    public func action(_ id: SuperRightActionID) -> SuperRightActionConfiguration? {
        actions.first { $0.id == id }
    }

    public static let defaultActions = SuperRightActionID.allCases.map {
        SuperRightActionConfiguration(id: $0)
    }

    public static let defaultFileFormats: [NewFileFormatDefinition] = [
        .init(id: "txt", displayName: "纯文本", fileExtension: "txt", isBuiltIn: true),
        .init(id: "markdown", displayName: "Markdown", fileExtension: "md", isBuiltIn: true),
        .init(id: "rtf", displayName: "RTF", fileExtension: "rtf", isBuiltIn: true),
        .init(id: "json", displayName: "JSON", fileExtension: "json", initialContent: "{}\n", isBuiltIn: true),
        .init(id: "xml", displayName: "XML", fileExtension: "xml", isBuiltIn: true),
        .init(id: "yaml", displayName: "YAML", fileExtension: "yaml", isBuiltIn: true),
        .init(id: "csv", displayName: "CSV", fileExtension: "csv", isBuiltIn: true),
        .init(id: "html", displayName: "HTML", fileExtension: "html", isBuiltIn: true),
        .init(id: "swift", displayName: "Swift", fileExtension: "swift", isBuiltIn: true),
        .init(id: "python", displayName: "Python", fileExtension: "py", isBuiltIn: true)
    ]
}

public struct FinderMenuContext: Equatable, Sendable {
    public let targetedURL: URL?
    public let selectedURLs: [URL]

    public init(targetedURL: URL?, selectedURLs: [URL]) {
        self.targetedURL = targetedURL
        self.selectedURLs = selectedURLs
    }
}

public enum FinderMenuCommand: Equatable, Sendable {
    case newFile(format: NewFileFormatDefinition, directory: URL)
    case newFolder(directory: URL)
    case cut(urls: [URL])
    case pasteMove(snapshot: MoveClipboardSnapshot, destination: URL)
    case copyPath(urls: [URL])
    case openTerminal(directory: URL, bundleIdentifier: String)
}

public struct FinderMenuItemDescriptor: Equatable, Sendable {
    public let title: String
    public let symbolName: String
    public let command: FinderMenuCommand?
    public let children: [FinderMenuItemDescriptor]
    public let isEnabled: Bool

    public init(
        title: String,
        symbolName: String,
        command: FinderMenuCommand? = nil,
        children: [FinderMenuItemDescriptor] = [],
        isEnabled: Bool = true
    ) {
        self.title = title
        self.symbolName = symbolName
        self.command = command
        self.children = children
        self.isEnabled = isEnabled
    }
}

public struct FinderMenuBuilder: Sendable {
    private let configuration: SuperRightFeatureConfiguration
    private let pendingMove: MoveClipboardSnapshot?

    public init(
        configuration: SuperRightFeatureConfiguration,
        pendingMove: MoveClipboardSnapshot? = nil
    ) {
        self.configuration = configuration
        self.pendingMove = pendingMove
    }

    public func build(for context: FinderMenuContext) -> [FinderMenuItemDescriptor] {
        let selectedURLs = context.selectedURLs.filter(\.isFileURL)
        let targetedURL = context.targetedURL.flatMap { $0.isFileURL ? $0 : nil }
        guard !selectedURLs.isEmpty || targetedURL != nil else { return [] }

        let singleSelection = selectedURLs.count == 1 ? selectedURLs[0] : nil
        let singleDirectory = singleSelection.flatMap { isDirectory($0) ? $0 : nil }
        let creationDirectory: URL? = if selectedURLs.isEmpty {
            targetedURL.flatMap(directoryURL(for:))
        } else {
            singleDirectory
        }
        let copyURLs = selectedURLs.isEmpty ? targetedURL.map { [$0] } ?? [] : selectedURLs
        let terminalDirectory = workingDirectory(
            targetedURL: targetedURL,
            selectedURLs: selectedURLs
        )
        let pasteDestination = pasteDestination(
            targetedURL: targetedURL,
            selectedURLs: selectedURLs
        )

        var items: [FinderMenuItemDescriptor] = []
        for action in configuration.actions where action.isEnabled {
            switch action.id {
            case .newFile:
                guard let creationDirectory else { continue }
                let formats = configuration.fileFormats.filter(\.isEnabled)
                let children = formats.map { format in
                    FinderMenuItemDescriptor(
                        title: format.displayName,
                        symbolName: "doc",
                        command: .newFile(format: format, directory: creationDirectory)
                    )
                }
                if children.isEmpty {
                    items.append(
                        .init(
                            title: "新建文件",
                            symbolName: "doc.badge.plus",
                            children: [
                                .init(
                                    title: "请先在设置中启用文件格式",
                                    symbolName: "exclamationmark.circle",
                                    isEnabled: false
                                )
                            ]
                        )
                    )
                } else {
                    items.append(
                        .init(
                            title: "新建文件",
                            symbolName: "doc.badge.plus",
                            children: children
                        )
                    )
                }
            case .newFolder:
                guard let creationDirectory else { continue }
                items.append(
                    .init(
                        title: "新建文件夹",
                        symbolName: "folder.badge.plus",
                        command: .newFolder(directory: creationDirectory)
                    )
                )
            case .cut:
                if !selectedURLs.isEmpty {
                    items.append(
                        .init(
                            title: "剪切",
                            symbolName: "scissors",
                            command: .cut(urls: selectedURLs)
                        )
                    )
                }
                if let pendingMove,
                   let pasteDestination,
                   canPaste(pendingMove, into: pasteDestination) {
                    items.append(
                        .init(
                            title: "粘贴到此处",
                            symbolName: "clipboard",
                            command: .pasteMove(
                                snapshot: pendingMove,
                                destination: pasteDestination
                            )
                        )
                    )
                }
            case .copyPath:
                guard !copyURLs.isEmpty else { continue }
                items.append(
                    .init(
                        title: "复制路径",
                        symbolName: "link",
                        command: .copyPath(urls: copyURLs)
                    )
                )
            case .openTerminal:
                guard let terminalDirectory else { continue }
                items.append(
                    .init(
                        title: "在终端中打开",
                        symbolName: "terminal",
                        command: .openTerminal(
                            directory: terminalDirectory,
                            bundleIdentifier: configuration.terminalBundleIdentifier
                        )
                    )
                )
            }
        }
        return items
    }

    private func workingDirectory(targetedURL: URL?, selectedURLs: [URL]) -> URL? {
        switch selectedURLs.count {
        case 0:
            return targetedURL.flatMap(directoryURL(for:))
        case 1:
            return directoryURL(for: selectedURLs[0])
        default:
            let parents = selectedURLs.map { $0.deletingLastPathComponent().standardizedFileURL }
            guard let first = parents.first, parents.dropFirst().allSatisfy({ $0 == first }) else {
                return nil
            }
            return first
        }
    }

    private func directoryURL(for url: URL) -> URL {
        isDirectory(url) ? url : url.deletingLastPathComponent()
    }

    private func pasteDestination(
        targetedURL: URL?,
        selectedURLs: [URL]
    ) -> URL? {
        if selectedURLs.isEmpty {
            guard let targetedURL, isDirectory(targetedURL) else { return nil }
            return targetedURL.standardizedFileURL
        }
        guard selectedURLs.count == 1,
              let selectedURL = selectedURLs.first,
              isDirectory(selectedURL) else {
            return nil
        }
        return selectedURL.standardizedFileURL
    }

    private func canPaste(_ snapshot: MoveClipboardSnapshot, into destination: URL) -> Bool {
        snapshot.items.allSatisfy { item in
            let source = item.url.standardizedFileURL
            guard item.isDirectory else { return source != destination }
            return destination != source && !destination.path.hasPrefix(source.path + "/")
        }
    }

    private func isDirectory(_ url: URL) -> Bool {
        var value = ObjCBool(false)
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &value) && value.boolValue
    }
}

public struct TerminalApplicationDefinition: Identifiable, Equatable, Sendable {
    public let bundleIdentifier: String
    public let displayName: String

    public var id: String { bundleIdentifier }

    public init(bundleIdentifier: String, displayName: String) {
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
    }
}

public enum TerminalApplicationCatalog {
    public static let candidates: [TerminalApplicationDefinition] = [
        .init(bundleIdentifier: "com.apple.Terminal", displayName: "Terminal"),
        .init(bundleIdentifier: "com.googlecode.iterm2", displayName: "iTerm2"),
        .init(bundleIdentifier: "dev.warp.Warp-Stable", displayName: "Warp"),
        .init(bundleIdentifier: "com.mitchellh.ghostty", displayName: "Ghostty"),
        .init(bundleIdentifier: "com.github.wez.wezterm", displayName: "WezTerm"),
        .init(bundleIdentifier: "org.alacritty", displayName: "Alacritty"),
        .init(bundleIdentifier: "net.kovidgoyal.kitty", displayName: "kitty")
    ]

    public static func resolveBundleIdentifier(
        preferred: String,
        isInstalled: (String) -> Bool
    ) -> String {
        if isInstalled(preferred) {
            return preferred
        }
        if isInstalled(SuperRightFeatureConfiguration.defaultTerminalBundleIdentifier) {
            return SuperRightFeatureConfiguration.defaultTerminalBundleIdentifier
        }
        return candidates.first(where: { isInstalled($0.bundleIdentifier) })?.bundleIdentifier
            ?? SuperRightFeatureConfiguration.defaultTerminalBundleIdentifier
    }
}

public struct SuperRightConfigurationSnapshotStore: Sendable {
    public static let finderExtensionBundleIdentifier = "me.touch.launcher.FinderExtension"

    public let url: URL

    public init(url: URL = Self.defaultURL) {
        self.url = url
    }

    public func load() throws -> SuperRightFeatureConfiguration? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let envelope = try JSONDecoder().decode(
            SnapshotEnvelope.self,
            from: Data(contentsOf: url)
        )
        guard envelope.schemaVersion == SuperRightConfigurationRepository.schemaVersion else {
            return nil
        }
        return envelope.configuration
    }

    public func save(_ configuration: SuperRightFeatureConfiguration) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(
            SnapshotEnvelope(
                schemaVersion: SuperRightConfigurationRepository.schemaVersion,
                configuration: configuration
            )
        )
        try data.write(to: url, options: .atomic)
    }

    public static var defaultURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        let containerSuffix = "/Library/Containers/\(finderExtensionBundleIdentifier)/Data"
        let containerRoot: URL
        if home.path.hasSuffix(containerSuffix) {
            containerRoot = home
        } else {
            containerRoot = home
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Containers", isDirectory: true)
                .appendingPathComponent(finderExtensionBundleIdentifier, isDirectory: true)
                .appendingPathComponent("Data", isDirectory: true)
        }
        return containerRoot
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("一念", isDirectory: true)
            .appendingPathComponent("SuperRight", isDirectory: true)
            .appendingPathComponent("configuration.json")
    }
}

private struct SnapshotEnvelope: Codable {
    let schemaVersion: Int
    let configuration: SuperRightFeatureConfiguration
}

public struct SuperRightFileCreator: Sendable {
    public init() {}

    public func createFile(
        in directory: URL,
        format: NewFileFormatDefinition
    ) throws -> URL {
        let fileExtension = normalizedExtension(format.fileExtension)
        let data = Data((format.initialContent ?? "").utf8)
        for index in 1...10_000 {
            let baseName = index == 1 ? "未命名" : "未命名 \(index)"
            let fileName = fileExtension.isEmpty ? baseName : "\(baseName).\(fileExtension)"
            let destination = directory.appendingPathComponent(fileName, isDirectory: false)
            do {
                try data.write(to: destination, options: .withoutOverwriting)
                return destination
            } catch CocoaError.fileWriteFileExists {
                continue
            }
        }
        throw CocoaError(.fileWriteUnknown)
    }

    public func createFolder(in directory: URL) throws -> URL {
        for index in 1...10_000 {
            let name = index == 1 ? "未命名文件夹" : "未命名文件夹 \(index)"
            let destination = directory.appendingPathComponent(name, isDirectory: true)
            do {
                try FileManager.default.createDirectory(
                    at: destination,
                    withIntermediateDirectories: false
                )
                return destination
            } catch CocoaError.fileWriteFileExists {
                continue
            }
        }
        throw CocoaError(.fileWriteUnknown)
    }

    private func normalizedExtension(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }
}
