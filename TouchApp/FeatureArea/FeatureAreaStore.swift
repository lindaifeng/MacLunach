import Foundation
import SwiftUI
import TouchCore
import TouchFeatureAPI
import FinderFeature
import ScreenshotFeature
import SuperRightFeature

@MainActor
final class FeatureAreaStore: ObservableObject {
    static let shared = FeatureAreaStore()

    @Published private(set) var plugins: [any FeaturePlugin]
    @Published private(set) var preferences: FeaturePreferences

    private let preferencesStore: FeaturePreferencesStore

    init(defaults: UserDefaults = .standard) {
        preferencesStore = FeaturePreferencesStore(defaults: defaults)
        let loadedPreferences = (try? preferencesStore.load()) ?? .init()
        preferences = loadedPreferences

        let builtIns: [any FeaturePlugin] = [
            FinderFeaturePlugin(),
            ScreenshotFeaturePlugin(),
            SuperRightFeaturePlugin()
        ]
        let storedOrder = Dictionary(uniqueKeysWithValues: loadedPreferences.order.enumerated().map { ($1, $0) })
        plugins = builtIns.sorted {
            let left = storedOrder[$0.manifest.id] ?? (loadedPreferences.order.count + $0.manifest.defaultOrder)
            let right = storedOrder[$1.manifest.id] ?? (loadedPreferences.order.count + $1.manifest.defaultOrder)
            return left < right
        }
    }

    var visiblePlugins: [any FeaturePlugin] {
        plugins.filter { !preferences.hidden.contains($0.manifest.id) }
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
    }

    func setHidden(_ hidden: Bool, for featureID: String) {
        if hidden {
            preferences.hidden.insert(featureID)
        } else {
            preferences.hidden.remove(featureID)
        }
        persist()
    }

    func updateShortcut(_ shortcut: TouchFeatureAPI.KeyboardShortcut, for featureID: String) -> String? {
        if let conflict = plugins.first(where: {
            $0.manifest.id != featureID && self.shortcut(for: $0.manifest.id) == shortcut
        }) {
            return "与“\(conflict.manifest.name)”的快捷键冲突"
        }

        preferences.shortcuts[featureID] = shortcut
        persist()
        return nil
    }

    func restoreDefaults(for featureID: String) {
        preferences.shortcuts.removeValue(forKey: featureID)
        preferences.hidden.remove(featureID)
        plugins.sort { $0.manifest.defaultOrder < $1.manifest.defaultOrder }
        persistOrder()
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
