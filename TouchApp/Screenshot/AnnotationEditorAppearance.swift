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
        reduceTransparency: Bool,
        increasedContrast: Bool
    ) -> Self {
        let base = ThemePalette.palette(for: theme)
        let tintColor: Color
        let themeName: String
        switch theme {
        case .crystal:
            tintColor = Color(red: 0.36, green: 0.48, blue: 0.94)
            themeName = "晶透毛玻璃"
        case .obsidian:
            tintColor = Color(red: 0.08, green: 0.16, blue: 0.34)
            themeName = "曜石深色玻璃"
        case .amber:
            tintColor = Color(red: 0.70, green: 0.36, blue: 0.20)
            themeName = "暖色烟熏玻璃"
        }

        let isDark = colorScheme == .dark
        let isOpaque = reduceTransparency || increasedContrast
        let surface = Color(nsColor: .controlBackgroundColor)
        let underPage = Color(nsColor: .underPageBackgroundColor)
        let chromeOpacity = isOpaque ? 1.0 : (isDark ? 0.78 : 0.72)
        let inspectorOpacity = isOpaque ? 1.0 : (isDark ? 0.88 : 0.82)
        let tintOpacity: Double = switch (theme, isDark, isOpaque) {
        case (.crystal, true, _): 0.16
        case (.crystal, false, _): 0.08
        case (.obsidian, true, _): 0.34
        case (.obsidian, false, _): 0.12
        case (.amber, true, _): 0.20
        case (.amber, false, _): 0.10
        }

        return .init(
            theme: theme,
            themeName: themeName,
            accent: base.accent,
            tintOverlay: tintColor.opacity(tintOpacity),
            chromeFill: surface.opacity(chromeOpacity),
            inspectorFill: surface.opacity(inspectorOpacity),
            canvasFill: underPage.opacity(isOpaque ? 1 : (isDark ? 0.82 : 0.76)),
            cropBarFill: surface.opacity(isOpaque ? 1 : 0.94),
            border: Color.primary.opacity(increasedContrast ? 0.52 : 0.18),
            reduceTransparency: reduceTransparency,
            increasedContrast: increasedContrast,
            colorScheme: colorScheme
        )
    }
}
