import AppKit
import ScreenshotFeature

@MainActor
final class ScreenshotSelectionFixtureAuthorizer: ScreenRecordingAuthorizing {
    var status: ScreenshotPermissionState { .authorized }
    func requestAccess() -> ScreenshotPermissionState { .authorized }
    func openSystemSettings() {}
}

final class ScreenshotSelectionFixtureCaptureService: ScreenshotCapturing, @unchecked Sendable {
    private let content: ScreenshotSelectionContent
    private let outputURL: URL

    init(content: ScreenshotSelectionContent, outputURL: URL) {
        self.content = content
        self.outputURL = outputURL
    }

    func availableSelectionContent() async throws -> ScreenshotSelectionContent {
        content
    }

    func capture(_ request: ScreenshotCaptureRequest) async throws {
        let data = try JSONEncoder().encode(request)
        try data.write(to: outputURL, options: .atomic)
    }

    func capturePrimaryDisplay() async throws {
        guard let display = content.displays.first else {
            throw ScreenshotFeatureError.noDisplayAvailable
        }
        try await capture(.init(mode: .fullScreen, target: .display(displayID: display.id)))
    }
}

@MainActor
enum ScreenshotSelectionFixtureContent {
    static func make() -> ScreenshotSelectionContent {
        let screens = NSScreen.screens
        let virtualMinX = screens.map(\.frame.minX).min() ?? 0
        let virtualMaxY = screens.map(\.frame.maxY).max() ?? 0
        let displays = screens.compactMap { screen -> ScreenshotDisplayDescriptor? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                    as? NSNumber else { return nil }
            return ScreenshotDisplayDescriptor(
                id: number.uint32Value,
                frame: .init(
                    x: screen.frame.minX - virtualMinX,
                    y: virtualMaxY - screen.frame.maxY,
                    width: screen.frame.width,
                    height: screen.frame.height
                ),
                pixelSize: .init(
                    width: screen.frame.width * screen.backingScaleFactor,
                    height: screen.frame.height * screen.backingScaleFactor
                ),
                scaleFactor: screen.backingScaleFactor
            )
        }
        let windows = displays.first.map { display in
            [ScreenshotWindowDescriptor(
                id: 990_001,
                ownerBundleIdentifier: "com.example.selection-fixture",
                title: "吸附测试窗口",
                frame: .init(
                    x: display.frame.x + display.frame.width * 0.66,
                    y: display.frame.y + display.frame.height * 0.18,
                    width: display.frame.width * 0.22,
                    height: display.frame.height * 0.26
                ),
                isOnScreen: true
            )]
        } ?? []
        return ScreenshotSelectionContent(displays: displays, windows: windows)
    }
}
