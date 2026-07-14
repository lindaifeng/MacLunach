import Foundation
import ScreenshotFeature
import ScreenshotServiceCore
import Testing

@Suite("ScreenshotRetentionController")
struct ScreenshotRetentionControllerTests {
    @Test("30 天和 500 张策略先达到者进入回收区且 pin 源受保护")
    func retentionMovesOnlyEligibleItemsToTrash() async throws {
        let root = historyTemporaryRoot()
        let now = Date(timeIntervalSince1970: 4_000_000)
        let store = try ScreenshotHistoryStore(rootURL: root)
        let controller = ScreenshotRetentionController(rootURL: root, store: store, now: { now })
        var artifacts: [ScreenshotArtifact] = []
        for index in 0..<5 {
            let artifact = historyArtifact(
                id: UUID(),
                createdAt: now.addingTimeInterval(TimeInterval(-(index + 1) * 86_400)),
                relativePath: "Captures/2026/07/\(index).png"
            )
            try createHistoryFile(for: artifact, under: root)
            try await store.insert(artifact, pinReferenceCount: index == 4 ? 1 : 0)
            artifacts.append(artifact)
        }

        let deleted = try await controller.enforce(.init(
            isEnabled: true,
            retentionDays: 3,
            maximumItemCount: 3,
            trashRetentionHours: 24
        ))

        #expect(deleted.count == 1)
        #expect(deleted[0] == artifacts[3].id)
        #expect(try await store.item(id: artifacts[4].id)?.deletedAt == nil)
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(".Trash/\(artifacts[3].id.uuidString.lowercased())/\(artifacts[3].id.uuidString.lowercased()).png").path
        ))
    }

    @Test("删除可在 24 小时内恢复，过期后物理删除")
    func trashCanRestoreThenPurgeExpiredItems() async throws {
        let root = historyTemporaryRoot()
        let clock = MutableHistoryClock(Date(timeIntervalSince1970: 8_000_000))
        let store = try ScreenshotHistoryStore(rootURL: root)
        let controller = ScreenshotRetentionController(rootURL: root, store: store, now: { clock.value })
        let first = historyArtifact(id: UUID(), createdAt: clock.value, relativePath: "Captures/2026/07/first.png")
        try createHistoryFile(for: first, under: root)
        try await store.insert(first)

        try await controller.delete(ids: [first.id])
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(first.relativePath).path))
        try await controller.restore(id: first.id)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(first.relativePath).path))
        #expect(try await store.item(id: first.id)?.deletedAt == nil)

        try await controller.delete(ids: [first.id])
        clock.value = clock.value.addingTimeInterval(25 * 3_600)
        let purged = try await controller.purgeExpiredTrash(retentionHours: 24)

        #expect(purged == [first.id])
        #expect(try await store.item(id: first.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".Trash/\(first.id.uuidString.lowercased())").path))
    }

    @Test("批量移动失败时文件与数据库都回滚")
    func failedMoveRollsBackFilesAndDatabase() async throws {
        let root = historyTemporaryRoot()
        let store = try ScreenshotHistoryStore(rootURL: root)
        let operations = FailingHistoryFileOperations(failOnMoveNumber: 2)
        let controller = ScreenshotRetentionController(rootURL: root, store: store, fileOperations: operations)
        let first = historyArtifact(id: UUID(), createdAt: Date(), relativePath: "Captures/a.png")
        let second = historyArtifact(id: UUID(), createdAt: Date(), relativePath: "Captures/b.png")
        for artifact in [first, second] {
            try createHistoryFile(for: artifact, under: root)
            try await store.insert(artifact)
        }

        await #expect(throws: ScreenshotRetentionError.self) {
            try await controller.delete(ids: [first.id, second.id])
        }

        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(first.relativePath).path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(second.relativePath).path))
        #expect(try await store.item(id: first.id)?.deletedAt == nil)
        #expect(try await store.item(id: second.id)?.deletedAt == nil)
    }

    @Test("关闭历史时按配置保留或删除捕获文件")
    func disabledHistoryHonorsFileRetentionSetting() async throws {
        let root = historyTemporaryRoot()
        let store = try ScreenshotHistoryStore(rootURL: root)
        let controller = ScreenshotRetentionController(rootURL: root, store: store)
        let kept = historyArtifact(id: UUID(), createdAt: Date(), relativePath: "Captures/kept.png")
        let removed = historyArtifact(id: UUID(), createdAt: Date(), relativePath: "Captures/removed.png")
        try createHistoryFile(for: kept, under: root)
        try createHistoryFile(for: removed, under: root)

        try await controller.recordCapture(kept, configuration: .init(isEnabled: false, keepsFilesWhenDisabled: true))
        try await controller.recordCapture(removed, configuration: .init(isEnabled: false, keepsFilesWhenDisabled: false))

        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(kept.relativePath).path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(removed.relativePath).path))
        #expect(try await store.recordCount() == 0)
    }

    @Test("没有历史记录的捕获产物也将原图和缩略图移入回收区")
    func discardWithoutHistoryMovesArtifactAndThumbnailToTrash() async throws {
        let root = historyTemporaryRoot()
        let store = try ScreenshotHistoryStore(rootURL: root)
        let artifact = ScreenshotArtifact(
            id: UUID(),
            createdAt: Date(),
            captureMode: .region,
            relativePath: "Captures/without-history.png",
            thumbnailRelativePath: "Thumbnails/without-history.png",
            pointSize: .init(width: 100, height: 50),
            pixelSize: .init(width: 200, height: 100),
            uniformTypeIdentifier: "public.png",
            sha256: "without-history",
            displays: []
        )
        let source = root.appendingPathComponent(artifact.relativePath)
        let thumbnail = root.appendingPathComponent(artifact.thumbnailRelativePath!)
        for url in [source, thumbnail] {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(url.lastPathComponent.utf8).write(to: url)
        }
        let controller = ScreenshotRetentionController(rootURL: root, store: store)

        try await controller.discard(artifact)

        let trash = root.appendingPathComponent(".Trash/\(artifact.id.uuidString.lowercased())")
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(!FileManager.default.fileExists(atPath: thumbnail.path))
        #expect(FileManager.default.fileExists(
            atPath: trash.appendingPathComponent("\(artifact.id.uuidString.lowercased()).png").path
        ))
        #expect(FileManager.default.fileExists(
            atPath: trash.appendingPathComponent("thumbnail-\(artifact.id.uuidString.lowercased()).png").path
        ))
        #expect(try await store.item(id: artifact.id) == nil)
    }

    @Test("无历史删除也拒绝路径遍历且不移动根目录外文件")
    func discardWithoutHistoryRejectsTraversal() async throws {
        let root = historyTemporaryRoot()
        let store = try ScreenshotHistoryStore(rootURL: root)
        let outside = root.deletingLastPathComponent()
            .appendingPathComponent("discard-outside-\(UUID().uuidString).png")
        try Data("outside".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        let artifact = ScreenshotArtifact(
            id: UUID(),
            createdAt: Date(),
            captureMode: .region,
            relativePath: "../\(outside.lastPathComponent)",
            thumbnailRelativePath: nil,
            pointSize: .init(width: 1, height: 1),
            pixelSize: .init(width: 1, height: 1),
            uniformTypeIdentifier: "public.png",
            sha256: "outside",
            displays: []
        )
        let controller = ScreenshotRetentionController(rootURL: root, store: store)

        await #expect(throws: ScreenshotRetentionError.self) {
            try await controller.discard(artifact)
        }

        #expect(try Data(contentsOf: outside) == Data("outside".utf8))
    }

    @Test("记录后路径被替换为根外符号链接时拒绝删除")
    func symlinkReplacementCannotMoveOutsideFile() async throws {
        let root = historyTemporaryRoot()
        let outside = root.deletingLastPathComponent()
            .appendingPathComponent("RetentionOutside-\(UUID().uuidString)", isDirectory: true)
        let artifact = historyArtifact(
            id: UUID(),
            createdAt: Date(),
            relativePath: "Captures/link/outside.png"
        )
        let store = try ScreenshotHistoryStore(rootURL: root)
        try await store.insert(artifact)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let outsideFile = outside.appendingPathComponent("outside.png")
        try Data("outside".utf8).write(to: outsideFile)
        let link = root.appendingPathComponent("Captures/link", isDirectory: true)
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        let controller = ScreenshotRetentionController(rootURL: root, store: store)

        await #expect(throws: ScreenshotRetentionError.self) {
            try await controller.delete(ids: [artifact.id])
        }

        #expect(FileManager.default.fileExists(atPath: outsideFile.path))
        #expect(try await store.item(id: artifact.id)?.deletedAt == nil)
    }
}

