import SwiftUI
import TouchFeatureAPI

struct FeatureCardView: View {
    let plugin: any FeaturePlugin
    let shortcut: TouchFeatureAPI.KeyboardShortcut
    let state: FeatureState
    let palette: ThemePalette
    let action: () -> Void
    let retry: () -> Void
    let editShortcut: () -> Void
    let hide: () -> Void
    let restoreDefaults: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: plugin.manifest.symbolName)
                    .font(.system(size: 22, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .foregroundStyle(palette.accent)
                    .background(
                        palette.accent.opacity(0.13),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                VStack(alignment: .leading, spacing: 3) {
                    Text(plugin.manifest.name)
                        .font(.system(size: 16, weight: .semibold))
                    if let statusLabel {
                        Label(statusLabel.text, systemImage: statusLabel.symbol)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(statusLabel.color)
                    }
                }
                Spacer(minLength: 6)
                Text(shortcut.displayValue)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        .white.opacity(0.10),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                    )
            }
            .foregroundStyle(palette.primaryText)
            .padding(.horizontal, 16)
            .frame(width: 224, height: 72)
            .background(
                palette.cardFill,
                in: RoundedRectangle(cornerRadius: 17, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .stroke(palette.border, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("feature.\(plugin.manifest.id)")
        .contextMenu {
            if case .failed = state {
                Button("重试", systemImage: "arrow.clockwise", action: retry)
                Divider()
            }
            Button("修改快捷键", action: editShortcut)
            Button("隐藏功能", action: hide)
            Divider()
            Button("恢复默认", action: restoreDefaults)
        }
    }

    private var statusLabel: (text: String, symbol: String, color: Color)? {
        switch state {
        case .unloaded:
            return ("正在载入", "ellipsis", .secondary)
        case .available:
            return nil
        case .running:
            return ("执行中", "hourglass", palette.accent)
        case .restricted:
            return ("需要授权", "lock.fill", .orange)
        case .failed:
            return ("执行故障 · 右键重试", "exclamationmark.triangle.fill", .red)
        case .disabled:
            return ("已停用", "pause.circle.fill", .secondary)
        }
    }
}
