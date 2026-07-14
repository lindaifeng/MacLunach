import Foundation
import FinderFeature
import ScreenshotFeature
import SuperRightFeature
import SwiftUI
import TouchCore
import TouchFeatureAPI

@MainActor
final class FeatureAreaStore: ObservableObject {
    @Published private(set) var plugins: [any FeaturePlugin]
    @Published private(set) var preferences: FeaturePreferences
    @Published private(set) var states: [String: FeatureState] = [:]
    @Published private(set) var configurations: FeatureConfigurations

    private let preferencesStore: FeaturePreferencesStore
    private let configurationStore: FeatureConfigurationStore
    private let registry: FeatureRegistry
    private let notificationCenter: NotificationCenter

    init(
        defaults: UserDefaults = .standard,
        plugins: [any FeaturePlugin],
        notificationCenter: NotificationCenter = .default
    ) {
        preferencesStore = FeaturePreferencesStore(defaults: defaults)
        configurationStore = FeatureConfigurationStore(defaults: defaults)
        self.notificationCenter = notificationCenter
        let loadedPreferences = (try? preferencesStore.load()) ?? .init()
        preferences = loadedPreferences
        configurations = configurationStore.load()

        registry = FeatureRegistry(plugins: plugins, preferences: loadedPreferences)
        let storedOrder = Dictionary(uniqueKeysWithValues: loadedPreferences.order.enumerated().map { ($1, $0) })
        self.plugins = plugins.sorted {
            let left = storedOrder[$0.manifest.id] ?? (loadedPreferences.order.count + $0.manifest.defaultOrder)
            let right = storedOrder[$1.manifest.id] ?? (loadedPreferences.order.count + $1.manifest.defaultOrder)
            return left < right
        }
        Task { [weak self] in await self?.loadStates() }
    }

    var visiblePlugins: [any FeaturePlugin] {
        plugins.filter { !preferences.hidden.contains($0.manifest.id) }
    }

    func isEnabled(_ featureID: String) -> Bool {
        !preferences.disabled.contains(featureID)
    }

    func shortcut(for featureID: String) -> TouchFeatureAPI.KeyboardShortcut {
        if let shortcut = preferences.shortcuts[featureID] {
            return shortcut
        }
        return plugins.first(where: { $0.manifest.id == featureID })?.manifest.defaultShortcut
            ?? .init(modifiers: [], key: "")
    }

