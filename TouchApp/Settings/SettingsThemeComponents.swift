import AppKit
import SwiftUI

struct SettingsPageHeader: View {
    let title: String
    let subtitle: String
    let theme: ThemeDefinition

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(theme.text.primary.color)
            Text(subtitle)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(theme.text.secondary.color)
        }
    }
}

struct SettingsCard<Content: View>: View {
    let theme: ThemeDefinition
    let content: Content

    init(theme: ThemeDefinition, @ViewBuilder content: () -> Content) {
        self.theme = theme
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(theme.card.fill.color, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .stroke(theme.card.border.color, lineWidth: 1)
            }
            .shadow(
                color: theme.card.shadow.color.color,
                radius: min(theme.card.shadow.radius, 9),
                x: theme.card.shadow.x,
                y: min(theme.card.shadow.y, 6)
            )
    }
}

struct SettingsSectionTitle: View {
    let title: String
    let detail: String?
    let theme: ThemeDefinition

    init(_ title: String, detail: String? = nil, theme: ThemeDefinition) {
        self.title = title
        self.detail = detail
        self.theme = theme
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(theme.text.secondary.color)
            if let detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.text.weak.color)
            }
        }
    }
}

struct SettingsValueRow: View {
    let title: String
    let detail: String?
    let value: String
    let theme: ThemeDefinition

    init(_ title: String, detail: String? = nil, value: String, theme: ThemeDefinition) {
        self.title = title
        self.detail = detail
        self.value = value
        self.theme = theme
    }

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.text.primary.color)
                if let detail {
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.text.secondary.color)
                }
            }
            Spacer(minLength: 16)
            Text(value)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(theme.text.secondary.color)
                .multilineTextAlignment(.trailing)
        }
    }
}

struct SettingsToggleRow: View {
    let title: String
    let detail: String?
    @Binding var isOn: Bool
    let theme: ThemeDefinition

    init(_ title: String, detail: String? = nil, isOn: Binding<Bool>, theme: ThemeDefinition) {
        self.title = title
        self.detail = detail
        _isOn = isOn
        self.theme = theme
    }

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(theme.text.primary.color)
                    if let detail {
                        Text(detail)
                            .font(.system(size: 11.5))
                            .foregroundStyle(theme.text.secondary.color)
                    }
                }
                Spacer(minLength: 16)
                SettingsSwitch(isOn: isOn, theme: theme)
            }
            .frame(minHeight: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct SettingsSwitch: View {
    let isOn: Bool
    let theme: ThemeDefinition

    var body: some View {
        Capsule()
            .fill(isOn ? activeColor : theme.shortcut.fill.color)
            .frame(width: 38, height: 22)
            .overlay {
                if isOn {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .black))
                        .foregroundStyle(.white)
                        .offset(x: -8)
                }
            }
            .overlay {
                Circle()
                    .fill(.white.opacity(isOn ? 1 : 0.82))
                    .frame(width: 16, height: 16)
                    .offset(x: isOn ? 8 : -8)
                    .shadow(
                        color: isOn ? activeColor.opacity(0.34) : .black.opacity(0.12),
                        radius: isOn ? 4 : 2,
                        y: 1
                    )
            }
            .overlay {
                Capsule()
                    .stroke(
                        isOn ? activeColor.opacity(0.72) : theme.shortcut.border.color,
                        lineWidth: 1
                    )
            }
            .animation(.easeOut(duration: theme.motion.duration), value: isOn)
    }

    private var activeColor: Color {
        let luminance = 0.2126 * theme.accent.red
            + 0.7152 * theme.accent.green
            + 0.0722 * theme.accent.blue
        return luminance > 0.82 ? theme.text.success.color : theme.accent.color
    }
}

struct SettingsActionButton: View {
    let title: String
    let symbol: String?
    let theme: ThemeDefinition
    let compact: Bool
    let action: () -> Void

    init(
        _ title: String,
        symbol: String? = nil,
        theme: ThemeDefinition,
        compact: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.symbol = symbol
        self.theme = theme
        self.compact = compact
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Group {
                if let symbol {
                    Label(title, systemImage: symbol)
                } else {
                    Text(title)
                }
            }
                .font(.system(size: compact ? 11 : 12, weight: .semibold))
                .foregroundStyle(theme.accent.color)
                .padding(.horizontal, compact ? 9 : 11)
                .padding(.vertical, compact ? 5 : 7)
                .background(
                    theme.accent.color.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: compact ? 8 : 9, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: compact ? 8 : 9, style: .continuous)
                        .stroke(theme.accent.color.opacity(0.28), lineWidth: 1)
                }
        }
        .buttonStyle(ThemePressButtonStyle(theme: theme, reduceMotion: false))
    }
}

struct SettingsDivider: View {
    let theme: ThemeDefinition

    var body: some View {
        Rectangle()
            .fill(theme.panel.edgeBorder.color.opacity(0.7))
            .frame(height: 1)
    }
}

struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> DragHandleView {
        DragHandleView()
    }

    func updateNSView(_ nsView: DragHandleView, context: Context) {}
}

final class DragHandleView: NSView {
    override var acceptsFirstResponder: Bool { false }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }
}
