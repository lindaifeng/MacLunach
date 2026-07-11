import TouchFeatureAPI

public struct ScreenshotFeaturePlugin: FeaturePlugin {
    public init() {}

    public let manifest = FeatureManifest(
        id: "me.touch.screenshot",
        name: "截取屏幕",
        summary: "截图、标注与钉图",
        symbolName: "crop",
        defaultOrder: 1,
        defaultShortcut: .init(modifiers: [.command], key: "2")
    )

    public func initialState() async -> FeatureState {
        .restricted(message: "需要配置屏幕录制权限")
    }

    public func perform() async throws -> FeatureActionResult {
        .requiresSetup(message: "请在功能区中配置截取屏幕")
    }
}