    func move(_ sourceID: String, before destinationID: String, animated: Bool) {
        guard sourceID != destinationID,
              let source = plugins.firstIndex(where: { $0.manifest.id == sourceID }),
              let destination = plugins.firstIndex(where: { $0.manifest.id == destinationID }) else { return }

        let updateOrder = {
            let plugin = self.plugins.remove(at: source)
            let adjustedDestination = source < destination ? destination - 1 : destination
            self.plugins.insert(plugin, at: max(0, adjustedDestination))
        }
        if animated {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.82), updateOrder)
        } else {
            updateOrder()
        }
        persistOrder()
        Task {
            await registry.move(from: source, to: source < destination ? destination - 1 : destination)
        }
    }

    func setHidden(_ hidden: Bool, for featureID: String) {
        if hidden {
            preferences.hidden.insert(featureID)
        } else {
            preferences.hidden.remove(featureID)
        }
        persist()
        Task { try? await registry.setVisibility(!hidden, for: featureID) }
    }

    func setEnabled(_ enabled: Bool, for featureID: String) async {
        do {
            try await registry.setEnabled(enabled, for: featureID)
            if enabled {
                preferences.disabled.remove(featureID)
            } else {
                preferences.disabled.insert(featureID)
            }
            persist()
        } catch {
            // Unknown plugins cannot be changed by the settings UI.
        }
        await refreshStates()
    }

    func updateFinderConfiguration<Value>(
        _ keyPath: WritableKeyPath<FinderFeatureConfiguration, Value>,
        to value: Value
    ) {
        configurations.finder[keyPath: keyPath] = value
        try? configurationStore.save(configurations.finder)
    }

    func updateScreenshotConfiguration<Value>(
        _ keyPath: WritableKeyPath<ScreenshotFeatureConfiguration, Value>,
        to value: Value
    ) {
        configurations.screenshot[keyPath: keyPath] = value
        try? configurationStore.save(configurations.screenshot)
    }

    func updateScreenshotModeShortcut(
        _ shortcut: TouchFeatureAPI.KeyboardShortcut,
        for mode: ScreenshotCaptureMode
    ) -> String? {
        if let conflict = plugins.first(where: { self.shortcut(for: $0.manifest.id) == shortcut }) {
            return "与“\(conflict.manifest.name)”的快捷键冲突"
        }
        if let conflict = configurations.screenshot.modeShortcuts.first(where: {
            $0.key != mode && $0.value == shortcut
        }) {
            return "与“\(conflict.key.settingsTitle)”快捷键冲突"
        }

        configurations.screenshot.modeShortcuts[mode] = shortcut
        try? configurationStore.save(configurations.screenshot)
        notificationCenter.post(name: .screenshotShortcutsDidChange, object: nil)
        return nil
    }

    func updateSuperRightConfiguration<Value>(
        _ keyPath: WritableKeyPath<SuperRightFeatureConfiguration, Value>,
        to value: Value
    ) {
        configurations.superRight[keyPath: keyPath] = value
        try? configurationStore.save(configurations.superRight)
    }

    func updateShortcut(_ shortcut: TouchFeatureAPI.KeyboardShortcut, for featureID: String) -> String? {
        if let conflict = plugins.first(where: {
            $0.manifest.id != featureID && self.shortcut(for: $0.manifest.id) == shortcut
        }) {
            return "与“\(conflict.manifest.name)”的快捷键冲突"
        }

        preferences.shortcuts[featureID] = shortcut
        persist()
        Task { try? await registry.setShortcut(shortcut, for: featureID) }
        if featureID == FeatureConfigurationStore.screenshotID {
            notificationCenter.post(name: .screenshotShortcutsDidChange, object: nil)
        }
        return nil
    }

    func restoreDefaults(for featureID: String) {
        preferences.shortcuts.removeValue(forKey: featureID)
        preferences.hidden.remove(featureID)
        plugins.sort { $0.manifest.defaultOrder < $1.manifest.defaultOrder }
        persistOrder()
        Task { try? await registry.restoreDefaults(for: featureID) }
    }

    func perform(_ featureID: String) async {
        guard isEnabled(featureID) else {
            openSettings(for: featureID)
            return
        }
        states[featureID] = .running
        do {
            let result = try await registry.perform(id: featureID)
            if case .requiresSetup = result {
                openSettings(for: featureID)
            }
        } catch FeatureRegistryError.unavailable(state: let state) {
            if case .restricted = state {
                openSettings(for: featureID)
            } else if state == .disabled {
                openSettings(for: featureID)
            }
        } catch {
            // The registry owns and publishes the isolated failure state below.
        }
        await refreshStates()
    }

    func retry(_ featureID: String) async {
        try? await registry.retry(id: featureID)
        await refreshStates()
    }

    private func loadStates() async {
        await registry.load()
        await refreshStates()
    }

    private func refreshStates() async {
        states = Dictionary(uniqueKeysWithValues: await registry.entries.map { ($0.manifest.id, $0.state) })
    }

    private func openSettings(for featureID: String) {
        notificationCenter.post(
            name: .openTouchSettings,
            object: TouchSettingsDestination(section: .featureArea, featureID: featureID)
        )
    }

    private func persistOrder() {
        preferences.order = plugins.map { $0.manifest.id }
        persist()
    }

    private func persist() {
        try? preferencesStore.save(preferences)
        objectWillChange.send()
    }
}

extension Notification.Name {
    static let screenshotShortcutsDidChange = Notification.Name(
        "me.touch.screenshot.shortcuts-did-change"
    )
}

private extension ScreenshotCaptureMode {
    var settingsTitle: String {
        switch self {
        case .region: "区域截图"
        case .window: "窗口截图"
        case .fullScreen: "全屏截图"
        case .allDisplays: "所有显示器截图"
        case .ocrRegion: "文字识别"
        case .colorPicker: "屏幕取色"
        }
    }
}
