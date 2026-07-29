import AppKit
import SwiftUI
import TouchCore

/// 标注编辑器使用的统一外观令牌。颜色始终建立在系统语义色之上，因此三套触达主题
/// 只改变强调色和环境染色，不会破坏浅色、深色或“增大对比度”下的文字可读性。
struct AnnotationEditorAppearance {
    let theme: TouchTheme
    let themeName: String
    let accent: Color
    let tintOverlay: Color
    let chromeFill: Color
    let inspectorFill: Color
    let canvasFill: Color
    let cropBarFill: Color
    let border: Color
    let toolFill: Color
    let toolSelectedFill: Color
    let toolText: Color
    let toolSelectedText: Color
    let toolBorder: Color
    let primaryActionFill: Color
    let primaryActionPressedFill: Color
    let primaryActionText: Color
    let selectionStroke: Color
    let reduceMotion: Bool
    let reduceTransparency: Bool
    let increasedContrast: Bool
    let colorScheme: ColorScheme

    var accessibilitySummary: String {
        let mode = colorScheme == .dark ? "深色" : "浅色"
        let transparency = reduceTransparency ? "降低透明度" : "标准透明度"
        let contrast = increasedContrast ? "增大对比度" : "标准对比度"
        return "\(themeName)主题，\(mode)，\(transparency)，\(contrast)"
    }

    static func make(
        theme: TouchTheme,
        colorScheme: ColorScheme,
        reduceMotion: Bool,
        reduceTransparency: Bool,
        increasedContrast: Bool
    ) -> Self {
        let definition = ThemeRegistry.shared.definition(for: theme)

        let isDark = colorScheme == .dark
        let isOpaque = reduceTransparency || increasedContrast
        let surface = Color(nsColor: .controlBackgroundColor)
        let underPage = Color(nsColor: .underPageBackgroundColor)
        let chromeOpacity = isOpaque ? 1.0 : (isDark ? 0.78 : 0.72)
        let inspectorOpacity = isOpaque ? 1.0 : (isDark ? 0.88 : 0.82)
        let tintOpacity = isOpaque ? 0 : min(
            definition.panel.reflection.opacity * (isDark ? 1.8 : 1),
            0.18
        )

        return .init(
            theme: theme,
            themeName: definition.displayName,
            accent: definition.accent.color,
            tintOverlay: definition.auxiliaryAccent.color.opacity(tintOpacity),
            chromeFill: surface.opacity(chromeOpacity),
            inspectorFill: surface.opacity(inspectorOpacity),
            canvasFill: underPage.opacity(isOpaque ? 1 : (isDark ? 0.82 : 0.76)),
            cropBarFill: surface.opacity(isOpaque ? 1 : 0.94),
            border: Color.primary.opacity(increasedContrast ? 0.52 : 0.18),
            toolFill: definition.panel.tint.color.opacity(isOpaque ? 0.16 : 0.1),
            toolSelectedFill: definition.accent.color.opacity(isOpaque ? 0.9 : 0.82),
            toolText: definition.text.primary.color,
            toolSelectedText: definition.tooltip.text.color,
            toolBorder: definition.card.border.color.opacity(increasedContrast ? 1 : 0.78),
            primaryActionFill: definition.accent.color,
            primaryActionPressedFill: definition.accent.color.opacity(0.78),
            primaryActionText: definition.tooltip.text.color,
            selectionStroke: definition.accent.color,
            reduceMotion: reduceMotion,
            reduceTransparency: reduceTransparency,
            increasedContrast: increasedContrast,
            colorScheme: colorScheme
        )
    }
}

struct AnnotationEditorButtonStyle: ButtonStyle {
    enum Role {
        case tool(isSelected: Bool)
        case secondaryAction
        case primaryAction
    }

    let appearance: AnnotationEditorAppearance
    let role: Role

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(foreground)
            .frame(minWidth: minimumWidth, minHeight: 32)
            .padding(.horizontal, horizontalPadding)
            .background(fill(isPressed: configuration.isPressed), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(border, lineWidth: 1)
            }
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed && isEnabled ? 0.97 : 1)
            .animation(
                appearance.reduceMotion ? nil : .easeOut(duration: 0.14),
                value: configuration.isPressed
            )
    }

    private var foreground: Color {
        switch role {
        case .tool(let isSelected):
            isSelected ? appearance.toolSelectedText : appearance.toolText
        case .secondaryAction:
            appearance.toolText
        case .primaryAction:
            appearance.primaryActionText
        }
    }

    private var border: Color {
        switch role {
        case .tool(let isSelected) where isSelected:
            appearance.toolSelectedFill
        case .primaryAction:
            appearance.primaryActionFill
        default:
            appearance.toolBorder
        }
    }

    private var minimumWidth: CGFloat {
        switch role {
        case .tool:
            32
        case .secondaryAction, .primaryAction:
            0
        }
    }

    private var horizontalPadding: CGFloat {
        switch role {
        case .tool:
            0
        case .secondaryAction, .primaryAction:
            11
        }
    }

    private func fill(isPressed: Bool) -> Color {
        switch role {
        case .tool(let isSelected):
            if isSelected {
                return appearance.toolSelectedFill.opacity(isPressed ? 0.8 : 1)
            }
            return appearance.toolFill.opacity(isPressed ? 0.72 : 1)
        case .secondaryAction:
            return appearance.toolFill.opacity(isPressed ? 0.72 : 1)
        case .primaryAction:
            return isPressed ? appearance.primaryActionPressedFill : appearance.primaryActionFill
        }
    }
}

extension ButtonStyle where Self == AnnotationEditorButtonStyle {
    static func annotationEditorTool(
        appearance: AnnotationEditorAppearance,
        isSelected: Bool = false
    ) -> Self {
        .init(appearance: appearance, role: .tool(isSelected: isSelected))
    }

    static func annotationEditorSecondaryAction(
        appearance: AnnotationEditorAppearance
    ) -> Self {
        .init(appearance: appearance, role: .secondaryAction)
    }

    static func annotationEditorPrimaryAction(
        appearance: AnnotationEditorAppearance
    ) -> Self {
        .init(appearance: appearance, role: .primaryAction)
    }
}
