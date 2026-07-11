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
                Toggle("在启动页显示", isOn: .constant(true))
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
        case "me.touch.finder":
            Toggle("优先复用现有访达窗口", isOn: .constant(true))
        case "me.touch.screenshot":
            Toggle("截图后显示标注工具栏", isOn: .constant(true))
            Toggle("截图后自动复制到剪贴板", isOn: .constant(true))
            Toggle("显示钉图操作", isOn: .constant(true))
        case "me.touch.super-right":
            Toggle("进入终端", isOn: .constant(true))
            Toggle("复制文件路径", isOn: .constant(true))
            Toggle("剪切文件", isOn: .constant(true))
            Toggle("新建文件", isOn: .constant(true))
        default:
            Text("此功能没有可配置项。")
        }
    }
}
