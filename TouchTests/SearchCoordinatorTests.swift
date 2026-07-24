import Foundation
import TouchCore
import XCTest
@testable import 触达

private struct CoordinatorApplicationDiscoverer: ApplicationDiscovering {
    let applications: [ApplicationRecord]

    func discoverApplications() async -> [ApplicationRecord] {
        applications
    }
}

private struct DelayedApplicationDiscoverer: ApplicationDiscovering {
    let applications: [ApplicationRecord]

    func discoverApplications() async -> [ApplicationRecord] {
        try? await Task.sleep(for: .milliseconds(120))
        return applications
    }
}

private actor CoordinatorApplicationLauncher: ApplicationLaunching {
    func openApplication(at url: URL) async throws {}
}

@MainActor
private final class CoordinatorSearchActions: SearchActionServicing {
    enum Failure: Error { case unavailable }

    var shouldFailOpen = false
    private(set) var openedURLs: [URL] = []
    private(set) var revealedURLs: [URL] = []
    private(set) var previewedURLs: [URL] = []

    func openFile(at url: URL) throws {
        if shouldFailOpen { throw Failure.unavailable }
        openedURLs.append(url)
    }

    func revealFile(at url: URL) throws {
        revealedURLs.append(url)
    }

    func previewFile(at url: URL) throws {
        previewedURLs.append(url)
    }
}

@MainActor
final class SearchCoordinatorTests: XCTestCase {
    func testPresentationStartsInActionModeWithoutSearchFocus() async throws {
        let coordinator = try await makeCoordinator()
        coordinator.query = "stale"

        coordinator.prepareForPresentation()

        XCTAssertEqual(coordinator.mode, .actions)
        XCTAssertEqual(coordinator.query, "")
        XCTAssertFalse(coordinator.isSearchFieldFocused)
        XCTAssertEqual(coordinator.state, .idle)
    }

    func testTabCycleMovesThroughActionApplicationAndFileFocusStates() async throws {
        let coordinator = try await makeCoordinator()
        coordinator.prepareForPresentation()

        coordinator.advanceMode()
        XCTAssertEqual(coordinator.mode, .applications)
        XCTAssertTrue(coordinator.isSearchFieldFocused)

        coordinator.advanceMode()
        XCTAssertEqual(coordinator.mode, .files)
        XCTAssertTrue(coordinator.isSearchFieldFocused)

        coordinator.advanceMode()
        XCTAssertEqual(coordinator.mode, .actions)
        XCTAssertFalse(coordinator.isSearchFieldFocused)
    }

    func testFocusedActionModeSearchesProvidedActions() async throws {
        let coordinator = try await makeCoordinator { query in
            SearchRanking.sort(
                [
                    SearchResult(
                        id: "action.feature.screenshot",
                        title: "截取屏幕",
                        subtitle: "内置功能 · A 键",
                        pinyin: "截图、标注与钉图",
                        initials: "A",
                        kind: .action
                    )
                ],
                query: query
            )
        }
        coordinator.mode = .actions
        coordinator.isSearchFieldFocused = true

        coordinator.query = "截图"

        try await waitUntil { coordinator.state.phase == .results }
        XCTAssertEqual(coordinator.state.results.map(\.title), ["截取屏幕"])
    }

    func testLeavingActionSearchClearsQueryAndFocus() async throws {
        let coordinator = try await makeCoordinator { _ in
            [SearchResult(title: "截取屏幕", kind: .action)]
        }
        coordinator.mode = .actions
        coordinator.isSearchFieldFocused = true
        coordinator.query = "截图"

        coordinator.exitActionSearch()

        XCTAssertEqual(coordinator.query, "")
        XCTAssertFalse(coordinator.isSearchFieldFocused)
        XCTAssertEqual(coordinator.state, .idle)
    }

    func testSearchWaitsForSharedEnvironmentPreparation() async throws {
        let catalog = ApplicationCatalog(
            discoverer: DelayedApplicationDiscoverer(
                applications: [application(id: "finder", name: "Finder")]
            ),
            launcher: CoordinatorApplicationLauncher()
        )
        let environment = SearchEnvironment(
            applicationCatalog: catalog,
            fileIndexStore: nil,
            systemActions: CoordinatorSearchActions()
        )
        let coordinator = SearchCoordinator(environment: environment)

        coordinator.query = "finder"

        try await waitUntil(timeout: .seconds(2)) { coordinator.state.phase == .results }
        XCTAssertEqual(coordinator.state.results.map(\.title), ["Finder"])
    }

    func testLatestQueryCancelsOlderDebouncedSearch() async throws {
        let coordinator = try await makeCoordinator(applications: [
            application(id: "finder", name: "Finder"),
            application(id: "calendar", name: "Calendar")
        ])

        coordinator.query = "find"
        coordinator.query = "calendar"

        try await waitUntil { coordinator.state.phase == .results }
        XCTAssertEqual(coordinator.state.results.map(\.title), ["Calendar"])
    }

