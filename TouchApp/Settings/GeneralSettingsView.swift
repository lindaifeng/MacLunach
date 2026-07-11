import SwiftUI

struct GeneralSettingsView: View {
    let section: TouchSettingsSection

    var body: some View {
        Form {
            Section {
                switch section {
                case .general:
                    Toggle("登录时自动启动触达", isOn: .constant(false))
                    LabeledContent("启动快捷键", value: "⌥ Space")
                    Toggle("呼出后自动聚焦搜索框", isOn: .constant(true))
                case .search:
                    Toggle("启用应用搜索", isOn: .constant(true))
                    Toggle("启用文件索引", isOn: .constant(true))
                    LabeledContent("索引状态", value: "等待首次构建")
                case .appearance:
                    Picker("默认主题", selection: .constant("毛玻璃")) {
                        Text("毛玻璃").tag("毛玻璃")
                        Text("暖光").tag("暖光")
                        Text("深色极简").tag("深色极简")
                    }
                case .permissions:
                    LabeledContent("辅助功能", value: "尚未授权")
                    LabeledContent("屏幕录制", value: "尚未授权")
                    LabeledContent("文件与文件夹", value: "按需请求")
                case .update:
                    Toggle("自动检查更新", isOn: .constant(true))
                    LabeledContent("当前版本", value: "0.1.0")
                case .privacy:
                    Text("搜索索引和偏好设置仅保存在本机。")
                    Button("清理搜索索引") {}
                case .about:
                    Text("触达")
                        .font(.title2.bold())
                    Text("心之所想，一触即达")
                        .foregroundStyle(.secondary)
                case .featureArea:
                    EmptyView()
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(section.title)
    }
}
