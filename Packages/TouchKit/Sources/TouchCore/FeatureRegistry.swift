import TouchFeatureAPI

public enum FeatureRegistryError: Error, Equatable {
    case unknownFeature
    case shortcutConflict(existingFeatureID: String)
    case unavailable(state: FeatureState)
    case executionTimedOut
    case executionFailed
}

public enum FeatureRegistrationError: Error, Equatable, Sendable {
    case duplicateID(String)
    case invalidManifest(pluginID: String, issues: Set<FeatureManifestIssue>)
    case incompatibleAPIVersion(pluginID: String, requested: FeatureAPIVersion)
    case minimumHostVersionNotMet(
        pluginID: String,
        minimum: FeatureVersion,
        current: FeatureVersion
    )
    case unsupportedRequiredCapabilities(pluginID: String, requested: Set<FeatureCapability>)
}

public enum FeatureManifestIssue: String, Hashable, Sendable {
    case invalidID
    case missingName
    case missingSummary
    case missingSymbolName
    case invalidDefaultOrder
    case invalidPluginVersion
    case invalidFeatureAPIVersion
    case invalidHostVersionRange
    case invalidConfigurationSchemaVersion
    case overlappingCapabilities
}

public struct FeatureHostCompatibility: Equatable, Sendable {
    public let hostVersion: FeatureVersion
    public let supportedFeatureAPIVersions: Set<FeatureAPIVersion>
    public let supportedCapabilities: Set<FeatureCapability>

    public init(
        hostVersion: FeatureVersion,
        supportedFeatureAPIVersions: Set<FeatureAPIVersion>,
        supportedCapabilities: Set<FeatureCapability>
    ) {
        self.hostVersion = hostVersion
        self.supportedFeatureAPIVersions = supportedFeatureAPIVersions
        self.supportedCapabilities = supportedCapabilities
    }

    public static let current = FeatureHostCompatibility(
        hostVersion: .init(major: 1, minor: 0, patch: 0),
        supportedFeatureAPIVersions: [.init(major: 1)],
        supportedCapabilities: Set(FeatureCapability.allCases)
    )
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
    public let registrationErrors: [FeatureRegistrationError]

    public init(
        plugins: [any FeaturePlugin],
        preferences: FeaturePreferences = .init(),
        hostCompatibility: FeatureHostCompatibility = .current
    ) {
        let pluginsByID = Dictionary(grouping: plugins, by: { $0.manifest.id })
        let duplicateIDs = Set(
            pluginsByID.compactMap { id, matches in matches.count > 1 ? id : nil }
        )
        var registrationErrors = duplicateIDs.sorted().map(FeatureRegistrationError.duplicateID)
        let acceptedPlugins = plugins.filter { plugin in
            guard !duplicateIDs.contains(plugin.manifest.id) else { return false }
            let manifestIssues = Self.validationIssues(for: plugin.manifest)
            guard manifestIssues.isEmpty else {
                registrationErrors.append(
                    .invalidManifest(pluginID: plugin.manifest.id, issues: manifestIssues)
                )
                return false
            }
            guard hostCompatibility.supportedFeatureAPIVersions.contains(
                plugin.manifest.featureAPIVersion
            ) else {
                registrationErrors.append(
                    .incompatibleAPIVersion(
                        pluginID: plugin.manifest.id,
                        requested: plugin.manifest.featureAPIVersion
                    )
                )
                return false
            }
            guard plugin.manifest.minimumHostVersion <= hostCompatibility.hostVersion else {
                registrationErrors.append(
                    .minimumHostVersionNotMet(
                        pluginID: plugin.manifest.id,
                        minimum: plugin.manifest.minimumHostVersion,
                        current: hostCompatibility.hostVersion
                    )
                )
                return false
            }
            let unsupportedCapabilities = plugin.manifest.capabilities.required
                .subtracting(hostCompatibility.supportedCapabilities)
            guard unsupportedCapabilities.isEmpty else {
                registrationErrors.append(
                    .unsupportedRequiredCapabilities(
                        pluginID: plugin.manifest.id,
                        requested: unsupportedCapabilities
                    )
                )
                return false
            }
            return true
        }

        self.registrationErrors = registrationErrors
        self.plugins = Dictionary(uniqueKeysWithValues: acceptedPlugins.map { ($0.manifest.id, $0) })
        let storedOrder = Dictionary(uniqueKeysWithValues: preferences.order.enumerated().map { ($1, $0) })
        self.entries = acceptedPlugins
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

    public func perform(id: String, timeout: Duration? = .seconds(5)) async throws -> FeatureActionResult {
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
            let result: FeatureActionResult
            if let timeout {
                result = try await withThrowingTaskGroup(of: FeatureActionResult.self) { group in
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
            } else {
                result = try await plugin.perform()
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

    public func swapShortcuts(between firstID: String, and secondID: String) throws {
        guard let firstIndex = entries.firstIndex(where: { $0.manifest.id == firstID }),
              let secondIndex = entries.firstIndex(where: { $0.manifest.id == secondID }) else {
            throw FeatureRegistryError.unknownFeature
        }
        guard firstIndex != secondIndex else { return }
        let firstShortcut = entries[firstIndex].shortcut
        entries[firstIndex].shortcut = entries[secondIndex].shortcut
        entries[secondIndex].shortcut = firstShortcut
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

    private static func validationIssues(for manifest: FeatureManifest) -> Set<FeatureManifestIssue> {
        var issues: Set<FeatureManifestIssue> = []
        if !isValidFeatureID(manifest.id) { issues.insert(.invalidID) }
        if manifest.name.allSatisfy(\.isWhitespace) { issues.insert(.missingName) }
        if manifest.summary.allSatisfy(\.isWhitespace) { issues.insert(.missingSummary) }
        if manifest.symbolName.allSatisfy(\.isWhitespace) { issues.insert(.missingSymbolName) }
        if manifest.defaultOrder < 0 { issues.insert(.invalidDefaultOrder) }
        if !isValid(manifest.pluginVersion) { issues.insert(.invalidPluginVersion) }
        if manifest.featureAPIVersion.major <= 0 { issues.insert(.invalidFeatureAPIVersion) }
        if !isValid(manifest.minimumHostVersion)
            || !isValid(manifest.maximumTestedHostVersion)
            || manifest.maximumTestedHostVersion < manifest.minimumHostVersion {
            issues.insert(.invalidHostVersionRange)
        }
        if manifest.configurationSchemaVersion <= 0 {
            issues.insert(.invalidConfigurationSchemaVersion)
        }
        if !manifest.capabilities.required.isDisjoint(with: manifest.capabilities.optional) {
            issues.insert(.overlappingCapabilities)
        }
        return issues
    }

    private static func isValidFeatureID(_ id: String) -> Bool {
        let components = id.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count >= 3 else { return false }
        return components.allSatisfy { component in
            guard let first = component.first,
                  let last = component.last,
                  first != "-",
                  last != "-" else { return false }
            return component.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
        }
    }

    private static func isValid(_ version: FeatureVersion) -> Bool {
        version.major >= 0 && version.minor >= 0 && version.patch >= 0
    }
}
