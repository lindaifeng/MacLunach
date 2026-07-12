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
}
