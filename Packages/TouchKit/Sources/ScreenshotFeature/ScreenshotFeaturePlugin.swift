import TouchFeatureAPI

public struct ScreenshotFeaturePlugin: FeaturePlugin {
    private let captureService: any ScreenshotCapturing

    public init(captureService: any ScreenshotCapturing = ScreenCaptureService()) {
        self.captureService = captureService
    }

    public let manifest = FeatureManifest(
        id: "me.touch.screenshot",
        name: "截取屏幕",
        summary: "截图、标注与钉图",
        symbolName: "crop",
        defaultOrder: 1,
        defaultShortcut: .init(modifiers: [.command], key: "2")
    )

    public func initialState() async -> FeatureState {
        if await captureService.hasScreenRecordingPermission() {
            return .available
        }
        return .restricted(message: "需要配置屏幕录制权限")
    }

    public func perform() async throws -> FeatureActionResult {
        guard await captureService.hasScreenRecordingPermission() else {
            return .requiresSetup(message: "请允许触达录制屏幕")
        }
        try await captureService.capturePrimaryDisplay()
        return .completed
    }
}
