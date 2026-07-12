import Foundation
import TouchCore
import XCTest
@testable import 触达

private struct EmptyApplicationDiscoverer: ApplicationDiscovering {
    func discoverApplications() async -> [ApplicationRecord] { [] }
}

private struct NoopApplicationLauncher: ApplicationLaunching {
    func openApplication(at url: URL) async throws {}
}

@MainActor
private final class MonitorSpy: SearchEventMonitoring {
    private(set) var startedRoots: [[URL]] = []
    private(set) var stopCount = 0
    private var handler: (@Sendable (FileIndexEvent) -> Void)?

    func start(roots: [URL], handler: @escaping @Sendable (FileIndexEvent) -> Void) {
        startedRoots.append(roots)
        self.handler = handler
    }

    func stop() {
        stopCount += 1
        handler = nil
    }

    func emit(_ event: FileIndexEvent) {
        handler?(event)
    }
}

@MainActor
private final class RootPersistenceSpy: SearchRootPersisting {
    var loadedRoots: [URL]
    private(set) var savedRoots: [[URL]] = []

    init(loadedRoots: [URL]) { self.loadedRoots = loadedRoots }
    func loadRoots(defaults: [URL]) -> [URL] { loadedRoots.isEmpty ? defaults : loadedRoots }
    func saveRoots(_ roots: [URL]) { savedRoots.append(roots) }
}

@MainActor
final class SearchEnvironmentRecoveryTests: XCTestCase {
    func testPrepareScansInBackgroundAndStartsEventMonitor() async throws {
        let fixture = try makeFixture()
        try Data("hello".utf8).write(to: fixture.root.appendingPathComponent("note.txt"))

        await fixture.environment.prepare()
        try await waitUntil { fixture.environment.diagnostics.status == .ready }

        let count = try await fixture.environment.fileIndexStore?.recordCount()
        XCTAssertEqual(count, 1)
        XCTAssertEqual(fixture.monitor.startedRoots.last, [fixture.root])
    }

