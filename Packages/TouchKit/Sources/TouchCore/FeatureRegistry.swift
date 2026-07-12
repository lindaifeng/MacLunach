import TouchFeatureAPI

public enum FeatureRegistryError: Error, Equatable {
    case unknownFeature
    case shortcutConflict(existingFeatureID: String)
    case unavailable(state: FeatureState)
    case executionTimedOut
    case executionFailed
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
            guard entries[index].state == .unloaded,
                  let plugin = plugins[entries[index].manifest.id] else { continue }
            let initialState = await plugin.initialState()
            if entries[index].state == .unloaded {
                entries[index].state = initialState
            }
        }
    }

    public func state(for id: String) -> FeatureState? {
        entries.first { $0.manifest.id == id }?.state
    }

    public func perform(id: String, timeout: Duration = .seconds(5)) async throws -> FeatureActionResult {
        guard let index = entries.firstIndex(where: { $0.manifest.id == id }),
              let plugin = plugins[id] else { throw FeatureRegistryError.unknownFeature }

        if entries[index].state == .unloaded {
            entries[index].state = .running
            let initialState = await plugin.initialState()
            guard entries[index].state == .running else {
                throw FeatureRegistryError.unavailable(state: entries[index].state)
            }
            guard initialState == .available else {
                entries[index].state = initialState
                throw FeatureRegistryError.unavailable(state: initialState)
            }
        } else {
            guard entries[index].state == .available else {
                throw FeatureRegistryError.unavailable(state: entries[index].state)
            }
            entries[index].state = .running
        }
        do {
            let result = try await withThrowingTaskGroup(of: FeatureActionResult.self) { group in
                group.addTask { try await plugin.perform() }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw FeatureRegistryError.executionTimedOut
                }
                guard let first = try await group.next() else {
                    throw FeatureRegistryError.executionFailed
                }
                group.cancelAll()
                return first
            }
            entries[index].state = .available
            return result
        } catch is CancellationError {
            entries[index].state = .available
            throw CancellationError()
        } catch FeatureRegistryError.executionTimedOut {
            entries[index].state = .failed(message: "功能响应超时，请重试。")
            throw FeatureRegistryError.executionTimedOut
        } catch {
            entries[index].state = .failed(message: "功能执行失败，请重试。")
            throw FeatureRegistryError.executionFailed
        }
    }

    public func retry(id: String) async throws {
        guard let index = entries.firstIndex(where: { $0.manifest.id == id }),
              let plugin = plugins[id] else { throw FeatureRegistryError.unknownFeature }
        entries[index].state = await plugin.initialState()
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
