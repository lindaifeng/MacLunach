import Foundation
import SQLite3
import ScreenshotFeature
import ScreenshotServiceCore
import Testing

@Suite("ScreenshotHistoryStore")
struct ScreenshotHistoryStoreTests {
    @Test("损坏数据库被隔离后以当前 schema 重建")
    func corruptDatabaseIsIsolatedAndRebuilt() async throws {
        let root = historyTemporaryRoot()
        let history = root.appendingPathComponent("History", isDirectory: true)
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
        try Data("not-a-sqlite-database".utf8).write(to: history.appendingPathComponent("history.sqlite"))

        let store = try ScreenshotHistoryStore(rootURL: root)

        #expect(try await store.schemaVersion() == ScreenshotHistoryStore.currentSchemaVersion)
        let backups = try FileManager.default.contentsOfDirectory(
            at: history.appendingPathComponent("Backups", isDirectory: true),
            includingPropertiesForKeys: nil
        )
        #expect(backups.contains { $0.lastPathComponent.hasPrefix("history-corrupt-") })
    }

    @Test("v1 数据迁移后保留记录并补齐 OCR、pin 和回收字段")
    func legacySchemaMigratesWithoutLosingRows() async throws {
        let root = historyTemporaryRoot()
        let databaseURL = root.appendingPathComponent("History/history.sqlite")
        try createLegacyHistoryDatabase(at: databaseURL)

        let store = try ScreenshotHistoryStore(rootURL: root)
        let items = try await store.search(.init(limit: 10))

        #expect(try await store.schemaVersion() == ScreenshotHistoryStore.currentSchemaVersion)
        #expect(items.count == 1)
        #expect(items[0].artifact.id.uuidString == "11111111-1111-1111-1111-111111111111")
        #expect(items[0].ocrSummary.isEmpty)
        #expect(items[0].pinReferenceCount == 0)
        #expect(items[0].deletedAt == nil)
    }

    @Test("插入完整元数据并按时间、宽高和 OCR 文本组合搜索")
    func insertAndCombinedSearchUseStoredMetadata() async throws {
        let root = historyTemporaryRoot()
        let store = try ScreenshotHistoryStore(rootURL: root)
        let old = historyArtifact(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            createdAt: Date(timeIntervalSince1970: 100),
            relativePath: "Captures/2026/07/old.png",
            width: 320,
            height: 200
        )
        let match = historyArtifact(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            createdAt: Date(timeIntervalSince1970: 200),
            relativePath: "Captures/2026/07/match.png",
            width: 900,
            height: 600
        )
        try await store.insert(old, ocrSummary: "普通截图")
        try await store.insert(match, ocrSummary: "订单号 Touch-2026", pinReferenceCount: 2)

        let results = try await store.search(.init(
            createdAfter: Date(timeIntervalSince1970: 150),
            createdBefore: Date(timeIntervalSince1970: 250),
            minimumPointWidth: 800,
            maximumPointWidth: 1_000,
            minimumPointHeight: 500,
            maximumPointHeight: 700,
            ocrText: "Touch-2026",
            limit: 20
        ))

        #expect(results.map(\.artifact.id) == [match.id])
        #expect(results[0].pinReferenceCount == 2)
        #expect(results[0].artifact.pixelSize == .init(width: 1_800, height: 1_200))
    }

    @Test("路径越出插件根时拒绝写入")
    func escapingPathsAreRejected() async throws {
        let root = historyTemporaryRoot()
        let store = try ScreenshotHistoryStore(rootURL: root)
        let artifact = historyArtifact(
            id: UUID(),
            createdAt: Date(),
            relativePath: "../outside.png"
        )

        await #expect(throws: ScreenshotHistoryStoreError.self) {
            try await store.insert(artifact)
        }
        #expect(try await store.recordCount() == 0)
    }

    @Test("已有符号链接指向插件根外时拒绝写入")
    func symlinkEscapingPathsAreRejected() async throws {
        let root = historyTemporaryRoot()
        let outside = root.deletingLastPathComponent()
            .appendingPathComponent("HistoryOutside-\(UUID().uuidString)", isDirectory: true)
        let link = root.appendingPathComponent("Captures/link", isDirectory: true)
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        let store = try ScreenshotHistoryStore(rootURL: root)
        let artifact = historyArtifact(
            id: UUID(),
            createdAt: Date(),
            relativePath: "Captures/link/outside.png"
        )

        await #expect(throws: ScreenshotHistoryStoreError.self) {
            try await store.insert(artifact)
        }
        #expect(try await store.recordCount() == 0)
    }
}

private func createLegacyHistoryDatabase(at url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    var database: OpaquePointer?
    guard sqlite3_open(url.path, &database) == SQLITE_OK else { throw LegacyDatabaseError.open }
    defer { sqlite3_close_v2(database) }
    let sql = """
    CREATE TABLE history_items (
        id TEXT PRIMARY KEY NOT NULL,
        created_at REAL NOT NULL,
        capture_mode TEXT NOT NULL,
        relative_path TEXT NOT NULL UNIQUE,
        thumbnail_relative_path TEXT,
        point_width REAL NOT NULL,
        point_height REAL NOT NULL,
        pixel_width REAL NOT NULL,
        pixel_height REAL NOT NULL,
        uniform_type_identifier TEXT NOT NULL,
        sha256 TEXT NOT NULL
    );
    INSERT INTO history_items VALUES (
        '11111111-1111-1111-1111-111111111111', 100, 'region',
        'Captures/2026/07/legacy.png', NULL, 100, 80, 200, 160,
        'public.png', 'legacy-sha'
    );
    PRAGMA user_version = 1;
    """
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
        throw LegacyDatabaseError.execute
    }
}

private enum LegacyDatabaseError: Error { case open, execute }

func historyTemporaryRoot() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("TouchHistoryTests-\(UUID().uuidString)", isDirectory: true)
}

func historyArtifact(
    id: UUID,
    createdAt: Date,
    relativePath: String,
    width: Double = 640,
    height: Double = 480,
    thumbnailRelativePath: String? = nil
) -> ScreenshotArtifact {
    ScreenshotArtifact(
        id: id,
        createdAt: createdAt,
        captureMode: .region,
        relativePath: relativePath,
        thumbnailRelativePath: thumbnailRelativePath,
        pointSize: .init(width: width, height: height),
        pixelSize: .init(width: width * 2, height: height * 2),
        uniformTypeIdentifier: "public.png",
        sha256: "sha-\(id.uuidString)",
        displays: []
    )
}
