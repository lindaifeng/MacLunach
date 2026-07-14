import CoreGraphics
import XCTest
@testable import 触达

final class SelectionGeometryTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 300, height: 200)

    func testDragNormalizesAllDirectionsAndEnforcesMinimumSizeInsideBounds() {
        XCTAssertEqual(
            SelectionGeometry.dragRect(
                from: CGPoint(x: 200, y: 150),
                to: CGPoint(x: 50, y: 40),
                in: bounds
            ),
            CGRect(x: 50, y: 40, width: 150, height: 110)
        )
        XCTAssertEqual(
            SelectionGeometry.dragRect(
                from: CGPoint(x: 298, y: 198),
                to: CGPoint(x: 299, y: 199),
                in: bounds,
                minimumSize: CGSize(width: 12, height: 10)
            ),
            CGRect(x: 288, y: 190, width: 12, height: 10)
        )
    }

    func testEightHandlesResizeWhileKeepingOppositeEdgeAndBounds() {
        let original = CGRect(x: 80, y: 60, width: 100, height: 80)
        let expectations: [(SelectionHandle, CGPoint, CGRect)] = [
            (.topLeft, CGPoint(x: 40, y: 20), CGRect(x: 40, y: 20, width: 140, height: 120)),
            (.top, CGPoint(x: 130, y: 20), CGRect(x: 80, y: 20, width: 100, height: 120)),
            (.topRight, CGPoint(x: 220, y: 20), CGRect(x: 80, y: 20, width: 140, height: 120)),
            (.right, CGPoint(x: 220, y: 100), CGRect(x: 80, y: 60, width: 140, height: 80)),
            (.bottomRight, CGPoint(x: 220, y: 180), CGRect(x: 80, y: 60, width: 140, height: 120)),
            (.bottom, CGPoint(x: 130, y: 180), CGRect(x: 80, y: 60, width: 100, height: 120)),
            (.bottomLeft, CGPoint(x: 40, y: 180), CGRect(x: 40, y: 60, width: 140, height: 120)),
            (.left, CGPoint(x: 40, y: 100), CGRect(x: 40, y: 60, width: 140, height: 80))
        ]

        for (handle, point, expected) in expectations {
            XCTAssertEqual(
                SelectionGeometry.resize(original, handle: handle, to: point, in: bounds),
                expected,
                "控制点 \(handle) 调整错误"
            )
        }

        XCTAssertEqual(
            SelectionGeometry.resize(
                original,
                handle: .left,
                to: CGPoint(x: 179, y: 100),
                in: bounds,
                minimumSize: CGSize(width: 16, height: 16)
            ),
            CGRect(x: 164, y: 60, width: 16, height: 80)
        )
    }

    func testSpaceMoveAndKeyboardNudgeStayInsideScreen() {
        let original = CGRect(x: 20, y: 30, width: 60, height: 40)
        XCTAssertEqual(
            SelectionGeometry.move(original, by: CGVector(dx: 40, dy: 30), in: bounds),
            CGRect(x: 60, y: 60, width: 60, height: 40)
        )
        XCTAssertEqual(
            SelectionGeometry.move(original, by: CGVector(dx: -100, dy: 500), in: bounds),
            CGRect(x: 0, y: 160, width: 60, height: 40)
        )
        XCTAssertEqual(
            SelectionGeometry.nudge(original, direction: .right, accelerated: false, in: bounds),
            CGRect(x: 21, y: 30, width: 60, height: 40)
        )
        XCTAssertEqual(
            SelectionGeometry.nudge(original, direction: .down, accelerated: true, in: bounds),
            CGRect(x: 20, y: 40, width: 60, height: 40)
        )
    }

    func testRetinaPixelSizeUsesCoveredPixelEdges() {
        XCTAssertEqual(
            SelectionGeometry.pixelSize(
                for: CGRect(x: 10.25, y: 20.5, width: 80.5, height: 40.25),
                scaleFactor: 2
            ),
            CGSize(width: 162, height: 81)
        )
    }

    func testSizeLabelRemainsInsideCurrentScreen() {
        let size = CGSize(width: 96, height: 28)
        let frame = SelectionGeometry.labelFrame(
            pointer: CGPoint(x: 296, y: 196),
            labelSize: size,
            in: bounds
        )

        XCTAssertTrue(bounds.contains(frame))
        XCTAssertLessThan(frame.minX, 296)
        XCTAssertLessThan(frame.minY, 196)
    }

    func testSelectionThatReachesAllDisplayEdgesIsRecognizedAsFullScreen() {
        let displayBounds = CGRect(x: 12, y: 24, width: 1000, height: 700)

        XCTAssertTrue(SelectionGeometry.covers(displayBounds, displayBounds))
        XCTAssertTrue(
            SelectionGeometry.covers(
                displayBounds.insetBy(dx: 0.5, dy: 0.5),
                displayBounds
            )
        )
        XCTAssertFalse(
            SelectionGeometry.covers(
                displayBounds.insetBy(dx: 1.1, dy: 0),
                displayBounds
            )
        )
        XCTAssertFalse(
            SelectionGeometry.covers(
                displayBounds.insetBy(dx: 0, dy: 1.1),
                displayBounds
            )
        )
    }
}
