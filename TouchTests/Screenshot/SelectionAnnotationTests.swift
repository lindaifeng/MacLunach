import CoreGraphics
import ScreenshotFeature
import XCTest
@testable import 触达

final class SelectionAnnotationTests: XCTestCase {
    func testGlobalOverlayPointsBecomeCaptureRelativeCoordinates() {
        let annotation = SelectionAnnotation(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            kind: .arrow,
            points: [CGPoint(x: 120, y: 230), CGPoint(x: 180, y: 290)],
            style: .init(color: .red, lineWidth: 3)
        )

        let capture = annotation.captureAnnotation(
            relativeTo: CGRect(x: 100, y: 200, width: 300, height: 200)
        )

        XCTAssertEqual(capture.kind, .arrow)
        XCTAssertEqual(capture.points, [.init(x: 20, y: 30), .init(x: 80, y: 90)])
        XCTAssertEqual(capture.style, annotation.style)
        XCTAssertNil(capture.text)
    }

    func testOnlyImplementedDrawingToolsMapToAnnotationKinds() {
        XCTAssertEqual(SelectionToolbarItem.rectangle.drawableAnnotationKind, .rectangle)
        XCTAssertEqual(SelectionToolbarItem.ellipse.drawableAnnotationKind, .ellipse)
        XCTAssertEqual(SelectionToolbarItem.line.drawableAnnotationKind, .line)
        XCTAssertEqual(SelectionToolbarItem.arrow.drawableAnnotationKind, .arrow)
        XCTAssertEqual(SelectionToolbarItem.freehand.drawableAnnotationKind, .freehand)
        XCTAssertEqual(SelectionToolbarItem.highlighter.drawableAnnotationKind, .highlighter)
        XCTAssertNil(SelectionToolbarItem.text.drawableAnnotationKind)
        XCTAssertTrue(SelectionToolbarItem.text.isImplementedAnnotationTool)
        XCTAssertTrue(SelectionToolbarItem.numberedMarker.isImplementedAnnotationTool)
        XCTAssertTrue(SelectionToolbarItem.note.isImplementedAnnotationTool)
        XCTAssertTrue(SelectionToolbarItem.sticker.isImplementedAnnotationTool)
        XCTAssertEqual(SelectionToolbarItem.mosaic.drawableAnnotationKind, .mosaic)
        XCTAssertTrue(SelectionToolbarItem.mosaic.isImplementedAnnotationTool)
        XCTAssertFalse(SelectionToolbarItem.copy.isImplementedAnnotationTool)
    }

    func testTextPayloadIsPreservedWhenCoordinatesBecomeCaptureRelative() {
        let annotation = SelectionAnnotation(
            kind: .note,
            points: [CGPoint(x: 120, y: 230), CGPoint(x: 320, y: 310)],
            style: .init(color: .red, lineWidth: 2),
            text: .init(value: "两行备注\n继续", fontSize: 14)
        )

        let capture = annotation.captureAnnotation(
            relativeTo: CGRect(x: 100, y: 200, width: 300, height: 200)
        )

        XCTAssertEqual(capture.kind, .note)
        XCTAssertEqual(capture.points, [.init(x: 20, y: 30), .init(x: 220, y: 110)])
        XCTAssertEqual(capture.text, .init(value: "两行备注\n继续", fontSize: 14))
    }

    func testMosaicParametersArePreservedWhenCoordinatesBecomeCaptureRelative() {
        let annotation = SelectionAnnotation(
            kind: .mosaic,
            points: [CGPoint(x: 120, y: 230), CGPoint(x: 180, y: 250)],
            style: .init(color: .red, lineWidth: 28),
            mosaic: .init(blockSize: 9)
        )

        let capture = annotation.captureAnnotation(
            relativeTo: CGRect(x: 100, y: 200, width: 300, height: 200)
        )

        XCTAssertEqual(capture.kind, .mosaic)
        XCTAssertEqual(capture.points, [.init(x: 20, y: 30), .init(x: 80, y: 50)])
        XCTAssertEqual(capture.mosaic, .init(blockSize: 9))
    }

