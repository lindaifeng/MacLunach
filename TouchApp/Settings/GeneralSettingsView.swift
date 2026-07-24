import AppKit
import EventKit
@preconcurrency import FinderSync
import ScreenshotFeature
import ServiceManagement
import SwiftUI
import TouchCore
import TouchFeatureAPI

struct GeneralSettingsView: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @EnvironmentObject private var screenshotEnvironment: ScreenshotEnvironment
    @EnvironmentObject private var featureStore: FeatureAreaStore
    @State private var isFinderExtensionEnabled = false
    @State private var calendarAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)
    @State private var launcherShortcut = LauncherShortcutPreferences.load()
    @State private var launcherShortcutError: String?
    @State private var launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    @State private var launchAtLoginMessage: String?
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
            if section == .general {
                refreshLaunchAtLoginState()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if section == .general {
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
            VStack(spacing: 13) {
                VStack(alignment: .leading, spacing: 6) {
                    SettingsToggleRow(
                        "开启自启",
                        detail: "登录 macOS 后自动在后台运行一念",
                        isOn: launchAtLoginBinding,
                        theme: theme
                    )
                    .accessibilityIdentifier("settings.launch-at-login")
                    if let launchAtLoginMessage {
                        Text(launchAtLoginMessage)
                            .font(.system(size: 11))
                            .foregroundStyle(theme.text.permission.color)
                    }
                }
                SettingsDivider(theme: theme)
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
        launchAtLoginEnabled = status == .enabled || status == .requiresApproval
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

                        Slider(
                            value: themeColorOpacityBinding,
                            in: ThemeStore.themeColorOpacityRange
                        )
                        .tint(theme.accent.color)
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
            calendarPermissionCard
            finderExtensionPermissionCard
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
                    Text(isScreenRecordingAuthorized ? "截取屏幕功能已可正常使用" : "截取屏幕功能当前不可用")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.text.secondary.color)
                }

                Spacer(minLength: 12)

                Text(isScreenRecordingAuthorized ? "已授权" : "未授权")
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

    private var calendarPermissionCard: some View {
        let authorized = calendarAuthorizationStatus == .fullAccess
        return SettingsCard(theme: theme) {
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
                    Text(authorized ? "每日任务可只读显示系统日程" : "授权后可在每日任务中查看系统日程")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.text.secondary.color)
                }
                Spacer(minLength: 12)
                Text(authorized ? "已授权" : "未授权")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(authorized ? .green : theme.text.permission.color)
                if !authorized {
                    SettingsActionButton("授权", symbol: "calendar", theme: theme, compact: true) {
                        requestCalendarAccess()
                    }
                }
            }
            .accessibilityIdentifier("settings.permissions.calendar")
        }
    }

    private var isScreenRecordingAuthorized: Bool {
        screenshotEnvironment.permissionState == .authorized
    }

    private func refreshPermissions() {
        screenshotEnvironment.refreshPermissionState()
        isFinderExtensionEnabled = FIFinderSyncController.isExtensionEnabled
        calendarAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)
        Task { await featureStore.retry(FeatureConfigurationStore.screenshotID) }
    }

    private func requestCalendarAccess() {
        Task {
            let store = EKEventStore()
            _ = try? await store.requestFullAccessToEvents()
            await MainActor.run { refreshPermissions() }
        }
    }

    private var updateContent: some View {
        SettingsCard(theme: theme) {
            VStack(spacing: 13) {
                SettingsToggleRow("自动检查更新", detail: "在后台检查新版本", isOn: .constant(true), theme: theme)
                SettingsDivider(theme: theme)
                HStack {
                    SettingsValueRow("当前版本", value: "0.1.0", theme: theme)
                    Spacer(minLength: 16)
                    SettingsActionButton("检查更新", symbol: "arrow.clockwise", theme: theme) {}
                }
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
                    SettingsActionButton("清理搜索索引", symbol: "trash", theme: theme) {}
                }
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
