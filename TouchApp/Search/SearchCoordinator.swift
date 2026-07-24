import Foundation
import TouchCore

struct SearchPresentationState: Equatable {
    enum Phase: Equatable {
        case idle
        case searching
        case results
        case noResults
        case failed(String)
    }

    var phase: Phase = .idle
    var results: [SearchResult] = []
    var selectedIndex: Int?

    static let idle = SearchPresentationState()
}

enum SearchDismissal: Equatable {
    case cleared
    case dismiss
}

@MainActor
final class SearchCoordinator: ObservableObject {
    private var queryByMode: [SearchMode: String] = [:]
    @Published var query = "" {
        didSet {
            guard query != oldValue else { return }
            queryByMode[mode] = query
            scheduleSearch(query: query, mode: mode)
        }
    }
    @Published var mode: SearchMode = .applications {
        didSet {
            guard mode != oldValue else { return }
            query = queryByMode[mode] ?? ""
            isSearchFieldFocused = mode != .actions
            if mode == .files {
                let environment = environment
                Task { await environment.prepareFileIndex() }
            }
            scheduleSearch(query: query, mode: mode)
        }
    }
    @Published var isSearchFieldFocused = true
    @Published private(set) var state = SearchPresentationState.idle

    private let environment: SearchEnvironment
    private let actionSearch: @MainActor (String) -> [SearchResult]
    private let actionActivation: @MainActor (SearchResult) -> Void
    private var searchTask: Task<Void, Never>?
    private var isKeyboardSelectionActive = false

    init(
        environment: SearchEnvironment,
        actionSearch: @escaping @MainActor (String) -> [SearchResult] = { _ in [] },
        actionActivation: @escaping @MainActor (SearchResult) -> Void = { _ in }
    ) {
        self.environment = environment
        self.actionSearch = actionSearch
        self.actionActivation = actionActivation
    }

    deinit {
        searchTask?.cancel()
    }

    var diagnostics: SearchDiagnostics {
        environment.diagnostics
    }

    func update(query newQuery: String, mode newMode: SearchMode) {
        let modeChanged = self.mode != newMode
        let queryChanged = self.query != newQuery

        // 先写入目标模式缓存，再切换模式；否则 mode.didSet 可能把新 query
        // 覆盖成旧缓存，造成切换模式后搜索框短暂清空或丢失输入。
        queryByMode[newMode] = newQuery
        self.mode = newMode
        self.query = newQuery

        if !modeChanged && !queryChanged {
            scheduleSearch(query: newQuery, mode: newMode)
        }
    }

    private func scheduleSearch(query: String, mode: SearchMode) {
        searchTask?.cancel()
        isKeyboardSelectionActive = false

        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            state = .idle
            return
        }

        state = SearchPresentationState(phase: .searching, results: [], selectedIndex: nil)
        let environment = environment
        let actionSearch = actionSearch
        searchTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(40))
                try Task.checkCancellation()
                let results: [SearchResult]
                switch mode {
                case .actions:
                    results = actionSearch(trimmedQuery)
                case .applications:
                    await environment.prepareApplications()
                    try Task.checkCancellation()
                    results = await environment.applicationCatalog.search(query: trimmedQuery)
                case .files:
                    await environment.prepareFileIndex()
                    try Task.checkCancellation()
                    guard let store = environment.fileIndexStore else {
                        self?.state = SearchPresentationState(
                            phase: .failed("文件索引暂不可用，应用搜索仍可正常使用。"),
                            results: [],
                            selectedIndex: nil
                        )
                        return
                    }
                    let records = try await store.search(trimmedQuery, limit: 80)
                    let candidates = records.map {
                        SearchResult(
                            title: $0.fileName,
                            subtitle: URL(fileURLWithPath: $0.path).deletingLastPathComponent().path,
                            path: $0.path,
                            kind: .file
                        )
                    }
                    results = SearchRanking.sort(candidates, query: trimmedQuery)
                }


                try Task.checkCancellation()
                guard self?.query == query, self?.mode == mode else { return }
                self?.state = SearchPresentationState(
                    phase: results.isEmpty ? .noResults : .results,
                    results: results,
                    selectedIndex: results.isEmpty ? nil : 0
                )
            } catch is CancellationError {
                return
            } catch {
                guard self?.query == query, self?.mode == mode else { return }
                self?.state = SearchPresentationState(
                    phase: .failed("搜索暂时不可用，请检查索引状态后重试。"),
                    results: [],
                    selectedIndex: nil
                )
            }
        }
    }

    func advanceMode() {
        switch mode {
        case .actions:
            mode = .applications
        case .applications:
            mode = .files
        case .files:
            mode = .actions
        }
    }

    func prepareForPresentation() {
        searchTask?.cancel()
        queryByMode = [:]
        mode = .applications
        query = ""
        isSearchFieldFocused = true
        state = .idle
        isKeyboardSelectionActive = false
    }

    func exitActionSearch() {
        guard mode == .actions, isSearchFieldFocused else { return }
        query = ""
        isSearchFieldFocused = false
        state = .idle
        isKeyboardSelectionActive = false
    }

    func moveSelection(by offset: Int) {
        guard !state.results.isEmpty else { return }
        let current = state.selectedIndex ?? 0
        state.selectedIndex = (current + offset + state.results.count) % state.results.count
        isKeyboardSelectionActive = true
    }

    func activateSelected(commandModifier: Bool = false) {
        guard let result = selectedResult else { return }
        let environment = environment
        if result.kind == .action {
            actionActivation(result)
            return
        }
        Task { [weak self] in
            do {
                if commandModifier {
                    try environment.systemActions.revealFile(at: URL(fileURLWithPath: result.path))
                } else {
                    switch result.kind {
                    case .action:
                        break
                    case .application:
                        try await environment.applicationCatalog.launch(bundleIdentifier: result.id)
                    case .file:
                        try environment.systemActions.openFile(at: URL(fileURLWithPath: result.path))
                    }
                }
                self?.requestDismissal()
            } catch {
                if result.kind == .file {
                    try? await environment.fileIndexStore?.delete(path: result.path)
                }
                self?.state.phase = .failed("无法打开“\(result.title)”，项目可能已移动或不可访问。")
            }
        }
    }

    func previewSelected() {
        guard mode == .files, let result = selectedResult else { return }
        do {
            try environment.systemActions.previewFile(at: URL(fileURLWithPath: result.path))
        } catch {
            state.phase = .failed("无法预览“\(result.title)”，项目可能已移动或不可访问。")
        }
    }

    func clearOrDismiss() -> SearchDismissal {
        guard !query.isEmpty else { return .dismiss }
        query = ""
        return .cleared
    }

    var canPreviewSelectedResult: Bool {
        mode == .files && isKeyboardSelectionActive && selectedResult != nil
    }

    private var selectedResult: SearchResult? {
        guard let index = state.selectedIndex, state.results.indices.contains(index) else { return nil }
        return state.results[index]
    }

    private func requestDismissal() {
        NotificationCenter.default.post(name: .dismissTouchLauncher, object: nil)
    }
}

extension Notification.Name {
    static let dismissTouchLauncher = Notification.Name("me.touch.dismiss-launcher")
}
