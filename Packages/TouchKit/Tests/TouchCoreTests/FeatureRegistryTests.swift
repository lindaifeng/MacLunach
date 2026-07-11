import Testing
import TouchFeatureAPI
@testable import TouchCore

private struct Plugin: FeaturePlugin {
    let manifest: FeatureManifest
    let state: FeatureState

    func initialState() async -> FeatureState { state }
    func perform() async throws -> FeatureActionResult { .completed }
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
