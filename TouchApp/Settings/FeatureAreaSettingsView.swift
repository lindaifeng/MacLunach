import SwiftUI
import TouchFeatureAPI
import FinderFeature
import ScreenshotFeature
import SuperRightFeature

struct FeatureAreaSettingsView: View {
    let onSelect: (String) -> Void

    private let manifests: [FeatureManifest] = [
        FinderFeaturePlugin().manifest,
        ScreenshotFeaturePlugin().manifest,
        SuperRightFeaturePlugin().manifest
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("功能区总览")
                .font(.largeTitle.bold())
            Text("集中管理启动页上的功能。每个功能独立加载，单项故障不会影响其他功能。")
                .foregroundStyle(.secondary)

            ForEach(manifests) { manifest in
                Button {
                    onSelect(manifest.id)
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: manifest.symbolName)
                            .font(.title2)
                            .frame(width: 34, height: 34)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(manifest.name).font(.headline)
                            Text(manifest.summary).font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(manifest.defaultShortcut.displayValue)
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.tertiary)
                    }
                    .padding(14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                .accessibilityIdentifier("settings.feature.\(manifest.id)")
            }
            Spacer()
        }
        .padding(30)
    }
}
