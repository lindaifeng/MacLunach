import AppKit
import ScreenshotFeature
import XCTest
@testable import 触达

final class FloatingThumbnailStateTests: XCTestCase {
    func testDefaultPolicyCopiesAndShowsThumbnail() {
        let policy = ScreenshotPostCapturePolicy(configuration: .init())
        XCTAssertTrue(policy.copiesToClipboard)
        XCTAssertTrue(policy.showsThumbnail)
        XCTAssertFalse(policy.beginsAnnotation)
    }

    func testConfiguredPostCaptureActionsAreMutuallyExclusive() {
        var configuration = ScreenshotFeatureConfiguration(afterCaptureAction: .saveOnly)
        XCTAssertEqual(
            ScreenshotPostCapturePolicy(configuration: configuration),
            .init(copiesToClipboard: false, showsThumbnail: false, beginsAnnotation: false)
        )

        configuration.afterCaptureAction = .copyAndSave
        XCTAssertEqual(
            ScreenshotPostCapturePolicy(configuration: configuration),
            .init(copiesToClipboard: true, showsThumbnail: false, beginsAnnotation: false)
        )

        configuration.afterCaptureAction = .annotate
        XCTAssertEqual(
            ScreenshotPostCapturePolicy(configuration: configuration),
            .init(copiesToClipboard: false, showsThumbnail: false, beginsAnnotation: true)
        )

        configuration.afterCaptureAction = .copyAndShowThumbnail
        configuration.showsFloatingThumbnail = false
        XCTAssertFalse(ScreenshotPostCapturePolicy(configuration: configuration).showsThumbnail)
    }

    func testTimeoutSupportsZeroThreeFiveTenAndNever() {
        XCTAssertEqual(ScreenshotThumbnailTimeout.seconds(0).floatingThumbnailDelay, 0)
        XCTAssertEqual(ScreenshotThumbnailTimeout.seconds(3).floatingThumbnailDelay, 3)
        XCTAssertEqual(ScreenshotThumbnailTimeout.seconds(5).floatingThumbnailDelay, 5)
        XCTAssertEqual(ScreenshotThumbnailTimeout.seconds(10).floatingThumbnailDelay, 10)
        XCTAssertNil(ScreenshotThumbnailTimeout.never.floatingThumbnailDelay)
    }

    func testSingleAndDoubleClickCannotBothFire() {
        var state = FloatingThumbnailInteractionState()
        state.pointerDown()
        XCTAssertEqual(state.pointerUp(clickCount: 1), .scheduleSingleClick)
        XCTAssertTrue(state.hasPendingSingleClick)

        state.pointerDown()
        XCTAssertEqual(state.pointerUp(clickCount: 2), .performDoubleClick)
        XCTAssertFalse(state.consumeSingleClick())
    }

    func testDragCancelsPendingClick() {
        var state = FloatingThumbnailInteractionState()
        state.pointerDown()
        XCTAssertEqual(state.pointerUp(clickCount: 1), .scheduleSingleClick)
        state.pointerDown()
        XCTAssertEqual(state.pointerMoved(distance: 8), .beginDrag)
        XCTAssertEqual(state.pointerUp(clickCount: 1), .none)
        XCTAssertFalse(state.consumeSingleClick())
    }

    func testBottomRightLayoutStaysInsideVisibleFrameAndStacksUpward() {
        let visible = CGRect(x: -1_440, y: 25, width: 1_440, height: 875)
        let first = FloatingThumbnailLayout.frame(
            contentSize: CGSize(width: 1_200, height: 800),
            visibleFrame: visible,
            verticalOffset: 0
        )
        let second = FloatingThumbnailLayout.frame(
            contentSize: CGSize(width: 1_200, height: 800),
            visibleFrame: visible,
            verticalOffset: first.height + FloatingThumbnailLayout.spacing
        )

        XCTAssertGreaterThanOrEqual(first.minX, visible.minX)
        XCTAssertGreaterThanOrEqual(first.minY, visible.minY)
        XCTAssertLessThanOrEqual(first.maxX, visible.maxX)
        XCTAssertLessThanOrEqual(first.maxY, visible.maxY)
        XCTAssertEqual(first.maxX, visible.maxX - FloatingThumbnailLayout.margin)
        XCTAssertGreaterThan(second.minY, first.minY)
    }

    func testDifferentThumbnailHeightsUseCumulativeOffsetWithoutOverlapping() {
        let visible = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let first = FloatingThumbnailLayout.frame(
            contentSize: CGSize(width: 1_200, height: 800),
            visibleFrame: visible,
            verticalOffset: 0
        )
        let second = FloatingThumbnailLayout.frame(
            contentSize: CGSize(width: 1_200, height: 240),
            visibleFrame: visible,
            verticalOffset: first.height + FloatingThumbnailLayout.spacing
        )

        XCTAssertGreaterThanOrEqual(
            second.minY,
            first.maxY + FloatingThumbnailLayout.spacing
        )
    }

    func testExtremeAspectRatiosStayWithinThumbnailBounds() {
        for sourceSize in [
            CGSize(width: 10_000, height: 100),
            CGSize(width: 100, height: 10_000)
        ] {
            let size = FloatingThumbnailLayout.panelSize(for: sourceSize)
            XCTAssertGreaterThanOrEqual(size.width, FloatingThumbnailLayout.minimumContentSize.width)
            XCTAssertGreaterThanOrEqual(size.height, FloatingThumbnailLayout.minimumContentSize.height)
            XCTAssertLessThanOrEqual(size.width, FloatingThumbnailLayout.maximumContentSize.width)
            XCTAssertLessThanOrEqual(size.height, FloatingThumbnailLayout.maximumContentSize.height)
        }
    }
}
