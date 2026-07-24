import Foundation
import XCTest
@testable import 触达

@MainActor
final class SearchRootBookmarkStoreTests: XCTestCase {
    func testMissingPreferenceUsesDefaultRootsButPersistedEmptySelectionStaysEmpty() {
        let suiteName = "SearchRootBookmarkStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SearchRootBookmarkStore(defaults: defaults, key: "roots")
        let fallback = [URL(fileURLWithPath: "/tmp/default-root")]

        XCTAssertEqual(store.loadRoots(defaults: fallback), fallback)

        store.saveRoots([])

        XCTAssertEqual(store.loadRoots(defaults: fallback), [])
    }

    func testSavedBookmarkRestoresDirectoryWithoutExposingItThroughDiagnosticsSummary() throws {
        let suiteName = "SearchRootBookmarkStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SearchRootBookmarkStore(defaults: defaults, key: "roots")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrivateParent-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("VisibleRoot", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        store.saveRoots([root])
        let restored = store.loadRoots(defaults: [])
        let diagnostics = SearchDiagnostics(roots: restored)

        XCTAssertEqual(restored, [root.standardizedFileURL])
        XCTAssertEqual(diagnostics.rootNames, ["VisibleRoot"])
        XCTAssertFalse(diagnostics.visibleSummary.contains("PrivateParent"))
    }

    func testLegacyEmptyPreferenceIsSeededWithDefaultRootsOnce() {
        let suiteName = "SearchRootBookmarkMigrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set([Data](), forKey: "roots")
        let store = SearchRootBookmarkStore(defaults: defaults, key: "roots")
        let fallback = [URL(fileURLWithPath: "/tmp/default-root")]

        XCTAssertEqual(store.loadRoots(defaults: fallback), fallback)

        store.saveRoots([])
        XCTAssertEqual(store.loadRoots(defaults: fallback), [])
    }

    func testInvalidSavedBookmarksRecoverToDefaultRoots() {
        let suiteName = "SearchRootBookmarkRecoveryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set([Data("invalid-bookmark".utf8)], forKey: "roots")
        let store = SearchRootBookmarkStore(defaults: defaults, key: "roots")
        let fallback = [FileManager.default.temporaryDirectory]

        XCTAssertEqual(store.loadRoots(defaults: fallback), fallback)
    }

    func testExistingCustomRootsAreMergedWithNewDefaultRoots() throws {
        let suiteName = "SearchRootBookmarkDefaultsMergeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("SearchRoots-\(UUID().uuidString)", isDirectory: true)
        let defaultRoot = base.appendingPathComponent("Desktop", isDirectory: true)
        let customRoot = base.appendingPathComponent("Projects", isDirectory: true)
        try FileManager.default.createDirectory(at: defaultRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: customRoot, withIntermediateDirectories: true)
        let store = SearchRootBookmarkStore(defaults: defaults, key: "roots")
        store.saveRoots([customRoot])
        defaults.removeObject(forKey: "roots.defaults-seeded-v3")

        XCTAssertEqual(
            store.loadRoots(defaults: [defaultRoot]),
            [defaultRoot.standardizedFileURL, customRoot.standardizedFileURL]
        )
    }
}
