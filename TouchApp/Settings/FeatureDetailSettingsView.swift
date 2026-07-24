import AppKit
import SwiftUI
import ScreenshotFeature
import TouchFeatureAPI

struct FeatureSettingsHost: View {
    let plugin: any FeaturePlugin
    let context: FeatureSettingsContext

    @ViewBuilder
    var body: some View {
        if let provider = plugin.settingsProvider {
            provider.makeSettingsView(context: context)
        } else {
            EmptyView()
        }
    }
}

struct FeatureDetailSettingsView: View {
    @EnvironmentObject private var featureStore: FeatureAreaStore
    @State private var shortcutError: String?
    @State private var globalShortcutError: String?
    @State private var allDisplaysShortcutError: String?
    @State private var colorPickerShortcutError: String?
    let featureID: String
    let theme: ThemeDefinition
    let onBack: () -> Void
    let onOpenPermissions: () -> Void

    private var plugin: (any FeaturePlugin)? {
        featureStore.plugins.first { $0.manifest.id == featureID }
    }

    private var title: String {
        plugin.map { "\($0.manifest.name)设置" } ?? "功能设置"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Button(action: onBack) {
                Label("返回功能区", systemImage: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.accent.color)
            }
            .buttonStyle(.plain)

            SettingsPageHeader(title: title, subtitle: "配置此功能的键位、显示方式与行为。", theme: theme)

            SettingsCard(theme: theme) {
                VStack(spacing: 13) {
                    SettingsToggleRow("启用此功能", isOn: enabledBinding, theme: theme)
                    SettingsDivider(theme: theme)
                    SettingsToggleRow("在启动页显示", isOn: visibleBinding, theme: theme)
                    SettingsDivider(theme: theme)
                    SingleKeyRecorderView(
                        shortcut: featureStore.shortcut(for: featureID),
                        errorMessage: shortcutError,
                        theme: theme
                    ) { shortcut in
                        shortcutError = featureStore.updateShortcut(shortcut, for: featureID)
                    }
                    SettingsDivider(theme: theme)
                    ShortcutRecorderView(
                        title: "快捷键",
                        detail: "默认使用 Option + 主键；后台运行时可直接触发，须含有特殊按键",
                        allowedModifierCounts: 1...2,
                        shortcut: featureStore.globalShortcut(for: featureID)
                            ?? .init(modifiers: [], key: ""),
                        errorMessage: globalShortcutError
                            ?? featureStore.globalShortcutRegistrationErrors[featureID],
                        theme: theme,
                        onClear: {
                            globalShortcutError = nil
                            featureStore.removeGlobalShortcut(for: featureID)
                        }
                    ) { shortcut in
                        globalShortcutError = featureStore.updateGlobalShortcut(
                            shortcut,
                            for: featureID
                        )
                    }
                    .accessibilityIdentifier("settings.feature-global-shortcut")
                }
            }

            SettingsSectionTitle("功能选项", theme: theme)
            SettingsCard(theme: theme) {
                VStack(spacing: 13) {
                    featureSpecificSettings
                }
            }
        }
    }

    @ViewBuilder
    private var featureSpecificSettings: some View {
        if let plugin, plugin.settingsProvider != nil {
            FeatureSettingsHost(
                plugin: plugin,
                context: FeatureSettingsContext(
                    openPermissions: onOpenPermissions,
                    startFocusSession: { request in
                        NotificationCenter.default.post(
                            name: .startTouchFocusSession,
                            object: request
                        )
                    }
                )
            )
        } else {
            hostOwnedFeatureSettings
        }
    }

    @ViewBuilder
    private var hostOwnedFeatureSettings: some View {
        switch featureID {
        case FeatureConfigurationStore.finderID:
            SettingsToggleRow(
                "优先复用现有访达窗口",
                detail: "避免重复打开相同位置",
                isOn: finderBinding(\.reuseExistingWindow),
                theme: theme
            )
        case FeatureConfigurationStore.screenshotID:
            if let shortcut = featureStore.configurations.screenshot.modeShortcuts[.allDisplays] {
                ShortcutRecorderView(
                    title: "所有显示器截图快捷键",
                    shortcut: shortcut,
                    errorMessage: allDisplaysShortcutError,
                    theme: theme
                ) { shortcut in
                    allDisplaysShortcutError = featureStore.updateScreenshotModeShortcut(
                        shortcut,
                        for: .allDisplays
                    )
                }
                SettingsDivider(theme: theme)
            }
            if let shortcut = featureStore.configurations.screenshot.modeShortcuts[.colorPicker] {
                ShortcutRecorderView(
                    title: "屏幕取色快捷键",
                    shortcut: shortcut,
                    errorMessage: colorPickerShortcutError,
                    theme: theme
                ) { shortcut in
                    colorPickerShortcutError = featureStore.updateScreenshotModeShortcut(
                        shortcut,
                        for: .colorPicker
                    )
                }
                SettingsDivider(theme: theme)
            }
            delayPicker
            SettingsDivider(theme: theme)
            screenshotSaveLocationRow
            SettingsDivider(theme: theme)
            SettingsToggleRow("截图后显示标注工具栏", isOn: screenshotBinding(\.showsAnnotationToolbar), theme: theme)
            SettingsDivider(theme: theme)
            SettingsToggleRow("截图后自动复制到剪贴板", isOn: screenshotBinding(\.copiesToClipboard), theme: theme)
            SettingsDivider(theme: theme)
            SettingsToggleRow("显示钉图操作", isOn: screenshotBinding(\.showsPinAction), theme: theme)
        default:
            Text("此功能没有可配置项。")
                    .font(.system(size: 12))
                .foregroundStyle(theme.text.secondary.color)
        }
    }

    private var screenshotSaveLocationRow: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("图片保存位置")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.text.primary.color)
                Text(screenshotSaveLocationTitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.text.secondary.color)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 16)
            Button("选择文件夹") { chooseScreenshotSaveLocation() }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.accent.color)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(theme.accent.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings.screenshot.save-location")
        }
    }

    private var screenshotSaveLocationTitle: String {
        switch featureStore.configurations.screenshot.saveLocation {
        case .downloads, .pluginDirectory:
            return "下载"
        case .desktop:
            return "桌面"
        case let .customBookmark(data):
            var stale = false
            if let url = try? URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) {
                return url.path
            }
            return "下载（自定义位置已失效）"
        }
    }

    private func chooseScreenshotSaveLocation() {
        let panel = NSOpenPanel()
        panel.title = "选择截图保存位置"
        panel.prompt = "选择"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url,
              let bookmark = try? url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
              ) else { return }
        featureStore.updateScreenshotConfiguration(\.saveLocation, to: .customBookmark(bookmark))
    }

    private var delayPicker: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("截图延时")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.text.primary.color)
                Text("在截取前等待指定时间")
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.text.secondary.color)
            }
            Spacer(minLength: 16)
            HStack(spacing: 4) {
                ForEach(ScreenshotCaptureDelay.allCases, id: \.self) { delay in
                    let isSelected = featureStore.configurations.screenshot.defaultDelay == delay
                    Button(delay.settingsTitle) {
                        featureStore.updateScreenshotConfiguration(\.defaultDelay, to: delay)
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isSelected ? theme.accent.color : theme.text.secondary.color)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(isSelected ? theme.accent.color.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(theme.shortcut.fill.color, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(theme.shortcut.border.color, lineWidth: 1))
        }
    }

    private var visibleBinding: Binding<Bool> {
        Binding(
            get: { !featureStore.preferences.hidden.contains(featureID) },
            set: { featureStore.setHidden(!$0, for: featureID) }
        )
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { featureStore.isEnabled(featureID) },
            set: { enabled in
                Task { await featureStore.setEnabled(enabled, for: featureID) }
            }
        )
    }

    private func finderBinding(_ keyPath: WritableKeyPath<FinderFeatureConfiguration, Bool>) -> Binding<Bool> {
        Binding(
            get: { featureStore.configurations.finder[keyPath: keyPath] },
            set: { featureStore.updateFinderConfiguration(keyPath, to: $0) }
        )
    }

    private func screenshotBinding(
        _ keyPath: WritableKeyPath<ScreenshotFeatureConfiguration, Bool>
    ) -> Binding<Bool> {
        Binding(
            get: { featureStore.configurations.screenshot[keyPath: keyPath] },
            set: { featureStore.updateScreenshotConfiguration(keyPath, to: $0) }
        )
    }

}

private extension ScreenshotCaptureDelay {
    var settingsTitle: String {
        switch self {
        case .none: "无延时"
        case .threeSeconds: "3 秒"
        case .fiveSeconds: "5 秒"
        case .tenSeconds: "10 秒"
        }
    }
}
