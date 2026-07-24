import TouchFeatureAPI

/// 文本解析工作台的插件入口；转换逻辑留在插件模块，窗口由宿主托管。
public struct ParserToolsFeaturePlugin: FeaturePlugin {
    public static let id = "me.touch.parser-tools"

    public init() {}

    public let manifest = FeatureManifest(
        id: ParserToolsFeaturePlugin.id,
        name: "解析工具",
        summary: "JSON、Base64、JWT 与代码转换",
        symbolName: "curlybraces.square",
        defaultOrder: 7,
        defaultShortcut: .init(modifiers: [], key: "8"),
        executionMode: .inProcess,
        primaryAction: .perform,
        settingsPresentation: .none
    )

    public func initialState() async -> FeatureState { .available }
    public func perform() async throws -> FeatureActionResult { .presentPanel(featureID: Self.id) }
}
