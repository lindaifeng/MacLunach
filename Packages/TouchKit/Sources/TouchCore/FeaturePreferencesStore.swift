import Foundation

public struct FeaturePreferencesStore {
    public static let storageKey = "feature-area.preferences.v1"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public func load() throws -> FeaturePreferences {
        guard let data = defaults.data(forKey: Self.storageKey) else {
            return .init()
        }

        return try JSONDecoder().decode(FeaturePreferences.self, from: data)
    }

    public func save(_ value: FeaturePreferences) throws {
        defaults.set(try JSONEncoder().encode(value), forKey: Self.storageKey)
    }
}
