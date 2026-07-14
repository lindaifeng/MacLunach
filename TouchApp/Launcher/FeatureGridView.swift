import SwiftUI
import TouchFeatureAPI

struct FeatureGridView: View {
    @EnvironmentObject private var featureStore: FeatureAreaStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var editingFeatureID: String?
    let palette: ThemePalette

    var body: some View {
        HStack(spacing: 18) {
            ForEach(featureStore.visiblePlugins, id: \.manifest.id) { plugin in
                FeatureCardView(
                    plugin: plugin,
                    shortcut: featureStore.shortcut(for: plugin.manifest.id),
                    state: featureStore.states[plugin.manifest.id] ?? .unloaded,
                    palette: palette,
                    action: { Task { await featureStore.perform(plugin.manifest.id) } },
                    retry: { Task { await featureStore.retry(plugin.manifest.id) } },
                    editShortcut: { editingFeatureID = plugin.manifest.id },
                    hide: { featureStore.setHidden(true, for: plugin.manifest.id) },
                    restoreDefaults: { featureStore.restoreDefaults(for: plugin.manifest.id) }
                )
                .draggable(plugin.manifest.id)
                .dropDestination(for: String.self) { featureIDs, _ in
                    guard let sourceID = featureIDs.first else { return false }
                    featureStore.move(sourceID, before: plugin.manifest.id, animated: !reduceMotion)
                    return true
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { editingFeatureID != nil },
            set: { if !$0 { editingFeatureID = nil } }
        )) {
            if let editingFeatureID {
                ShortcutEditorView(featureID: editingFeatureID)
                    .environmentObject(featureStore)
            }
        }
    }
}
