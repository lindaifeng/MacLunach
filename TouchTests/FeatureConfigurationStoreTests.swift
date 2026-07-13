import Foundation
import XCTest
@testable import 触达

final class FeatureConfigurationStoreTests: XCTestCase {
    func testPluginConfigurationsRoundTripInIndependentNamespaces() throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = FeatureConfigurationStore(defaults: defaults)

        try store.save(FinderFeatureConfiguration(reuseExistingWindow: false))
        try store.save(ScreenshotFeatureConfiguration(copiesToClipboard: false))
        try store.save(SuperRightFeatureConfiguration(cutsFiles: false, createsFiles: false))

        let loaded = store.load()
        XCTAssertFalse(loaded.finder.reuseExistingWindow)
        XCTAssertFalse(loaded.screenshot.copiesToClipboard)
        XCTAssertTrue(loaded.screenshot.showsAnnotationToolbar)
        XCTAssertFalse(loaded.superRight.cutsFiles)
        XCTAssertFalse(loaded.superRight.createsFiles)
        XCTAssertNotEqual(
            FeatureConfigurationStore.storageKey(for: FeatureConfigurationStore.finderID),
            FeatureConfigurationStore.storageKey(for: FeatureConfigurationStore.screenshotID)
        )
    }

    func testCorruptPluginConfigurationFallsBackWithoutAffectingOtherPlugins() throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = FeatureConfigurationStore(defaults: defaults)
        try store.save(FinderFeatureConfiguration(reuseExistingWindow: false))
        defaults.set(
            Data("not-json".utf8),
            forKey: FeatureConfigurationStore.storageKey(for: FeatureConfigurationStore.screenshotID)
        )

        let loaded = store.load()

        XCTAssertFalse(loaded.finder.reuseExistingWindow)
        XCTAssertEqual(loaded.screenshot, ScreenshotFeatureConfiguration())
        XCTAssertEqual(loaded.superRight, SuperRightFeatureConfiguration())
    }

    func testOlderConfigurationGetsDefaultsForNewFields() throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            Data(#"{"copiesToClipboard":false}"#.utf8),
            forKey: FeatureConfigurationStore.storageKey(for: FeatureConfigurationStore.screenshotID)
        )

        let loaded = FeatureConfigurationStore(defaults: defaults).load().screenshot

        XCTAssertFalse(loaded.copiesToClipboard)
        XCTAssertTrue(loaded.showsAnnotationToolbar)
        XCTAssertTrue(loaded.showsPinAction)
    }

    @MainActor
    func testFeatureAreaStorePersistsVisibilityAndPluginSettings() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let first = FeatureAreaStore(defaults: defaults, plugins: [])

        first.setHidden(true, for: FeatureConfigurationStore.screenshotID)
        first.updateScreenshotConfiguration(\.copiesToClipboard, to: false)
        first.updateSuperRightConfiguration(\.createsFiles, to: false)

        let restored = FeatureAreaStore(defaults: defaults, plugins: [])
        XCTAssertTrue(restored.preferences.hidden.contains(FeatureConfigurationStore.screenshotID))
        XCTAssertFalse(restored.configurations.screenshot.copiesToClipboard)
        XCTAssertFalse(restored.configurations.superRight.createsFiles)
        XCTAssertTrue(restored.configurations.finder.reuseExistingWindow)
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "FeatureConfigurationStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}
