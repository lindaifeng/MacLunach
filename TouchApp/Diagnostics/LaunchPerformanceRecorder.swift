import Foundation
import os

extension Notification.Name {
    static let touchLauncherWillDisplay = Notification.Name("me.touch.launcher-will-display")
}

@MainActor
final class LaunchPerformanceRecorder {
    static let shared = LaunchPerformanceRecorder()

    private let signposter = OSSignposter(
        subsystem: "me.touch.launcher",
        category: "LauncherPerformance"
    )
    private var intervalState: OSSignpostIntervalState?
    private var startNanoseconds: UInt64?
    private var completion: ((Double) -> Void)?

    private init() {}

    func begin(completion: ((Double) -> Void)? = nil) {
        intervalState = signposter.beginInterval("LauncherToggleToVisible")
        startNanoseconds = DispatchTime.now().uptimeNanoseconds
        self.completion = completion
    }

    func endAfterRenderedFrame() {
        guard let startNanoseconds else { return }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - startNanoseconds) / 1_000_000

        if let intervalState {
            signposter.endInterval("LauncherToggleToVisible", intervalState)
        }

        let completion = completion
        self.intervalState = nil
        self.startNanoseconds = nil
        self.completion = nil
        completion?(elapsed)
    }
}