    func testStickerPayloadIsPreservedWhenCoordinatesBecomeCaptureRelative() {
        let annotation = SelectionAnnotation(
            kind: .sticker,
            points: [CGPoint(x: 145, y: 250)],
            style: .init(color: .red, lineWidth: 1),
            sticker: .init(value: "✅", size: 34)
        )

        let capture = annotation.captureAnnotation(
            relativeTo: CGRect(x: 100, y: 200, width: 300, height: 200)
        )

        XCTAssertEqual(capture.kind, .sticker)
        XCTAssertEqual(capture.points, [.init(x: 45, y: 50)])
        XCTAssertEqual(capture.sticker, .init(value: "✅", size: 34))
    }

    func testWatermarkPayloadAndBoundsBecomeCaptureRelative() {
        let watermark = ScreenshotAnnotationWatermark(
            value: "机密",
            fontSize: 16,
            opacity: 0.2,
            angleDegrees: -24,
            spacing: 70
        )
        let annotation = SelectionAnnotation(
            kind: .watermark,
            points: [CGPoint(x: 100, y: 200), CGPoint(x: 400, y: 400)],
            style: .init(color: .red, lineWidth: 1),
            watermark: watermark
        )

        let capture = annotation.captureAnnotation(
            relativeTo: CGRect(x: 100, y: 200, width: 300, height: 200)
        )

        XCTAssertEqual(capture.points, [.init(x: 0, y: 0), .init(x: 300, y: 200)])
        XCTAssertEqual(capture.watermark, watermark)
    }

    func testBeautifyPayloadAndBoundsBecomeCaptureRelative() {
        let beautify = ScreenshotAnnotationBeautify(
            cornerRadius: 16,
            shadowRadius: 14,
            shadowOpacity: 0.22,
            shadowOffsetX: 0,
            shadowOffsetY: 5,
            insets: .init(top: 32, right: 32, bottom: 32, left: 32),
            backgroundGradient: .init(
                colors: [.init(red: 0.3, green: 0.2, blue: 0.9),
                         .init(red: 0.2, green: 0.8, blue: 0.9)],
                angleDegrees: 25
            )
        )
        let annotation = SelectionAnnotation(
            kind: .beautify,
            points: [CGPoint(x: 100, y: 200), CGPoint(x: 400, y: 400)],
            style: .init(color: .red, lineWidth: 1),
            beautify: beautify
        )

        let capture = annotation.captureAnnotation(
            relativeTo: CGRect(x: 100, y: 200, width: 300, height: 200)
        )

        XCTAssertEqual(capture.points, [.init(x: 0, y: 0), .init(x: 300, y: 200)])
        XCTAssertEqual(capture.beautify, beautify)
    }

    func testAnnotationHistorySupportsUndoRedoAndClearsRedoBranch() {
        let first = annotation(id: "11111111-1111-1111-1111-111111111111")
        let second = annotation(id: "22222222-2222-2222-2222-222222222222")
        let replacement = annotation(id: "33333333-3333-3333-3333-333333333333")
        var history = SelectionAnnotationHistory()
        history.add(first)
        history.add(second)

        XCTAssertEqual(history.undo(), second)
        XCTAssertEqual(history.annotations, [first])
        XCTAssertEqual(history.redo(), second)
        XCTAssertEqual(history.annotations, [first, second])
        XCTAssertEqual(history.undo(), second)

        history.add(replacement)

        XCTAssertNil(history.redo())
        XCTAssertEqual(history.annotations, [first, replacement])
    }

    func testAnnotationHistoryUpdatesActiveDraftWithoutCreatingUndoEntries() {
        let draft = annotation(id: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
        var history = SelectionAnnotationHistory()
        history.add(draft)

        XCTAssertTrue(history.update(id: draft.id) { $0.points.append(CGPoint(x: 90, y: 100)) })
        XCTAssertEqual(history.annotations.first?.points.count, 3)
        XCTAssertEqual(history.undo()?.id, draft.id)
        XCTAssertTrue(history.annotations.isEmpty)
    }

    private func annotation(id: String) -> SelectionAnnotation {
        SelectionAnnotation(
            id: UUID(uuidString: id)!,
            kind: .line,
            points: [CGPoint(x: 10, y: 20), CGPoint(x: 30, y: 40)],
            style: .init(color: .red, lineWidth: 3)
        )
    }
}
