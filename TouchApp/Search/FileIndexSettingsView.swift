import AppKit
import SwiftUI

struct FileIndexSettingsView: View {
    @ObservedObject var environment: SearchEnvironment
    @ObservedObject private var diagnostics: SearchDiagnostics

    init(environment: SearchEnvironment) {
        self.environment = environment
        diagnostics = environment.diagnostics
    }

    var body: some View {
        Form {
            Section("索引状态") {
                LabeledContent("索引状态", value: diagnostics.status.label)
                    .accessibilityIdentifier("search.index-status")
                LabeledContent("已扫描项目", value: diagnostics.fileCount.formatted())
                LabeledContent("数据库大小", value: ByteCountFormatter.string(fromByteCount: diagnostics.databaseSize, countStyle: .file))
                LabeledContent("最后更新", value: lastUpdatedText)
                if case let .unavailable(message) = diagnostics.status {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("索引范围") {
                if diagnostics.roots.isEmpty {
                    Text("尚未添加索引目录")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(diagnostics.roots.enumerated()), id: \.offset) { index, _ in
                        HStack {
                            Image(systemName: "folder")
                            Text(diagnostics.rootNames[index])
                            Spacer()
                            Button("移除") {
                                Task { await environment.removeRoot(at: index) }
                            }
                            .accessibilityIdentifier("search.remove-root.\(index)")
                        }
                    }
                }

                Button("添加目录…") {
                    chooseDirectory()
                }
                .accessibilityIdentifier("search.add-root")
            }

            Section("默认排除") {
                ForEach(diagnostics.exclusionRules, id: \.self) { rule in
                    Label(rule, systemImage: "minus.circle")
                }
            }

            Section {
                Button("重建索引") {
                    Task { await environment.rebuildIndex() }
                }
                .disabled(diagnostics.status == .rebuilding)
                .accessibilityIdentifier("search.rebuild-index")
            } footer: {
                Text("重建只影响文件索引；应用搜索始终保持可用。诊断信息不会显示完整文件路径。")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("搜索")
    }

    private var lastUpdatedText: String {
        guard let date = diagnostics.lastUpdatedAt else { return "尚未完成" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "添加到索引"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await environment.addRoot(url) }
    }
}
