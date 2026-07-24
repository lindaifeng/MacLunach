import Foundation
import Testing
import TouchFeatureAPI
@testable import TouchCore

@Test func featureStorageIsBoundToOnePluginNamespace() throws {
    let suiteName = "FeatureStorageTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let factory = FeatureStorageFactory(defaults: defaults)
    let first = factory.makeStorage(pluginID: "me.touch.first")
    let second = factory.makeStorage(pluginID: "me.touch.second")
    let snapshot = FeatureConfigurationSnapshot(
        schemaVersion: 2,
        data: Data("first".utf8)
    )

    try first.saveConfiguration(snapshot)

    #expect(first.pluginID == "me.touch.first")
    #expect(try first.loadConfiguration() == snapshot)
    #expect(try second.loadConfiguration() == nil)
}

@Test func featureStorageBacksUpConfigurationWhenMigrationFails() throws {
    let suiteName = "FeatureStorageTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let instant = Date(timeIntervalSince1970: 1_234)
    let storage = FeatureStorageFactory(defaults: defaults, now: { instant })
        .makeStorage(pluginID: "me.touch.migrating")
    let snapshot = FeatureConfigurationSnapshot(
        schemaVersion: 1,
        data: Data("legacy".utf8)
    )
    try storage.saveConfiguration(snapshot)

    try storage.backupConfiguration(reason: "migration-failed")

    #expect(try storage.loadConfiguration() == nil)
    #expect(
        try storage.configurationBackups()
            == [
                .init(
                    createdAt: instant,
                    reason: "migration-failed",
                    snapshot: snapshot
                )
            ]
    )
}
