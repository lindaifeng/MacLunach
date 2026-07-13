import Testing
import TouchFeatureAPI
@testable import FinderFeature
@testable import ScreenshotFeature
@testable import SuperRightFeature

@Test func builtInFeatureManifestsAreUnique() {
    let plugins: [any FeaturePlugin] = [
        FinderFeaturePlugin(),
        ScreenshotFeaturePlugin(),
        SuperRightFeaturePlugin()
    ]

    #expect(Set(plugins.map { $0.manifest.id }).count == 3)
    #expect(plugins.map { $0.manifest.name } == ["打开访达", "截取屏幕", "超级右键"])
}

@Test func unfinishedFinderExtensionIsExplicitlyRestricted() async {
    #expect(await SuperRightFeaturePlugin().initialState() == .restricted(message: "需要启用 Finder 扩展"))
}

private actor ScreenshotCaptureServiceStub: ScreenshotCapturing {
    let permission: Bool
    private(set) var captureCount = 0

    init(permission: Bool) {
        self.permission = permission
    }

    func hasScreenRecordingPermission() async -> Bool { permission }

    func capturePrimaryDisplay() async throws {
        captureCount += 1
    }
}

@Test func screenshotPluginCapturesWhenPermissionIsGranted() async throws {
    let service = ScreenshotCaptureServiceStub(permission: true)
    let plugin = ScreenshotFeaturePlugin(captureService: service)

    #expect(await plugin.initialState() == .available)
    #expect(try await plugin.perform() == .completed)
    #expect(await service.captureCount == 1)
}

@Test func screenshotPluginRequestsSetupWithoutCapturingWhenPermissionIsMissing() async throws {
    let service = ScreenshotCaptureServiceStub(permission: false)
    let plugin = ScreenshotFeaturePlugin(captureService: service)

    #expect(await plugin.initialState() == .restricted(message: "需要配置屏幕录制权限"))
    #expect(try await plugin.perform() == .requiresSetup(message: "请允许触达录制屏幕"))
    #expect(await service.captureCount == 0)
}
