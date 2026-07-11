import SwiftUI
import TouchFeatureAPI

struct FeatureGridView: View {
    let plugins: [any FeaturePlugin]
    let palette: ThemePalette

    var body: some View {
        HStack(spacing: 24) {
            ForEach(plugins, id: \.manifest.id) { plugin in
                FeatureCardView(plugin: plugin, palette: palette) {
                    Task { _ = try? await plugin.perform() }
                }
            }
        }
    }
}
