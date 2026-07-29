import Foundation

public enum FileActionServiceProtocolVersion {
    public static let current = 6
}

public enum FileActionServiceOperationStatus: String, Codable, Equatable, Sendable {
    case running
    case cancelling
    case completed
    case failed
    case cancelled
    case unknown
}

public struct FileActionServiceOperationState: Codable, Equatable, Sendable {
    public let requestID: UUID
    public let status: FileActionServiceOperationStatus
    /// 终态的原始返回值。用于服务重启后对同一请求安全重放，避免重复执行写操作。
    public let terminalResult: FileActionServiceTerminalResult?
    /// 终态失败原因。未知或仍在执行中的状态不携带该字段。
    public let failure: FileActionServiceFailure?

    public init(
        requestID: UUID,
        status: FileActionServiceOperationStatus,
        terminalResult: FileActionServiceTerminalResult? = nil,
        failure: FileActionServiceFailure? = nil
    ) {
        self.requestID = requestID
        self.status = status
        self.terminalResult = terminalResult
        self.failure = failure
    }
}

/// 可持久化的动作终态。它刻意不包含 operationState，避免协议响应出现值类型递归。
public struct FileActionServiceTerminalResult: Codable, Equatable, Sendable {
    public let createdURL: URL?
    public let openedApplicationBundleIdentifier: String?
    public let move: FileActionServiceMoveResult?

    public init(
        createdURL: URL? = nil,
        openedApplicationBundleIdentifier: String? = nil,
        move: FileActionServiceMoveResult? = nil
    ) {
        self.createdURL = createdURL
        self.openedApplicationBundleIdentifier = openedApplicationBundleIdentifier
        self.move = move
    }
}

public enum FileActionServiceMoveConflictPolicy: String, Codable, Equatable, Sendable {
    /// 仅返回冲突项，不修改任何源文件；由主应用请求用户选择后再执行。
    case prompt
    case skip
    case keepBoth
    case cancel
}

public struct FileActionServiceMoveConflict: Codable, Equatable, Sendable {
    public let sourceURL: URL
    public let destinationURL: URL

    public init(sourceURL: URL, destinationURL: URL) {
        self.sourceURL = sourceURL.standardizedFileURL
        self.destinationURL = destinationURL.standardizedFileURL
    }
}

public struct FileActionServiceMovedItem: Codable, Equatable, Sendable {
    public let sourceURL: URL
    public let destinationURL: URL

    public init(sourceURL: URL, destinationURL: URL) {
        self.sourceURL = sourceURL.standardizedFileURL
        self.destinationURL = destinationURL.standardizedFileURL
    }
}

/// 单个来源未能移动时保留的可重试结果。
///
/// 批量移动不能因为一个项目失败而丢失此前已完成的结果；Finder 据此只保留
/// 尚未成功的剪切项目，避免用户重试时重复移动已完成项目。
public struct FileActionServiceMoveFailedItem: Codable, Equatable, Sendable {
    public let sourceURL: URL
    public let message: String

    public init(sourceURL: URL, message: String) {
        self.sourceURL = sourceURL.standardizedFileURL
        self.message = message
    }
}

public struct FileActionServiceMoveResult: Codable, Equatable, Sendable {
    public let movedItems: [FileActionServiceMovedItem]
    public let skippedSourceURLs: [URL]
    public let failedItems: [FileActionServiceMoveFailedItem]
    public let conflicts: [FileActionServiceMoveConflict]

    public init(
        movedItems: [FileActionServiceMovedItem] = [],
        skippedSourceURLs: [URL] = [],
        failedItems: [FileActionServiceMoveFailedItem] = [],
        conflicts: [FileActionServiceMoveConflict] = []
    ) {
        self.movedItems = movedItems
        self.skippedSourceURLs = skippedSourceURLs.map(\.standardizedFileURL)
        self.failedItems = failedItems
        self.conflicts = conflicts
    }

    private enum CodingKeys: String, CodingKey {
        case movedItems
        case skippedSourceURLs
        case failedItems
        case conflicts
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        movedItems = try container.decodeIfPresent(
            [FileActionServiceMovedItem].self,
            forKey: .movedItems
        ) ?? []
        skippedSourceURLs = (try container.decodeIfPresent(
            [URL].self,
            forKey: .skippedSourceURLs
        ))?.map(\.standardizedFileURL) ?? []
        // 版本 3 的已落盘/在途响应没有此字段；把它解释为无失败项，而不是让
        // Finder 将一次已知结果误报成协议损坏。
        failedItems = try container.decodeIfPresent(
            [FileActionServiceMoveFailedItem].self,
            forKey: .failedItems
        ) ?? []
        conflicts = try container.decodeIfPresent(
            [FileActionServiceMoveConflict].self,
            forKey: .conflicts
        ) ?? []
    }
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
    public let sourceURLs: [URL]?
    public let conflictPolicy: FileActionServiceMoveConflictPolicy?
    public let operationRequestID: UUID?

    public init(
        name: String,
        directory: URL? = nil,
        displayName: String? = nil,
        fileExtension: String? = nil,
        initialContent: String? = nil,
        preferredBundleIdentifier: String? = nil,
        sourceURLs: [URL]? = nil,
        conflictPolicy: FileActionServiceMoveConflictPolicy? = nil,
        operationRequestID: UUID? = nil
    ) {
        self.name = name
        self.directory = directory
        self.displayName = displayName
        self.fileExtension = fileExtension
        self.initialContent = initialContent
        self.preferredBundleIdentifier = preferredBundleIdentifier
        self.sourceURLs = sourceURLs?.map(\.standardizedFileURL)
        self.conflictPolicy = conflictPolicy
        self.operationRequestID = operationRequestID
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

    public static func move(
        sources: [URL],
        destination: URL,
        conflictPolicy: FileActionServiceMoveConflictPolicy
    ) -> Self {
        .init(
            name: "move",
            directory: destination,
            sourceURLs: sources,
            conflictPolicy: conflictPolicy
        )
    }

    public static func operationStatus(requestID: UUID) -> Self {
        .init(name: "operationStatus", operationRequestID: requestID)
    }

    public static func cancelOperation(requestID: UUID) -> Self {
        .init(name: "cancelOperation", operationRequestID: requestID)
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
    public let move: FileActionServiceMoveResult?
    public let operationState: FileActionServiceOperationState?

    public init(
        createdURL: URL? = nil,
        openedApplicationBundleIdentifier: String? = nil,
        move: FileActionServiceMoveResult? = nil,
        operationState: FileActionServiceOperationState? = nil
    ) {
        self.createdURL = createdURL
        self.openedApplicationBundleIdentifier = openedApplicationBundleIdentifier
        self.move = move
        self.operationState = operationState
    }

    public init(terminalResult: FileActionServiceTerminalResult) {
        self.init(
            createdURL: terminalResult.createdURL,
            openedApplicationBundleIdentifier: terminalResult.openedApplicationBundleIdentifier,
            move: terminalResult.move
        )
    }

    public var terminalResult: FileActionServiceTerminalResult {
        .init(
            createdURL: createdURL,
            openedApplicationBundleIdentifier: openedApplicationBundleIdentifier,
            move: move
        )
    }
}

public enum FileActionServiceFailure: Error, Codable, Equatable, Sendable {
    case incompatibleProtocol(expected: Int, received: Int)
    case unsupportedAction(String)
    case malformedRequest(String)
    case internalFailure(String)
}
