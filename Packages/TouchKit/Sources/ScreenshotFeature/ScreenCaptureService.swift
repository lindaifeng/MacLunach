import AppKit
import CoreGraphics
@preconcurrency import ScreenCaptureKit

public enum ScreenshotCaptureError: Error, Equatable, Sendable {
    case permissionDenied
    case noDisplayAvailable
    case imageEncodingFailed
}

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

public actor ScreenCaptureService: ScreenshotCapturing {
    public init() {}

    public func capturePrimaryDisplay() async throws {
        guard CGPreflightScreenCaptureAccess() else {
            throw ScreenshotCaptureError.permissionDenied
        }

        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
                ?? content.displays.first else {
            throw ScreenshotCaptureError.noDisplayAvailable
        }
        let ownApplications = content.applications.filter {
            $0.bundleIdentifier == Bundle.main.bundleIdentifier
        }
        let filter = SCContentFilter(
            display: display,
            excludingApplications: ownApplications,
            exceptingWindows: []
        )
        let configuration = SCStreamConfiguration()
        configuration.width = display.width
        configuration.height = display.height
        configuration.showsCursor = false
        configuration.capturesAudio = false

        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
        let pngData = await MainActor.run {
            let representation = NSBitmapImageRep(cgImage: image)
            return representation.representation(using: .png, properties: [:])
        }
        guard let pngData else { throw ScreenshotCaptureError.imageEncodingFailed }

        await MainActor.run {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setData(pngData, forType: .png)
        }
    }
}
