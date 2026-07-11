import TouchFeatureAPI

public struct SuperRightFeaturePlugin: FeaturePlugin {
    public init() {}

    public let manifest = FeatureManifest(
        id: "me.touch.super-right",
        name: "超级右键",
        summary: "增强 Finder 右键菜单",
        symbolName: "ellipsis",
        defaultOrder: 2,
        defaultShortcut: .init(modifiers: [.command], key: "3")
    )

    public func initialState() async -> FeatureState {
        .restricted(message: "需要启用 Finder 扩展")
    }

    public func perform() async throws -> FeatureActionResult {
        .requiresSetup(message: "请在功能区中配置超级右键")
    }
}
