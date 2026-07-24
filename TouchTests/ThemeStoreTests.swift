import XCTest
import TouchCore
@testable import 触达

final class ThemeStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "ThemeStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    @MainActor
    func testMigratesLegacyThemeAndPersistsNewIdentifier() {
        defaults.set("amber", forKey: ThemeStore.legacyStorageKey)

        let store = ThemeStore(defaults: defaults, arguments: [])

        XCTAssertEqual(store.theme, .day)
        XCTAssertEqual(defaults.string(forKey: ThemeStore.storageKey), "day")
    }

    @MainActor
    func testCommandLineAcceptsCurrentAndLegacyIdentifiers() {
        XCTAssertEqual(
            ThemeStore(defaults: defaults, arguments: ["--appearance-theme=night"]).theme,
            .night
        )
        XCTAssertEqual(
            ThemeStore(defaults: defaults, arguments: ["--appearance-theme=crystal"]).theme,
            .defaultGlass
        )
    }

    @MainActor
    func testUnknownThemeFallsBackToDefault() {
        defaults.set("missing-theme", forKey: ThemeStore.storageKey)
        XCTAssertEqual(ThemeStore(defaults: defaults, arguments: []).theme, .defaultGlass)
    }

    @MainActor
    func testThemeColorOpacityDefaultsToFullStrengthAndPersistsUpdates() {
        let store = ThemeStore(defaults: defaults, arguments: [])

        XCTAssertEqual(store.themeColorOpacity, 1, accuracy: 0.001)

        store.setThemeColorOpacity(0.62)

        XCTAssertEqual(store.themeColorOpacity, 0.62, accuracy: 0.001)
        XCTAssertEqual(
            defaults.double(forKey: ThemeStore.themeColorOpacityStorageKey),
            0.62,
            accuracy: 0.001
        )
        XCTAssertEqual(
            ThemeStore(defaults: defaults, arguments: []).themeColorOpacity,
            0.62,
            accuracy: 0.001
        )
    }

    @MainActor
    func testThemeColorOpacityClampsToSupportedRange() {
        let store = ThemeStore(defaults: defaults, arguments: [])

        store.setThemeColorOpacity(-0.5)
        XCTAssertEqual(store.themeColorOpacity, 0, accuracy: 0.001)

        store.setThemeColorOpacity(1.5)
        XCTAssertEqual(store.themeColorOpacity, 1, accuracy: 0.001)
    }
}
