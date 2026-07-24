import SwiftUI
import TouchFeatureAPI

struct FeatureAreaSettingsView: View {
    @EnvironmentObject private var featureStore: FeatureAreaStore
    let theme: ThemeDefinition
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsPageHeader(
                title: "功能区",
                subtitle: "每个功能独立加载，单项故障不会影响其他功能。",
                theme: theme
            )

            ForEach(featureStore.plugins, id: \.manifest.id) { plugin in
                featureCard(plugin)
            }
        }
    }

    private func featureCard(_ plugin: FeaturePlugin) -> some View {
        let manifest = plugin.manifest
        let state = featureStore.states[manifest.id] ?? .unloaded

        return SettingsCard(theme: theme) {
            HStack(spacing: 12) {
                Button {
                    onSelect(manifest.id)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: manifest.symbolName)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(theme.accent.color)
                            .frame(width: 38, height: 38)
                            .background(theme.icon.container.color, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(manifest.name)
                                .font(.system(size: 13.5, weight: .semibold))
                                .foregroundStyle(theme.text.primary.color)
                            Text(manifest.summary)
                                .font(.system(size: 11))
                                .foregroundStyle(theme.text.secondary.color)
                            if let status = statusPresentation(for: state) {
                                Label(status.text, systemImage: status.symbol)
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .foregroundStyle(status.color)
                                    .accessibilityIdentifier("settings.feature.\(manifest.id).status")
                            }
                        }
                        Spacer(minLength: 12)
                        Text(featureStore.shortcut(for: manifest.id).key.uppercased())
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(theme.shortcut.text.color)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(theme.shortcut.fill.color, in: RoundedRectangle(cornerRadius: theme.shortcut.cornerRadius, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: theme.shortcut.cornerRadius, style: .continuous).stroke(theme.shortcut.border.color, lineWidth: 1))
                        if featureStore.preferences.hidden.contains(manifest.id) {
                            Text("已隐藏")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(theme.text.weak.color)
                        }
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(theme.text.weak.color)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings.feature.\(manifest.id)")

                if case .failed = state {
                    SettingsActionButton("重试", symbol: "arrow.clockwise", theme: theme) {
                        Task { await featureStore.retry(manifest.id) }
                    }
                    .accessibilityIdentifier("settings.feature.\(manifest.id).retry")
                }
            }
        }
    }

    private func statusPresentation(for state: FeatureState) -> (text: String, symbol: String, color: Color)? {
        switch state {
        case .unloaded:
            return ("正在载入", "ellipsis", theme.text.secondary.color)
        case .available:
            return nil
        case .running:
            return ("执行中", "hourglass", theme.accent.color)
        case .restricted:
            return nil
        case .failed:
            return ("故障", "exclamationmark.triangle.fill", .red)
        case .disabled:
            return ("已停用", "pause.circle.fill", theme.text.secondary.color)
        }
    }
}
