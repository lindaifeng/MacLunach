import AppKit
import SwiftUI
import TouchCore

struct ThemeColorToken: Equatable {
    let red: Double
    let green: Double
    let blue: Double
    let opacity: Double

    init(hex: UInt32, opacity: Double = 1) {
        red = Double((hex >> 16) & 0xFF) / 255
        green = Double((hex >> 8) & 0xFF) / 255
        blue = Double(hex & 0xFF) / 255
        self.opacity = opacity
    }

    var color: Color {
        Color(red: red, green: green, blue: blue, opacity: opacity)
    }

    var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: opacity)
    }
}

enum ThemeGradientDirection: Equatable {
    case topToBottom
    case topLeadingToBottomTrailing

    var startPoint: UnitPoint {
        switch self {
        case .topToBottom: .top
        case .topLeadingToBottomTrailing: .topLeading
        }
    }

    var endPoint: UnitPoint {
        switch self {
        case .topToBottom: .bottom
        case .topLeadingToBottomTrailing: .bottomTrailing
        }
    }
}

struct ThemeGradientToken: Equatable {
    let colors: [ThemeColorToken]
    let direction: ThemeGradientDirection

    var gradient: LinearGradient {
        LinearGradient(
            colors: colors.map(\.color),
            startPoint: direction.startPoint,
            endPoint: direction.endPoint
        )
    }
}

struct ThemeShadowToken: Equatable {
    let color: ThemeColorToken
    let radius: CGFloat
    let x: CGFloat
    let y: CGFloat
}

enum ThemeGlassMaterial: Equatable {
    case underWindowBackground
    case popover
    case hudWindow
    case sidebar
}

struct ThemePanelTokens: Equatable {
    let material: ThemeGlassMaterial
    let effectOpacity: Double
    let gradient: ThemeGradientToken
    let tint: ThemeColorToken
    let reflection: ThemeColorToken
    let fallback: ThemeColorToken
    let border: ThemeColorToken
    let edgeBorder: ThemeColorToken
    let highlight: ThemeColorToken
    let cornerRadius: CGFloat
    let shadow: ThemeShadowToken
}

struct ThemeSearchTokens: Equatable {
    let fill: ThemeColorToken
    let border: ThemeColorToken
    let focusedBorder: ThemeColorToken
    let focusRing: ThemeColorToken
    let placeholder: ThemeColorToken
    let cornerRadius: CGFloat
    let shadow: ThemeShadowToken
}

struct ThemeCardTokens: Equatable {
    let fill: ThemeColorToken
    let hoverFill: ThemeColorToken
    let border: ThemeColorToken
    let hoverBorder: ThemeColorToken
    let selectedFill: ThemeColorToken
    let cornerRadius: CGFloat
    let shadow: ThemeShadowToken
    let hoverShadow: ThemeShadowToken
}

struct ThemeTextTokens: Equatable {
    let primary: ThemeColorToken
    let secondary: ThemeColorToken
    let weak: ThemeColorToken
    let permission: ThemeColorToken
    let failure: ThemeColorToken
    let success: ThemeColorToken
}

struct ThemeIconTokens: Equatable {
    let brandGradient: ThemeGradientToken
    let container: ThemeColorToken
    let primary: ThemeColorToken
    let secondary: ThemeColorToken
    let neutral: ThemeColorToken
}

struct ThemeShortcutTokens: Equatable {
    let fill: ThemeColorToken
    let border: ThemeColorToken
    let text: ThemeColorToken
    let cornerRadius: CGFloat
}

struct ThemeTooltipTokens: Equatable {
    let fill: ThemeColorToken
    let text: ThemeColorToken
    let shadow: ThemeColorToken
}

struct ThemeMotionTokens: Equatable {
    let duration: Double
    let hoverOffset: CGFloat
    let pressedScale: CGFloat
}

struct ThemeDefinition: Identifiable, Equatable {
    let id: TouchTheme
    let displayName: String
    let panel: ThemePanelTokens
    let search: ThemeSearchTokens
    let card: ThemeCardTokens
    let text: ThemeTextTokens
    let icon: ThemeIconTokens
    let shortcut: ThemeShortcutTokens
    let tooltip: ThemeTooltipTokens
    let accent: ThemeColorToken
    let auxiliaryAccent: ThemeColorToken
    let motion: ThemeMotionTokens
}