private func createHistoryFile(for artifact: ScreenshotArtifact, under root: URL) throws {
    let url = root.appendingPathComponent(artifact.relativePath)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(artifact.id.uuidString.utf8).write(to: url)
}

private final class MutableHistoryClock: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Date
    init(_ value: Date) { storedValue = value }
    var value: Date {
        get { lock.withLock { storedValue } }
        set { lock.withLock { storedValue = newValue } }
    }
}

private final class FailingHistoryFileOperations: ScreenshotHistoryFileOperating, @unchecked Sendable {
    private let fileManager = FileManager.default
    private let failOnMoveNumber: Int
    private let lock = NSLock()
    private var moveCount = 0

    init(failOnMoveNumber: Int) { self.failOnMoveNumber = failOnMoveNumber }

    func createDirectory(at url: URL) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func moveItem(at source: URL, to destination: URL) throws {
        let shouldFail = lock.withLock { () -> Bool in
            moveCount += 1
            return moveCount == failOnMoveNumber
        }
        if shouldFail { throw TestMoveError.expected }
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.moveItem(at: source, to: destination)
    }

    func removeItem(at url: URL) throws { try fileManager.removeItem(at: url) }
    func fileExists(at url: URL) -> Bool { fileManager.fileExists(atPath: url.path) }
}

private enum TestMoveError: Error { case expected }
