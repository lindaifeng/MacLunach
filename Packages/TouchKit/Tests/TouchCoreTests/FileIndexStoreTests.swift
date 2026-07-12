import Foundation
import SQLite3
import Testing
@testable import TouchCore

@Test func storeFindsPartialFileName() async throws {
    let store = try FileIndexStore.temporary()
    try await store.upsert([
        FileIndexRecord(path: "/tmp/项目/设计说明.md", rootPath: "/tmp/项目", contentType: "net.daringfireball.markdown", size: 10, createdAt: .now, modifiedAt: .now, isDirectory: false),
        FileIndexRecord(path: "/tmp/项目/日报.txt", rootPath: "/tmp/项目", contentType: "public.plain-text", size: 8, createdAt: .now, modifiedAt: .now, isDirectory: false)
    ])

    #expect(try await store.search("设计", limit: 10).map(\.fileName) == ["设计说明.md"])
}

@Test func trigramSearchFindsMiddleSubstringAndTreatsWildcardsLiterally() async throws {
    let store = try FileIndexStore.temporary()
    try await store.upsert([
        FileIndexRecord(path: "/tmp/search/quarterly-roadmap.txt", rootPath: "/tmp/search", contentType: "public.text", size: 1, createdAt: .now, modifiedAt: .now, isDirectory: false),
        FileIndexRecord(path: "/tmp/search/100%_ready.txt", rootPath: "/tmp/search", contentType: "public.text", size: 1, createdAt: .now, modifiedAt: .now, isDirectory: false)
    ])

    #expect(try await store.search("terly-roa", limit: 10).map(\.fileName) == ["quarterly-roadmap.txt"])
    #expect(try await store.search("%_", limit: 10).map(\.fileName) == ["100%_ready.txt"])
    #expect(try await store.schemaVersion() == 1)
}

@Test func openingLegacyDatabaseMigratesExistingRowsIntoTrigramIndex() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("TouchStoreMigration-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let databaseURL = directory.appendingPathComponent("file-index.sqlite")
    var database: OpaquePointer?
    #expect(sqlite3_open(databaseURL.path, &database) == SQLITE_OK)
    defer { sqlite3_close_v2(database) }
    let legacySchema = """
    CREATE TABLE files (
        path TEXT PRIMARY KEY NOT NULL,
        root_path TEXT NOT NULL,
        file_name TEXT NOT NULL,
        normalized_name TEXT NOT NULL,
        content_type TEXT NOT NULL,
        size INTEGER NOT NULL,
        created_at REAL NOT NULL,
        modified_at REAL NOT NULL,
        is_directory INTEGER NOT NULL
    );
    INSERT INTO files VALUES (
        '/tmp/legacy/annual-planning.txt', '/tmp/legacy', 'annual-planning.txt',
        'annual-planning.txt', 'public.text', 1, 0, 0, 0
    );
    """
    #expect(sqlite3_exec(database, legacySchema, nil, nil, nil) == SQLITE_OK)
    #expect(sqlite3_close_v2(database) == SQLITE_OK)
    database = nil

    let store = try FileIndexStore(databaseURL: databaseURL)

    #expect(try await store.schemaVersion() == 1)
    #expect(try await store.search("planning", limit: 10).map(\.fileName) == ["annual-planning.txt"])
}

@Test func deletingRootRemovesOnlyMatchingRows() async throws {
    let store = try FileIndexStore.temporary()
    try await store.upsert([
        FileIndexRecord(path: "/a/one.txt", rootPath: "/a", contentType: "public.plain-text", size: 1, createdAt: .now, modifiedAt: .now, isDirectory: false),
        FileIndexRecord(path: "/b/two.txt", rootPath: "/b", contentType: "public.plain-text", size: 1, createdAt: .now, modifiedAt: .now, isDirectory: false)
    ])

    try await store.delete(root: "/a")

    #expect(try await store.search("", limit: 10).map(\.path) == ["/b/two.txt"])
}

