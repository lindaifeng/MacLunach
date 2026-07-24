import Foundation
import ScreenshotFeature
import TouchFeatureAPI

struct FinderFeatureConfiguration: Codable, Equatable, Sendable {
    var reuseExistingWindow: Bool

    init(reuseExistingWindow: Bool = true) {
        self.reuseExistingWindow = reuseExistingWindow
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        reuseExistingWindow = try values.decodeIfPresent(Bool.self, forKey: .reuseExistingWindow) ?? true
    }
}

struct FeatureConfigurations: Equatable, Sendable {
    var finder: FinderFeatureConfiguration
    var screenshot: ScreenshotFeatureConfiguration
}

struct FeatureConfigurationStore {
    static let finderID = "me.touch.finder"
    static let screenshotID = "me.touch.screenshot"

    private let defaults: UserDefaults
    private let now: () -> Date
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
    }

    func load() -> FeatureConfigurations {
        FeatureConfigurations(
            finder: load(FinderFeatureConfiguration.self, pluginID: Self.finderID) ?? .init(),
            screenshot: loadScreenshotConfiguration()
        )
    }

    func save(_ configuration: FinderFeatureConfiguration) throws {
        try save(configuration, pluginID: Self.finderID)
    }

    func save(_ configuration: ScreenshotFeatureConfiguration) throws {
        let envelope = ScreenshotConfigurationEnvelope(configuration: configuration)
        defaults.set(try encoder.encode(envelope), forKey: Self.storageKey(for: Self.screenshotID))
    }

    func handoffLegacyConfiguration(to storage: any FeatureStorage) throws {
        guard try storage.loadConfiguration() == nil else { return }
        let legacyKey = Self.storageKey(for: storage.pluginID)
        guard let data = defaults.data(forKey: legacyKey) else { return }

        try storage.saveConfiguration(.init(schemaVersion: 1, data: data))
        defaults.removeObject(forKey: legacyKey)
    }

    static let legacyScreenshotStorageKey = "me.touch.features.\(screenshotID).configuration.v1"

    static func storageKey(for pluginID: String) -> String {
        let version = pluginID == screenshotID ? 2 : 1
        return "me.touch.features.\(pluginID).configuration.v\(version)"
    }

    static func screenshotCorruptBackupKey(at date: Date) -> String {
        "me.touch.features.\(screenshotID).configuration.v2.corrupt.\(Int(date.timeIntervalSince1970))"
    }

    private func loadScreenshotConfiguration() -> ScreenshotFeatureConfiguration {
        let currentKey = Self.storageKey(for: Self.screenshotID)
        if let data = defaults.data(forKey: currentKey) {
            do {
                let envelope = try decoder.decode(ScreenshotConfigurationEnvelope.self, from: data)
                guard envelope.schemaVersion == ScreenshotConfigurationEnvelope.currentSchemaVersion else {
                    // A newer app may own this value. Preserve it so a downgrade cannot destroy user settings.
                    return .init()
                }
                return envelope.configuration
            } catch {
                defaults.set(data, forKey: Self.screenshotCorruptBackupKey(at: now()))
                defaults.removeObject(forKey: currentKey)
                return .init()
            }
        }

        guard let legacyData = defaults.data(forKey: Self.legacyScreenshotStorageKey) else {
            return .init()
        }
        do {
            let configuration = try decoder.decode(ScreenshotFeatureConfiguration.self, from: legacyData)
            try save(configuration)
            defaults.removeObject(forKey: Self.legacyScreenshotStorageKey)
            return configuration
        } catch {
            defaults.set(legacyData, forKey: Self.screenshotCorruptBackupKey(at: now()))
            defaults.removeObject(forKey: Self.legacyScreenshotStorageKey)
            return .init()
        }
    }

    private func load<Value: Decodable>(_ type: Value.Type, pluginID: String) -> Value? {
        guard let data = defaults.data(forKey: Self.storageKey(for: pluginID)) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    private func save<Value: Encodable>(_ value: Value, pluginID: String) throws {
        defaults.set(try encoder.encode(value), forKey: Self.storageKey(for: pluginID))
    }
}
