import SwiftUI
import TouchFeatureAPI

struct FeatureCardView: View {
    let plugin: any FeaturePlugin
    let shortcut: TouchFeatureAPI.KeyboardShortcut
    let palette: ThemePalette
    let action: () -> Void
    let editShortcut: () -> Void
    let hide: () -> Void
    let restoreDefaults: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: plugin.manifest.symbolName)
                    .font(.system(size: 27, weight: .medium))
                    .frame(width: 40)
                    .foregroundStyle(palette.accent)
                Text(plugin.manifest.name)
                    .font(.system(size: 19, weight: .semibold))
                Spacer()
                Text(shortcut.displayValue)
                    .font(.system(size: 15, weight: .medium, design: .monospaced))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            }
            .foregroundStyle(palette.primaryText)
            .padding(.horizontal, 22)
            .frame(width: 260, height: 86)
            .background(palette.cardFill, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(palette.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("feature.\(plugin.manifest.id)")
        .contextMenu {
            Button("修改快捷键", action: editShortcut)
            Button("隐藏功能", action: hide)
            Divider()
            Button("恢复默认", action: restoreDefaults)
        }
    }
}