    func testMovingSelectionWrapsAroundResults() async throws {
        let coordinator = try await makeCoordinator(applications: [
            application(id: "finder", name: "Finder"),
            application(id: "find-my", name: "Find My")
        ])
        coordinator.query = "find"
        try await waitUntil { coordinator.state.phase == .results }

        coordinator.moveSelection(by: -1)

        XCTAssertEqual(coordinator.state.selectedIndex, 1)
    }

    func testSpacePreviewRequiresKeyboardSelectionAndQueryChangeDisarmsIt() async throws {
        let store = try FileIndexStore.temporary()
        try await store.upsert([
            FileIndexRecord(
                path: "/tmp/TouchFixture/design brief.txt",
                rootPath: "/tmp/TouchFixture",
                contentType: "public.plain-text",
                size: 1,
                createdAt: .now,
                modifiedAt: .now,
                isDirectory: false
            )
        ])
        let coordinator = try await makeCoordinator(fileIndexStore: store)
        coordinator.mode = .files
        coordinator.query = "design"
        try await waitUntil { coordinator.state.phase == .results }

        XCTAssertFalse(coordinator.canPreviewSelectedResult)
        coordinator.moveSelection(by: 1)
        XCTAssertTrue(coordinator.canPreviewSelectedResult)

        coordinator.query = "design brief"
        XCTAssertFalse(coordinator.canPreviewSelectedResult)
    }

    func testCommandEnterRevealsApplicationInsteadOfLaunchingIt() async throws {
        let actions = CoordinatorSearchActions()
        let coordinator = try await makeCoordinator(
            applications: [application(id: "finder", name: "Finder")],
            actions: actions
        )
        coordinator.query = "finder"
        try await waitUntil { coordinator.state.phase == .results }

        coordinator.activateSelected(commandModifier: true)

        try await waitUntil { !actions.revealedURLs.isEmpty }
        XCTAssertEqual(actions.revealedURLs.map(\.path), ["/Applications/Finder.app"])
    }

    func testFailedFileOpenRemovesStalePathFromIndex() async throws {
        let store = try FileIndexStore.temporary()
        let stalePath = "/tmp/TouchStaleFixture/missing-note.txt"
        try await store.upsert([
            FileIndexRecord(
                path: stalePath,
                rootPath: "/tmp/TouchStaleFixture",
                contentType: "public.plain-text",
                size: 1,
                createdAt: .now,
                modifiedAt: .now,
                isDirectory: false
            )
        ])
        let actions = CoordinatorSearchActions()
        actions.shouldFailOpen = true
        let coordinator = try await makeCoordinator(fileIndexStore: store, actions: actions)
        coordinator.mode = .files
        coordinator.query = "missing"
        try await waitUntil { coordinator.state.phase == .results }

        coordinator.activateSelected()

        try await waitUntil {
            if case .failed = coordinator.state.phase { return true }
            return false
        }
        let remainingRecords = try await store.search("missing", limit: 10)
        XCTAssertTrue(remainingRecords.isEmpty)
    }

    private func makeCoordinator(
        applications: [ApplicationRecord] = [],
        fileIndexStore: FileIndexStore? = nil,
        actions: CoordinatorSearchActions = CoordinatorSearchActions(),
        actionSearch: @escaping @MainActor (String) -> [SearchResult] = { _ in [] }
    ) async throws -> SearchCoordinator {
        let catalog = ApplicationCatalog(
            discoverer: CoordinatorApplicationDiscoverer(applications: applications),
            launcher: CoordinatorApplicationLauncher()
        )
        let environment = SearchEnvironment(
            applicationCatalog: catalog,
            fileIndexStore: fileIndexStore,
            systemActions: actions
        )
        await environment.prepare()
        return SearchCoordinator(environment: environment, actionSearch: actionSearch)
    }

    private func application(id: String, name: String) -> ApplicationRecord {
        ApplicationRecord(
            bundleIdentifier: id,
            name: name,
            path: "/Applications/\(name).app",
            isUserInstalled: true
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @MainActor () async throws -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("等待异步搜索状态超时")
    }
}

final class SearchResultHighlightingTests: XCTestCase {
    func testContiguousMatchHighlightsTheMatchingTitlePart() {
        let result = SearchResult(title: "Finder", kind: .application)

        let matches = SearchResultHighlighting.matchedRanges(in: result, query: "ind")

        XCTAssertEqual(matches.map { String(result.title[$0]) }, ["ind"])
    }

    func testFuzzyMatchHighlightsEachMatchedCharacter() {
        let result = SearchResult(title: "Finder", kind: .application)

        let matches = SearchResultHighlighting.matchedRanges(in: result, query: "fd")

        XCTAssertEqual(matches.map { String(result.title[$0]) }, ["F", "d"])
    }

    func testPinyinMatchHighlightsTheWholeVisibleTitle() {
        let result = SearchResult(
            title: "系统设置",
            pinyin: "xi tong she zhi",
            initials: "xtsz",
            kind: .application
        )

        let matches = SearchResultHighlighting.matchedRanges(in: result, query: "xtsz")

        XCTAssertEqual(matches.map { String(result.title[$0]) }, ["系统设置"])
    }
}
