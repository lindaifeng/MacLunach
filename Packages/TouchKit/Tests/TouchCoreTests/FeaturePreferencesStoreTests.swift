import Foundation
import Testing
import TouchFeatureAPI
@testable import TouchCore

@Test func preferencesRoundTripWithoutTouchingOtherSuite() throws {
    let suiteName = "FeaturePreferencesStoreTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let store = FeaturePreferencesStore(defaults: defaults)
    let value = FeaturePreferences(
        order: ["screenshot", "finder"],
        hidden: ["finder"],
        shortcuts: ["screenshot": .init(modifiers: [.command], key: "2")]
    )

    try store.save(value)

    #expect(try store.load() == value)
    #expect(UserDefaults.standard.data(forKey: FeaturePreferencesStore.storageKey) == nil)
}
