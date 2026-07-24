import Foundation
import SwiftUI

/// 由设置宿主提供给插件设置页的通用导航能力。
@MainActor
public struct FeatureSettingsContext {
    private let openPermissionsHandler: () -> Void
    private let startFocusSessionHandler: (FocusSessionRequest) -> Void

    public init(
        openPermissions: @escaping () -> Void,
        startFocusSession: @escaping (FocusSessionRequest) -> Void = { _ in }
    ) {
        openPermissionsHandler = openPermissions
        startFocusSessionHandler = startFocusSession
    }

    public func openPermissions() {
        openPermissionsHandler()
    }

    public func startFocusSession(_ request: FocusSessionRequest) {
        startFocusSessionHandler(request)
    }

}

/// 跨功能区传递的专注请求。任务模块仅发送意图，不读取或修改番茄模块的私有状态。
public struct FocusSessionRequest: Equatable, Sendable {
    public let title: String
    public let plannedMinutes: Int
    public let deadline: Date?

    public init(title: String, plannedMinutes: Int, deadline: Date? = nil) {
        self.title = title
        self.plannedMinutes = max(1, plannedMinutes)
        self.deadline = deadline
    }

    /// 截止时间优先；没有截止时间时回退到预计时长，并至少安排一个番茄。
    public func requiredPomodoroCount(referenceDate: Date = .now, workMinutes: Int = 25) -> Int {
        let secondsPerPomodoro = Double(max(1, workMinutes) * 60)
        let availableSeconds = deadline?.timeIntervalSince(referenceDate) ?? Double(plannedMinutes * 60)
        return max(1, Int(ceil(availableSeconds / secondsPerPomodoro)))
    }
}

/// 第一方插件设置页的视图工厂。
///
/// 宿主只负责托管返回的视图，不读取或解释插件私有配置。
@MainActor
public protocol FeatureSettingsProvider {
    func makeSettingsView(context: FeatureSettingsContext) -> AnyView
}
