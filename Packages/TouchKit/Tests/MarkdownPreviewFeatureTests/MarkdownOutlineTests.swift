import XCTest
@testable import MarkdownPreviewFeature
final class MarkdownOutlineTests: XCTestCase {
    func testLevelsDuplicatesAndEmptyHeadings() {
        let state = MarkdownOutlineBuilder().build(renderedHeadings: [(1," 标题 "),(2,"标题"),(6,"尾部"),(3,"   "),(7,"忽略")], mode: .reading)
        guard case let .available(headings) = state else { return XCTFail() }
        XCTAssertEqual(headings.map(\.level), [1,2,6])
        XCTAssertEqual(headings.map(\.id), ["标题", "标题-1", "尾部"])
    }
    func testEditingIsRestricted() {
        XCTAssertEqual(MarkdownOutlineBuilder().build(renderedHeadings: [(1,"A")], mode: .editing), .restricted(message: "切换到阅读或分栏模式以查看目录"))
    }

    func testOutlineKeepsRenderedAnchorInsteadOfRebuildingSourceAnchor() {
        let state = MarkdownOutlineBuilder().build(
            renderedHeadings: [.init(level: 2, title: "重复", anchor: "rendered-7")],
            mode: .split
        )

        guard case let .available(headings) = state else { return XCTFail() }
        XCTAssertEqual(headings.first?.id, "rendered-7")
    }

    func testEditingIsRestrictedWithoutSourceParsing() {
        XCTAssertEqual(
            MarkdownOutlineBuilder().build(
                renderedHeadings: [RenderedMarkdownHeading](),
                mode: .editing
            ),
            .restricted(message: "切换到阅读或分栏模式以查看目录")
        )
    }
    func testActiveHeadingUsesLastHeadingAboveViewport() {
        let headings = [MarkdownHeading(id:"a",level:1,title:"A",sourceIndex:0), MarkdownHeading(id:"b",level:2,title:"B",sourceIndex:1)]
        XCTAssertEqual(MarkdownOutlineBuilder().activeHeading(in: headings, visibleOffsets: ["a":-100,"b":10])?.id, "b")
    }
}
