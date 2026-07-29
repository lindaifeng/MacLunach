import AppKit
import EventKit
@preconcurrency import FinderSync
import ScreenshotFeature
import ServiceManagement
import SwiftUI
import TouchCore
import TouchFeatureAPI
import UserNotifications

@MainActor
private final class NotificationPermissionState: ObservableObject {
    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined

    func refresh() {
        // macOS 15.3 的 getNotificationSettings 回调会在系统私有队列触发
        // Swift 并发隔离断言。权限页不得在出现或从系统设置返回时调用它；
        // 用户在本应用主动请求通知后，再由 requestAuthorization 的结果更新状态。
    }

    func update(granted: Bool) {
        authorizationStatus = granted ? .authorized : .denied
    }
}

@MainActor
struct GeneralSettingsView: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @EnvironmentObject private var screenshotEnvironment: ScreenshotEnvironment
    @EnvironmentObject private var featureStore: FeatureAreaStore
    @State private var isFinderExtensionEnabled = false
    @State private var calendarAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)
    @State private var calendarPermissionMessage: String?
    @State private var launcherShortcut = LauncherShortcutPreferences.load()
    @State private var launcherShortcutError: String?
    @State private var launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    @State private var launchAtLoginMessage: String?
    @State private var isAccessibilityTrusted = AXIsProcessTrusted()
    @StateObject private var notificationPermissionState = NotificationPermissionState()
    @State private var isRebuildingIndex = false
    @State private var searchIndexMessage: String?
    @ObservedObject var searchEnvironment: SearchEnvironment
    let section: TouchSettingsSection
    let theme: ThemeDefinition

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsPageHeader(
                title: section.title,
                subtitle: subtitle,
                theme: theme
            )

            switch section {
            case .general:
                generalContent
            case .appearance:
                appearanceContent
            case .permissions:
                permissionsContent
            case .update:
                updateContent
            case .privacy:
                privacyContent
            case .about:
                aboutContent
            case .search, .featureArea:
                EmptyView()
            }
        }
        .onAppear {
            if section == .general || section == .permissions {
                refreshLaunchAtLoginState()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if section == .general || section == .permissions {
                refreshLaunchAtLoginState()
            }
        }
    }

    private var subtitle: String {
        switch section {
        case .general: "启动、快捷键与搜索行为"
        case .appearance: "选择一念的工作界面材质与色彩"
        case .permissions: "统一管理各功能区所需的系统授权"
        case .update: "保持应用处于最新状态"
        case .privacy: "所有数据默认只保留在本机"
        case .about: "所想即现"
        case .search, .featureArea: ""
        }
    }

    private var generalContent: some View {
        SettingsCard(theme: theme) {
            ShortcutRecorderView(
                title: "启动器呼出快捷键",
                detail: "使用一个修饰键与一个主键全局呼出",
                requiresExactlyOneModifier: true,
                shortcut: launcherShortcut,
                errorMessage: launcherShortcutError,
                theme: theme
            ) { shortcut in
                launcherShortcutError = featureStore.validateLauncherShortcut(shortcut)
                if launcherShortcutError == nil {
                    launcherShortcut = shortcut
                    LauncherShortcutPreferences.save(shortcut)
                }
            }
            .accessibilityIdentifier("settings.launcher-shortcut")
        }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLoginEnabled },
            set: { updateLaunchAtLogin($0) }
        )
    }

    private func updateLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status != .notRegistered {
                try SMAppService.mainApp.unregister()
            }
            refreshLaunchAtLoginState()
        } catch {
            launchAtLoginMessage = "自启设置失败：\(error.localizedDescription)"
            refreshLaunchAtLoginState(preservingMessage: true)
        }
    }

    private func refreshLaunchAtLoginState(preservingMessage: Bool = false) {
        let status = SMAppService.mainApp.status
        // `.requiresApproval` only means the registration request is pending in
        // System Settings. It must not be presented as an enabled login item.
        launchAtLoginEnabled = status == .enabled
        guard !preservingMessage else { return }
        switch status {
        case .requiresApproval:
            launchAtLoginMessage = "请在“系统设置 → 通用 → 登录项”中允许一念"
        case .notFound:
            launchAtLoginMessage = "当前应用位置不支持自启，请将一念移到“应用程序”后重试"
        case .enabled, .notRegistered:
            launchAtLoginMessage = nil
        @unknown default:
            launchAtLoginMessage = "暂时无法读取系统自启状态"
        }
    }

    private var appearanceContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 11) {
                SettingsSectionTitle("主题", detail: "切换后会立即应用到启动器和设置窗口。", theme: theme)
                HStack(spacing: 10) {
                    ForEach(ThemeRegistry.shared.allDefinitions) { option in
                        themeOption(option)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 11) {
                SettingsSectionTitle(
                    "不透明度",
                    detail: "调整主题色强度，拖动时当前窗口会实时预览。",
                    theme: theme
                )
                SettingsCard(theme: theme) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 12) {
                            Label("主题色", systemImage: "circle.lefthalf.filled")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(theme.text.primary.color)
                            Spacer()
                            Text(themeColorOpacityPercentage)
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundStyle(theme.accent.color)
                                .accessibilityIdentifier("settings.theme.opacity.value")
                        }

                        ThemedSlider(
                            value: themeColorOpacityBinding,
                            in: ThemeStore.themeColorOpacityRange,
                            step: 0.01,
                            theme: theme
                        )
                        .accessibilityLabel("主题色不透明度")
                        .accessibilityValue(themeColorOpacityPercentage)
                        .accessibilityIdentifier("settings.theme.opacity")
                    }
                }
            }
        }
    }

    private var themeColorOpacityBinding: Binding<Double> {
        Binding(
            get: { themeStore.themeColorOpacity },
            set: { themeStore.setThemeColorOpacity($0) }
        )
    }

    private var themeColorOpacityPercentage: String {
        "\(Int((themeStore.themeColorOpacity * 100).rounded()))%"
    }

    private func themeOption(_ option: ThemeDefinition) -> some View {
        let isSelected = themeStore.theme == option.id
        return Button {
            themeStore.select(option.id)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(option.panel.gradient.gradient)
                    .overlay(option.panel.tint.color)
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(option.panel.border.color, lineWidth: 1)
                    }
                    .overlay(alignment: .bottomLeading) {
                        Circle()
                            .fill(option.accent.color)
                            .frame(width: 10, height: 10)
                            .padding(8)
                    }
                    .frame(height: 54)
                Text(themeTitle(option))
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(theme.text.primary.color)
                Text(themeDescription(option))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(theme.text.secondary.color)
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? theme.accent.color.opacity(0.12) : theme.card.fill.color, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(isSelected ? theme.accent.color : theme.card.border.color, lineWidth: isSelected ? 1.5 : 1)
            }
        }
        .buttonStyle(ThemePressButtonStyle(theme: theme, reduceMotion: false))
        .accessibilityIdentifier("settings.theme.\(option.id.rawValue)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func themeTitle(_ option: ThemeDefinition) -> String {
        switch option.id {
        case .defaultGlass: "默认"
        case .night: "黑夜"
        case .graphite: "石墨灰"
        case .day: "白天"
        }
    }

    private func themeDescription(_ option: ThemeDefinition) -> String {
        switch option.id {
        case .defaultGlass: "高级毛玻璃"
        case .night: "沉浸深色"
        case .graphite: "中性深灰"
        case .day: "清爽浅色"
        }
    }

    private var permissionsContent: some View {
        VStack(spacing: 13) {
            screenRecordingPermissionCard
            accessibilityPermissionCard
            calendarPermissionCard
            notificationPermissionCard
            fileAccessPermissionCard
            fullDiskAccessPermissionCard
            finderExtensionPermissionCard
            launchAtLoginPermissionCard
        }
        .onAppear(perform: refreshPermissions)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions()
        }
    }

    private var screenRecordingPermissionCard: some View {
        SettingsCard(theme: theme) {
            HStack(spacing: 11) {
                Image(systemName: isScreenRecordingAuthorized ? "checkmark.shield.fill" : "lock.trianglebadge.exclamationmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(isScreenRecordingAuthorized ? .green : theme.text.permission.color)
                    .frame(width: 34, height: 34)
                    .background(theme.icon.container.color, in: RoundedRectangle(cornerRadius: 9, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text("屏幕录制")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.text.primary.color)
                    Text(screenRecordingPermissionDetail)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.text.secondary.color)
                }

                Spacer(minLength: 12)

                Text(screenRecordingPermissionTitle)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isScreenRecordingAuthorized ? .green : theme.text.permission.color)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(
                        (isScreenRecordingAuthorized ? Color.green : theme.text.permission.color).opacity(0.10),
                        in: Capsule()
                    )

                if !isScreenRecordingAuthorized {
                    SettingsActionButton("系统设置", symbol: "gearshape", theme: theme, compact: true) {
                        screenshotEnvironment.openSystemSettings()
                    }
                }
            }
        }
    }

    private var finderExtensionPermissionCard: some View {
        SettingsCard(theme: theme) {
            HStack(spacing: 11) {
                Image(systemName: isFinderExtensionEnabled ? "checkmark.shield.fill" : "puzzlepiece.extension")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(isFinderExtensionEnabled ? .green : theme.text.permission.color)
                    .frame(width: 34, height: 34)
                    .background(theme.icon.container.color, in: RoundedRectangle(cornerRadius: 9, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text("Finder 扩展")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.text.primary.color)
                    Text(isFinderExtensionEnabled ? "超级右键已可在 Finder 中显示菜单" : "启用后才能在 Finder 中使用超级右键")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.text.secondary.color)
                }

                Spacer(minLength: 12)

                Text(isFinderExtensionEnabled ? "已启用" : "需要启用")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isFinderExtensionEnabled ? .green : theme.text.permission.color)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(
                        (isFinderExtensionEnabled ? Color.green : theme.text.permission.color).opacity(0.10),
                        in: Capsule()
                    )

                SettingsActionButton("管理扩展", symbol: "puzzlepiece.extension", theme: theme, compact: true) {
                    FIFinderSyncController.showExtensionManagementInterface()
                }
                .accessibilityIdentifier("settings.permissions.finder-extension.manage")
            }
            .accessibilityIdentifier("settings.permissions.finder-extension")
        }
    }

    private var accessibilityPermissionCard: some View {
        SettingsCard(theme: theme) {
            HStack(spacing: 11) {
                Image(systemName: isAccessibilityTrusted ? "checkmark.shield.fill" : "accessibility")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(isAccessibilityTrusted ? .green : theme.text.permission.color)
                    .frame(width: 34, height: 34)
                    .background(theme.icon.container.color, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text("辅助功能")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.text.primary.color)
                    Text(isAccessibilityTrusted ? "全局快捷键等辅助功能已可使用" : "授权后可可靠响应全局快捷键与系统级交互")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.text.secondary.color)
                }
                Spacer(minLength: 12)
                permissionStatusBadge(isAccessibilityTrusted ? "已授权" : "需要启用", isAvailable: isAccessibilityTrusted)
                if !isAccessibilityTrusted {
                    SettingsActionButton("系统设置", symbol: "accessibility", theme: theme, compact: true) {
                        openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
                    }
                }
            }
            .accessibilityIdentifier("settings.permissions.accessibility")
        }
    }

    private var fullDiskAccessPermissionCard: some View {
        SettingsCard(theme: theme) {
            HStack(spacing: 11) {
                Image(systemName: "externaldrive.badge.questionmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(theme.text.permission.color)
                    .frame(width: 34, height: 34)
                    .background(theme.icon.container.color, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text("完全磁盘访问")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.text.primary.color)
                    Text("macOS 未提供可靠的授权查询，请在系统设置中确认状态")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.text.secondary.color)
                }
                Spacer(minLength: 12)
                permissionStatusBadge("需确认", isAvailable: false)
                SettingsActionButton("系统设置", symbol: "externaldrive", theme: theme, compact: true) {
                    openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
                }
            }
            .accessibilityIdentifier("settings.permissions.full-disk-access")
        }
    }

    private var launchAtLoginPermissionCard: some View {
        SettingsCard(theme: theme) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 11) {
                    Image(systemName: launchAtLoginEnabled ? "checkmark.shield.fill" : "power")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(launchAtLoginEnabled ? .green : theme.text.permission.color)
                        .frame(width: 34, height: 34)
                        .background(theme.icon.container.color, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("登录项")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(theme.text.primary.color)
                        Text("登录 macOS 后自动在后台运行一念")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.text.secondary.color)
                    }
                    Spacer(minLength: 12)
                    permissionStatusBadge(launchAtLoginStatusTitle, isAvailable: launchAtLoginEnabled)
                    if SMAppService.mainApp.status == .requiresApproval {
                        SettingsActionButton("系统设置", symbol: "gearshape", theme: theme, compact: true) {
                            openSystemSettings("x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
                        }
                    }
                }
                SettingsToggleRow(
                    "启用登录项",
                    detail: launchAtLoginStatusDetail,
                    isOn: launchAtLoginBinding,
                    theme: theme
                )
                .disabled(SMAppService.mainApp.status == .requiresApproval)
                .accessibilityIdentifier("settings.permissions.launch-at-login")
                if let launchAtLoginMessage {
                    Text(launchAtLoginMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.text.permission.color)
                }
            }
            .accessibilityIdentifier("settings.permissions.launch-at-login.card")
        }
    }

    private var launchAtLoginStatusTitle: String {
        switch SMAppService.mainApp.status {
        case .enabled: "已启用"
        case .requiresApproval: "需要批准"
        case .notRegistered: "未启用"
        case .notFound: "位置不支持"
        @unknown default: "通信异常"
        }
    }

    private var launchAtLoginStatusDetail: String {
        switch SMAppService.mainApp.status {
        case .enabled: "登录项已启用，可随时在此关闭"
        case .requiresApproval: "请在“系统设置 → 通用 → 登录项”中允许一念"
        case .notFound: "请将一念移到“应用程序”后重试"
        case .notRegistered: "启用后会在登录 macOS 时后台启动"
        @unknown default: "暂时无法读取系统自启状态，请重新检测"
        }
    }

    private func permissionStatusBadge(_ title: String, isAvailable: Bool) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(isAvailable ? .green : theme.text.permission.color)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                (isAvailable ? Color.green : theme.text.permission.color).opacity(0.10),
                in: Capsule()
            )
    }

    private var calendarPermissionCard: some View {
        let authorized = calendarAuthorizationStatus == .fullAccess
        return SettingsCard(theme: theme) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 11) {
                    Image(systemName: authorized ? "checkmark.shield.fill" : "calendar.badge.exclamationmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(authorized ? .green : theme.text.permission.color)
                        .frame(width: 34, height: 34)
                        .background(theme.icon.container.color, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("日历")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(theme.text.primary.color)
                        Text(calendarPermissionDetail)
                            .font(.system(size: 11))
                            .foregroundStyle(theme.text.secondary.color)
                    }
                    Spacer(minLength: 12)
                    permissionStatusBadge(calendarPermissionTitle, isAvailable: authorized)
                    if let actionTitle = calendarPermissionActionTitle {
                        SettingsActionButton(
                            actionTitle,
                            symbol: actionTitle == "授权" ? "calendar" : "gearshape",
                            theme: theme,
                            compact: true
                        ) {
                            requestCalendarAccess()
                        }
                    }
                }
                if let calendarPermissionMessage {
                    Text(calendarPermissionMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.text.permission.color)
                }
            }
            .accessibilityIdentifier("settings.permissions.calendar")
        }
    }

    private var calendarPermissionTitle: String {
        switch calendarAuthorizationStatus {
        case .fullAccess: "已授权"
        case .writeOnly: "仅写入"
        case .notDetermined: "未请求"
        case .denied: "被拒绝"
        case .restricted: "受限制"
        @unknown default: "通信异常"
        }
    }

    private var calendarPermissionDetail: String {
        switch calendarAuthorizationStatus {
        case .fullAccess: "每日任务可只读显示系统日程"
        case .writeOnly: "当前仅有写入权限，无法读取日程；请在系统设置中允许完整访问"
        case .notDetermined: "授权后可在每日任务中查看系统日程"
        case .denied: "日历权限已被拒绝，可在系统设置中恢复"
        case .restricted: "日历权限受系统策略限制，当前无法启用"
        @unknown default: "日历权限状态暂时无法确认，请重新检测"
        }
    }

    private var calendarPermissionActionTitle: String? {
        switch calendarAuthorizationStatus {
        case .notDetermined: "授权"
        case .writeOnly, .denied: "系统设置"
        case .fullAccess, .restricted: nil
        @unknown default: "系统设置"
        }
    }

    private var isScreenRecordingAuthorized: Bool {
        screenshotEnvironment.permissionState == .authorized
    }

    private var screenRecordingPermissionTitle: String {
        switch screenshotEnvironment.permissionState {
        case .authorized: "已授权"
        case .notRequested: "未请求"
        case .denied: "被拒绝"
        case .restricted: "受限制"
        }
    }

    private var screenRecordingPermissionDetail: String {
        switch screenshotEnvironment.permissionState {
        case .authorized: "截取屏幕功能已可正常使用"
        case .notRequested: "首次使用截图时需要请求屏幕录制权限"
        case .denied: "屏幕录制权限已被拒绝，可在系统设置中恢复"
        case .restricted: "屏幕录制权限受系统策略限制，当前无法启用"
        }
    }

    private func fileAccessSymbol(for state: SearchEnvironment.FileAccessState) -> String {
        switch state {
        case .granted: "checkmark.shield.fill"
        case .notConfigured: "folder.badge.questionmark"
        case .partiallyGranted: "folder.badge.gearshape"
        case .denied: "lock.folder"
        }
    }

    private func fileAccessTitle(for state: SearchEnvironment.FileAccessState) -> String {
        switch state {
        case .granted: "已授权"
        case .notConfigured: "未配置"
        case .partiallyGranted: "部分可用"
        case .denied: "访问失败"
        }
    }

    private func fileAccessDetail(for state: SearchEnvironment.FileAccessState) -> String {
        switch state {
        case let .granted(count): "已授权访问 \(count) 个检索目录"
        case .notConfigured: "尚未配置可检索目录"
        case let .partiallyGranted(accessible, total): "\(accessible)/\(total) 个检索目录可访问，其余需要重新授权"
        case let .denied(total): "已配置 \(total) 个目录，但当前均无法访问"
        }
    }

    private func refreshPermissions() {
        screenshotEnvironment.refreshPermissionState()
        isAccessibilityTrusted = AXIsProcessTrusted()
        isFinderExtensionEnabled = FIFinderSyncController.isExtensionEnabled
        calendarAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)
        notificationPermissionState.refresh()
        refreshLaunchAtLoginState()
        Task { await featureStore.retry(FeatureConfigurationStore.screenshotID) }
    }

    private var notificationPermissionCard: some View {
        let authorized = notificationPermissionState.authorizationStatus == .authorized
            || notificationPermissionState.authorizationStatus == .provisional
        return SettingsCard(theme: theme) {
            HStack(spacing: 11) {
                Image(systemName: authorized ? "checkmark.shield.fill" : "bell.badge")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(authorized ? .green : theme.text.permission.color)
                    .frame(width: 34, height: 34)
                    .background(theme.icon.container.color, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text("通知").font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.text.primary.color)
                    Text(notificationPermissionDetail)
                        .font(.system(size: 11)).foregroundStyle(theme.text.secondary.color)
                }
                Spacer()
                Text(notificationPermissionTitle).font(.system(size: 11, weight: .semibold)).foregroundStyle(authorized ? .green : theme.text.permission.color)
                if !authorized {
                    SettingsActionButton(notificationPermissionState.authorizationStatus == .notDetermined ? "请求" : "系统设置", symbol: "bell", theme: theme, compact: true) {
                        requestNotificationAccess()
                    }
                }
            }
        }
    }

    private var fileAccessPermissionCard: some View {
        let state = searchEnvironment.fileAccessState
        let available = if case .granted = state { true } else { false }
        return SettingsCard(theme: theme) {
            HStack(spacing: 11) {
                Image(systemName: fileAccessSymbol(for: state))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(available ? .green : theme.text.permission.color)
                    .frame(width: 34, height: 34)
                    .background(theme.icon.container.color, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text("文件与目录访问").font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.text.primary.color)
                    Text(fileAccessDetail(for: state))
                        .font(.system(size: 11)).foregroundStyle(theme.text.secondary.color)
                }
                Spacer()
                Text(fileAccessTitle(for: state)).font(.system(size: 11, weight: .semibold)).foregroundStyle(available ? .green : theme.text.permission.color)
                if !available {
                    SettingsActionButton("前往搜索", symbol: "folder", theme: theme, compact: true) {
                        NotificationCenter.default.post(name: .openTouchSettings, object: TouchSettingsDestination(section: .search))
                    }
                }
            }
        }
    }

    private var notificationPermissionTitle: String {
        switch notificationPermissionState.authorizationStatus {
        case .authorized, .provisional: "已授权"
        case .denied: "被拒绝"
        case .notDetermined: "未请求"
        @unknown default: "通信异常"
        }
    }

    private var notificationPermissionDetail: String {
        switch notificationPermissionState.authorizationStatus {
        case .denied: "通知已被拒绝，可在系统设置中恢复"
        case .authorized, .provisional: "专注计时和任务提醒可正常送达"
        case .notDetermined: "授权后可接收专注计时和任务提醒"
        @unknown default: "通知状态暂时无法确认，请重新检测"
        }
    }

    private func requestNotificationAccess() {
        if notificationPermissionState.authorizationStatus == .notDetermined {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                DispatchQueue.main.async {
                    notificationPermissionState.update(granted: granted)
                }
            }
        } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
            NSWorkspace.shared.open(url)
        }
    }

    private func openSystemSettings(_ destination: String) {
        guard let url = URL(string: destination) else { return }
        NSWorkspace.shared.open(url)
    }

    private func requestCalendarAccess() {
        guard calendarAuthorizationStatus == .notDetermined else {
            openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")
            return
        }
        Task {
            do {
                _ = try await EKEventStore().requestFullAccessToEvents()
                await MainActor.run {
                    calendarPermissionMessage = nil
                    refreshPermissions()
                }
            } catch {
                await MainActor.run {
                    calendarPermissionMessage = "请求日历权限失败：\(error.localizedDescription)"
                    refreshPermissions()
                }
            }
        }
    }

    private var updateContent: some View {
        SettingsCard(theme: theme) {
            VStack(spacing: 13) {
                SettingsValueRow("当前版本", value: "0.1.0", theme: theme)
                SettingsDivider(theme: theme)
                Text("更新服务将在发布阶段启用；当前开发版本不提供无效的更新检查入口。")
                    .font(.system(size: 11.5)).foregroundStyle(theme.text.secondary.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var privacyContent: some View {
        SettingsCard(theme: theme) {
            VStack(alignment: .leading, spacing: 13) {
                Text("搜索索引和偏好设置仅保存在本机。")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.text.primary.color)
                HStack {
                    Text("清理后会在下次搜索时重新建立索引。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.text.secondary.color)
                    Spacer()
                    SettingsActionButton(isRebuildingIndex ? "正在重建" : "清理并重建", symbol: "arrow.clockwise", theme: theme) {
                        rebuildSearchIndex()
                    }
                }
                if let searchIndexMessage {
                    Text(searchIndexMessage).font(.system(size: 11)).foregroundStyle(theme.text.secondary.color)
                }
            }
        }
    }

    private func rebuildSearchIndex() {
        guard !isRebuildingIndex else { return }
        isRebuildingIndex = true
        searchIndexMessage = "正在清理并重建搜索索引…"
        Task {
            await searchEnvironment.rebuildIndex()
            isRebuildingIndex = false
            switch searchEnvironment.diagnostics.status {
            case .ready: searchIndexMessage = "搜索索引已重建完成。"
            case let .unavailable(message): searchIndexMessage = message
            default: searchIndexMessage = searchEnvironment.diagnostics.status.label
            }
        }
    }

    private var aboutContent: some View {
        SettingsCard(theme: theme) {
            HStack(spacing: 14) {
                BrandLogoView(size: 42)
                VStack(alignment: .leading, spacing: 4) {
                    Text("一念")
                        .font(.custom("PingFangSC-Semibold", fixedSize: 18))
                        .foregroundStyle(theme.icon.brandGradient.gradient)
                    Text("所想即现")
                        .font(.custom("PingFangSC-Medium", fixedSize: 12.5))
                        .foregroundStyle(theme.text.secondary.color)
                    Text("版本 0.1.0")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.text.weak.color)
                }
                Spacer()
            }
        }
    }
}
