import SwiftUI

struct FeatureDetailSettingsView: View {
    @EnvironmentObject private var featureStore: FeatureAreaStore
    @State private var shortcutError: String?
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

    private func superRightBinding(
        _ keyPath: WritableKeyPath<SuperRightFeatureConfiguration, Bool>
    ) -> Binding<Bool> {
        Binding(
            get: { featureStore.configurations.superRight[keyPath: keyPath] },
            set: { featureStore.updateSuperRightConfiguration(keyPath, to: $0) }
        )
    }
}
