import Foundation
import ScreenshotFeature
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

    func testLegacyScreenshotConfigurationMigratesToVersionTwoEnvelope() throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            Data(#"{"copiesToClipboard":false}"#.utf8),
            forKey: FeatureConfigurationStore.legacyScreenshotStorageKey
        )
        let store = FeatureConfigurationStore(
            defaults: defaults,
            now: { Date(timeIntervalSince1970: 1_789_000_000) }
        )

        let loaded = store.load().screenshot

        XCTAssertFalse(loaded.copiesToClipboard)
        XCTAssertEqual(loaded.history.retentionDays, 30)
        XCTAssertNil(defaults.data(forKey: FeatureConfigurationStore.legacyScreenshotStorageKey))
        XCTAssertNotNil(
            defaults.data(forKey: FeatureConfigurationStore.storageKey(for: FeatureConfigurationStore.screenshotID))
        )
    }

    func testCorruptVersionTwoScreenshotConfigurationIsBackedUpWithoutAffectingFinder() throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let now = Date(timeIntervalSince1970: 1_789_000_000)
        let store = FeatureConfigurationStore(defaults: defaults, now: { now })
        try store.save(FinderFeatureConfiguration(reuseExistingWindow: false))
        let corrupt = Data("not-json".utf8)
        defaults.set(
            corrupt,
            forKey: FeatureConfigurationStore.storageKey(for: FeatureConfigurationStore.screenshotID)
        )

        let loaded = store.load()

        XCTAssertFalse(loaded.finder.reuseExistingWindow)
        XCTAssertEqual(loaded.screenshot, ScreenshotFeatureConfiguration())
        let currentKey = FeatureConfigurationStore.storageKey(for: FeatureConfigurationStore.screenshotID)
        let backupKey = FeatureConfigurationStore.screenshotCorruptBackupKey(at: now)
        XCTAssertEqual(defaults.data(forKey: backupKey), corrupt)
        XCTAssertNil(defaults.data(forKey: currentKey))

        _ = store.load()
        XCTAssertEqual(defaults.data(forKey: backupKey), corrupt)
        XCTAssertNil(defaults.data(forKey: currentKey))
    }

    func testFutureScreenshotSchemaIsPreservedWithoutBeingMarkedCorrupt() throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let now = Date(timeIntervalSince1970: 1_789_000_000)
        let currentKey = FeatureConfigurationStore.storageKey(for: FeatureConfigurationStore.screenshotID)
        let futureEnvelope = ScreenshotConfigurationEnvelope(
            schemaVersion: ScreenshotConfigurationEnvelope.currentSchemaVersion + 1,
            configuration: ScreenshotFeatureConfiguration(copiesToClipboard: false)
        )
        let futureData = try JSONEncoder().encode(futureEnvelope)
        defaults.set(futureData, forKey: currentKey)

        let loaded = FeatureConfigurationStore(defaults: defaults, now: { now }).load().screenshot

        XCTAssertEqual(loaded, ScreenshotFeatureConfiguration())
        XCTAssertEqual(defaults.data(forKey: currentKey), futureData)
        XCTAssertNil(
            defaults.data(forKey: FeatureConfigurationStore.screenshotCorruptBackupKey(at: now))
        )
    }

    func testCorruptLegacyScreenshotConfigurationIsBackedUpThenRemoved() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let now = Date(timeIntervalSince1970: 1_789_000_000)
        let corrupt = Data("legacy-not-json".utf8)
        defaults.set(corrupt, forKey: FeatureConfigurationStore.legacyScreenshotStorageKey)

        let loaded = FeatureConfigurationStore(defaults: defaults, now: { now }).load().screenshot

        XCTAssertEqual(loaded, ScreenshotFeatureConfiguration())
        XCTAssertEqual(
            defaults.data(forKey: FeatureConfigurationStore.screenshotCorruptBackupKey(at: now)),
            corrupt
        )
        XCTAssertNil(defaults.data(forKey: FeatureConfigurationStore.legacyScreenshotStorageKey))
    }

    func testOlderConfigurationGetsDefaultsForNewFields() throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            Data(#"{"copiesToClipboard":false}"#.utf8),
            forKey: FeatureConfigurationStore.legacyScreenshotStorageKey
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
