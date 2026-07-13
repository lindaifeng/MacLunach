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
    private var activatedFeatureIDs: Set<String> = []
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
                    state: preferences.disabled.contains($0.manifest.id) ? .disabled : .unloaded,
                    shortcut: preferences.shortcuts[$0.manifest.id] ?? $0.manifest.defaultShortcut,
                    isVisible: !preferences.hidden.contains($0.manifest.id)
                )
            }
    }

    public func load() async {
        for id in entries.map(\.manifest.id) {
            guard state(for: id) == .unloaded, let plugin = plugins[id] else { continue }
            await activateLifecycleIfNeeded(for: plugin, id: id)
            let initialState = await plugin.initialState()
            setState(initialState, for: id, onlyIf: .unloaded)
        }
    }

    public func state(for id: String) -> FeatureState? {
        entries.first { $0.manifest.id == id }?.state
    }

    public func perform(id: String, timeout: Duration = .seconds(5)) async throws -> FeatureActionResult {
        guard let plugin = plugins[id], let state = state(for: id) else {
            throw FeatureRegistryError.unknownFeature
        }

        switch state {
        case .unloaded:
            setState(.running, for: id)
            await activateLifecycleIfNeeded(for: plugin, id: id)
            let initialState = await plugin.initialState()
            guard self.state(for: id) == .running else {
                throw FeatureRegistryError.unavailable(state: self.state(for: id) ?? .disabled)
            }
            guard initialState == .available else {
                setState(initialState, for: id)
                throw FeatureRegistryError.unavailable(state: initialState)
            }
        case .available:
            setState(.running, for: id)
        case .running, .restricted, .failed, .disabled:
            throw FeatureRegistryError.unavailable(state: state)
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

            if case .requiresSetup = result {
                let refreshedState = await plugin.initialState()
                setState(refreshedState, for: id, onlyIf: .running)
            } else {
                setState(.available, for: id, onlyIf: .running)
            }
            return result
        } catch is CancellationError {
            setState(.available, for: id, onlyIf: .running)
            throw CancellationError()
        } catch FeatureRegistryError.executionTimedOut {
            setState(.failed(message: "功能响应超时，请重试。"), for: id, onlyIf: .running)
            throw FeatureRegistryError.executionTimedOut
        } catch {
            setState(.failed(message: "功能执行失败，请重试。"), for: id, onlyIf: .running)
            throw FeatureRegistryError.executionFailed
        }
    }

    public func retry(id: String) async throws {
        guard let plugin = plugins[id], let state = state(for: id) else {
            throw FeatureRegistryError.unknownFeature
        }
        guard state != .disabled else {
            throw FeatureRegistryError.unavailable(state: .disabled)
        }
        let refreshedState = await plugin.initialState()
        guard self.state(for: id) != .disabled else {
            throw FeatureRegistryError.unavailable(state: .disabled)
        }
        setState(refreshedState, for: id)
    }

    public func setEnabled(_ isEnabled: Bool, for id: String) async throws {
        guard let plugin = plugins[id], let currentState = state(for: id) else {
            throw FeatureRegistryError.unknownFeature
        }

        if isEnabled {
            guard currentState == .disabled else { return }
            setState(.unloaded, for: id)
            await activateLifecycleIfNeeded(for: plugin, id: id)
            let initialState = await plugin.initialState()
            setState(initialState, for: id, onlyIf: .unloaded)
        } else {
            guard currentState != .disabled else { return }
            setState(.disabled, for: id)
            await deactivateLifecycle(for: plugin, id: id)
        }
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
            disabled: Set(entries.filter { $0.state == .disabled }.map(\.manifest.id)),
            shortcuts: Dictionary(uniqueKeysWithValues: entries.compactMap { entry in
                guard entry.shortcut != entry.manifest.defaultShortcut else { return nil }
                return (entry.manifest.id, entry.shortcut)
            })
        )
    }

    private func activateLifecycleIfNeeded(
        for plugin: any FeaturePlugin,
        id: String
    ) async {
        guard let lifecycle = plugin as? any FeatureLifecycleHandling,
              activatedFeatureIDs.insert(id).inserted else { return }
        await lifecycle.featureDidEnable()

        // A lifecycle hook may suspend. If the feature was disabled while it
        // was enabling, compensate before returning so no private resource leaks.
        if state(for: id) == .disabled, activatedFeatureIDs.remove(id) != nil {
            await lifecycle.featureDidDisable()
        }
    }

    private func deactivateLifecycle(
        for plugin: any FeaturePlugin,
        id: String
    ) async {
        activatedFeatureIDs.remove(id)
        guard let lifecycle = plugin as? any FeatureLifecycleHandling else { return }
        await lifecycle.featureDidDisable()
    }

    private func setState(_ state: FeatureState, for id: String, onlyIf expected: FeatureState? = nil) {
        guard let index = entries.firstIndex(where: { $0.manifest.id == id }) else { return }
        if let expected, entries[index].state != expected { return }
        entries[index].state = state
    }
}
