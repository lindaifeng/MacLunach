import Foundation
import TouchCore

@MainActor
protocol SearchEventMonitoring: AnyObject {
    func start(roots: [URL], handler: @escaping @Sendable (FileIndexEvent) -> Void)
    func stop()
}

extension FileEventMonitor: SearchEventMonitoring {}

@MainActor
protocol SearchRootPersisting: AnyObject {
    func loadRoots(defaults: [URL]) -> [URL]
    func saveRoots(_ roots: [URL])
}

@MainActor
final class SearchRootBookmarkStore: SearchRootPersisting {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "search.indexRootBookmarks") {
        self.defaults = defaults
        self.key = key
    }

    func loadRoots(defaults fallbackRoots: [URL]) -> [URL] {
        guard let bookmarks = defaults.array(forKey: key) as? [Data] else { return fallbackRoots }
        var containsStaleBookmark = false
        let roots = bookmarks.compactMap { data -> URL? in
            var isStale = false
            guard let url = try? URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) else { return nil }
            containsStaleBookmark = containsStaleBookmark || isStale
            return url.standardizedFileURL
        }
        if containsStaleBookmark { saveRoots(roots) }
        return roots
    }

    func saveRoots(_ roots: [URL]) {
        let bookmarks = roots.compactMap {
            try? $0.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        }
        // Never replace a valid selection with a partially encoded one.
        guard bookmarks.count == roots.count else { return }
        defaults.set(bookmarks, forKey: key)
    }
}

@MainActor
final class SearchEnvironment: ObservableObject {
    let applicationCatalog: ApplicationCatalog
    private(set) var fileIndexStore: FileIndexStore?
    let systemActions: any SearchActionServicing
    let diagnostics: SearchDiagnostics

    private let initialFileRecords: [FileIndexRecord]
    private let databaseURL: URL?
    private let eventMonitor: (any SearchEventMonitoring)?
    private let rootPersistence: (any SearchRootPersisting)?
    private var roots: [URL]
    private var preparationTask: Task<Void, Never>?
    private var indexingTask: Task<Void, Never>?
    private var didPrepareIndex = false
    private var securityScopedRoots: [URL] = []

    init(
        applicationCatalog: ApplicationCatalog,
        fileIndexStore: FileIndexStore?,
        systemActions: any SearchActionServicing = WorkspaceSearchActionService(),
        initialFileRecords: [FileIndexRecord] = [],
        roots: [URL] = [],
        databaseURL: URL? = nil,
        eventMonitor: (any SearchEventMonitoring)? = nil,
        rootPersistence: (any SearchRootPersisting)? = nil
    ) {
        self.applicationCatalog = applicationCatalog
        self.fileIndexStore = fileIndexStore
        self.systemActions = systemActions
        self.initialFileRecords = initialFileRecords
        self.roots = Self.normalizedRoots(roots)
        self.databaseURL = databaseURL
        self.eventMonitor = eventMonitor
        self.rootPersistence = rootPersistence
        diagnostics = SearchDiagnostics(
            roots: Self.normalizedRoots(roots),
            fileCount: initialFileRecords.count,
            databaseSize: Self.databaseSize(at: databaseURL),
            lastUpdatedAt: initialFileRecords.isEmpty ? nil : .now,
            status: initialFileRecords.isEmpty ? .waiting : .ready
        )
        securityScopedRoots = self.roots.filter { $0.startAccessingSecurityScopedResource() }
    }

    deinit {
        for root in securityScopedRoots { root.stopAccessingSecurityScopedResource() }
    }

    static func makeForCurrentProcess() -> SearchEnvironment {
        if CommandLine.arguments.contains("--search-fixture") { return fixture() }
        return live()
    }

    func prepare() async {
        let task: Task<Void, Never>
        if let preparationTask {
            task = preparationTask
        } else {
            let applicationCatalog = applicationCatalog
            task = Task { _ = await applicationCatalog.refresh() }
            preparationTask = task
        }
        await task.value
        guard !didPrepareIndex else { return }
        didPrepareIndex = true

        guard let fileIndexStore else {
            diagnostics.update(status: .unavailable("文件索引数据库无法打开；应用搜索仍可正常使用。"))
            return
        }
        if !initialFileRecords.isEmpty {
            do {
                try await fileIndexStore.upsert(initialFileRecords)
                refreshDiagnostics(fileCount: try await fileIndexStore.recordCount(), status: .ready)
            } catch {
                diagnostics.update(status: .unavailable("文件索引暂不可用；应用搜索仍可正常使用。"))
            }
            return
        }

        let count = (try? await fileIndexStore.recordCount()) ?? 0
        if count > 0 {
            refreshDiagnostics(fileCount: count, status: .ready, updateTimestamp: false)
            startMonitoring()
            // FSEvents starts before reconciliation so changes occurring during the
            // background pass are still delivered. Application search is independent.
            indexingTask = Task { [weak self] in await self?.performReconciliation() }
        } else {
            diagnostics.update(status: .indexing)
            indexingTask = Task { [weak self] in await self?.performInitialIndexing() }
        }
    }

