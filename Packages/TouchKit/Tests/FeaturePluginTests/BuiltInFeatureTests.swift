import Testing
import TouchFeatureAPI
@testable import ClipboardFeature
@testable import OCRFeature
@testable import TranslationFeature
@testable import FinderFeature
@testable import ScreenshotFeature
@testable import SuperRightFeature

@MainActor
private final class ScreenshotRouterStub: ScreenshotActionRouting {
    var state: FeatureState
    var result: FeatureActionResult
    private(set) var actions: [ScreenshotPluginAction] = []
    private(set) var activationCount = 0
    private(set) var deactivationCount = 0

    init(state: FeatureState = .available, result: FeatureActionResult = .completed) {
        self.state = state
        self.result = result
    }

    func featureState() -> FeatureState { state }

    func route(_ action: ScreenshotPluginAction) async throws -> FeatureActionResult {
        actions.append(action)
        return result
    }

    func activate() async { activationCount += 1 }
    func deactivate() async { deactivationCount += 1 }
}

@Test @MainActor func builtInFeatureManifestsAreUnique() {
    let plugins: [any FeaturePlugin] = [
        FinderFeaturePlugin(),
        ScreenshotFeaturePlugin(router: ScreenshotRouterStub()),
        SuperRightFeaturePlugin()
    ]

    #expect(Set(plugins.map { $0.manifest.id }).count == 3)
    #expect(plugins.map { $0.manifest.name } == ["打开访达", "截取屏幕", "超级右键"])
}

@Test @MainActor func builtInFeatureManifestsIncludeTextWorkspaces() {
    let plugins: [any FeaturePlugin] = [
        ClipboardFeaturePlugin(),
        TranslationFeaturePlugin(systemVersion: .init(majorVersion: 15, minorVersion: 0, patchVersion: 0)),
        OCRFeaturePlugin()
    ]

    #expect(Set(plugins.map(\.manifest.id)) == [
        "me.touch.clipboard", "me.touch.translation", "me.touch.ocr"
    ])
}

@Test func unfinishedFinderExtensionIsExplicitlyRestricted() async {
    #expect(await SuperRightFeaturePlugin().initialState() == .restricted(message: "需要启用 Finder 扩展"))
}

@Test @MainActor func screenshotPluginOnlyRoutesDefaultModeAction() async throws {
    let router = ScreenshotRouterStub()
    let plugin = ScreenshotFeaturePlugin(router: router)

    #expect(await plugin.initialState() == .available)
    #expect(try await plugin.perform() == .completed)
    #expect(router.actions == [.captureDefaultMode])
}

@Test @MainActor func screenshotPluginForwardsLifecycleWithoutPerformingAnAction() async {
    let router = ScreenshotRouterStub(state: .restricted(message: "需要配置屏幕录制权限"))
    let plugin = ScreenshotFeaturePlugin(router: router)

    #expect(await plugin.initialState() == .restricted(message: "需要配置屏幕录制权限"))
    await plugin.featureDidEnable()
    await plugin.featureDidDisable()

    #expect(router.activationCount == 1)
    #expect(router.deactivationCount == 1)
    #expect(router.actions.isEmpty)
}