@Test func deletingPathRemovesOnlyTheStaleResult() async throws {
    let store = try FileIndexStore.temporary()
    try await store.upsert([
        FileIndexRecord(path: "/a/one.txt", rootPath: "/a", contentType: "public.plain-text", size: 1, createdAt: .now, modifiedAt: .now, isDirectory: false),
        FileIndexRecord(path: "/a/two.txt", rootPath: "/a", contentType: "public.plain-text", size: 1, createdAt: .now, modifiedAt: .now, isDirectory: false)
    ])

    try await store.delete(path: "/a/one.txt")

    #expect(try await store.search("", limit: 10).map(\.path) == ["/a/two.txt"])
}

@Test func storeReportsRecordCountWithoutLoadingRows() async throws {
    let store = try FileIndexStore.temporary()
    try await store.upsert([
        FileIndexRecord(path: "/tmp/count/a.txt", rootPath: "/tmp/count", contentType: "public.text", size: 1, createdAt: .now, modifiedAt: .now, isDirectory: false),
        FileIndexRecord(path: "/tmp/count/b.txt", rootPath: "/tmp/count", contentType: "public.text", size: 1, createdAt: .now, modifiedAt: .now, isDirectory: false)
    ])

    #expect(try await store.recordCount() == 2)
    try await store.delete(path: "/tmp/count/a.txt")
    #expect(try await store.recordCount() == 1)
}

@Test func closedStoreCanBeIsolatedAndRecreated() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("TouchStoreRecovery-\(UUID().uuidString)", isDirectory: true)
    let databaseURL = directory.appendingPathComponent("file-index.sqlite")
    let store = try FileIndexStore(databaseURL: databaseURL)
    try await store.upsert([
        FileIndexRecord(path: "/tmp/recovery/old.txt", rootPath: "/tmp/recovery", contentType: "public.text", size: 1, createdAt: .now, modifiedAt: .now, isDirectory: false)
    ])

    try await store.close()
    let isolatedURL = try FileIndexStore.isolateDatabase(
        at: databaseURL,
        reason: .rebuild,
        timestamp: Date(timeIntervalSince1970: 1_000)
    )

    #expect(isolatedURL?.lastPathComponent == "file-index.recovery-1000000.sqlite")
    #expect(isolatedURL.map { FileManager.default.fileExists(atPath: $0.path) } == true)
    #expect(!FileManager.default.fileExists(atPath: databaseURL.path))
    let replacement = try FileIndexStore(databaseURL: databaseURL)
    #expect(try await replacement.recordCount() == 0)
}

@Test func corruptDatabaseIsAutomaticallyIsolatedOnRecoveryOpen() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("TouchStoreCorrupt-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let databaseURL = directory.appendingPathComponent("file-index.sqlite")
    try Data("not a sqlite database".utf8).write(to: databaseURL)

    let result = try FileIndexStore.openRecovering(
        databaseURL: databaseURL,
        timestamp: Date(timeIntervalSince1970: 2_000)
    )

    #expect(result.didRecover)
    #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("file-index.corrupt-2000000.sqlite").path))
    #expect(try await result.store.recordCount() == 0)
}

@Test func deletingSubtreeRemovesDescendantsWithoutTouchingSiblingPaths() async throws {
    let store = try FileIndexStore.temporary()
    try await store.upsert([
        FileIndexRecord(path: "/tmp/root/folder/a.txt", rootPath: "/tmp/root", contentType: "public.text", size: 1, createdAt: .now, modifiedAt: .now, isDirectory: false),
        FileIndexRecord(path: "/tmp/root/folder/nested/b.txt", rootPath: "/tmp/root", contentType: "public.text", size: 1, createdAt: .now, modifiedAt: .now, isDirectory: false),
        FileIndexRecord(path: "/tmp/root/folder-other/c.txt", rootPath: "/tmp/root", contentType: "public.text", size: 1, createdAt: .now, modifiedAt: .now, isDirectory: false)
    ])

    try await store.delete(subtree: "/tmp/root/folder")

    #expect(try await store.search("a", limit: 10).isEmpty)
    #expect(try await store.search("b", limit: 10).isEmpty)
    #expect(try await store.search("c", limit: 10).map(\.fileName) == ["c.txt"])
}
