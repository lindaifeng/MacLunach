import Testing
@testable import TouchCore

@Test func themesCycleInProductOrder() {
    #expect(TouchTheme.defaultGlass.next == .night)
    #expect(TouchTheme.night.next == .graphite)
    #expect(TouchTheme.graphite.next == .day)
    #expect(TouchTheme.day.next == .defaultGlass)
}

@Test func themeRoundTripsThroughRawValue() throws {
    for theme in TouchTheme.allCases {
        #expect(TouchTheme(rawValue: theme.rawValue) == theme)
    }
}

@Test func legacyThemeValuesMigrateToNewProductThemes() {
    #expect(TouchTheme(persistedValue: "crystal") == .defaultGlass)
    #expect(TouchTheme(persistedValue: "obsidian") == .night)
    #expect(TouchTheme(persistedValue: "graphite-gray") == .graphite)
    #expect(TouchTheme(persistedValue: "amber") == .day)
    #expect(TouchTheme(persistedValue: "unknown") == nil)
}
