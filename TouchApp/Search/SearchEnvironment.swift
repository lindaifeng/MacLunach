import Foundation
import TouchCore

@MainActor
final class SearchEnvironment {
    let applicationCatalog: ApplicationCatalog
    let fileIndexStore: FileIndexStore?
    let systemActions: any SearchActionServicing
    private let initialFileRecords: [FileIndexRecord]
    private var preparationTask: Task<Void, Never>?

    init(
        applicationCatalog: ApplicationCatalog,
        fileIndexStore: FileIndexStore?,
        systemActions: any SearchActionServicing = WorkspaceSearchActionService(),
        initialFileRecords: [FileIndexRecord] = []
    ) {
        self.applicationCatalog = applicationCatalog
        self.fileIndexStore = fileIndexStore
        self.systemActions = systemActions
        self.initialFileRecords = initialFileRecords
    }

    static func makeForCurrentProcess() -> SearchEnvironment {
        if CommandLine.arguments.contains("--search-fixture") {
            return fixture()
        }
        return live()
    }

    func prepare() async {
        let task: Task<Void, Never>
        if let preparationTask {
            task = preparationTask
        } else {
            let applicationCatalog = applicationCatalog
            let fileIndexStore = fileIndexStore
            let initialFileRecords = initialFileRecords
            task = Task {
                _ = await applicationCatalog.refresh()
                if !initialFileRecords.isEmpty {
                    try? await fileIndexStore?.upsert(initialFileRecords)
                }
            }
            preparationTask = task
        }
        await task.value
    }

    private static func live() -> SearchEnvironment {
        let catalog = ApplicationCatalog(
            discoverer: WorkspaceApplicationDiscoverer(),
            launcher: WorkspaceApplicationLauncher()
        )
        return SearchEnvironment(
            applicationCatalog: catalog,
            fileIndexStore: try? FileIndexStore(databaseURL: fileIndexDatabaseURL())
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
            FileIndexRecord(
                path: "\(root)/Design Brief.txt",
                rootPath: root,
                contentType: "public.plain-text",
                size: 128,
                createdAt: now,
                modifiedAt: now,
                isDirectory: false
            ),
            FileIndexRecord(
                path: "\(root)/Design Notes.md",
                rootPath: root,
                contentType: "net.daringfireball.markdown",
                size: 256,
                createdAt: now,
                modifiedAt: now,
                isDirectory: false
            )
        ]
        return SearchEnvironment(
            applicationCatalog: catalog,
            fileIndexStore: try? .temporary(),
            systemActions: FixtureSearchActionService(logURL: actionLogURL, failingAction: failingAction),
            initialFileRecords: records
        )
    }

    private static func argumentValue(for prefix: String) -> String? {
        CommandLine.arguments
            .first(where: { $0.hasPrefix(prefix) })
            .flatMap { argument in
                guard let value = argument.split(separator: "=", maxSplits: 1).last else { return nil }
                return String(value)
            }
    }

    private static func fileIndexDatabaseURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("Touch/Search", isDirectory: true)
            .appendingPathComponent("files.sqlite")
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
