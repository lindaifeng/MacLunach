import Foundation

enum DayTheme {
    static let definition = ThemeDefinition(
        id: .day,
        displayName: "白天",
        panel: .init(
            material: .sidebar,
            effectOpacity: 1,
            gradient: .init(
                colors: [.init(hex: 0xF9FAFD), .init(hex: 0xF4F6FA), .init(hex: 0xEEF2F7)],
                direction: .topToBottom
            ),
            tint: .init(hex: 0xF8FAFD, opacity: 0.96),
            reflection: .init(hex: 0x8EB7EA, opacity: 0.045),
            fallback: .init(hex: 0xF8FAFD),
            border: .init(hex: 0xFFFFFF, opacity: 0.90),
            edgeBorder: .init(hex: 0xE2E6EE, opacity: 0.82),
            highlight: .init(hex: 0xFFFFFF, opacity: 0.96),
            cornerRadius: 30,
            shadow: .init(color: .init(hex: 0x1B2745, opacity: 0.08), radius: 28, x: 0, y: 18)
        ),
        search: .init(
            fill: .init(hex: 0xFFFFFF, opacity: 0.90),
            border: .init(hex: 0xE1E5ED),
            focusedBorder: .init(hex: 0x6680FF),
            focusRing: .init(hex: 0x6680FF, opacity: 0.11),
            placeholder: .init(hex: 0xA2A9B8),
            cornerRadius: 22,
            shadow: .init(color: .init(hex: 0x1B2745, opacity: 0.05), radius: 12, x: 0, y: 8)
        ),
        card: .init(
            fill: .init(hex: 0xFFFFFF),
            hoverFill: .init(hex: 0xFFFFFF),
            border: .init(hex: 0xE6E9F0),
            hoverBorder: .init(hex: 0xCDD5E6),
            selectedFill: .init(hex: 0x586DFF, opacity: 0.10),
            cornerRadius: 19,
            shadow: .init(color: .init(hex: 0x1B2745, opacity: 0.05), radius: 10, x: 0, y: 6),
            hoverShadow: .init(color: .init(hex: 0x1B2745, opacity: 0.10), radius: 16, x: 0, y: 10)
        ),
        text: .init(
            primary: .init(hex: 0x1D2330),
            secondary: .init(hex: 0x697184),
            weak: .init(hex: 0xA2A9B8),
            permission: .init(hex: 0xF28A2E),
            failure: .init(hex: 0xD9485F),
            success: .init(hex: 0x2EAD82)
        ),
        icon: .init(
            brandGradient: .init(
                colors: [.init(hex: 0x2454F5), .init(hex: 0x735BFF), .init(hex: 0xC96FEF)],
                direction: .topLeadingToBottomTrailing
            ),
            container: .init(hex: 0xEEF1FF),
            primary: .init(hex: 0x5C6FFF),
            secondary: .init(hex: 0x3F7CFF),
            neutral: .init(hex: 0x697184)
        ),
        shortcut: .init(
            fill: .init(hex: 0xF2F4F8),
            border: .init(hex: 0xE5E8EF),
            text: .init(hex: 0x687084),
            cornerRadius: 11
        ),
        tooltip: .init(
            fill: .init(hex: 0x1B1D23, opacity: 0.90),
            text: .init(hex: 0xFFFFFF, opacity: 0.96),
            shadow: .init(hex: 0x000000, opacity: 0.20)
        ),
        accent: .init(hex: 0x586DFF),
        auxiliaryAccent: .init(hex: 0x3F7CFF),
        interactiveAccent: .init(hex: 0x315F9D),
        motion: .init(duration: 0.19, hoverOffset: -2, pressedScale: 0.98)
    )
}
