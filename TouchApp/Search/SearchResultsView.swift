import SwiftUI

struct SearchResultsView: View {
    @ObservedObject var coordinator: SearchCoordinator
    let theme: ThemeDefinition

    var body: some View {
        Group {
            switch coordinator.state.phase {
            case .idle:
                EmptyView()
            case .searching:
                VStack(spacing: 10) {
                    ProgressView()
                    Text("正在搜索…")
                        .foregroundStyle(theme.text.secondary.color)
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
                                theme: theme
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
                    title: noResultsTitle,
                    message: noResultsMessage
                )
            case let .failed(message):
                emptyState(title: "操作未完成", message: message)
            }
        }
        .id(transitionIdentity)
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.08), value: transitionIdentity)
    }

    private var noResultsTitle: String {
        switch coordinator.mode {
        case .actions: "没有找到匹配的动作"
        case .applications: "没有找到匹配的应用"
        case .files: "没有找到匹配的文件"
        }
    }

    private var noResultsMessage: String {
        switch coordinator.mode {
        case .actions: "请尝试功能名称或自定义动作名称。"
        case .applications: "请尝试应用名称、拼音或首字母。"
        case .files: ""
        }
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
                .foregroundStyle(theme.text.primary.color)
            if !message.isEmpty {
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.text.secondary.color)
                    .multilineTextAlignment(.center)
            }
            if coordinator.mode == .files {
                Button {
                    NotificationCenter.default.post(name: .openTouchSettings, object: TouchSettingsSection.search)
                } label: {
                    Text("检查索引范围")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.text.secondary.color)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("search.empty.index-settings")
            }
        }
        .frame(maxWidth: .infinity, minHeight: 180)
    }
}

extension Notification.Name {
    static let rebuildTouchSearchIndex = Notification.Name("me.touch.rebuild-search-index")
}
