import XCTest
import TouchCore
@testable import 触达

final class ThemeRegistryTests: XCTestCase {
    func testDefaultRegistryCoversEveryThemeExactlyOnce() {
        let definitions = ThemeRegistry.shared.allDefinitions

        XCTAssertEqual(definitions.count, TouchTheme.allCases.count)
        XCTAssertEqual(Set(definitions.map(\.id)), Set(TouchTheme.allCases))
    }

    func testDefinitionsKeepThemeSpecificSemanticValuesIsolated() {
        let registry = ThemeRegistry.shared
        let glass = registry.definition(for: .defaultGlass)
        let night = registry.definition(for: .night)
        let graphite = registry.definition(for: .graphite)
        let day = registry.definition(for: .day)

        XCTAssertEqual(glass.panel.tint.opacity, 0.38, accuracy: 0.001)
        XCTAssertEqual(glass.panel.effectOpacity, 0.86, accuracy: 0.001)
        XCTAssertEqual(night.panel.tint.opacity, 0.96, accuracy: 0.001)
        XCTAssertEqual(graphite.panel.tint.opacity, 0.94, accuracy: 0.001)
        XCTAssertEqual(day.panel.tint.opacity, 0.96, accuracy: 0.001)
        XCTAssertNotEqual(glass.accent, night.accent)
        XCTAssertNotEqual(night.accent, graphite.accent)
        XCTAssertNotEqual(night.accent, day.accent)
    }

    func testDefaultGlassFeatureIconMatchesSelectedSearchModeColor() {
        let glass = ThemeRegistry.shared.definition(for: .defaultGlass)

        XCTAssertEqual(glass.icon.primary, glass.accent)
    }
}
