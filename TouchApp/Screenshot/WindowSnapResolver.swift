import CoreGraphics
import ScreenshotFeature

struct WindowSnapMatch: Equatable, Sendable {
    let windowID: UInt32
    let frame: CGRect
    let title: String?
}

struct WindowSnapResolver: Sendable {
    private let windows: [ScreenshotWindowDescriptor]
    private let excludedBundleIdentifiers: Set<String>
    let releaseThreshold: CGFloat

    init(
        windows: [ScreenshotWindowDescriptor],
        excludedBundleIdentifiers: Set<String> = [
            "me.touch.launcher",
            "me.touch.launcher.ScreenshotService"
        ],
        releaseThreshold: CGFloat = 8
    ) {
        self.windows = windows
        self.excludedBundleIdentifiers = excludedBundleIdentifiers
        self.releaseThreshold = max(0, releaseThreshold)
    }

    func candidate(at point: CGPoint) -> WindowSnapMatch? {
        for window in windows where window.isOnScreen {
            if let bundleID = window.ownerBundleIdentifier,
               excludedBundleIdentifiers.contains(bundleID) {
                continue
            }
            let frame = CGRect(
                x: window.frame.x,
                y: window.frame.y,
                width: window.frame.width,
                height: window.frame.height
            )
            guard frame.width > 0, frame.height > 0, frame.contains(point) else { continue }
            return WindowSnapMatch(windowID: window.id, frame: frame, title: window.title)
        }
        return nil
    }

    func shouldReleaseSnap(from origin: CGPoint, to current: CGPoint) -> Bool {
        hypot(current.x - origin.x, current.y - origin.y) > releaseThreshold
    }
}
