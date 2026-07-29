import Foundation
import SuperRightFeature
import XCTest

final class MoveClipboardTests: XCTestCase {
    func testSnapshotRoundTripKeepsStandardizedSource() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.txt")
        try Data("source".utf8).write(to: source)
        let store = MoveClipboardStore(url: root.appendingPathComponent("move.json"))

        let snapshot = try MoveClipboardSnapshot.capture(urls: [source], now: .now)
        try store.save(snapshot)

        XCTAssertEqual(
            try store.loadValid(now: .now)?.items.map(\.url),
            [source.standardizedFileURL]
        )
    }

    func testLoadingSnapshotRejectsSourceReplacedAfterCut() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.txt")
        try Data("source".utf8).write(to: source)
        let store = MoveClipboardStore(url: root.appendingPathComponent("move.json"))
        try store.save(try MoveClipboardSnapshot.capture(urls: [source], now: .now))

        try FileManager.default.removeItem(at: source)
        try Data("replacement".utf8).write(to: source)

        XCTAssertThrowsError(try store.loadValid(now: .now)) { error in
            XCTAssertEqual(error as? MoveClipboardError, .sourceChanged(source.standardizedFileURL))
        }
    }

    func testMoveConflictRequestRoundTripsAtomically() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.txt")
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("source".utf8).write(to: source)

        let snapshot = try MoveClipboardSnapshot.capture(urls: [source])
        let request = MoveConflictRequest(
            snapshot: snapshot,
            destination: destination,
            conflicts: [.init(
                sourceURL: source,
                destinationURL: destination.appendingPathComponent(source.lastPathComponent)
            )]
        )
        let store = MoveConflictRequestStore(url: root.appendingPathComponent("move-conflict.json"))

        try store.save(request)

        XCTAssertEqual(try store.loadValid()?.id, request.id)
        XCTAssertEqual(try store.loadValid()?.destination, destination.standardizedFileURL)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MoveClipboardTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
