import CoreGraphics
import ScreenshotFeature
import XCTest
@testable import 触达

final class WindowSnapResolverTests: XCTestCase {
    func testPointerSnapsToFrontmostVisibleEligibleWindow() {
        let windows = [
            window(id: 1, bundleID: "com.example.front", frame: CGRect(x: 20, y: 20, width: 80, height: 60)),
            window(id: 2, bundleID: "com.example.back", frame: CGRect(x: 0, y: 0, width: 200, height: 160)),
            window(id: 3, bundleID: "com.example.hidden", frame: CGRect(x: 20, y: 20, width: 80, height: 60), isOnScreen: false)
        ]
        let resolver = WindowSnapResolver(windows: windows)

        let match = resolver.candidate(at: CGPoint(x: 40, y: 40))

        XCTAssertEqual(match?.windowID, 1)
        XCTAssertEqual(match?.frame, CGRect(x: 20, y: 20, width: 80, height: 60))
    }

    func testTouchWindowsAndZeroSizedWindowsAreNeverSnapped() {
        let resolver = WindowSnapResolver(
            windows: [
                window(id: 1, bundleID: "me.touch.launcher", frame: CGRect(x: 0, y: 0, width: 100, height: 100)),
                window(id: 2, bundleID: "me.touch.launcher.ScreenshotService", frame: CGRect(x: 0, y: 0, width: 100, height: 100)),
                window(id: 3, bundleID: "com.example.empty", frame: .zero)
            ]
        )

        XCTAssertNil(resolver.candidate(at: CGPoint(x: 20, y: 20)))
    }

    func testDraggingPastThresholdReleasesWindowSnap() {
        let resolver = WindowSnapResolver(windows: [], releaseThreshold: 8)

        XCTAssertFalse(resolver.shouldReleaseSnap(from: CGPoint(x: 50, y: 50), to: CGPoint(x: 56, y: 55)))
        XCTAssertTrue(resolver.shouldReleaseSnap(from: CGPoint(x: 50, y: 50), to: CGPoint(x: 59, y: 50)))
    }

    private func window(
        id: UInt32,
        bundleID: String,
        frame: CGRect,
        isOnScreen: Bool = true
    ) -> ScreenshotWindowDescriptor {
        .init(
            id: id,
            ownerBundleIdentifier: bundleID,
            title: "窗口 \(id)",
            frame: .init(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height),
            isOnScreen: isOnScreen
        )
    }
}
