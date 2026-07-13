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

private actor LifecyclePlugin: FeaturePlugin, FeatureLifecycleHandling {
    enum Behavior: Sendable {
        case completed
        case requiresSetup
        case waitsForDisable
    }

    nonisolated let manifest: FeatureManifest
    private var currentState: FeatureState
    private let behavior: Behavior
    private var continuation: CheckedContinuation<Void, any Error>?
    private(set) var enableCount = 0
    private(set) var disableCount = 0
    private(set) var performCount = 0

    init(id: String, state: FeatureState = .available, behavior: Behavior = .completed) {
        manifest = .init(
            id: id,
            name: id,
            summary: id,
            symbolName: "puzzlepiece",
            defaultOrder: 0,
            defaultShortcut: .init(modifiers: [], key: String(id.prefix(1)))
        )
        currentState = state
        self.behavior = behavior
    }

    func initialState() async -> FeatureState { currentState }

    func perform() async throws -> FeatureActionResult {
        performCount += 1
        switch behavior {
        case .completed:
            return .completed
        case .requiresSetup:
            currentState = .restricted(message: "需要设置")
            return .requiresSetup(message: "需要设置")
        case .waitsForDisable:
            try await withCheckedThrowingContinuation { continuation = $0 }
            return .completed
        }
    }

    func featureDidEnable() async {
        enableCount += 1
    }

    func featureDidDisable() async {
        disableCount += 1
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }

    func waitUntilPerforming() async {
        while continuation == nil {
            await Task.yield()
        }
    }
}

@Test func registryActivatesLifecycleWhenPerformedBeforeInitialLoad() async throws {
    let plugin = LifecyclePlugin(id: "screenshot")
    let registry = FeatureRegistry(plugins: [plugin])

    #expect(try await registry.perform(id: "screenshot") == .completed)
    await registry.load()

    #expect(await plugin.enableCount == 1)
    #expect(await registry.state(for: "screenshot") == .available)
}

@Test func registryKeepsVisibilityAndEnabledLifecycleIndependent() async throws {
    let plugin = LifecyclePlugin(id: "screenshot")
    let registry = FeatureRegistry(
        plugins: [plugin],
        preferences: .init(hidden: ["screenshot"])
    )

    await registry.load()
    try await registry.setVisibility(true, for: "screenshot")
    try await registry.setVisibility(false, for: "screenshot")

    #expect(await plugin.enableCount == 1)
    #expect(await plugin.disableCount == 0)
    #expect(await registry.state(for: "screenshot") == .available)
    #expect(await registry.preferences().hidden == ["screenshot"])
    #expect(await registry.preferences().disabled.isEmpty)
}

@Test func registryDisablesAndReenablesOnlyTheRequestedPlugin() async throws {
    let screenshot = LifecyclePlugin(id: "screenshot")
    let finder = LifecyclePlugin(id: "finder")
    let registry = FeatureRegistry(
        plugins: [screenshot, finder],
        preferences: .init(disabled: ["screenshot"])
    )

    await registry.load()
    #expect(await registry.state(for: "screenshot") == .disabled)
    #expect(await screenshot.enableCount == 0)
    #expect(await finder.enableCount == 1)

    await #expect(throws: FeatureRegistryError.unavailable(state: .disabled)) {
        try await registry.perform(id: "screenshot")
    }
    await #expect(throws: FeatureRegistryError.unavailable(state: .disabled)) {
        try await registry.retry(id: "screenshot")
    }

    try await registry.setEnabled(true, for: "screenshot")
    #expect(await registry.state(for: "screenshot") == .available)
    #expect(await screenshot.enableCount == 1)
    #expect(await finder.enableCount == 1)

    try await registry.setEnabled(false, for: "screenshot")
    #expect(await registry.state(for: "screenshot") == .disabled)
    #expect(await screenshot.disableCount == 1)
    #expect(await registry.state(for: "finder") == .available)
    #expect(await finder.disableCount == 0)
}

@Test func registryRefreshesRestrictedStateAfterRequiresSetup() async throws {
    let screenshot = LifecyclePlugin(id: "screenshot", behavior: .requiresSetup)
    let finder = LifecyclePlugin(id: "finder")
    let registry = FeatureRegistry(plugins: [screenshot, finder])
    await registry.load()

    #expect(
        try await registry.perform(id: "screenshot")
            == .requiresSetup(message: "需要设置")
    )
    #expect(await registry.state(for: "screenshot") == .restricted(message: "需要设置"))
    #expect(await registry.state(for: "finder") == .available)
}

@Test func disablingDuringExecutionCannotOverwriteDisabledState() async throws {
    let screenshot = LifecyclePlugin(id: "screenshot", behavior: .waitsForDisable)
    let registry = FeatureRegistry(plugins: [screenshot])
    await registry.load()

    let execution = Task { try await registry.perform(id: "screenshot") }
    await screenshot.waitUntilPerforming()
    try await registry.setEnabled(false, for: "screenshot")
    _ = try? await execution.value

    #expect(await registry.state(for: "screenshot") == .disabled)
    #expect(await screenshot.disableCount == 1)
}
