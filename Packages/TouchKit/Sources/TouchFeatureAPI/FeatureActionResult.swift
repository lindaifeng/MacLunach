public enum FeatureActionResult: Equatable, Sendable {
    case completed
    case requiresSetup(message: String)
    /// 由宿主负责呈现的独立功能面板，插件不直接依赖 AppKit 窗口实现。
    case presentPanel(featureID: String)
}
