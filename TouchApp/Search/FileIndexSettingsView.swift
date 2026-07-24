import AppKit
import SwiftUI

struct FileIndexSettingsView: View {
    @ObservedObject var environment: SearchEnvironment
    @ObservedObject private var diagnostics: SearchDiagnostics
    let theme: ThemeDefinition

    init(environment: SearchEnvironment, theme: ThemeDefinition) {
        self.environment = environment
        self.theme = theme
        diagnostics = environment.diagnostics
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsPageHeader(
                title: "搜索",
                subtitle: "管理本机文件索引范围与诊断状态",
                theme: theme
            )

            SettingsCard(theme: theme) {
                VStack(spacing: 12) {
                    SettingsValueRow("索引状态", value: diagnostics.status.label, theme: theme)
                        .accessibilityIdentifier("search.index-status")
                    SettingsDivider(theme: theme)
                    SettingsValueRow("已扫描项目", value: diagnostics.fileCount.formatted(), theme: theme)
                    SettingsDivider(theme: theme)
                    SettingsValueRow(
                        "数据库大小",
                        value: ByteCountFormatter.string(fromByteCount: diagnostics.databaseSize, countStyle: .file),
                        theme: theme
                    )
                    SettingsDivider(theme: theme)
                    SettingsValueRow("最后更新", value: lastUpdatedText, theme: theme)

                    if case let .unavailable(message) = diagnostics.status {
                        HStack(spacing: 7) {
                            Image(systemName: "exclamationmark.triangle.fill")
                            Text(message)
                        }
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    SettingsDivider(theme: theme)
                    HStack {
                        Spacer()
                        SettingsActionButton(
                            "重建索引",
                            symbol: "arrow.clockwise",
                            theme: theme,
                            compact: true
                        ) {
                            Task { await environment.rebuildIndex() }
                        }
                        .disabled(diagnostics.status == .rebuilding)
                        .accessibilityIdentifier("search.rebuild-index")
                    }
                }
            }

            SettingsSectionTitle(
                "索引范围",
                detail: "默认检索桌面、文稿与下载，可按需增减目录。",
                theme: theme
            )
            SettingsCard(theme: theme) {
                VStack(alignment: .leading, spacing: 12) {
                    if !diagnostics.roots.isEmpty {
                        ForEach(Array(diagnostics.roots.enumerated()), id: \.offset) { index, _ in
                            HStack(spacing: 10) {
                                Image(systemName: "folder.fill")
                                    .foregroundStyle(theme.accent.color)
                                Text(diagnostics.rootNames[index])
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(theme.text.primary.color)
                                Spacer(minLength: 12)
                                Button("移除") {
                                    Task { await environment.removeRoot(at: index) }
                                }
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(theme.text.secondary.color)
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("search.remove-root.\(index)")
                            }
                            if index < diagnostics.roots.count - 1 {
                                SettingsDivider(theme: theme)
                            }
                        }
                    }

                    SettingsActionButton("添加", symbol: "plus", theme: theme, compact: true, action: chooseDirectories)
                        .accessibilityIdentifier("search.add-root")
                }
            }

            SettingsSectionTitle("默认排除", detail: "常见构建产物与缓存目录不会加入搜索结果。", theme: theme)
            SettingsCard(theme: theme) {
                VStack(alignment: .leading, spacing: 12) {
                    if !diagnostics.exclusionRules.isEmpty {
                        FlowLayout(spacing: 8) {
                            ForEach(diagnostics.exclusionRules, id: \.self) { rule in
                                Button {
                                    Task { await environment.removeExclusionRule(rule) }
                                } label: {
                                    HStack(spacing: 6) {
                                        Text(exclusionDisplayName(for: rule))
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: 10, weight: .semibold))
                                            .opacity(0.72)
                                    }
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(theme.text.secondary.color)
                                    .padding(.leading, 10)
                                    .padding(.trailing, 8)
                                    .padding(.vertical, 6)
                                    .background(theme.shortcut.fill.color, in: Capsule())
                                    .overlay(Capsule().stroke(theme.shortcut.border.color, lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                                .help("删除排除目录：\(rule)")
                            }
                        }
                    }

                    SettingsActionButton(
                        "添加",
                        symbol: "folder.badge.plus",
                        theme: theme,
                        compact: true,
                        action: chooseExclusionDirectories
                    )
                    .accessibilityIdentifier("search.add-exclusion")
                }
            }
        }
    }

    private var lastUpdatedText: String {
        guard let date = diagnostics.lastUpdatedAt else { return "尚未完成" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private func exclusionDisplayName(for rule: String) -> String {
        guard rule.hasPrefix("/") else { return rule }
        let name = URL(fileURLWithPath: rule).lastPathComponent
        return name.isEmpty ? rule : name
    }

    private func chooseDirectories() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "添加到索引"
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task {
            for url in urls {
                await environment.addRoot(url)
            }
        }
    }

    private func chooseExclusionDirectories() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "排除所选文件夹"
        guard panel.runModal() == .OK else { return }
        let paths = panel.urls.map { $0.standardizedFileURL.path }
        Task {
            for path in paths {
                await environment.addExclusionRule(path, rebuildAfterChange: false)
            }
            if !paths.isEmpty {
                await environment.rebuildIndex()
            }
        }
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat

    init(spacing: CGFloat) {
        self.spacing = spacing
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var width: CGFloat = 0
        var height: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if width > 0, width + spacing + size.width > maxWidth {
                height += rowHeight + spacing
                width = 0
                rowHeight = 0
            }
            width += (width > 0 ? spacing : 0) + size.width
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: proposal.width ?? width, height: height + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var point = bounds.origin
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if point.x > bounds.minX, point.x + spacing + size.width > bounds.maxX {
                point.x = bounds.minX
                point.y += rowHeight + spacing
                rowHeight = 0
            }
            if point.x > bounds.minX { point.x += spacing }
            subview.place(at: point, proposal: ProposedViewSize(size))
            point.x += size.width
            rowHeight = max(rowHeight, size.height)
        }
    }
}
