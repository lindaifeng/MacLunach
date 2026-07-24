import Foundation

public enum FileActionServiceProtocolVersion {
    public static let current = 2
}

/// Finder 扩展交给文件动作服务执行的受控请求。
///
/// 使用稳定的 `name` + 可选参数结构，而不是把 Finder 侧的业务模型直接带进
/// XPC，这样协议仍然可以被独立的 XPC target 使用，也方便后续增加动作。
public struct FileActionServiceAction: Codable, Equatable, Sendable {
    public let name: String
    public let directory: URL?
    public let displayName: String?
    public let fileExtension: String?
    public let initialContent: String?
    public let preferredBundleIdentifier: String?

    public init(
        name: String,
        directory: URL? = nil,
        displayName: String? = nil,
        fileExtension: String? = nil,
        initialContent: String? = nil,
        preferredBundleIdentifier: String? = nil
    ) {
        self.name = name
        self.directory = directory
        self.displayName = displayName
        self.fileExtension = fileExtension
        self.initialContent = initialContent
        self.preferredBundleIdentifier = preferredBundleIdentifier
    }

    public static let ping = FileActionServiceAction(name: "ping")

    public static func createFile(
        directory: URL,
        displayName: String,
        fileExtension: String,
        initialContent: String?
    ) -> Self {
        .init(
            name: "createFile",
            directory: directory,
            displayName: displayName,
            fileExtension: fileExtension,
            initialContent: initialContent
        )
    }

    public static func createFolder(directory: URL) -> Self {
        .init(name: "createFolder", directory: directory)
    }

    public static func openTerminal(
        directory: URL,
        preferredBundleIdentifier: String
    ) -> Self {
        .init(
            name: "openTerminal",
            directory: directory,
            preferredBundleIdentifier: preferredBundleIdentifier
        )
    }
}

public struct FileActionServicePong: Codable, Equatable, Sendable {
    public let processID: Int32
    public let timestamp: Date

    public init(processID: Int32, timestamp: Date) {
        self.processID = processID
        self.timestamp = timestamp
    }
}

public struct FileActionServiceActionResult: Codable, Equatable, Sendable {
    public let createdURL: URL?
    public let openedApplicationBundleIdentifier: String?

    public init(
        createdURL: URL? = nil,
        openedApplicationBundleIdentifier: String? = nil
    ) {
        self.createdURL = createdURL
        self.openedApplicationBundleIdentifier = openedApplicationBundleIdentifier
    }
}

public enum FileActionServiceFailure: Error, Codable, Equatable, Sendable {
    case incompatibleProtocol(expected: Int, received: Int)
    case unsupportedAction(String)
    case malformedRequest(String)
    case internalFailure(String)
}
