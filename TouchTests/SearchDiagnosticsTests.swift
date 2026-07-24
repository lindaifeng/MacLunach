import Foundation
import XCTest
@testable import 触达

@MainActor
final class SearchDiagnosticsTests: XCTestCase {
    func testVisibleDiagnosticsUseRootNamesWithoutExposingFullPaths() {
        let diagnostics = SearchDiagnostics(
            roots: [
                URL(fileURLWithPath: "/Users/example/Documents"),
                URL(fileURLWithPath: "/Volumes/Private/Design")
            ],
            fileCount: 42,
            databaseSize: 2_048,
            lastUpdatedAt: Date(timeIntervalSince1970: 1_000),
            status: .ready
        )

        XCTAssertEqual(diagnostics.rootNames, ["Documents", "Design"])
        XCTAssertFalse(diagnostics.visibleSummary.contains("/Users/example"))
        XCTAssertFalse(diagnostics.visibleSummary.contains("/Volumes/Private"))
        XCTAssertTrue(diagnostics.visibleSummary.contains("42"))
    }

    func testIndexingProgressIsClampedAndClearedWhenReady() {
        let diagnostics = SearchDiagnostics(
            roots: [URL(fileURLWithPath: "/tmp/Desktop")],
            status: .indexing
        )

        diagnostics.updateIndexingProgress(1.4, rootName: "Desktop")

        XCTAssertEqual(diagnostics.indexingProgress, 1)
        XCTAssertEqual(diagnostics.indexingRootName, "Desktop")
        XCTAssertTrue(diagnostics.isActivelyIndexing)

        diagnostics.update(status: .ready)

        XCTAssertNil(diagnostics.indexingProgress)
        XCTAssertNil(diagnostics.indexingRootName)
        XCTAssertFalse(diagnostics.isActivelyIndexing)
    }
}
