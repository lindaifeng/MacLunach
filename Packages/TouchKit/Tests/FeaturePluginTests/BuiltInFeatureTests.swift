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

@Test func unfinishedServicesAreExplicitlyRestricted() async {
    #expect(await ScreenshotFeaturePlugin().initialState() == .restricted(message: "需要配置屏幕录制权限"))
    #expect(await SuperRightFeaturePlugin().initialState() == .restricted(message: "需要启用 Finder 扩展"))
}
