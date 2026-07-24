import Foundation

enum NightTheme {
    static let definition = ThemeDefinition(
        id: .night,
        displayName: "黑夜",
        panel: .init(
            material: .hudWindow,
            effectOpacity: 1,
            gradient: .init(
                colors: [.init(hex: 0x151824), .init(hex: 0x0E111A), .init(hex: 0x090B11)],
                direction: .topToBottom
            ),
            tint: .init(hex: 0x0C0F18, opacity: 0.96),
            reflection: .init(hex: 0x7C6CFF, opacity: 0.055),
            fallback: .init(hex: 0x0C0F18),
            border: .init(hex: 0xFFFFFF, opacity: 0.09),
            edgeBorder: .init(hex: 0x7C6CFF, opacity: 0.16),
            highlight: .init(hex: 0xFFFFFF, opacity: 0.10),
            cornerRadius: 30,
            shadow: .init(color: .init(hex: 0x000000, opacity: 0.48), radius: 38, x: 0, y: 26)
        ),
        search: .init(
            fill: .init(hex: 0x151925),
            border: .init(hex: 0xFFFFFF, opacity: 0.08),
            focusedBorder: .init(hex: 0x6C7CFF),
            focusRing: .init(hex: 0x6C7CFF, opacity: 0.12),
            placeholder: .init(hex: 0x626878),
            cornerRadius: 22,
            shadow: .init(color: .init(hex: 0x000000, opacity: 0.20), radius: 12, x: 0, y: 8)
        ),
        card: .init(
            fill: .init(hex: 0x151925),
            hoverFill: .init(hex: 0x1B2030),
            border: .init(hex: 0xFFFFFF, opacity: 0.07),
            hoverBorder: .init(hex: 0x7C6CFF, opacity: 0.45),
            selectedFill: .init(hex: 0x7C6CFF, opacity: 0.16),
            cornerRadius: 19,
            shadow: .init(color: .init(hex: 0x000000, opacity: 0.12), radius: 10, x: 0, y: 6),
            hoverShadow: .init(color: .init(hex: 0x000000, opacity: 0.22), radius: 14, x: 0, y: 9)
        ),
        text: .init(
            primary: .init(hex: 0xF7F8FC),
            secondary: .init(hex: 0x9EA4B5),
            weak: .init(hex: 0x626878),
            permission: .init(hex: 0xFF9A3D),
            failure: .init(hex: 0xFF667A),
            success: .init(hex: 0x4ED5A5)
        ),
        icon: .init(
            brandGradient: .init(
                colors: [.init(hex: 0x78A7FF), .init(hex: 0x9B78FF), .init(hex: 0xE1A0FF)],
                direction: .topLeadingToBottomTrailing
            ),
            container: .init(hex: 0x23284B),
            primary: .init(hex: 0x8A86FF),
            secondary: .init(hex: 0x69A6FF),
            neutral: .init(hex: 0x9EA4B5)
        ),
        shortcut: .init(
            fill: .init(hex: 0x232735),
            border: .init(hex: 0xFFFFFF, opacity: 0.06),
            text: .init(hex: 0xC5C9D6),
            cornerRadius: 11
        ),
        tooltip: .init(
            fill: .init(hex: 0x242731, opacity: 0.94),
            text: .init(hex: 0xFFFFFF, opacity: 0.96),
            shadow: .init(hex: 0x000000, opacity: 0.34)
        ),
        accent: .init(hex: 0x7C6CFF),
        auxiliaryAccent: .init(hex: 0x579DFF),
        motion: .init(duration: 0.17, hoverOffset: -2, pressedScale: 0.98)
    )
}

/// 参考截图工作台的中性深灰主题。它刻意避开纯黑和高饱和紫色大面积铺陈，
/// 主要依靠石墨背景、稍亮卡片和克制阴影建立层级。
enum GraphiteTheme {
    static let definition = ThemeDefinition(
        id: .graphite,
        displayName: "石墨灰",
        panel: .init(
            material: .hudWindow,
            effectOpacity: 1,
            gradient: .init(
                colors: [.init(hex: 0x555555), .init(hex: 0x494949), .init(hex: 0x414141)],
                direction: .topToBottom
            ),
            tint: .init(hex: 0x484848, opacity: 0.94),
            reflection: .init(hex: 0xFFFFFF, opacity: 0.035),
            fallback: .init(hex: 0x484848),
            border: .init(hex: 0xFFFFFF, opacity: 0.10),
            edgeBorder: .init(hex: 0xFFFFFF, opacity: 0.14),
            highlight: .init(hex: 0xFFFFFF, opacity: 0.11),
            cornerRadius: 28,
            shadow: .init(color: .init(hex: 0x000000, opacity: 0.38), radius: 30, x: 0, y: 20)
        ),
        search: .init(
            fill: .init(hex: 0x5A5A5A),
            border: .init(hex: 0xFFFFFF, opacity: 0.08),
            focusedBorder: .init(hex: 0xFFFFFF, opacity: 0.52),
            focusRing: .init(hex: 0xFFFFFF, opacity: 0.08),
            placeholder: .init(hex: 0xB2B2B2),
            cornerRadius: 18,
            shadow: .init(color: .init(hex: 0x000000, opacity: 0.16), radius: 10, x: 0, y: 6)
        ),
        card: .init(
            fill: .init(hex: 0x575757),
            hoverFill: .init(hex: 0x606060),
            border: .init(hex: 0xFFFFFF, opacity: 0.075),
            hoverBorder: .init(hex: 0xFFFFFF, opacity: 0.15),
            selectedFill: .init(hex: 0xFFFFFF, opacity: 0.11),
            cornerRadius: 17,
            shadow: .init(color: .init(hex: 0x000000, opacity: 0.14), radius: 9, x: 0, y: 5),
            hoverShadow: .init(color: .init(hex: 0x000000, opacity: 0.22), radius: 13, x: 0, y: 8)
        ),
        text: .init(
            primary: .init(hex: 0xF5F5F5),
            secondary: .init(hex: 0xC0C0C0),
            weak: .init(hex: 0x929292),
            permission: .init(hex: 0xFFB15C),
            failure: .init(hex: 0xFF7A86),
            // 石墨工作台参考 macOS 深色外观的系统绿色，用于紧凑成功提示。
            success: .init(hex: 0x32D74B)
        ),
        icon: .init(
            brandGradient: .init(
                colors: [.init(hex: 0xFFFFFF), .init(hex: 0xECECEC), .init(hex: 0xCFCFCF)],
                direction: .topLeadingToBottomTrailing
            ),
            container: .init(hex: 0x606060),
            primary: .init(hex: 0xF0F0F0),
            secondary: .init(hex: 0xD0D0D0),
            neutral: .init(hex: 0xC0C0C0)
        ),
        shortcut: .init(
            fill: .init(hex: 0x626262),
            border: .init(hex: 0xFFFFFF, opacity: 0.08),
            text: .init(hex: 0xE2E2E2),
            cornerRadius: 10
        ),
        tooltip: .init(
            fill: .init(hex: 0x2F2F2F, opacity: 0.96),
            text: .init(hex: 0xFFFFFF, opacity: 0.96),
            shadow: .init(hex: 0x000000, opacity: 0.30)
        ),
        accent: .init(hex: 0xF2F2F2),
        auxiliaryAccent: .init(hex: 0xCFCFCF),
        motion: .init(duration: 0.16, hoverOffset: -1, pressedScale: 0.985)
    )
}
