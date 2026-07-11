import Testing
@testable import TouchCore

@Test func themesCycleInProductOrder() {
    #expect(TouchTheme.crystal.next == .obsidian)
    #expect(TouchTheme.obsidian.next == .amber)
    #expect(TouchTheme.amber.next == .crystal)
}

@Test func themeRoundTripsThroughRawValue() throws {
    for theme in TouchTheme.allCases {
        #expect(TouchTheme(rawValue: theme.rawValue) == theme)
    }
}
