import TouchFeatureAPI

public enum FeatureRegistryError: Error, Equatable {
    case unknownFeature
    case shortcutConflict(existingFeatureID: String)
}

public struct FeatureEntry: Sendable {
    public let manifest: FeatureManifest
    public var state: FeatureState
    public var shortcut: KeyboardShortcut
    public var isVisible: Bool

    public init(manifest: FeatureManifest, state: FeatureState, shortcut: KeyboardShortcut, isVisible: Bool) {
        self.manifest = manifest
        self.state = state
        self.shortcut = shortcut
        self.isVisible = isVisible
    }
}

public actor FeatureRegistry {
    private let plugins: [String: any FeaturePlugin]
    public private(set) var entries: [FeatureEntry]

    public init(plugins: [any FeaturePlugin], preferences: FeaturePreferences = .init()) {
        self.plugins = Dictionary(uniqueKeysWithValues: plugins.map { ($0.manifest.id, $0) })
        let storedOrder = Dictionary(uniqueKeysWithValues: preferences.order.enumerated().map { ($1, $0) })
        self.entries = plugins
            .sorted {
                let left = storedOrder[$0.manifest.id] ?? (preferences.order.count + $0.manifest.defaultOrder)
                let right = storedOrder[$1.manifest.id] ?? (preferences.order.count + $1.manifest.defaultOrder)
                return left < right
            }
            .map {
                FeatureEntry(
                    manifest: $0.manifest,
                    state: .unloaded,
                    shortcut: preferences.shortcuts[$0.manifest.id] ?? $0.manifest.defaultShortcut,
                    isVisible: !preferences.hidden.contains($0.manifest.id)
                )
            }
    }

    public func load() async {
        for index in entries.indices {
            guard let plugin = plugins[entries[index].manifest.id] else { continue }
            entries[index].state = await plugin.initialState()
        }
    }

    public func state(for id: String) -> FeatureState? {
        entries.first { $0.manifest.id == id }?.state
    }

    public func setShortcut(_ shortcut: KeyboardShortcut, for id: String) throws {
        guard let index = entries.firstIndex(where: { $0.manifest.id == id }) else {
            throw FeatureRegistryError.unknownFeature
        }

        if let conflict = entries.first(where: { $0.manifest.id != id && $0.shortcut == shortcut }) {
            throw FeatureRegistryError.shortcutConflict(existingFeatureID: conflict.manifest.id)
        }

        entries[index].shortcut = shortcut
    }

    public func move(from source: Int, to destination: Int) {
        guard entries.indices.contains(source), destination >= 0, destination <= entries.count else { return }
        let entry = entries.remove(at: source)
        entries.insert(entry, at: min(destination, entries.count))
    }

    public func setVisibility(_ isVisible: Bool, for id: String) throws {
        guard let index = entries.firstIndex(where: { $0.manifest.id == id }) else {
            throw FeatureRegistryError.unknownFeature
        }
        entries[index].isVisible = isVisible
    }

    public func restoreDefaults(for id: String) throws {
        guard let index = entries.firstIndex(where: { $0.manifest.id == id }) else {
            throw FeatureRegistryError.unknownFeature
        }
        entries[index].shortcut = entries[index].manifest.defaultShortcut
        entries[index].isVisible = true
        entries.sort { $0.manifest.defaultOrder < $1.manifest.defaultOrder }
    }

    public func preferences() -> FeaturePreferences {
        FeaturePreferences(
            order: entries.map(\.manifest.id),
            hidden: Set(entries.filter { !$0.isVisible }.map(\.manifest.id)),
            shortcuts: Dictionary(uniqueKeysWithValues: entries.compactMap { entry in
                guard entry.shortcut != entry.manifest.defaultShortcut else { return nil }
                return (entry.manifest.id, entry.shortcut)
            })
        )
    }
}
