import Foundation

enum DefaultGlassTheme {
    static let definition = ThemeDefinition(
        id: .defaultGlass,
        displayName: "默认高级毛玻璃",
        panel: .init(
            material: .popover,
            effectOpacity: 0.86,
            gradient: .init(
                colors: [
                    .init(hex: 0xF4F7FA, opacity: 0.18),
                    .init(hex: 0xDCE3EB, opacity: 0.12),
                    .init(hex: 0xAEBECE, opacity: 0.08)
                ],
                direction: .topLeadingToBottomTrailing
            ),
            tint: .init(hex: 0xECF1F8, opacity: 0.38),
            reflection: .init(hex: 0xFFE0CD, opacity: 0.10),
            fallback: .init(hex: 0xECF1F8, opacity: 0.94),
            border: .init(hex: 0xFFFFFF, opacity: 0.68),
            edgeBorder: .init(hex: 0x74879B, opacity: 0.18),
            highlight: .init(hex: 0xFFFFFF, opacity: 0.75),
            cornerRadius: 32,
            shadow: .init(color: .init(hex: 0x2C3B4E, opacity: 0.16), radius: 32, x: 0, y: 24)
        ),
        search: .init(
            fill: .init(hex: 0xFFFFFF, opacity: 0.26),
            border: .init(hex: 0xFFFFFF, opacity: 0.62),
            focusedBorder: .init(hex: 0x748CFF, opacity: 0.72),
            focusRing: .init(hex: 0x748CFF, opacity: 0.10),
            placeholder: .init(hex: 0x4C5767, opacity: 0.46),
            cornerRadius: 23,
            shadow: .init(color: .init(hex: 0x495B73, opacity: 0.08), radius: 12, x: 0, y: 8)
        ),
        card: .init(
            fill: .init(hex: 0xFFFFFF, opacity: 0.28),
            hoverFill: .init(hex: 0xFFFFFF, opacity: 0.38),
            border: .init(hex: 0xFFFFFF, opacity: 0.65),
            hoverBorder: .init(hex: 0xFFFFFF, opacity: 0.78),
            selectedFill: .init(hex: 0x748CFF, opacity: 0.12),
            cornerRadius: 19,
            shadow: .init(color: .init(hex: 0x34455A, opacity: 0.10), radius: 14, x: 0, y: 10),
            hoverShadow: .init(color: .init(hex: 0x34455A, opacity: 0.15), radius: 18, x: 0, y: 12)
        ),
        text: .init(
            primary: .init(hex: 0x303846),
            secondary: .init(hex: 0x697687),
            weak: .init(hex: 0x485464, opacity: 0.48),
            permission: .init(hex: 0xF28B32),
            failure: .init(hex: 0xD9485F),
            success: .init(hex: 0x2EAD82)
        ),
        icon: .init(
            brandGradient: .init(
                colors: [.init(hex: 0x4F80FF), .init(hex: 0x7E78F5), .init(hex: 0xC88EF1)],
                direction: .topLeadingToBottomTrailing
            ),
            container: .init(hex: 0xFFFFFF, opacity: 0.40),
            primary: .init(hex: 0x748CFF),
            secondary: .init(hex: 0x7C82E8),
            neutral: .init(hex: 0x637185)
        ),
        shortcut: .init(
            fill: .init(hex: 0xFFFFFF, opacity: 0.34),
            border: .init(hex: 0xFFFFFF, opacity: 0.52),
            text: .init(hex: 0x596677),
            cornerRadius: 11
        ),
        tooltip: .init(
            fill: .init(hex: 0x1B1D23, opacity: 0.90),
            text: .init(hex: 0xFFFFFF, opacity: 0.96),
            shadow: .init(hex: 0x000000, opacity: 0.22)
        ),
        accent: .init(hex: 0x748CFF),
        auxiliaryAccent: .init(hex: 0x8EB7EA),
        interactiveAccent: .init(hex: 0x4A74C9),
        motion: .init(duration: 0.19, hoverOffset: -2, pressedScale: 0.98)
    )
}
