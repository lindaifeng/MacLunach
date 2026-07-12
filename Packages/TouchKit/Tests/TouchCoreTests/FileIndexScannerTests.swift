import Foundation
import Testing
@testable import TouchCore

@Test func scannerIndexesVisibleFilesAndExcludesTrashAndCaches() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("Visible", isDirectory: true), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: root.appendingPathComponent(".Trash", isDirectory: true), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("Library/Caches", isDirectory: true), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try Data("visible".utf8).write(to: root.appendingPathComponent("Visible/设计.md"))
    try Data("trash".utf8).write(to: root.appendingPathComponent(".Trash/old.txt"))
    try Data("cache".utf8).write(to: root.appendingPathComponent("Library/Caches/cache.txt"))

    let records = try await FileIndexScanner.records(root: root)

    #expect(records.map(\.fileName).contains("设计.md"))
    #expect(records.contains { $0.path.contains("/.Trash/") } == false)
    #expect(records.contains { $0.path.contains("/Library/Caches/") } == false)
}

@Test func scannerPublishesBatchesWithoutWaitingForFullScan() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for index in 0..<3 { try Data().write(to: root.appendingPathComponent("file-\(index).txt")) }

    var batches: [[FileIndexRecord]] = []
    for try await batch in FileIndexScanner.batches(root: root, batchSize: 1) {
        batches.append(batch)
    }

    #expect(batches.count == 3)
    #expect(batches.allSatisfy { $0.count == 1 })
}

@Test func subtreeScanKeepsConfiguredRootAndIncludesChangedDirectory() async throws {
    let configuredRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let subtree = configuredRoot.appendingPathComponent("Folder", isDirectory: true)
    try FileManager.default.createDirectory(at: subtree, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: configuredRoot) }
    try Data().write(to: subtree.appendingPathComponent("note.txt"))

    var records: [FileIndexRecord] = []
    for try await batch in FileIndexScanner.batches(
        root: subtree,
        indexRoot: configuredRoot,
        includeRoot: true,
        batchSize: 10
    ) {
        records.append(contentsOf: batch)
    }

    let expectedPaths = [subtree, subtree.appendingPathComponent("note.txt")]
        .map { $0.resolvingSymlinksInPath().path }
    #expect(Set(records.map(\.path)) == Set(expectedPaths))
    #expect(records.allSatisfy { $0.rootPath == configuredRoot.resolvingSymlinksInPath().path })
}