    func addRoot(_ url: URL) async {
        let normalized = url.standardizedFileURL
        let previousRoots = roots
        let updatedRoots = Self.normalizedRoots(previousRoots + [normalized])
        let previousPaths = Set(previousRoots.map(Self.canonicalPath(for:)))
        let updatedPaths = Set(updatedRoots.map(Self.canonicalPath(for:)))
        guard previousPaths != updatedPaths else { return }

        let interruptedIndexing = await cancelIndexing()
        if normalized.startAccessingSecurityScopedResource() {
            securityScopedRoots.append(normalized)
        }
        roots = updatedRoots
        releaseAccessForUnconfiguredRoots()
        rootPersistence?.saveRoots(roots)
        diagnostics.update(roots: roots, status: .indexing)
        eventMonitor?.stop()
        do {
            for removedRoot in previousRoots where !updatedPaths.contains(Self.canonicalPath(for: removedRoot)) {
                try await fileIndexStore?.delete(root: Self.canonicalPath(for: removedRoot))
            }
            try await scan(root: normalized, replacingExisting: true, status: .indexing)
            refreshDiagnostics(fileCount: try await fileIndexStore?.recordCount() ?? 0, status: .ready)
            startMonitoring()
            if interruptedIndexing { startReconciliation() }
        } catch {
            diagnostics.update(status: .unavailable("目录索引未完成，请检查访问权限后重试。"))
            startMonitoring()
        }
    }

    func removeRoot(at index: Int) async {
        let interruptedIndexing = await cancelIndexing()
        guard roots.indices.contains(index) else { return }
        let removed = roots.remove(at: index)
        if let accessIndex = securityScopedRoots.firstIndex(of: removed) {
            securityScopedRoots.remove(at: accessIndex).stopAccessingSecurityScopedResource()
        }
        rootPersistence?.saveRoots(roots)
        eventMonitor?.stop()
        do {
            try await fileIndexStore?.delete(root: Self.canonicalPath(for: removed))
            diagnostics.update(roots: roots)
            refreshDiagnostics(fileCount: try await fileIndexStore?.recordCount() ?? 0, status: .ready)
        } catch {
            diagnostics.update(status: .unavailable("无法移除该目录的索引记录，请重试。"))
        }
        startMonitoring()
        if interruptedIndexing { startReconciliation() }
    }

    func rebuildIndex() async {
        _ = await cancelIndexing()
        eventMonitor?.stop()
        diagnostics.update(status: .rebuilding)

        do {
            if let databaseURL {
                try await fileIndexStore?.close()
                _ = try FileIndexStore.isolateDatabase(at: databaseURL, reason: .rebuild)
                fileIndexStore = try FileIndexStore(databaseURL: databaseURL)
            } else if let fileIndexStore {
                for root in roots { try await fileIndexStore.delete(root: Self.canonicalPath(for: root)) }
            } else {
                throw FileIndexStoreError.openFailed
            }

            if initialFileRecords.isEmpty {
                for root in roots where FileManager.default.fileExists(atPath: root.path) {
                    try Task.checkCancellation()
                    try await scan(root: root, replacingExisting: true, status: .rebuilding)
                }
            } else {
                try await fileIndexStore?.upsert(initialFileRecords)
            }
            refreshDiagnostics(fileCount: try await fileIndexStore?.recordCount() ?? 0, status: .ready)
            startMonitoring()
        } catch is CancellationError {
            diagnostics.update(status: .waiting)
        } catch {
            if fileIndexStore == nil, let databaseURL {
                fileIndexStore = try? FileIndexStore.openRecovering(databaseURL: databaseURL).store
            }
            diagnostics.update(status: .unavailable("重建未完成，请检查目录访问权限后重试；应用搜索仍可正常使用。"))
            startMonitoring()
        }
    }

