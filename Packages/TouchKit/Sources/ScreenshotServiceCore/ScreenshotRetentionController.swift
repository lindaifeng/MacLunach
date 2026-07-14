import Foundation
import ScreenshotFeature

public enum ScreenshotRetentionError: Error, Sendable {
    case recordNotFound(UUID)
    case recordIsNotDeleted(UUID)
    case invalidRelativePath(String)
    case fileOperationFailed(String)
}

public protocol ScreenshotHistoryFileOperating: Sendable {
    func createDirectory(at url: URL) throws
    func moveItem(at source: URL, to destination: URL) throws
    func removeItem(at url: URL) throws
    func fileExists(at url: URL) -> Bool
}

public struct LocalScreenshotHistoryFileOperations: ScreenshotHistoryFileOperating, @unchecked Sendable {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func createDirectory(at url: URL) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    public func moveItem(at source: URL, to destination: URL) throws {
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.moveItem(at: source, to: destination)
    }

    public func removeItem(at url: URL) throws {
        try fileManager.removeItem(at: url)
    }

    public func fileExists(at url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
    }
}

public actor ScreenshotRetentionController {
    private struct Move: Sendable {
        let source: URL
        let destination: URL
    }

    private let rootURL: URL
    private let store: ScreenshotHistoryStore
    private let fileOperations: any ScreenshotHistoryFileOperating
    private let now: @Sendable () -> Date
    private let operationLimit: Int

    public init(
        rootURL: URL,
        store: ScreenshotHistoryStore,
        fileOperations: any ScreenshotHistoryFileOperating = LocalScreenshotHistoryFileOperations(),
        now: @escaping @Sendable () -> Date = Date.init,
        operationLimit: Int = 100
    ) {
        self.rootURL = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        self.store = store
        self.fileOperations = fileOperations
        self.now = now
        self.operationLimit = max(1, operationLimit)
    }

    public func recordCapture(
        _ artifact: ScreenshotArtifact,
        ocrSummary: String = "",
        configuration: ScreenshotHistoryConfiguration
    ) async throws {
        if configuration.isEnabled {
            try await store.insert(artifact, ocrSummary: ocrSummary)
            _ = try await enforce(configuration)
        } else if !configuration.keepsFilesWhenDisabled {
            try removeArtifactFiles(artifact)
        }
    }

    public func updateOCRSummary(artifactID: UUID, summary: String) async throws {
        try await store.updateOCRSummary(id: artifactID, summary: summary)
    }

    @discardableResult
    public func enforce(_ configuration: ScreenshotHistoryConfiguration) async throws -> [UUID] {
        guard configuration.isEnabled else { return [] }
        let cutoff = now().addingTimeInterval(-TimeInterval(max(0, configuration.retentionDays)) * 86_400)
        let candidates = try await store.retentionCandidates(
            olderThan: cutoff,
            maximumItemCount: max(0, configuration.maximumItemCount),
            limit: operationLimit
        )
        let ids = candidates.map(\.id)
        if !ids.isEmpty { try await delete(ids: ids) }
        _ = try await purgeExpiredTrash(retentionHours: configuration.trashRetentionHours)
        return ids
    }

    public func delete(ids: [UUID]) async throws {
        let uniqueIDs = Array(Set(ids))
        guard !uniqueIDs.isEmpty else { return }
        var items: [ScreenshotHistoryItem] = []
        for id in uniqueIDs {
            guard let item = try await store.item(id: id), item.deletedAt == nil else {
                throw ScreenshotRetentionError.recordNotFound(id)
            }
            items.append(item)
        }

        var moves: [Move] = []
        var trashPaths: [UUID: String] = [:]
        do {
            for item in items {
                let trashRelativePath = ".Trash/\(item.id.uuidString.lowercased())"
                let trashDirectory = try safeURL(for: trashRelativePath)
                try fileOperations.createDirectory(at: trashDirectory)
                let itemMoves = try movesToTrash(for: item, trashDirectory: trashDirectory)
                for move in itemMoves {
                    try fileOperations.moveItem(at: move.source, to: move.destination)
                    moves.append(move)
                }
                trashPaths[item.id] = trashRelativePath
            }
            try await store.markDeleted(trashPaths, at: now())
        } catch {
            rollback(moves)
            throw ScreenshotRetentionError.fileOperationFailed(String(describing: error))
        }
    }

    public func restore(id: UUID) async throws {
        guard let item = try await store.item(id: id),
              item.deletedAt != nil,
              let trashRelativePath = item.trashRelativePath else {
            throw ScreenshotRetentionError.recordIsNotDeleted(id)
        }
        let trashDirectory = try safeURL(for: trashRelativePath)
        let restoreMoves = try movesFromTrash(for: item, trashDirectory: trashDirectory)
        var completed: [Move] = []
        do {
            for move in restoreMoves {
                try fileOperations.createDirectory(at: move.destination.deletingLastPathComponent())
                try fileOperations.moveItem(at: move.source, to: move.destination)
                completed.append(move)
            }
            try await store.restoreRecord(id: id)
            if fileOperations.fileExists(at: trashDirectory) {
                try? fileOperations.removeItem(at: trashDirectory)
            }
        } catch {
            rollback(completed)
            throw ScreenshotRetentionError.fileOperationFailed(String(describing: error))
        }
    }

    @discardableResult
    public func purgeExpiredTrash(retentionHours: Int) async throws -> [UUID] {
        let cutoff = now().addingTimeInterval(-TimeInterval(max(0, retentionHours)) * 3_600)
        let items = try await store.deletedItems(before: cutoff, limit: operationLimit)
        guard !items.isEmpty else { return [] }
        let purgeRoot = try safeURL(for: ".Trash/.Purge")
        try fileOperations.createDirectory(at: purgeRoot)
        var moves: [Move] = []
        do {
            for item in items {
                guard let trashRelativePath = item.trashRelativePath else {
                    throw ScreenshotRetentionError.recordIsNotDeleted(item.id)
                }
                let source = try safeURL(for: trashRelativePath)
                guard fileOperations.fileExists(at: source) else { continue }
                let destination = purgeRoot.appendingPathComponent(
                    "\(item.id.uuidString.lowercased())-\(UUID().uuidString.lowercased())",
                    isDirectory: true
                )
                try fileOperations.moveItem(at: source, to: destination)
                moves.append(.init(source: source, destination: destination))
            }
            try await store.removePermanently(ids: items.map(\.id))
        } catch {
            rollback(moves)
            throw ScreenshotRetentionError.fileOperationFailed(String(describing: error))
        }
        for move in moves where fileOperations.fileExists(at: move.destination) {
            try? fileOperations.removeItem(at: move.destination)
        }
        return items.map(\.id)
    }

    @discardableResult
    public func emptyHistory(preservingPinned: Bool) async throws -> [UUID] {
        let items = try await store.activeItems(
            preservingPinned: preservingPinned,
            limit: operationLimit
        )
        let ids = items.map(\.id)
        if !ids.isEmpty { try await delete(ids: ids) }
        return ids
    }

    private func movesToTrash(
        for item: ScreenshotHistoryItem,
        trashDirectory: URL
    ) throws -> [Move] {
        var moves: [Move] = []
        let source = try safeURL(for: item.artifact.relativePath)
        let primaryName = trashFilename(for: item.artifact, isThumbnail: false)
        moves.append(.init(source: source, destination: trashDirectory.appendingPathComponent(primaryName)))
        if let thumbnail = item.artifact.thumbnailRelativePath {
            moves.append(.init(
                source: try safeURL(for: thumbnail),
                destination: trashDirectory.appendingPathComponent(
                    trashFilename(for: item.artifact, isThumbnail: true)
                )
            ))
        }
        return moves
    }

    private func movesFromTrash(
        for item: ScreenshotHistoryItem,
        trashDirectory: URL
    ) throws -> [Move] {
        var moves: [Move] = [
            .init(
                source: trashDirectory.appendingPathComponent(trashFilename(for: item.artifact, isThumbnail: false)),
                destination: try safeURL(for: item.artifact.relativePath)
            )
        ]
        if let thumbnail = item.artifact.thumbnailRelativePath {
            moves.append(.init(
                source: trashDirectory.appendingPathComponent(trashFilename(for: item.artifact, isThumbnail: true)),
                destination: try safeURL(for: thumbnail)
            ))
        }
        return moves
    }

    private func trashFilename(for artifact: ScreenshotArtifact, isThumbnail: Bool) -> String {
        let sourcePath = isThumbnail ? artifact.thumbnailRelativePath ?? "" : artifact.relativePath
        let ext = URL(fileURLWithPath: sourcePath).pathExtension
        let base = isThumbnail
            ? "thumbnail-\(artifact.id.uuidString.lowercased())"
            : artifact.id.uuidString.lowercased()
        return ext.isEmpty ? base : "\(base).\(ext)"
    }

    private func removeArtifactFiles(_ artifact: ScreenshotArtifact) throws {
        for relativePath in [artifact.relativePath, artifact.thumbnailRelativePath].compactMap({ $0 }) {
            let url = try safeURL(for: relativePath)
            guard fileOperations.fileExists(at: url) else { continue }
            do { try fileOperations.removeItem(at: url) }
            catch { throw ScreenshotRetentionError.fileOperationFailed(String(describing: error)) }
        }
    }

    private func rollback(_ moves: [Move]) {
        for move in moves.reversed() where fileOperations.fileExists(at: move.destination) {
            try? fileOperations.createDirectory(at: move.source.deletingLastPathComponent())
            try? fileOperations.moveItem(at: move.destination, to: move.source)
        }
    }

    private func safeURL(for relativePath: String) throws -> URL {
        do {
            return try ScreenshotFeaturePaths(rootURL: rootURL).resolve(relativePath: relativePath)
        } catch {
            throw ScreenshotRetentionError.invalidRelativePath(relativePath)
        }
    }
}
