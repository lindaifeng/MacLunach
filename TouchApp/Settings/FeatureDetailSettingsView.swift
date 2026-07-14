import SwiftUI
import ScreenshotFeature

struct FeatureDetailSettingsView: View {
    @EnvironmentObject private var featureStore: FeatureAreaStore
    @State private var shortcutError: String?
    @State private var allDisplaysShortcutError: String?
    @State private var colorPickerShortcutError: String?
    let featureID: String
    let onBack: () -> Void

    private var title: String {
        switch featureID {
        case "me.touch.finder": "打开访达设置"
        case "me.touch.screenshot": "截取屏幕设置"
        case "me.touch.super-right": "超级右键设置"
        default: "功能设置"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Button(action: onBack) {
                Label("返回功能区", systemImage: "chevron.left")
            }
            .buttonStyle(.plain)

            Text(title)
                .font(.largeTitle.bold())

            Form {
                Toggle("启用此功能", isOn: enabledBinding)
                Toggle("在启动页显示", isOn: visibleBinding)
                ShortcutRecorderView(
                    shortcut: featureStore.shortcut(for: featureID),
                    errorMessage: shortcutError
                ) { shortcut in
                    shortcutError = featureStore.updateShortcut(shortcut, for: featureID)
                }
                Divider()
                featureSpecificSettings
            }
            .formStyle(.grouped)
            Spacer()
        }
        .padding(30)
    }

    @ViewBuilder
    private var featureSpecificSettings: some View {
        switch featureID {
        case FeatureConfigurationStore.finderID:
            Toggle("优先复用现有访达窗口", isOn: finderBinding(\.reuseExistingWindow))
        case FeatureConfigurationStore.screenshotID:
            ScreenshotPermissionSettingsView()
            if let shortcut = featureStore.configurations.screenshot.modeShortcuts[.allDisplays] {
                ShortcutRecorderView(
                    title: "所有显示器截图快捷键",
                    shortcut: shortcut,
                    errorMessage: allDisplaysShortcutError
                ) { shortcut in
                    allDisplaysShortcutError = featureStore.updateScreenshotModeShortcut(
                        shortcut,
                        for: .allDisplays
                    )
                }
            }
            if let shortcut = featureStore.configurations.screenshot.modeShortcuts[.colorPicker] {
                ShortcutRecorderView(
                    title: "屏幕取色快捷键",
                    shortcut: shortcut,
                    errorMessage: colorPickerShortcutError
                ) { shortcut in
                    colorPickerShortcutError = featureStore.updateScreenshotModeShortcut(
                        shortcut,
                        for: .colorPicker
                    )
                }
            }
            Picker(
                "截图延时",
                selection: screenshotValueBinding(\.defaultDelay)
            ) {
                ForEach(ScreenshotCaptureDelay.allCases, id: \.self) { delay in
                    Text(delay.settingsTitle).tag(delay)
                }
            }
            Toggle("截图后显示标注工具栏", isOn: screenshotBinding(\.showsAnnotationToolbar))
            Toggle("截图后自动复制到剪贴板", isOn: screenshotBinding(\.copiesToClipboard))
            Toggle("显示钉图操作", isOn: screenshotBinding(\.showsPinAction))
        case FeatureConfigurationStore.superRightID:
            Toggle("进入终端", isOn: superRightBinding(\.opensTerminal))
            Toggle("复制文件路径", isOn: superRightBinding(\.copiesFilePath))
            Toggle("剪切文件", isOn: superRightBinding(\.cutsFiles))
            Toggle("新建文件", isOn: superRightBinding(\.createsFiles))
        default:
            Text("此功能没有可配置项。")
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

    private func screenshotValueBinding<Value>(
        _ keyPath: WritableKeyPath<ScreenshotFeatureConfiguration, Value>
    ) -> Binding<Value> {
        Binding(
            get: { featureStore.configurations.screenshot[keyPath: keyPath] },
            set: { featureStore.updateScreenshotConfiguration(keyPath, to: $0) }
        )
    }

    private func superRightBinding(
        _ keyPath: WritableKeyPath<SuperRightFeatureConfiguration, Bool>
    ) -> Binding<Bool> {
        Binding(
            get: { featureStore.configurations.superRight[keyPath: keyPath] },
            set: { featureStore.updateSuperRightConfiguration(keyPath, to: $0) }
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

private struct ScreenshotPermissionSettingsView: View {
    @EnvironmentObject private var featureStore: FeatureAreaStore
    @EnvironmentObject private var screenshotEnvironment: ScreenshotEnvironment

    private var isGranted: Bool {
        screenshotEnvironment.permissionState == .authorized
    }

    var body: some View {
        HStack {
            Label(
                isGranted ? "屏幕录制权限已授权" : "需要屏幕录制权限",
                systemImage: isGranted ? "checkmark.circle.fill" : "lock.trianglebadge.exclamationmark"
            )
            .foregroundStyle(isGranted ? .green : .orange)
            Spacer()
            if !isGranted {
                if screenshotEnvironment.permissionState == .notRequested {
                    Button("请求权限") {
                        screenshotEnvironment.requestPermission()
                        Task { await featureStore.retry(FeatureConfigurationStore.screenshotID) }
                    }
                }
                Button("重新检查") {
                    screenshotEnvironment.refreshPermissionState()
                    Task { await featureStore.retry(FeatureConfigurationStore.screenshotID) }
                }
                Button("打开系统设置") {
                    screenshotEnvironment.openSystemSettings()
                }
            }
        }
        .onAppear {
            screenshotEnvironment.refreshPermissionState()
            Task { await featureStore.retry(FeatureConfigurationStore.screenshotID) }
        }
    }
}
