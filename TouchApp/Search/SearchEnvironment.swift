import Foundation
import Combine
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
    private let defaultsSeededKey: String

    init(defaults: UserDefaults = .standard, key: String = "search.indexRootBookmarks") {
        self.defaults = defaults
        self.key = key
        defaultsSeededKey = "\(key).defaults-seeded-v3"
    }

    func loadRoots(defaults fallbackRoots: [URL]) -> [URL] {
        guard let bookmarks = defaults.array(forKey: key) as? [Data] else {
            saveRoots(fallbackRoots)
            return fallbackRoots
        }
        if bookmarks.isEmpty, !defaults.bool(forKey: defaultsSeededKey) {
            saveRoots(fallbackRoots)
            return fallbackRoots
        }
        var containsStaleBookmark = false
        let roots = bookmarks.compactMap { data -> URL? in
            var isStale = false
            let securityScopedURL = try? URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            let url = securityScopedURL ?? (try? URL(
                resolvingBookmarkData: data,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ))
            guard let url else { return nil }
            containsStaleBookmark = containsStaleBookmark || isStale
            return url.standardizedFileURL
        }
        if roots.isEmpty, !bookmarks.isEmpty, !fallbackRoots.isEmpty {
            saveRoots(fallbackRoots)
            return fallbackRoots
        }
        if !defaults.bool(forKey: defaultsSeededKey) {
            let mergedRoots = Self.merging(fallbackRoots, with: roots)
            saveRoots(mergedRoots)
            return mergedRoots
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
        defaults.set(true, forKey: defaultsSeededKey)
    }

    private static func merging(_ defaults: [URL], with customRoots: [URL]) -> [URL] {
        (defaults + customRoots).reduce(into: [URL]()) { result, url in
            let normalized = url.standardizedFileURL
            let path = normalized.resolvingSymlinksInPath().path
            guard !result.contains(where: {
                $0.resolvingSymlinksInPath().path == path
            }) else { return }
            result.append(normalized)
        }
    }
}

@MainActor
protocol SearchExclusionPersisting: AnyObject {
    func loadRules(defaults: [String]) -> [String]
    func saveRules(_ rules: [String])
}

@MainActor
final class SearchExclusionDefaultsStore: SearchExclusionPersisting {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "search.exclusionRules") {
        self.defaults = defaults
        self.key = key
    }

    func loadRules(defaults fallbackRules: [String]) -> [String] {
        guard let rules = defaults.stringArray(forKey: key) else { return fallbackRules }
        return rules
    }

    func saveRules(_ rules: [String]) {
        defaults.set(rules, forKey: key)
    }
}

@MainActor
final class SearchEnvironment: ObservableObject {
    enum FileAccessState: Equatable {
        case notConfigured
        case granted(count: Int)
        case partiallyGranted(accessible: Int, total: Int)
        case denied(total: Int)
    }

    let applicationCatalog: ApplicationCatalog
    private(set) var fileIndexStore: FileIndexStore?
    let systemActions: any SearchActionServicing
    let diagnostics: SearchDiagnostics
    @Published private(set) var fileAccessState: FileAccessState = .notConfigured

    private let initialFileRecords: [FileIndexRecord]
    private let databaseURL: URL?
    private let eventMonitor: (any SearchEventMonitoring)?
    private let rootPersistence: (any SearchRootPersisting)?
    private let exclusionPersistence: (any SearchExclusionPersisting)?
    private var roots: [URL]
    private var exclusionRules: [String]
    private var preparationTask: Task<Void, Never>?
    private var indexingTask: Task<Void, Never>?
    private var didPrepareIndex = false
    private var securityScopedRoots: [URL] = []
    private var indexingProcessedItemCount = 0
    private var indexingCompletedRoots = 0
    private var indexingTotalRoots = 0

    init(
        applicationCatalog: ApplicationCatalog,
        fileIndexStore: FileIndexStore?,
        systemActions: any SearchActionServicing = WorkspaceSearchActionService(),
        initialFileRecords: [FileIndexRecord] = [],
        roots: [URL] = [],
        databaseURL: URL? = nil,
        eventMonitor: (any SearchEventMonitoring)? = nil,
        rootPersistence: (any SearchRootPersisting)? = nil,
        exclusionRules: [String] = SearchDiagnostics.defaultExclusionRules,
        exclusionPersistence: (any SearchExclusionPersisting)? = nil
    ) {
        self.applicationCatalog = applicationCatalog
        self.fileIndexStore = fileIndexStore
        self.systemActions = systemActions
        self.initialFileRecords = initialFileRecords
        self.roots = Self.normalizedRoots(roots)
        self.databaseURL = databaseURL
        self.eventMonitor = eventMonitor
        self.rootPersistence = rootPersistence
        self.exclusionRules = exclusionRules
        self.exclusionPersistence = exclusionPersistence
        diagnostics = SearchDiagnostics(
            roots: Self.normalizedRoots(roots),
            fileCount: initialFileRecords.count,
            databaseSize: Self.databaseSize(at: databaseURL),
            lastUpdatedAt: initialFileRecords.isEmpty ? nil : .now,
            status: initialFileRecords.isEmpty ? .waiting : .ready,
            exclusionRules: exclusionRules
        )
        securityScopedRoots = self.roots.filter { $0.startAccessingSecurityScopedResource() }
        refreshFileAccessState()
    }

