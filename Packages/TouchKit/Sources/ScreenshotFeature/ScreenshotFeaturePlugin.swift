import TouchFeatureAPI

public enum ScreenshotPluginAction: Equatable, Sendable {
    case captureDefaultMode
}

@MainActor
public protocol ScreenshotActionRouting: AnyObject, Sendable {
    func featureState() -> FeatureState
    func route(_ action: ScreenshotPluginAction) async throws -> FeatureActionResult
    func activate() async
    func deactivate() async
}

public struct ScreenshotFeaturePlugin: FeaturePlugin, FeatureLifecycleHandling {
    private let router: any ScreenshotActionRouting

    public init(router: any ScreenshotActionRouting) {
        self.router = router
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
        await router.featureState()
    }

    public func perform() async throws -> FeatureActionResult {
        try await router.route(.captureDefaultMode)
    }

    public func featureDidEnable() async {
        await router.activate()
    }

    public func featureDidDisable() async {
        await router.deactivate()
    }
}