    private func performInitialIndexing() async {
        do {
            for root in roots where FileManager.default.fileExists(atPath: root.path) {
                try Task.checkCancellation()
                try await scan(root: root, replacingExisting: false, status: .indexing)
            }
            refreshDiagnostics(fileCount: try await fileIndexStore?.recordCount() ?? 0, status: .ready)
            startMonitoring()
        } catch is CancellationError {
            return
        } catch {
            diagnostics.update(status: .unavailable("首次索引未完成，请检查目录访问权限后重试；应用搜索仍可正常使用。"))
            startMonitoring()
        }
    }

    private func performReconciliation() async {
        do {
            for root in roots where FileManager.default.fileExists(atPath: root.path) {
                try Task.checkCancellation()
                try await scan(root: root, replacingExisting: true, status: .ready)
            }
            refreshDiagnostics(fileCount: try await fileIndexStore?.recordCount() ?? 0, status: .ready)
        } catch is CancellationError {
            return
        } catch {
            diagnostics.update(status: .unavailable("后台索引对账未完成；应用搜索仍可正常使用。"))
        }
    }

    private func startReconciliation() {
        guard fileIndexStore != nil, !roots.isEmpty else { return }
        indexingTask = Task { [weak self] in await self?.performReconciliation() }
    }

    private func cancelIndexing() async -> Bool {
        guard let indexingTask else { return false }
        indexingTask.cancel()
        await indexingTask.value
        self.indexingTask = nil
        return true
    }

    private func releaseAccessForUnconfiguredRoots() {
        let configuredPaths = Set(roots.map(Self.canonicalPath(for:)))
        let removed = securityScopedRoots.filter { !configuredPaths.contains(Self.canonicalPath(for: $0)) }
        for root in removed { root.stopAccessingSecurityScopedResource() }
        securityScopedRoots.removeAll { !configuredPaths.contains(Self.canonicalPath(for: $0)) }
    }

    private func scan(root: URL, replacingExisting: Bool, status: SearchDiagnostics.Status) async throws {
        guard let fileIndexStore else { throw FileIndexStoreError.openFailed }
        if replacingExisting { try await fileIndexStore.delete(root: Self.canonicalPath(for: root)) }
        for try await batch in FileIndexScanner.batches(root: root) {
            try Task.checkCancellation()
            try await fileIndexStore.upsert(batch)
            refreshDiagnostics(fileCount: try await fileIndexStore.recordCount(), status: status)
        }
    }

    private func scan(subtree: URL, belongingTo root: URL, status: SearchDiagnostics.Status) async throws {
        guard let fileIndexStore else { throw FileIndexStoreError.openFailed }
        try await fileIndexStore.delete(subtree: Self.canonicalPath(for: subtree))
        for try await batch in FileIndexScanner.batches(root: subtree, indexRoot: root, includeRoot: true) {
            try Task.checkCancellation()
            try await fileIndexStore.upsert(batch)
            refreshDiagnostics(fileCount: try await fileIndexStore.recordCount(), status: status)
        }
    }

    private func startMonitoring() {
        guard !roots.isEmpty else { return }
        eventMonitor?.start(roots: roots) { [weak self] event in
            Task { @MainActor [weak self] in await self?.handle(event: event) }
        }
    }

