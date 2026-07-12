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
