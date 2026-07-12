import Foundation
import Testing
@testable import TouchCore

private struct StubApplicationDiscoverer: ApplicationDiscovering {
    let applications: [ApplicationRecord]
    func discoverApplications() async -> [ApplicationRecord] { applications }
}

@Test func catalogDeduplicatesBundleIdentifiersAndPrefersUserApplication() async {
    let system = ApplicationRecord(bundleIdentifier: "com.example.editor", name: "Editor", path: "/System/Applications/Editor.app", isUserInstalled: false)
    let user = ApplicationRecord(bundleIdentifier: "com.example.editor", name: "Editor", path: "/Applications/Editor.app", isUserInstalled: true)
    let catalog = ApplicationCatalog(discoverer: StubApplicationDiscoverer(applications: [system, user]))

    let results = await catalog.refresh()

    #expect(results.map(\.path) == ["/Applications/Editor.app"])
}

@Test func recordedLaunchRaisesUsageScore() async {
    let application = ApplicationRecord(bundleIdentifier: "com.example.editor", name: "Editor", path: "/Applications/Editor.app", isUserInstalled: true)
    let catalog = ApplicationCatalog(discoverer: StubApplicationDiscoverer(applications: [application]))
    _ = await catalog.refresh()

    let before = await catalog.search(query: "editor").first?.baseScore ?? 0
    await catalog.recordLaunch(bundleIdentifier: "com.example.editor", at: Date())
    let after = await catalog.search(query: "editor").first?.baseScore ?? 0

    #expect(after > before)
}

@Test func catalogCarriesApplicationIconCacheKeyIntoSearchResults() async {
    let application = ApplicationRecord(
        bundleIdentifier: "com.example.editor",
        name: "Editor",
        path: "/Applications/Editor.app",
        iconCacheKey: "com.example.editor|resolved-v2",
        isUserInstalled: true
    )
    let catalog = ApplicationCatalog(discoverer: StubApplicationDiscoverer(applications: [application]))
    _ = await catalog.refresh()

    let result = await catalog.search(query: "editor").first

    #expect(result?.iconCacheKey == application.iconCacheKey)
}

private actor StubApplicationLauncher: ApplicationLaunching {
    enum Failure: Error { case rejected }

    private let shouldFail: Bool
    private(set) var openedPaths: [String] = []

    init(shouldFail: Bool = false) {
        self.shouldFail = shouldFail
    }

    func openApplication(at url: URL) async throws {
        if shouldFail { throw Failure.rejected }
        openedPaths.append(url.path)
    }
}

@Test func launchRecordsUsageOnlyAfterWorkspaceSucceeds() async throws {
    let application = ApplicationRecord(
        bundleIdentifier: "com.example.editor",
        name: "Editor",
        path: "/Applications/Editor.app",
        isUserInstalled: true
    )
    let discoverer = StubApplicationDiscoverer(applications: [application])
    let successfulLauncher = StubApplicationLauncher()
    let successfulCatalog = ApplicationCatalog(discoverer: discoverer, launcher: successfulLauncher)
    _ = await successfulCatalog.refresh()

    let beforeSuccess = await successfulCatalog.search(query: "editor").first?.baseScore ?? 0
    try await successfulCatalog.launch(bundleIdentifier: application.bundleIdentifier)
    let afterSuccess = await successfulCatalog.search(query: "editor").first?.baseScore ?? 0
    #expect(afterSuccess > beforeSuccess)
    #expect(await successfulLauncher.openedPaths == [application.path])

    let failingLauncher = StubApplicationLauncher(shouldFail: true)
    let failingCatalog = ApplicationCatalog(discoverer: discoverer, launcher: failingLauncher)
    _ = await failingCatalog.refresh()
    let beforeFailure = await failingCatalog.search(query: "editor").first?.baseScore ?? 0

    await #expect(throws: SearchActionError.cannotOpen(path: application.path)) {
        try await failingCatalog.launch(bundleIdentifier: application.bundleIdentifier)
    }
    let afterFailure = await failingCatalog.search(query: "editor").first?.baseScore ?? 0
    #expect(afterFailure == beforeFailure)
}

@Test func fileSystemDiscovererReadsApplicationBundlesFromConfiguredRoots() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("TouchApplicationDiscoveryTests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let appURL = root.appendingPathComponent("示例.app", isDirectory: true)
    let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
    try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)
    let info: [String: Any] = [
        "CFBundleIdentifier": "me.touch.fixture",
        "CFBundleDisplayName": "示例应用"
    ]
    let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    try data.write(to: contentsURL.appendingPathComponent("Info.plist"))
    defer { try? FileManager.default.removeItem(at: root) }

    let discoverer = FileSystemApplicationDiscoverer(
        roots: [ApplicationSearchRoot(url: root, isUserInstalled: true)]
    )
    let applications = await discoverer.discoverApplications()

    #expect(applications.count == 1)
    #expect(applications.first?.bundleIdentifier == "me.touch.fixture")
    #expect(applications.first?.name == "示例应用")
    #expect(applications.first?.localizedName == "示例应用")
    #expect(applications.first?.iconCacheKey.contains("me.touch.fixture") == true)
    #expect(
        applications.first.map { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath() }
            == appURL.resolvingSymlinksInPath()
    )
    #expect(applications.first?.isUserInstalled == true)
    #expect(applications.first?.pinyin.contains("shi") == true)
    #expect(applications.first?.initials.hasPrefix("s") == true)
}

@Test func fileSystemDiscovererAcceptsKnownApplicationBundleURLsAsRoots() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("TouchKnownApplicationTests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let appURL = root.appendingPathComponent("Known.app", isDirectory: true)
    let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
    try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)
    let info: [String: Any] = [
        "CFBundleIdentifier": "me.touch.known",
        "CFBundleName": "Known"
    ]
    let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    try data.write(to: contentsURL.appendingPathComponent("Info.plist"))
    defer { try? FileManager.default.removeItem(at: root) }

    let discoverer = FileSystemApplicationDiscoverer(
        roots: [ApplicationSearchRoot(url: appURL, isUserInstalled: true)]
    )

    let applications = await discoverer.discoverApplications()

    #expect(applications.map(\.bundleIdentifier) == ["me.touch.known"])
}
