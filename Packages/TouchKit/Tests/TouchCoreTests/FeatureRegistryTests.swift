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

@Test func registryRejectsEveryPluginWithADuplicateID() async {
    let first = Plugin(
        manifest: .init(
            id: "me.touch.duplicate",
            name: "First",
            summary: "First",
            symbolName: "1.circle",
            defaultOrder: 0,
            defaultShortcut: .init(modifiers: [], key: "1")
        ),
        state: .available
    )
    let second = Plugin(
        manifest: .init(
            id: "me.touch.duplicate",
            name: "Second",
            summary: "Second",
            symbolName: "2.circle",
            defaultOrder: 1,
            defaultShortcut: .init(modifiers: [], key: "2")
        ),
        state: .available
    )

    let registry = FeatureRegistry(plugins: [first, second])

    #expect(await registry.entries.isEmpty)
    #expect(
        await registry.registrationErrors
            == [.duplicateID("me.touch.duplicate")]
    )
}

@Test func registryRejectsIncompatibleFeatureAPIVersion() async {
    let plugin = Plugin(
        manifest: .init(
            id: "me.touch.future",
            name: "Future",
            summary: "Future API",
            symbolName: "sparkles",
            defaultOrder: 0,
            defaultShortcut: .init(modifiers: [], key: "f"),
            featureAPIVersion: .init(major: 2)
        ),
        state: .available
    )
    let registry = FeatureRegistry(
        plugins: [plugin],
        hostCompatibility: .init(
            hostVersion: .init(major: 1, minor: 0, patch: 0),
            supportedFeatureAPIVersions: [.init(major: 1)],
            supportedCapabilities: Set(FeatureCapability.allCases)
        )
    )

    #expect(await registry.entries.isEmpty)
    #expect(
        await registry.registrationErrors
            == [
                .incompatibleAPIVersion(
                    pluginID: "me.touch.future",
                    requested: .init(major: 2)
                )
            ]
    )
}

@Test func registryRejectsUnsupportedRequiredCapabilities() async {
    let plugin = Plugin(
        manifest: .init(
            id: "me.touch.networked",
            name: "Networked",
            summary: "Requires network access",
            symbolName: "network",
            defaultOrder: 0,
            defaultShortcut: .init(modifiers: [], key: "n"),
            capabilities: .init(required: [.network])
        ),
        state: .available
    )
    let registry = FeatureRegistry(
        plugins: [plugin],
        hostCompatibility: .init(
            hostVersion: .init(major: 1, minor: 0, patch: 0),
            supportedFeatureAPIVersions: [.init(major: 1)],
            supportedCapabilities: [.fileSystemRead]
        )
    )

    #expect(await registry.entries.isEmpty)
    #expect(
        await registry.registrationErrors
            == [
                .unsupportedRequiredCapabilities(
                    pluginID: "me.touch.networked",
                    requested: [.network]
                )
            ]
    )
}

@Test func registryRejectsPluginThatRequiresANewerHost() async {
    let plugin = Plugin(
        manifest: .init(
            id: "me.touch.new-host",
            name: "New Host",
            summary: "Requires a newer host",
            symbolName: "arrow.up.circle",
            defaultOrder: 0,
            defaultShortcut: .init(modifiers: [], key: "u"),
            minimumHostVersion: .init(major: 2, minor: 0, patch: 0),
            maximumTestedHostVersion: .init(major: 2, minor: 9, patch: 0)
        ),
        state: .available
    )
    let registry = FeatureRegistry(
        plugins: [plugin],
        hostCompatibility: .init(
            hostVersion: .init(major: 1, minor: 5, patch: 0),
            supportedFeatureAPIVersions: [.init(major: 1)],
            supportedCapabilities: Set(FeatureCapability.allCases)
        )
    )

    #expect(await registry.entries.isEmpty)
    #expect(
        await registry.registrationErrors
            == [
                .minimumHostVersionNotMet(
                    pluginID: "me.touch.new-host",
                    minimum: .init(major: 2, minor: 0, patch: 0),
                    current: .init(major: 1, minor: 5, patch: 0)
                )
            ]
    )
}

@Test func registryRejectsIncompleteManifestBeforeLoading() async {
    let plugin = Plugin(
        manifest: .init(
            id: "invalid-id",
            name: "",
            summary: "",
            symbolName: "",
            defaultOrder: -1,
            defaultShortcut: .init(modifiers: [], key: "i"),
            pluginVersion: .init(major: -1, minor: 0, patch: 0),
            featureAPIVersion: .init(major: 0),
            minimumHostVersion: .init(major: 2, minor: 0, patch: 0),
            maximumTestedHostVersion: .init(major: 1, minor: 0, patch: 0),
            configurationSchemaVersion: 0,
            capabilities: .init(required: [.network], optional: [.network])
        ),
        state: .available
    )
    let registry = FeatureRegistry(plugins: [plugin])

    #expect(await registry.entries.isEmpty)
    #expect(
        await registry.registrationErrors
            == [
                .invalidManifest(
                    pluginID: "invalid-id",
                    issues: [
                        .invalidID,
                        .missingName,
                        .missingSummary,
                        .missingSymbolName,
                        .invalidDefaultOrder,
                        .invalidPluginVersion,
                        .invalidFeatureAPIVersion,
                        .invalidHostVersionRange,
                        .invalidConfigurationSchemaVersion,
                        .overlappingCapabilities
                    ]
                )
            ]
    )
}

