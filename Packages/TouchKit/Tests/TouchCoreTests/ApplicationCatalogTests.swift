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
