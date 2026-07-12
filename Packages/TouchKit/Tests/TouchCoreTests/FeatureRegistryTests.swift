import Testing
import TouchFeatureAPI
@testable import TouchCore

private struct Plugin: FeaturePlugin {
    let manifest: FeatureManifest
    let state: FeatureState

    func initialState() async -> FeatureState { state }
    func perform() async throws -> FeatureActionResult { .completed }
}

private struct PerformingPlugin: FeaturePlugin {
    enum Behavior: Sendable {
        case success
        case failure
        case delayed(Duration)
    }

    let manifest: FeatureManifest
    let state: FeatureState
    let behavior: Behavior

    func initialState() async -> FeatureState { state }

    func perform() async throws -> FeatureActionResult {
        switch behavior {
        case .success:
            return .completed
        case .failure:
            throw FeatureRegistryError.executionFailed
        case let .delayed(duration):
            try await Task.sleep(for: duration)
            return .completed
        }
    }
}

@Test func registrySortsByStoredOrderAndIsolatesFailure() async throws {
    let first = Plugin(
        manifest: .init(
            id: "a",
            name: "A",
            summary: "A",
            symbolName: "a.circle",
            defaultOrder: 0,
            defaultShortcut: .init(modifiers: [.command], key: "1")
        ),
        state: .failed(message: "broken")
    )
    let second = Plugin(
        manifest: .init(
            id: "b",
            name: "B",
            summary: "B",
            symbolName: "b.circle",
            defaultOrder: 1,
            defaultShortcut: .init(modifiers: [.command], key: "2")
        ),
        state: .available
    )

    let registry = FeatureRegistry(plugins: [second, first])
    await registry.load()

    let entries = await registry.entries
    #expect(entries.map(\.manifest.id) == ["a", "b"])
    #expect(await registry.state(for: "a") == .failed(message: "broken"))
    #expect(await registry.state(for: "b") == .available)
}

@Test func registryRejectsShortcutConflict() async throws {
    let shortcut = KeyboardShortcut(modifiers: [.command], key: "1")
    let a = Plugin(
        manifest: .init(id: "a", name: "A", summary: "A", symbolName: "a.circle", defaultOrder: 0, defaultShortcut: shortcut),
        state: .available
    )
    let b = Plugin(
        manifest: .init(
            id: "b",
            name: "B",
            summary: "B",
            symbolName: "b.circle",
            defaultOrder: 1,
            defaultShortcut: .init(modifiers: [.command], key: "2")
        ),
        state: .available
    )

    let registry = FeatureRegistry(plugins: [a, b])

    do {
        try await registry.setShortcut(shortcut, for: "b")
        Issue.record("expected shortcut conflict")
    } catch let error as FeatureRegistryError {
        #expect(error == .shortcutConflict(existingFeatureID: "a"))
    }
}

@Test func registryAppliesAndExportsFeaturePreferences() async throws {
    let a = Plugin(
        manifest: .init(
            id: "a",
            name: "A",
            summary: "A",
            symbolName: "a.circle",
            defaultOrder: 0,
            defaultShortcut: .init(modifiers: [.command], key: "1")
        ),
        state: .available
    )
    let b = Plugin(
        manifest: .init(
            id: "b",
            name: "B",
            summary: "B",
            symbolName: "b.circle",
            defaultOrder: 1,
            defaultShortcut: .init(modifiers: [.command], key: "2")
        ),
        state: .available
    )
    let customShortcut = KeyboardShortcut(modifiers: [.control, .option], key: "s")
    let preferences = FeaturePreferences(
        order: ["b", "a"],
        hidden: ["a"],
        shortcuts: ["b": customShortcut]
    )

    let registry = FeatureRegistry(plugins: [a, b], preferences: preferences)

    let entries = await registry.entries
    #expect(entries.map(\.manifest.id) == ["b", "a"])
    #expect(entries.first(where: { $0.manifest.id == "a" })?.isVisible == false)
    #expect(entries.first(where: { $0.manifest.id == "b" })?.shortcut == customShortcut)
    #expect(await registry.preferences() == preferences)
}

@Test func registryOwnsExecutionStateAndRestoresAvailabilityAfterSuccess() async throws {
    let plugin = PerformingPlugin(
        manifest: .init(id: "action", name: "Action", summary: "Action", symbolName: "play", defaultOrder: 0, defaultShortcut: .init(modifiers: [], key: "a")),
        state: .available,
        behavior: .success
    )
    let registry = FeatureRegistry(plugins: [plugin])

    #expect(try await registry.perform(id: "action") == .completed)
    #expect(await registry.state(for: "action") == .available)
}

@Test func registryTimesOutOnlyTheFailingPluginAndCanRetryIt() async throws {
    let slow = PerformingPlugin(
        manifest: .init(id: "slow", name: "Slow", summary: "Slow", symbolName: "clock", defaultOrder: 0, defaultShortcut: .init(modifiers: [], key: "s")),
        state: .available,
        behavior: .delayed(.seconds(1))
    )
    let healthy = PerformingPlugin(
        manifest: .init(id: "healthy", name: "Healthy", summary: "Healthy", symbolName: "checkmark", defaultOrder: 1, defaultShortcut: .init(modifiers: [], key: "h")),
        state: .available,
        behavior: .success
    )
    let registry = FeatureRegistry(plugins: [slow, healthy])

    await #expect(throws: FeatureRegistryError.executionTimedOut) {
        try await registry.perform(id: "slow", timeout: .milliseconds(10))
    }
    #expect(await registry.state(for: "slow") == .failed(message: "功能响应超时，请重试。"))
    #expect(try await registry.perform(id: "healthy") == .completed)
    try await registry.retry(id: "slow")
    #expect(await registry.state(for: "slow") == .available)
}

@Test func registryDoesNotExecuteRestrictedPlugin() async throws {
    let plugin = PerformingPlugin(
        manifest: .init(id: "restricted", name: "Restricted", summary: "Restricted", symbolName: "lock", defaultOrder: 0, defaultShortcut: .init(modifiers: [], key: "r")),
        state: .restricted(message: "permission"),
        behavior: .success
    )
    let registry = FeatureRegistry(plugins: [plugin])

    await #expect(throws: FeatureRegistryError.unavailable(state: .restricted(message: "permission"))) {
        try await registry.perform(id: "restricted")
    }
}
