import AppKit
import CoreGraphics
@preconcurrency import ScreenCaptureKit

public enum ScreenshotCaptureError: Error, Equatable, Sendable {
    case permissionDenied
    case noDisplayAvailable
    case imageEncodingFailed
}

public protocol ScreenshotCapturing: Sendable {
    func hasScreenRecordingPermission() async -> Bool
    func capturePrimaryDisplay() async throws
}

public enum ScreenRecordingAuthorization {
    public static var isGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    @MainActor
    public static func request() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    @MainActor
    public static func openSystemSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}

public actor ScreenCaptureService: ScreenshotCapturing {
    public init() {}

    public func hasScreenRecordingPermission() async -> Bool {
        ScreenRecordingAuthorization.isGranted
    }

    public func capturePrimaryDisplay() async throws {
        guard ScreenRecordingAuthorization.isGranted else {
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
