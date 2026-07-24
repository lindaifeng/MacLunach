import Foundation
import TouchFeatureAPI

/// 独立番茄模块：只负责定义专注会话与发出面板呈现意图，窗口由主应用托管。
public struct PomodoroFeaturePlugin: FeaturePlugin {
    public static let id = "me.touch.pomodoro"

    public init() {}

    public let manifest = FeatureManifest(
        id: PomodoroFeaturePlugin.id,
        name: "番茄闹钟",
        summary: "开始一段清晰的专注时间",
        symbolName: "timer",
        defaultOrder: 4,
        defaultShortcut: .init(modifiers: [], key: "5"),
        capabilities: .init(optional: [.notifications]),
        executionMode: .inProcess,
        primaryAction: .perform,
        settingsPresentation: .none
    )

    public func initialState() async -> FeatureState { .available }

    public func perform() async throws -> FeatureActionResult {
        .presentPanel(featureID: Self.id)
    }
}
