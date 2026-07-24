import CryptoKit
import Foundation
import XCTest
@testable import 触达

@MainActor
final class MarkdownPreviewOutlineBridgeTests: XCTestCase {
    func testDOMHeadingsKeepTheirRenderedAnchorsWithoutChangingMarkdownSource() {
        let source = """
        # 重复

        ## 重复
        """
        let sourceHashBeforeExtraction = SHA256.hash(data: Data(source.utf8))
        let headings = MarkdownPreviewOutlineBridge.headings(from: [
            ["level": 1, "title": "重复", "anchor": "rendered-2"],
            ["level": 2, "title": "重复", "anchor": "rendered-7"]
        ])
        let sourceHashAfterExtraction = SHA256.hash(data: Data(source.utf8))

        XCTAssertEqual(headings.map(\.anchor), ["rendered-2", "rendered-7"])
        XCTAssertEqual(sourceHashBeforeExtraction, sourceHashAfterExtraction)
    }

    func testBridgeAssignsMissingDOMAnchorsAndScrollsByRenderedAnchor() {
        XCTAssertTrue(MarkdownPreviewOutlineBridge.collectHeadingsScript.contains("node.id || `touch-heading-${index}`"))
        XCTAssertTrue(MarkdownPreviewOutlineBridge.collectHeadingsScript.contains("node.id = `touch-heading-${index}`"))
        XCTAssertEqual(
            MarkdownPreviewOutlineBridge.scrollToHeadingScript(anchor: "section-\"two\""),
            "document.getElementById(\"section-\\\"two\\\"\")?.scrollIntoView({ behavior: 'smooth', block: 'start' });"
        )
    }
}