    func handle(event: FileIndexEvent) async {
        switch event {
        case let .rescanRequired(url):
            for root in affectedRoots(for: url) {
                try? await scan(root: root, replacingExisting: true, status: .indexing)
            }
        case let .changed(url):
            guard let root = affectedRoots(for: url).first, let store = fileIndexStore else { return }
            if FileManager.default.fileExists(atPath: url.path),
               let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentTypeKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey]) {
                if values.isDirectory == true {
                    try? await scan(subtree: url, belongingTo: root, status: .indexing)
                } else {
                    let record = FileIndexRecord(
                        path: url.path,
                        rootPath: root.path,
                        contentType: values.contentType?.identifier ?? "public.data",
                        size: Int64(values.fileSize ?? 0),
                        createdAt: values.creationDate ?? .distantPast,
                        modifiedAt: values.contentModificationDate ?? .distantPast,
                        isDirectory: false
                    )
                    try? await store.upsert([record])
                }
            } else {
                try? await store.delete(subtree: Self.canonicalPath(for: url))
            }
        }
        let count = (try? await fileIndexStore?.recordCount()) ?? 0
        refreshDiagnostics(fileCount: count, status: .ready)
    }

    private func affectedRoots(for eventURL: URL) -> [URL] {
        let eventPath = Self.canonicalPath(for: eventURL)
        return roots.filter { root in
            let rootPath = Self.canonicalPath(for: root)
            return eventPath == rootPath || eventPath.hasPrefix(rootPath + "/") || rootPath.hasPrefix(eventPath + "/")
        }
    }

    private func refreshDiagnostics(
        fileCount: Int,
        status: SearchDiagnostics.Status,
        updateTimestamp: Bool = true
    ) {
        diagnostics.update(
            roots: roots,
            fileCount: fileCount,
            databaseSize: Self.databaseSize(at: databaseURL),
            lastUpdatedAt: updateTimestamp ? .some(.now) : nil,
            status: status
        )
    }

    private static func live() -> SearchEnvironment {
        let catalog = ApplicationCatalog(
            discoverer: WorkspaceApplicationDiscoverer(),
            launcher: WorkspaceApplicationLauncher()
        )
        let databaseURL = fileIndexDatabaseURL()
        let rootPersistence = SearchRootBookmarkStore()
        let roots = rootPersistence.loadRoots(defaults: defaultRoots())
        let store = try? FileIndexStore.openRecovering(databaseURL: databaseURL).store
        return SearchEnvironment(
            applicationCatalog: catalog,
            fileIndexStore: store,
            roots: roots,
            databaseURL: databaseURL,
            eventMonitor: FileEventMonitor(),
            rootPersistence: rootPersistence
        )
    }

    private static func fixture() -> SearchEnvironment {
        let actionLogURL = argumentValue(for: "--search-action-log=")
            .map { URL(fileURLWithPath: $0) }
        let failingAction = argumentValue(for: "--search-action-failure=")
        let finder = ApplicationRecord(
            bundleIdentifier: "com.apple.finder",
            name: "Finder",
            path: "/System/Library/CoreServices/Finder.app",
            isUserInstalled: false
        )
        let catalog = ApplicationCatalog(
            discoverer: FixtureApplicationDiscoverer(applications: [finder]),
            launcher: FixtureApplicationLauncher(logURL: actionLogURL, failingAction: failingAction)
        )
        let now = Date()
        let root = "/tmp/TouchSearchFixture"
        let records = [
            FileIndexRecord(path: "\(root)/Design Brief.txt", rootPath: root, contentType: "public.plain-text", size: 128, createdAt: now, modifiedAt: now, isDirectory: false),
            FileIndexRecord(path: "\(root)/Design Notes.md", rootPath: root, contentType: "net.daringfireball.markdown", size: 256, createdAt: now, modifiedAt: now, isDirectory: false)
        ]
        return SearchEnvironment(
            applicationCatalog: catalog,
            fileIndexStore: try? .temporary(),
            systemActions: FixtureSearchActionService(logURL: actionLogURL, failingAction: failingAction),
            initialFileRecords: records,
            roots: [URL(fileURLWithPath: root)]
        )
    }

    private static func argumentValue(for prefix: String) -> String? {
        CommandLine.arguments.first(where: { $0.hasPrefix(prefix) }).flatMap { argument in
            guard let value = argument.split(separator: "=", maxSplits: 1).last else { return nil }
            return String(value)
        }
    }

    private static func fileIndexDatabaseURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Touch/Search", isDirectory: true).appendingPathComponent("file-index.sqlite")
    }

    private static func defaultRoots() -> [URL] {
        let directories: [FileManager.SearchPathDirectory] = [.desktopDirectory, .documentDirectory, .downloadsDirectory]
        return directories.compactMap { FileManager.default.urls(for: $0, in: .userDomainMask).first }.map(\.standardizedFileURL)
    }

    private static func normalizedRoots(_ roots: [URL]) -> [URL] {
        roots.map(\.standardizedFileURL).reduce(into: [URL]()) { result, candidate in
            let candidatePath = canonicalPath(for: candidate)
            if result.contains(where: {
                let existingPath = canonicalPath(for: $0)
                return candidatePath == existingPath || candidatePath.hasPrefix(existingPath + "/")
            }) {
                return
            }
            result.removeAll {
                canonicalPath(for: $0).hasPrefix(candidatePath + "/")
            }
            result.append(candidate)
        }
    }

    private static func canonicalPath(for url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func databaseSize(at url: URL?) -> Int64 {
        guard let url,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else { return 0 }
        return size.int64Value
    }
}

private struct FixtureApplicationDiscoverer: ApplicationDiscovering {
    let applications: [ApplicationRecord]
    func discoverApplications() async -> [ApplicationRecord] { applications }
}

private struct FixtureApplicationLauncher: ApplicationLaunching {
    let logURL: URL?
    let failingAction: String?

    func openApplication(at url: URL) async throws {
        if failingAction == "launch" { throw SearchFixtureActionError.requestedFailure }
        SearchFixtureActionLog.append("launch", url: url, to: logURL)
    }
}