    func testRebuildStopsMonitorIsolatesDatabaseAndRestartsMonitoring() async throws {
        let fixture = try makeFixture()
        try Data("hello".utf8).write(to: fixture.root.appendingPathComponent("note.txt"))
        await fixture.environment.rebuildIndex()
        let stopCountBeforeSecondRebuild = fixture.monitor.stopCount

        await fixture.environment.rebuildIndex()

        XCTAssertGreaterThan(fixture.monitor.stopCount, stopCountBeforeSecondRebuild)
        XCTAssertEqual(fixture.monitor.startedRoots.last, [fixture.root])
        let isolated = try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path)
            .filter { $0.hasPrefix("file-index.recovery-") }
        XCTAssertFalse(isolated.isEmpty)
        let count = try await fixture.environment.fileIndexStore?.recordCount()
        XCTAssertEqual(count, 1)
        XCTAssertEqual(fixture.environment.diagnostics.status, .ready)
    }

    func testRemovingRootDeletesOnlyItsRecordsAndPersistsRemainingRoots() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TouchEnvironmentRemove-\(UUID().uuidString)", isDirectory: true)
        let firstRoot = directory.appendingPathComponent("First", isDirectory: true)
        let secondRoot = directory.appendingPathComponent("Second", isDirectory: true)
        try FileManager.default.createDirectory(at: firstRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: true)
        try Data("b".utf8).write(to: secondRoot.appendingPathComponent("b.txt"))
        let databaseURL = directory.appendingPathComponent("file-index.sqlite")
        let store = try FileIndexStore(databaseURL: databaseURL)
        try await store.upsert([
            record(path: firstRoot.appendingPathComponent("a.txt"), root: firstRoot),
            record(path: secondRoot.appendingPathComponent("b.txt"), root: secondRoot)
        ])
        let persistence = RootPersistenceSpy(loadedRoots: [firstRoot, secondRoot])
        let environment = SearchEnvironment(
            applicationCatalog: catalog(),
            fileIndexStore: store,
            roots: [firstRoot, secondRoot],
            databaseURL: databaseURL,
            eventMonitor: MonitorSpy(),
            rootPersistence: persistence
        )

        await environment.removeRoot(at: 0)

        let removedRecords = try await store.search("a", limit: 10)
        let remainingNames = try await store.search("b", limit: 10).map(\.fileName)
        XCTAssertTrue(removedRecords.isEmpty)
        XCTAssertEqual(remainingNames, ["b.txt"])
        XCTAssertEqual(persistence.savedRoots.last, [secondRoot])
    }

    func testFileEventsIncrementallyInsertAndDeleteChangedPath() async throws {
        let fixture = try makeFixture()
        await fixture.environment.prepare()
        try await waitUntil { fixture.environment.diagnostics.status == .ready }
        let file = fixture.root.appendingPathComponent("event-note.txt")
        try Data("event".utf8).write(to: file)

        fixture.monitor.emit(.changed(file))
        try await waitUntil {
            try await fixture.environment.fileIndexStore?.search("event-note", limit: 10).count == 1
        }

        try FileManager.default.removeItem(at: file)
        fixture.monitor.emit(.changed(file))
        try await waitUntil {
            try await fixture.environment.fileIndexStore?.search("event-note", limit: 10).isEmpty == true
        }
    }

    func testStartupReconciliationRepairsChangesMadeWhileAppWasNotRunning() async throws {
        let fixture = try makeFixture()
        let staleURL = fixture.root.appendingPathComponent("stale.txt")
        try await fixture.environment.fileIndexStore?.upsert([record(path: staleURL, root: fixture.root)])
        let freshURL = fixture.root.appendingPathComponent("fresh.txt")
        try Data("fresh".utf8).write(to: freshURL)

        await fixture.environment.prepare()

        try await waitUntil {
            let fresh = try await fixture.environment.fileIndexStore?.search("fresh", limit: 10).count == 1
            let stale = try await fixture.environment.fileIndexStore?.search("stale", limit: 10).isEmpty == true
            return fresh && stale
        }
        XCTAssertEqual(fixture.monitor.startedRoots.last, [fixture.root])
    }

    func testRescanRequiredOnlyReconcilesAffectedRoot() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TouchEnvironmentAffectedRoots-\(UUID().uuidString)", isDirectory: true)
        let firstRoot = directory.appendingPathComponent("First", isDirectory: true)
        let secondRoot = directory.appendingPathComponent("Second", isDirectory: true)
        try FileManager.default.createDirectory(at: firstRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("file-index.sqlite")
        let store = try FileIndexStore(databaseURL: databaseURL)
        try await store.upsert([
            record(path: firstRoot.appendingPathComponent("old-first.txt"), root: firstRoot),
            record(path: secondRoot.appendingPathComponent("old-second.txt"), root: secondRoot)
        ])
        try Data("new".utf8).write(to: firstRoot.appendingPathComponent("new-first.txt"))
        try Data("new".utf8).write(to: secondRoot.appendingPathComponent("new-second.txt"))
        let monitor = MonitorSpy()
        let environment = SearchEnvironment(
            applicationCatalog: catalog(),
            fileIndexStore: store,
            roots: [firstRoot, secondRoot],
            databaseURL: databaseURL,
            eventMonitor: monitor,
            rootPersistence: RootPersistenceSpy(loadedRoots: [firstRoot, secondRoot])
        )
        await environment.handle(event: .rescanRequired(firstRoot.appendingPathComponent("nested")))

        try await waitUntil { try await store.search("new-first", limit: 10).count == 1 }
        let oldFirst = try await store.search("old-first", limit: 10)
        let oldSecond = try await store.search("old-second", limit: 10)
        let newSecond = try await store.search("new-second", limit: 10)
        XCTAssertTrue(oldFirst.isEmpty)
        XCTAssertEqual(oldSecond.count, 1)
        XCTAssertTrue(newSecond.isEmpty)
    }

    func testDeletedFolderEventRemovesAllDescendants() async throws {
        let fixture = try makeFixture()
        let folder = fixture.root.appendingPathComponent("Folder", isDirectory: true)
        let nested = folder.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let first = folder.appendingPathComponent("first.txt")
        let second = nested.appendingPathComponent("second.txt")
        try Data().write(to: first)
        try Data().write(to: second)
        try await fixture.environment.fileIndexStore?.upsert([
            record(path: folder, root: fixture.root),
            record(path: first, root: fixture.root),
            record(path: nested, root: fixture.root),
            record(path: second, root: fixture.root)
        ])

        try FileManager.default.removeItem(at: folder)
        await fixture.environment.handle(event: .changed(folder))

        let firstIsGone = try await fixture.environment.fileIndexStore?.search("first", limit: 10).isEmpty == true
        let secondIsGone = try await fixture.environment.fileIndexStore?.search("second", limit: 10).isEmpty == true
        XCTAssertTrue(firstIsGone)
        XCTAssertTrue(secondIsGone)
    }

    func testAddingRootPersistsItAndRestartsMonitorWithAllRoots() async throws {
        let fixture = try makeFixture()
        await fixture.environment.prepare()
        try await waitUntil { fixture.environment.diagnostics.status == .ready }
        let addedRoot = fixture.directory.appendingPathComponent("Added", isDirectory: true)
        try FileManager.default.createDirectory(at: addedRoot, withIntermediateDirectories: true)
        try Data().write(to: addedRoot.appendingPathComponent("added.txt"))
        let persistence = RootPersistenceSpy(loadedRoots: [fixture.root])
        let monitor = MonitorSpy()
        let environment = SearchEnvironment(
            applicationCatalog: catalog(),
            fileIndexStore: try FileIndexStore.temporary(),
            roots: [fixture.root],
            eventMonitor: monitor,
            rootPersistence: persistence
        )

        await environment.addRoot(addedRoot)

        let addedResults = try await environment.fileIndexStore?.search("added", limit: 10)
        XCTAssertEqual(persistence.savedRoots.last, [fixture.root, addedRoot])
        XCTAssertEqual(monitor.startedRoots.last, [fixture.root, addedRoot])
        XCTAssertEqual(addedResults?.count, 1)
    }

    func testAddingParentRootCoalescesPreviouslyConfiguredDescendant() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TouchEnvironmentOverlappingRoots-\(UUID().uuidString)", isDirectory: true)
        let parent = directory.appendingPathComponent("Parent", isDirectory: true)
        let child = parent.appendingPathComponent("Child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let liveFile = child.appendingPathComponent("live.txt")
        let staleFile = child.appendingPathComponent("stale.txt")
        try Data().write(to: liveFile)
        try Data().write(to: staleFile)
        let persistence = RootPersistenceSpy(loadedRoots: [child])
        let monitor = MonitorSpy()
        let store = try FileIndexStore.temporary()
        try await store.upsert([
            record(path: liveFile, root: child),
            record(path: staleFile, root: child)
        ])
        try FileManager.default.removeItem(at: staleFile)
        let environment = SearchEnvironment(
            applicationCatalog: catalog(),
            fileIndexStore: store,
            roots: [child],
            eventMonitor: monitor,
            rootPersistence: persistence
        )

        await environment.addRoot(parent)

        XCTAssertEqual(environment.diagnostics.roots, [parent])
        XCTAssertEqual(persistence.savedRoots.last, [parent])
        XCTAssertEqual(monitor.startedRoots.last, [parent])
        let liveResults = try await store.search("live", limit: 10)
        let staleResults = try await store.search("stale", limit: 10)
        XCTAssertEqual(liveResults.count, 1)
        XCTAssertEqual(liveResults.first?.rootPath, parent.resolvingSymlinksInPath().path)
        XCTAssertTrue(staleResults.isEmpty)
    }

    func testAddingDescendantOfConfiguredRootIsANoOp() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TouchEnvironmentRedundantRoot-\(UUID().uuidString)", isDirectory: true)
        let parent = directory.appendingPathComponent("Parent", isDirectory: true)
        let child = parent.appendingPathComponent("Child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let file = child.appendingPathComponent("owned-by-parent.txt")
        try Data().write(to: file)
        let store = try FileIndexStore.temporary()
        try await store.upsert([record(path: file, root: parent)])
        let persistence = RootPersistenceSpy(loadedRoots: [parent])
        let monitor = MonitorSpy()
        let environment = SearchEnvironment(
            applicationCatalog: catalog(),
            fileIndexStore: store,
            roots: [parent],
            eventMonitor: monitor,
            rootPersistence: persistence
        )

        await environment.addRoot(child)

        XCTAssertEqual(environment.diagnostics.roots, [parent])
        XCTAssertTrue(persistence.savedRoots.isEmpty)
        XCTAssertTrue(monitor.startedRoots.isEmpty)
        let results = try await store.search("owned-by-parent", limit: 10)
        XCTAssertEqual(results.first?.rootPath, parent.resolvingSymlinksInPath().path)
    }

    private func makeFixture() throws -> (environment: SearchEnvironment, monitor: MonitorSpy, root: URL, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TouchEnvironmentRecovery-\(UUID().uuidString)", isDirectory: true)
        let root = directory.appendingPathComponent("Root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("file-index.sqlite")
        let monitor = MonitorSpy()
        let environment = SearchEnvironment(
            applicationCatalog: catalog(),
            fileIndexStore: try FileIndexStore(databaseURL: databaseURL),
            roots: [root],
            databaseURL: databaseURL,
            eventMonitor: monitor,
            rootPersistence: RootPersistenceSpy(loadedRoots: [root])
        )
        return (environment, monitor, root, directory)
    }

    private func catalog() -> ApplicationCatalog {
        ApplicationCatalog(discoverer: EmptyApplicationDiscoverer(), launcher: NoopApplicationLauncher())
    }

    private func record(path: URL, root: URL) -> FileIndexRecord {
        FileIndexRecord(path: path.path, rootPath: root.path, contentType: "public.text", size: 1, createdAt: .now, modifiedAt: .now, isDirectory: false)
    }

    private func waitUntil(
        timeout: Duration = .seconds(3),
        condition: @escaping @MainActor () async throws -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for condition")
    }
}
