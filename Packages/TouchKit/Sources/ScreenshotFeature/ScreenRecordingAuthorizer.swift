import AppKit
import CoreGraphics
import Foundation

public protocol ScreenshotCapturing: Sendable {
    func capturePrimaryDisplay() async throws
}

@MainActor
public protocol ScreenRecordingAuthorizing: AnyObject, Sendable {
    var status: ScreenshotPermissionState { get }
    func requestAccess() -> ScreenshotPermissionState
    func openSystemSettings()
}

@MainActor
public final class SystemScreenRecordingAuthorizer: ScreenRecordingAuthorizing {
    public static let requestRecordedKey = "me.touch.screenshot.screen-recording-requested.v1"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var status: ScreenshotPermissionState {
        if CGPreflightScreenCaptureAccess() {
            return .authorized
        }
        return defaults.bool(forKey: Self.requestRecordedKey) ? .denied : .notRequested
    }

    public func requestAccess() -> ScreenshotPermissionState {
        guard status == .notRequested else { return status }
        defaults.set(true, forKey: Self.requestRecordedKey)
        return CGRequestScreenCaptureAccess() ? .authorized : .denied
    }

    public func openSystemSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}
