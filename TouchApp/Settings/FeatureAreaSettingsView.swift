import SwiftUI
import TouchFeatureAPI

struct FeatureAreaSettingsView: View {
    @EnvironmentObject private var featureStore: FeatureAreaStore
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("功能区总览")
                .font(.largeTitle.bold())
            Text("集中管理启动页上的功能。每个功能独立加载，单项故障不会影响其他功能。")
                .foregroundStyle(.secondary)

            ForEach(featureStore.plugins, id: \.manifest.id) { plugin in
                let manifest = plugin.manifest
                let state = featureStore.states[manifest.id] ?? .unloaded
                HStack(spacing: 10) {
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
                            Text(featureStore.shortcut(for: manifest.id).displayValue)
                                .foregroundStyle(.secondary)
                            if featureStore.preferences.hidden.contains(manifest.id) {
                                Text("已隐藏")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if let status = statusPresentation(for: state) {
                                Label(status.text, systemImage: status.symbol)
                                    .font(.caption)
                                    .foregroundStyle(status.color)
                                    .accessibilityIdentifier("settings.feature.\(manifest.id).status")
                            }
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("settings.feature.\(manifest.id)")

                    if case .failed = state {
                        Button("重试", systemImage: "arrow.clockwise") {
                            Task { await featureStore.retry(manifest.id) }
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("settings.feature.\(manifest.id).retry")
                    }
                }
                .padding(14)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
            }
            Spacer()
        }
        .padding(30)
    }

    private func statusPresentation(for state: FeatureState) -> (text: String, symbol: String, color: Color)? {
        switch state {
        case .unloaded:
            return ("正在载入", "ellipsis", .secondary)
        case .available:
            return nil
        case .running:
            return ("执行中", "hourglass", .accentColor)
        case .restricted:
            return ("需要授权", "lock.fill", .orange)
        case .failed:
            return ("故障", "exclamationmark.triangle.fill", .red)
        case .disabled:
            return ("已停用", "pause.circle.fill", .secondary)
        }
    }
}