@Test func registrySortsByStoredOrderAndIsolatesFailure() async throws {
    let first = Plugin(
        manifest: .init(
            id: "me.touch.test-a",
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
            id: "me.touch.test-b",
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
    #expect(entries.map(\.manifest.id) == ["me.touch.test-a", "me.touch.test-b"])
    #expect(await registry.state(for: "me.touch.test-a") == .failed(message: "broken"))
    #expect(await registry.state(for: "me.touch.test-b") == .available)
}

@Test func registryRejectsShortcutConflict() async throws {
    let shortcut = KeyboardShortcut(modifiers: [.command], key: "1")
    let a = Plugin(
        manifest: .init(id: "me.touch.test-a", name: "A", summary: "A", symbolName: "a.circle", defaultOrder: 0, defaultShortcut: shortcut),
        state: .available
    )
    let b = Plugin(
        manifest: .init(
            id: "me.touch.test-b",
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
        try await registry.setShortcut(shortcut, for: "me.touch.test-b")
        Issue.record("expected shortcut conflict")
    } catch let error as FeatureRegistryError {
        #expect(error == .shortcutConflict(existingFeatureID: "me.touch.test-a"))
    }
}

@Test func registrySwapsTwoFeatureShortcutsAtomically() async throws {
    let a = Plugin(
        manifest: .init(
            id: "me.touch.test-a",
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
            id: "me.touch.test-b",
            name: "B",
            summary: "B",
            symbolName: "b.circle",
            defaultOrder: 1,
            defaultShortcut: .init(modifiers: [.command], key: "2")
        ),
        state: .available
    )
    let registry = FeatureRegistry(plugins: [a, b])

    try await registry.swapShortcuts(between: a.manifest.id, and: b.manifest.id)

    let entries = await registry.entries
    #expect(entries.first(where: { $0.manifest.id == a.manifest.id })?.shortcut.key == "2")
    #expect(entries.first(where: { $0.manifest.id == b.manifest.id })?.shortcut.key == "1")
}

@Test func registryAppliesAndExportsFeaturePreferences() async throws {
    let a = Plugin(
        manifest: .init(
            id: "me.touch.test-a",
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
            id: "me.touch.test-b",
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
        order: ["me.touch.test-b", "me.touch.test-a"],
        hidden: ["me.touch.test-a"],
        shortcuts: ["me.touch.test-b": customShortcut]
    )

    let registry = FeatureRegistry(plugins: [a, b], preferences: preferences)

    let entries = await registry.entries
    #expect(entries.map(\.manifest.id) == ["me.touch.test-b", "me.touch.test-a"])
    #expect(entries.first(where: { $0.manifest.id == "me.touch.test-a" })?.isVisible == false)
    #expect(entries.first(where: { $0.manifest.id == "me.touch.test-b" })?.shortcut == customShortcut)
    #expect(await registry.preferences() == preferences)
}

@Test func registryOwnsExecutionStateAndRestoresAvailabilityAfterSuccess() async throws {
    let plugin = PerformingPlugin(
        manifest: .init(id: "me.touch.action", name: "Action", summary: "Action", symbolName: "play", defaultOrder: 0, defaultShortcut: .init(modifiers: [], key: "a")),
        state: .available,
        behavior: .success
    )
    let registry = FeatureRegistry(plugins: [plugin])

    #expect(try await registry.perform(id: "me.touch.action") == .completed)
    #expect(await registry.state(for: "me.touch.action") == .available)
}

@Test func registryTimesOutOnlyTheFailingPluginAndCanRetryIt() async throws {
    let slow = PerformingPlugin(
        manifest: .init(id: "me.touch.slow", name: "Slow", summary: "Slow", symbolName: "clock", defaultOrder: 0, defaultShortcut: .init(modifiers: [], key: "s")),
        state: .available,
        behavior: .delayed(.seconds(1))
    )
    let healthy = PerformingPlugin(
        manifest: .init(id: "me.touch.healthy", name: "Healthy", summary: "Healthy", symbolName: "checkmark", defaultOrder: 1, defaultShortcut: .init(modifiers: [], key: "h")),
        state: .available,
        behavior: .success
    )
    let registry = FeatureRegistry(plugins: [slow, healthy])

    await #expect(throws: FeatureRegistryError.executionTimedOut) {
        try await registry.perform(id: "me.touch.slow", timeout: .milliseconds(10))
    }
    #expect(await registry.state(for: "me.touch.slow") == .failed(message: "功能响应超时，请重试。"))
    #expect(try await registry.perform(id: "me.touch.healthy") == .completed)
    try await registry.retry(id: "me.touch.slow")
    #expect(await registry.state(for: "me.touch.slow") == .available)
}

@Test func registryDoesNotExecuteRestrictedPlugin() async throws {
    let plugin = PerformingPlugin(
        manifest: .init(id: "me.touch.restricted", name: "Restricted", summary: "Restricted", symbolName: "lock", defaultOrder: 0, defaultShortcut: .init(modifiers: [], key: "r")),
        state: .restricted(message: "permission"),
        behavior: .success
    )
    let registry = FeatureRegistry(plugins: [plugin])

    await #expect(throws: FeatureRegistryError.unavailable(state: .restricted(message: "permission"))) {
        try await registry.perform(id: "me.touch.restricted")
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
    let plugin = LifecyclePlugin(id: "me.touch.test-screenshot")
    let registry = FeatureRegistry(plugins: [plugin])

    #expect(try await registry.perform(id: "me.touch.test-screenshot") == .completed)
    await registry.load()

    #expect(await plugin.enableCount == 1)
    #expect(await registry.state(for: "me.touch.test-screenshot") == .available)
}

@Test func registryKeepsVisibilityAndEnabledLifecycleIndependent() async throws {
    let plugin = LifecyclePlugin(id: "me.touch.test-screenshot")
    let registry = FeatureRegistry(
        plugins: [plugin],
        preferences: .init(hidden: ["me.touch.test-screenshot"])
    )

    await registry.load()
    try await registry.setVisibility(true, for: "me.touch.test-screenshot")
    try await registry.setVisibility(false, for: "me.touch.test-screenshot")

    #expect(await plugin.enableCount == 1)
    #expect(await plugin.disableCount == 0)
    #expect(await registry.state(for: "me.touch.test-screenshot") == .available)
    #expect(await registry.preferences().hidden == ["me.touch.test-screenshot"])
    #expect(await registry.preferences().disabled.isEmpty)
}

@Test func registryDisablesAndReenablesOnlyTheRequestedPlugin() async throws {
    let screenshot = LifecyclePlugin(id: "me.touch.test-screenshot")
    let finder = LifecyclePlugin(id: "me.touch.test-finder")
    let registry = FeatureRegistry(
        plugins: [screenshot, finder],
        preferences: .init(disabled: ["me.touch.test-screenshot"])
    )

    await registry.load()
    #expect(await registry.state(for: "me.touch.test-screenshot") == .disabled)
    #expect(await screenshot.enableCount == 0)
    #expect(await finder.enableCount == 1)

    await #expect(throws: FeatureRegistryError.unavailable(state: .disabled)) {
        try await registry.perform(id: "me.touch.test-screenshot")
    }
    await #expect(throws: FeatureRegistryError.unavailable(state: .disabled)) {
        try await registry.retry(id: "me.touch.test-screenshot")
    }

    try await registry.setEnabled(true, for: "me.touch.test-screenshot")
    #expect(await registry.state(for: "me.touch.test-screenshot") == .available)
    #expect(await screenshot.enableCount == 1)
    #expect(await finder.enableCount == 1)

    try await registry.setEnabled(false, for: "me.touch.test-screenshot")
    #expect(await registry.state(for: "me.touch.test-screenshot") == .disabled)
    #expect(await screenshot.disableCount == 1)
    #expect(await registry.state(for: "me.touch.test-finder") == .available)
    #expect(await finder.disableCount == 0)
}

@Test func registryRefreshesRestrictedStateAfterRequiresSetup() async throws {
    let screenshot = LifecyclePlugin(id: "me.touch.test-screenshot", behavior: .requiresSetup)
    let finder = LifecyclePlugin(id: "me.touch.test-finder")
    let registry = FeatureRegistry(plugins: [screenshot, finder])
    await registry.load()

    #expect(
        try await registry.perform(id: "me.touch.test-screenshot")
            == .requiresSetup(message: "需要设置")
    )
    #expect(await registry.state(for: "me.touch.test-screenshot") == .restricted(message: "需要设置"))
    #expect(await registry.state(for: "me.touch.test-finder") == .available)
}

@Test func disablingDuringExecutionCannotOverwriteDisabledState() async throws {
    let screenshot = LifecyclePlugin(id: "me.touch.test-screenshot", behavior: .waitsForDisable)
    let registry = FeatureRegistry(plugins: [screenshot])
    await registry.load()

    let execution = Task { try await registry.perform(id: "me.touch.test-screenshot") }
    await screenshot.waitUntilPerforming()
    try await registry.setEnabled(false, for: "me.touch.test-screenshot")
    _ = try? await execution.value

    #expect(await registry.state(for: "me.touch.test-screenshot") == .disabled)
    #expect(await screenshot.disableCount == 1)
}
