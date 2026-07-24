import TouchFeatureAPI

/// Markdown 阅读与编辑工作区的插件入口；具体窗口由宿主负责提供。
public struct MarkdownPreviewFeaturePlugin: FeaturePlugin {
    public static let id = "me.touch.markdown-preview"

    public init() {}

    public let manifest = FeatureManifest(
        id: MarkdownPreviewFeaturePlugin.id,
        name: "Markdown",
        summary: "编辑与渲染实时对照",
        symbolName: "text.document",
        defaultOrder: 6,
        defaultShortcut: .init(modifiers: [], key: "7"),
        executionMode: .inProcess,
        primaryAction: .perform,
        settingsPresentation: .none
    )

    public func initialState() async -> FeatureState { .available }
    public func perform() async throws -> FeatureActionResult { .presentPanel(featureID: Self.id) }
}
