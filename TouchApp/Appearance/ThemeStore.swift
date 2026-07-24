import Foundation
import TouchCore

@MainActor
final class ThemeStore: ObservableObject {
    static let storageKey = "appearance.theme.v2"
    static let legacyStorageKey = "appearance.theme.v1"
    static let themeColorOpacityStorageKey = "appearance.theme-color-opacity.v1"
    static let themeColorOpacityRange: ClosedRange<Double> = 0...1

    @Published private(set) var theme: TouchTheme
    @Published private(set) var themeColorOpacity: Double
    private let defaults: UserDefaults

    init(
        defaults: UserDefaults = .standard,
        arguments: [String] = CommandLine.arguments
    ) {
        self.defaults = defaults
        themeColorOpacity = Self.storedThemeColorOpacity(in: defaults)
        if let override = Self.themeOverride(in: arguments) {
            theme = override
        } else if let stored = defaults.string(forKey: Self.storageKey)
            .flatMap({ TouchTheme(persistedValue: $0) }) {
            theme = stored
        } else if let legacy = defaults.string(forKey: Self.legacyStorageKey)
            .flatMap({ TouchTheme(persistedValue: $0) }) {
            theme = legacy
            defaults.set(legacy.rawValue, forKey: Self.storageKey)
        } else {
            theme = .defaultGlass
        }
    }

    func cycle() {
        theme = theme.next
        defaults.set(theme.rawValue, forKey: Self.storageKey)
    }

    func select(_ theme: TouchTheme) {
        self.theme = theme
        defaults.set(theme.rawValue, forKey: Self.storageKey)
    }

    func setThemeColorOpacity(_ opacity: Double) {
        themeColorOpacity = Self.clampedThemeColorOpacity(opacity)
        defaults.set(themeColorOpacity, forKey: Self.themeColorOpacityStorageKey)
    }

    static func themeOverride(in arguments: [String]) -> TouchTheme? {
        let prefix = "--appearance-theme="
        return arguments.first(where: { $0.hasPrefix(prefix) })
            .map { String($0.dropFirst(prefix.count)) }
            .flatMap { TouchTheme(persistedValue: $0) }
    }

    private static func storedThemeColorOpacity(in defaults: UserDefaults) -> Double {
        guard let number = defaults.object(forKey: themeColorOpacityStorageKey) as? NSNumber else {
            return themeColorOpacityRange.upperBound
        }
        return clampedThemeColorOpacity(number.doubleValue)
    }

    private static func clampedThemeColorOpacity(_ opacity: Double) -> Double {
        guard opacity.isFinite else { return themeColorOpacityRange.upperBound }
        return min(max(opacity, themeColorOpacityRange.lowerBound), themeColorOpacityRange.upperBound)
    }
}
