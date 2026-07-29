import SwiftUI

struct ThemePressButtonStyle: ButtonStyle {
    let theme: ThemeDefinition
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? theme.motion.pressedScale : 1)
            .animation(
                reduceMotion ? nil : .easeOut(duration: theme.motion.duration),
                value: configuration.isPressed
            )
    }
}

struct ThemeIconControlStyle: ViewModifier {
    let theme: ThemeDefinition

    func body(content: Content) -> some View {
        content
            .frame(width: 34, height: 34)
            .background(
                theme.icon.container.color,
                in: Circle()
            )
            .overlay {
                Circle().stroke(theme.card.border.color, lineWidth: 1)
            }
    }
}

extension View {
    func themeIconControl(_ theme: ThemeDefinition) -> some View {
        modifier(ThemeIconControlStyle(theme: theme))
    }
}

struct ThemeIconButton: View {
    let systemName: String
    let tooltip: String
    let accessibilityLabel: String
    let theme: ThemeDefinition
    var tint: Color? = nil
    var isSelected = false
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(controlTint)
                .frame(width: 34, height: 34)
                .background(
                    controlTint.opacity(isSelected ? 0.18 : 0.10),
                    in: Circle()
                )
                .overlay {
                    Circle().stroke(
                        controlTint.opacity(isSelected ? 0.42 : 0.22),
                        lineWidth: 1
                    )
                }
        }
        .buttonStyle(ThemePressButtonStyle(theme: theme, reduceMotion: reduceMotion))
        .help(tooltip)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var controlTint: Color {
        tint ?? theme.interactiveAccent.color
    }
}

/// 文字类工作台使用的紧凑方形图标按钮。
///
/// 相比功能卡片中的圆形按钮，这一样式更接近速译参考界面的克制工具栏，
/// 同时保留主题化悬停、选中、按下、提示与辅助功能语义。
struct TextWorkspaceToolbarButton: View {
    private enum Icon {
        case system(String)
        case asset(String)
    }

    private let icon: Icon
    let tooltip: String
    let accessibilityLabel: String
    let theme: ThemeDefinition
    var isSelected = false
    var usesPrimaryForeground = false
    var size: CGFloat = 30
    var iconSize: CGFloat?
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    init(
        systemName: String,
        tooltip: String,
        accessibilityLabel: String,
        theme: ThemeDefinition,
        isSelected: Bool = false,
        usesPrimaryForeground: Bool = false,
        size: CGFloat = 30,
        iconSize: CGFloat? = nil,
        action: @escaping () -> Void
    ) {
        icon = .system(systemName)
        self.tooltip = tooltip
        self.accessibilityLabel = accessibilityLabel
        self.theme = theme
        self.isSelected = isSelected
        self.usesPrimaryForeground = usesPrimaryForeground
        self.size = size
        self.iconSize = iconSize
        self.action = action
    }

    init(
        assetName: String,
        tooltip: String,
        accessibilityLabel: String,
        theme: ThemeDefinition,
        isSelected: Bool = false,
        usesPrimaryForeground: Bool = false,
        size: CGFloat = 30,
        iconSize: CGFloat? = nil,
        action: @escaping () -> Void
    ) {
        icon = .asset(assetName)
        self.tooltip = tooltip
        self.accessibilityLabel = accessibilityLabel
        self.theme = theme
        self.isSelected = isSelected
        self.usesPrimaryForeground = usesPrimaryForeground
        self.size = size
        self.iconSize = iconSize
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            iconView
                .foregroundStyle(foregroundColor)
                .frame(width: size, height: size)
                .background(
                    backgroundColor,
                    in: RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
                        .stroke(
                            isSelected
                                ? theme.interactiveAccent.color.opacity(0.40)
                                : (isHovering ? theme.interactiveAccent.color.opacity(0.26) : .clear),
                            lineWidth: 1
                        )
                }
                .contentShape(RoundedRectangle(cornerRadius: size * 0.32, style: .continuous))
        }
        .buttonStyle(ThemePressButtonStyle(theme: theme, reduceMotion: reduceMotion))
        .onHover { isHovering = $0 }
        .animation(
            reduceMotion ? nil : .easeOut(duration: theme.motion.duration),
            value: isHovering
        )
        .help(tooltip)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var iconView: some View {
        switch icon {
        case let .system(systemName):
            Image(systemName: systemName)
                .font(.system(size: iconSize ?? max(11, size * 0.42), weight: .semibold))
        case let .asset(assetName):
            Image(assetName)
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .frame(
                    width: iconSize ?? size * 0.60,
                    height: iconSize ?? size * 0.60
                )
        }
    }

    private var backgroundColor: Color {
        if isSelected {
            return theme.interactiveAccent.color.opacity(0.18)
        }
        if isHovering {
            return theme.interactiveAccent.color.opacity(0.11)
        }
        // 参考速译工具栏：默认态只显示图标；悬停和选中时再出现承载面，
        // 避免多个工具按钮在紧凑窗口里形成一排深色方块。
        return .clear
    }

    private var foregroundColor: Color {
        if isSelected {
            return theme.interactiveAccent.color
        }
        return usesPrimaryForeground ? theme.text.primary.color : theme.interactiveAccent.color
    }
}

struct ThemeStatusToast: View {
    let title: String
    let detail: String?
    let systemName: String
    let theme: ThemeDefinition

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(theme.panel.fallback.color)
                .frame(width: 30, height: 30)
                .background(theme.text.success.color, in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13.5, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.text.primary.color)
                if let detail {
                    Text(detail)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(theme.text.secondary.color)
                }
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 18)
        .frame(minHeight: 50)
        .background(theme.tooltip.fill.color, in: Capsule())
        .overlay {
            Capsule().stroke(theme.panel.highlight.color, lineWidth: 1)
        }
        .shadow(color: theme.tooltip.shadow.color, radius: 18, y: 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(detail.map { "\(title)，\($0)" } ?? title)
    }
}

struct ThemePrimaryActionButton: View {
    let title: String
    let systemName: String
    let theme: ThemeDefinition
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemName)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(Color.white)
                .padding(.horizontal, 14)
                .frame(height: 34)
                .background(theme.accent.color, in: Capsule())
                .shadow(color: theme.accent.color.opacity(0.22), radius: 10, y: 5)
        }
        .buttonStyle(ThemePressButtonStyle(theme: theme, reduceMotion: reduceMotion))
    }
}
