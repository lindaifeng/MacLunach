import FileActionServiceProtocol
import Foundation

public enum MoveClipboardError: Error, Equatable, Sendable {
    case emptySelection
    case invalidSource(URL)
    case unsupportedVersion(Int)
    case expired
    case sourceMissing(URL)
    case sourceChanged(URL)
}

public struct MoveClipboardItem: Codable, Equatable, Sendable {
    public let url: URL
    public let resourceIdentifier: String
    public let isDirectory: Bool

    public init(url: URL, resourceIdentifier: String, isDirectory: Bool) {
        self.url = url.standardizedFileURL
        self.resourceIdentifier = resourceIdentifier
        self.isDirectory = isDirectory
    }
}

public struct MoveClipboardSnapshot: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let items: [MoveClipboardItem]
    public let createdAt: Date
    public let expiresAt: Date

    public init(
        version: Int = Self.currentVersion,
        items: [MoveClipboardItem],
        createdAt: Date,
        expiresAt: Date
    ) {
        self.version = version
        self.items = items
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }

    public static func capture(
        urls: [URL],
        now: Date = .now,
        lifetime: TimeInterval = 3_600
    ) throws -> Self {
        let uniqueURLs = Array(Set(urls.map(\.standardizedFileURL))).sorted { $0.path < $1.path }
        guard !uniqueURLs.isEmpty else { throw MoveClipboardError.emptySelection }

        let items = try uniqueURLs.map { url in
            let values = try url.resourceValues(forKeys: [.fileResourceIdentifierKey, .isDirectoryKey])
            guard let identifier = values.fileResourceIdentifier else {
                throw MoveClipboardError.invalidSource(url)
            }
            return MoveClipboardItem(
                url: url,
                resourceIdentifier: String(describing: identifier),
                isDirectory: values.isDirectory ?? false
            )
        }
        return .init(items: items, createdAt: now, expiresAt: now.addingTimeInterval(lifetime))
    }
}

public struct MoveClipboardStore: Sendable {
    public let url: URL

    public init(url: URL = Self.defaultURL) {
        self.url = url
    }

    public func save(_ snapshot: MoveClipboardSnapshot) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
    }

    public func loadValid(now: Date = .now) throws -> MoveClipboardSnapshot? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let snapshot = try JSONDecoder().decode(MoveClipboardSnapshot.self, from: Data(contentsOf: url))
        guard snapshot.version == MoveClipboardSnapshot.currentVersion else {
            throw MoveClipboardError.unsupportedVersion(snapshot.version)
        }
        guard !snapshot.items.isEmpty else { throw MoveClipboardError.emptySelection }
        guard now < snapshot.expiresAt else { throw MoveClipboardError.expired }

        for item in snapshot.items {
            let source = item.url.standardizedFileURL
            guard FileManager.default.fileExists(atPath: source.path) else {
                throw MoveClipboardError.sourceMissing(source)
            }
            let values = try source.resourceValues(forKeys: [.fileResourceIdentifierKey])
            guard let identifier = values.fileResourceIdentifier,
                  String(describing: identifier) == item.resourceIdentifier else {
                throw MoveClipboardError.sourceChanged(source)
            }
        }
        return snapshot
    }

    public func clear() throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    public static var defaultURL: URL {
        SuperRightConfigurationSnapshotStore.defaultURL
            .deletingLastPathComponent()
            .appendingPathComponent("move-clipboard.json", isDirectory: false)
    }
}

/// Finder 扩展发现同名冲突后交给主应用展示决策窗口的持久化请求。
public struct MoveConflictRequest: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let id: UUID
    public let snapshot: MoveClipboardSnapshot
    public let destination: URL
    public let conflicts: [FileActionServiceMoveConflict]
    public let createdAt: Date
    public let expiresAt: Date

    public init(
        version: Int = Self.currentVersion,
        id: UUID = UUID(),
        snapshot: MoveClipboardSnapshot,
        destination: URL,
        conflicts: [FileActionServiceMoveConflict],
        createdAt: Date = .now,
        expiresAt: Date? = nil
    ) {
        self.version = version
        self.id = id
        self.snapshot = snapshot
        self.destination = destination.standardizedFileURL
        self.conflicts = conflicts
        self.createdAt = createdAt
        self.expiresAt = expiresAt ?? createdAt.addingTimeInterval(300)
    }
}

public struct MoveConflictRequestStore: Sendable {
    public let url: URL

    public init(url: URL = Self.defaultURL) {
        self.url = url
    }

    public func save(_ request: MoveConflictRequest) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(request).write(to: url, options: .atomic)
    }

    public func loadValid(now: Date = .now) throws -> MoveConflictRequest? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let request = try JSONDecoder().decode(MoveConflictRequest.self, from: Data(contentsOf: url))
        guard request.version == MoveConflictRequest.currentVersion else {
            throw MoveClipboardError.unsupportedVersion(request.version)
        }
        guard now < request.expiresAt else { throw MoveClipboardError.expired }
        guard !request.conflicts.isEmpty else { throw MoveClipboardError.emptySelection }
        return request
    }

    public func clear() throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    public static var defaultURL: URL {
        SuperRightConfigurationSnapshotStore.defaultURL
            .deletingLastPathComponent()
            .appendingPathComponent("move-conflict.json", isDirectory: false)
    }
}

public enum MoveConflictResolution: Sendable {
    case skipConflicts
    case keepBoth
}

public enum MoveConflictResolutionError: Error, Equatable, Sendable {
    case clipboardStateChanged
    case unexpectedResponse
}

/// 主应用的冲突窗口通过这个入口再次请求文件服务；不直接在 UI 进程改动文件。
public enum MoveConflictResolutionService {
    public static func resolve(
        _ request: MoveConflictRequest,
        resolution: MoveConflictResolution,
        clipboardStore: MoveClipboardStore = .init(),
        conflictStore: MoveConflictRequestStore = .init()
    ) async throws -> FileActionServiceMoveResult {
        guard let currentSnapshot = try clipboardStore.loadValid(),
              currentSnapshot == request.snapshot else {
            throw MoveConflictResolutionError.clipboardStateChanged
        }
        let policy: FileActionServiceMoveConflictPolicy = switch resolution {
        case .skipConflicts: .skip
        case .keepBoth: .keepBoth
        }
        let actionResult = try await FileActionServiceRelay.perform(action: .move(
            sources: request.snapshot.items.map(\.url),
            destination: request.destination,
            conflictPolicy: policy
        ))
        guard let move = actionResult.move else {
            throw MoveConflictResolutionError.unexpectedResponse
        }

        let remaining = Set(move.skippedSourceURLs.map(\.standardizedFileURL))
            .union(move.failedItems.map(\.sourceURL).map(\.standardizedFileURL))
        let items = request.snapshot.items.filter { remaining.contains($0.url.standardizedFileURL) }
        if items.isEmpty {
            try clipboardStore.clear()
        } else {
            try clipboardStore.save(.init(
                items: items,
                createdAt: request.snapshot.createdAt,
                expiresAt: request.snapshot.expiresAt
            ))
        }
        try conflictStore.clear()
        return move
    }

    public static func cancel(
        conflictStore: MoveConflictRequestStore = .init()
    ) throws {
        try conflictStore.clear()
    }
}
