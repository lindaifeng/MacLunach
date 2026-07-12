import SwiftUI

struct SearchResultsView: View {
    @ObservedObject var coordinator: SearchCoordinator
    let palette: ThemePalette

    var body: some View {
        Group {
            switch coordinator.state.phase {
            case .idle:
                EmptyView()
            case .searching:
                VStack(spacing: 10) {
                    ProgressView()
                    Text("正在搜索…")
                        .foregroundStyle(palette.secondaryText)
                }
                .frame(maxWidth: .infinity, minHeight: 180)
            case .results:
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(Array(coordinator.state.results.enumerated()), id: \.element.id) { index, result in
                            SearchResultRow(
                                result: result,
                                query: coordinator.query,
                                isSelected: coordinator.state.selectedIndex == index,
                                palette: palette
                            ) {
                                coordinator.moveSelection(by: index - (coordinator.state.selectedIndex ?? 0))
                                coordinator.activateSelected()
                            }
                        }
                    }
                }
                .frame(maxHeight: 260)
            case .noResults:
                emptyState(
                    title: "没有找到匹配结果",
                    message: coordinator.mode == .applications
                        ? "可以切换到文件搜索，或尝试应用名称、拼音和首字母。"
                        : "请检查索引范围，或前往设置重建文件索引。"
                )
            case let .failed(message):
                emptyState(title: "操作未完成", message: message)
            }
        }
        .id(transitionIdentity)
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.08), value: transitionIdentity)
    }

    private var transitionIdentity: String {
        let phase: String
        switch coordinator.state.phase {
        case .idle: phase = "idle"
        case .searching: phase = "searching"
        case .results: phase = "results"
        case .noResults: phase = "no-results"
        case let .failed(message): phase = "failed:\(message)"
        }
        return "\(coordinator.mode.rawValue)|\(coordinator.query)|\(phase)|\(coordinator.state.results.map(\.id).joined(separator: ","))"
    }

    private func emptyState(title: String, message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28, weight: .medium))
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(palette.primaryText)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(palette.secondaryText)
                .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                Button(coordinator.mode == .applications ? "切换到文件" : "切换到应用") {
                    coordinator.toggleMode()
                }
                .accessibilityIdentifier("search.empty.switch-mode")
                Button("检查索引范围") {
                    NotificationCenter.default.post(name: .openTouchSettings, object: nil)
                }
                .accessibilityIdentifier("search.empty.index-settings")
                Button("重建索引") {
                    NotificationCenter.default.post(name: .rebuildTouchSearchIndex, object: nil)
                }
                .accessibilityIdentifier("search.empty.rebuild-index")
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, minHeight: 180)
    }
}

extension Notification.Name {
    static let rebuildTouchSearchIndex = Notification.Name("me.touch.rebuild-search-index")
}