    deinit {
        for root in securityScopedRoots { root.stopAccessingSecurityScopedResource() }
    }

    static func makeForCurrentProcess() -> SearchEnvironment {
        if CommandLine.arguments.contains("--search-fixture") { return fixture() }
        return live()
    }

    func prepare() async {
        await prepareApplications()
        await prepareFileIndex()
    }

    func prepareApplications() async {
        let task: Task<Void, Never>
        if let preparationTask {
            task = preparationTask
        } else {
            let applicationCatalog = applicationCatalog
            task = Task { _ = await applicationCatalog.refresh() }
            preparationTask = task
        }
        await task.value
    }

    func prepareFileIndex() async {
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
            beginIndexingActivity(status: .indexing, totalRoots: roots.count, rootName: roots.first?.lastPathComponent)
            refreshDiagnostics(fileCount: count, status: .indexing, updateTimestamp: false)
            startMonitoring()
            // FSEvents starts before reconciliation so changes occurring during the
            // background pass are still delivered. Application search is independent.
            indexingTask = Task { [weak self] in await self?.performReconciliation() }
        } else {
            beginIndexingActivity(status: .indexing, totalRoots: roots.count, rootName: roots.first?.lastPathComponent)
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
        refreshFileAccessState()
        rootPersistence?.saveRoots(roots)
        refreshFileAccessState()
        diagnostics.update(roots: roots)
        beginIndexingActivity(status: .indexing, totalRoots: 1, rootName: normalized.lastPathComponent)
        eventMonitor?.stop()
        do {
            for removedRoot in previousRoots where !updatedPaths.contains(Self.canonicalPath(for: removedRoot)) {
                try await fileIndexStore?.delete(root: Self.canonicalPath(for: removedRoot))
            }
            try await scan(root: normalized, replacingExisting: true, status: .indexing)
            diagnostics.updateIndexingProgress(1, rootName: normalized.lastPathComponent)
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

    func addExclusionRule(_ rawRule: String, rebuildAfterChange: Bool = true) async {
        let rule = rawRule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rule.isEmpty,
              !exclusionRules.contains(where: { $0.localizedCaseInsensitiveCompare(rule) == .orderedSame }) else { return }
        exclusionRules.append(rule)
        exclusionPersistence?.saveRules(exclusionRules)
        diagnostics.update(exclusionRules: exclusionRules)
        if rebuildAfterChange { await rebuildIndex() }
    }

    func removeExclusionRule(_ rule: String) async {
        guard let index = exclusionRules.firstIndex(of: rule) else { return }
        exclusionRules.remove(at: index)
        exclusionPersistence?.saveRules(exclusionRules)
        diagnostics.update(exclusionRules: exclusionRules)
        await rebuildIndex()
    }

    func rebuildIndex() async {
        _ = await cancelIndexing()
        eventMonitor?.stop()
        beginIndexingActivity(status: .rebuilding, totalRoots: roots.count, rootName: roots.first?.lastPathComponent)

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
                let availableRoots = roots.filter {
                    FileManager.default.fileExists(atPath: $0.path)
                }
                for (index, root) in availableRoots.enumerated() {
                    try Task.checkCancellation()
                    updateIndexingProgress(
                        completedRoots: index,
                        totalRoots: availableRoots.count,
                        currentRoot: root
                    )
                    try await scan(root: root, replacingExisting: true, status: .rebuilding)
                    updateIndexingProgress(
                        completedRoots: index + 1,
                        totalRoots: availableRoots.count,
                        currentRoot: root
                    )
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
            let availableRoots = roots.filter {
                FileManager.default.fileExists(atPath: $0.path)
            }
            for (index, root) in availableRoots.enumerated() {
                try Task.checkCancellation()
                updateIndexingProgress(
                    completedRoots: index,
                    totalRoots: availableRoots.count,
                    currentRoot: root
                )
                try await scan(root: root, replacingExisting: false, status: .indexing)
                updateIndexingProgress(
                    completedRoots: index + 1,
                    totalRoots: availableRoots.count,
                    currentRoot: root
                )
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
            let availableRoots = roots.filter {
                FileManager.default.fileExists(atPath: $0.path)
            }
            for (index, root) in availableRoots.enumerated() {
                try Task.checkCancellation()
                updateIndexingProgress(
                    completedRoots: index,
                    totalRoots: availableRoots.count,
                    currentRoot: root
                )
                try await scan(root: root, replacingExisting: true, status: .indexing)
                updateIndexingProgress(
                    completedRoots: index + 1,
                    totalRoots: availableRoots.count,
                    currentRoot: root
                )
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
        beginIndexingActivity(status: .indexing, totalRoots: roots.count, rootName: roots.first?.lastPathComponent)
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
        refreshFileAccessState()
    }

    private func refreshFileAccessState() {
        guard !roots.isEmpty else {
            fileAccessState = .notConfigured
            return
        }
        let accessibleCount = roots.filter { root in
            let path = Self.canonicalPath(for: root)
            return securityScopedRoots.contains(where: { Self.canonicalPath(for: $0) == path })
                || FileManager.default.isReadableFile(atPath: root.path)
        }.count
        if accessibleCount == roots.count {
            fileAccessState = .granted(count: accessibleCount)
        } else if accessibleCount == 0 {
            fileAccessState = .denied(total: roots.count)
        } else {
            fileAccessState = .partiallyGranted(accessible: accessibleCount, total: roots.count)
        }
    }

    private func scan(root: URL, replacingExisting: Bool, status: SearchDiagnostics.Status) async throws {
        guard let fileIndexStore else { throw FileIndexStoreError.openFailed }
        if !diagnostics.isActivelyIndexing {
            beginIndexingActivity(status: status, totalRoots: 1, rootName: root.lastPathComponent)
        }
        if replacingExisting { try await fileIndexStore.delete(root: Self.canonicalPath(for: root)) }
        for try await batch in FileIndexScanner.batches(root: root, exclusionRules: exclusionRules) {
            try Task.checkCancellation()
            try await fileIndexStore.upsert(batch)
            recordIndexingActivity(batch.count, rootName: root.lastPathComponent)
            refreshDiagnostics(fileCount: try await fileIndexStore.recordCount(), status: status)
        }
    }

    private func scan(subtree: URL, belongingTo root: URL, status: SearchDiagnostics.Status) async throws {
        guard let fileIndexStore else { throw FileIndexStoreError.openFailed }
        if !diagnostics.isActivelyIndexing {
            beginIndexingActivity(status: status, totalRoots: 1, rootName: root.lastPathComponent)
        }
        try await fileIndexStore.delete(subtree: Self.canonicalPath(for: subtree))
        for try await batch in FileIndexScanner.batches(
            root: subtree,
            indexRoot: root,
            includeRoot: true,
            exclusionRules: exclusionRules
        ) {
            try Task.checkCancellation()
            try await fileIndexStore.upsert(batch)
            recordIndexingActivity(batch.count, rootName: root.lastPathComponent)
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
            if FileIndexScanner.isExcluded(url, root: root, rules: exclusionRules) {
                try? await store.delete(subtree: Self.canonicalPath(for: url))
                let count = (try? await store.recordCount()) ?? 0
                refreshDiagnostics(fileCount: count, status: .ready)
                return
            }
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

    private func updateIndexingProgress(
        completedRoots: Int,
        totalRoots: Int,
        currentRoot: URL
    ) {
        indexingCompletedRoots = completedRoots
        indexingTotalRoots = totalRoots
        diagnostics.updateIndexingActivity(
            processedItemCount: indexingProcessedItemCount,
            completedRoots: completedRoots,
            totalRoots: totalRoots,
            rootName: currentRoot.lastPathComponent
        )
    }

    private func beginIndexingActivity(
        status: SearchDiagnostics.Status,
        totalRoots: Int,
        rootName: String?
    ) {
        indexingProcessedItemCount = 0
        indexingCompletedRoots = 0
        indexingTotalRoots = max(0, totalRoots)
        diagnostics.update(status: status)
        diagnostics.updateIndexingActivity(
            processedItemCount: 0,
            completedRoots: 0,
            totalRoots: indexingTotalRoots,
            rootName: rootName
        )
    }

    private func recordIndexingActivity(_ itemCount: Int, rootName: String?) {
        indexingProcessedItemCount += itemCount
        diagnostics.updateIndexingActivity(
            processedItemCount: indexingProcessedItemCount,
            completedRoots: indexingCompletedRoots,
            totalRoots: indexingTotalRoots,
            rootName: rootName
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
        let exclusionPersistence = SearchExclusionDefaultsStore()
        let exclusionRules = exclusionPersistence.loadRules(defaults: SearchDiagnostics.defaultExclusionRules)
        let store = try? FileIndexStore.openRecovering(databaseURL: databaseURL).store
        return SearchEnvironment(
            applicationCatalog: catalog,
            fileIndexStore: store,
            roots: roots,
            databaseURL: databaseURL,
            eventMonitor: FileEventMonitor(),
            rootPersistence: rootPersistence,
            exclusionRules: exclusionRules,
            exclusionPersistence: exclusionPersistence
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
