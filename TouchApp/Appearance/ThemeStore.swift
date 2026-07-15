import Foundation
import SwiftUI
import TouchCore

@MainActor
final class ThemeStore: ObservableObject {
    static let storageKey = "appearance.theme.v1"

    @Published private(set) var theme: TouchTheme
    private let defaults: UserDefaults

    init(
        defaults: UserDefaults = .standard,
        arguments: [String] = CommandLine.arguments
    ) {
        self.defaults = defaults
        theme = Self.themeOverride(in: arguments)
            ?? defaults.string(forKey: Self.storageKey).flatMap(TouchTheme.init(rawValue:))
            ?? .crystal
    }

    func cycle() {
        theme = theme.next
        defaults.set(theme.rawValue, forKey: Self.storageKey)
    }

    private static func themeOverride(in arguments: [String]) -> TouchTheme? {
        let prefix = "--appearance-theme="
        return arguments.first(where: { $0.hasPrefix(prefix) })
            .map { String($0.dropFirst(prefix.count)) }
            .flatMap(TouchTheme.init(rawValue:))
    }
}

struct ThemePalette {
    let tint: Color
    let accent: Color
    let primaryText: Color
    let secondaryText: Color
    let cardFill: Color
    let border: Color

    static func palette(for theme: TouchTheme) -> Self {
        switch theme {
        case .crystal:
            .init(
                tint: Color(red: 0.30, green: 0.42, blue: 0.68).opacity(0.24),
                accent: Color(red: 0.42, green: 0.45, blue: 1.00),
                primaryText: .white,
                secondaryText: .white.opacity(0.64),
                cardFill: .white.opacity(0.13),
                border: .white.opacity(0.32)
            )
        case .obsidian:
            .init(
                tint: Color(red: 0.02, green: 0.04, blue: 0.09).opacity(0.68),
                accent: Color(red: 0.31, green: 0.51, blue: 1.00),
                primaryText: .white,
                secondaryText: .white.opacity(0.62),
                cardFill: .black.opacity(0.25),
                border: Color(red: 0.36, green: 0.55, blue: 1.00).opacity(0.42)
            )
        case .amber:
            .init(
                tint: Color(red: 0.54, green: 0.31, blue: 0.25).opacity(0.35),
                accent: Color(red: 0.82, green: 0.66, blue: 0.92),
                primaryText: .white,
                secondaryText: .white.opacity(0.68),
                cardFill: .white.opacity(0.14),
                border: Color(red: 1.00, green: 0.86, blue: 0.73).opacity(0.42)
            )
        }
    }
}
