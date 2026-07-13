import Foundation

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

struct ScreenshotFeatureConfiguration: Codable, Equatable, Sendable {
    var showsAnnotationToolbar: Bool
    var copiesToClipboard: Bool
    var showsPinAction: Bool

    init(
        showsAnnotationToolbar: Bool = true,
        copiesToClipboard: Bool = true,
        showsPinAction: Bool = true
    ) {
        self.showsAnnotationToolbar = showsAnnotationToolbar
        self.copiesToClipboard = copiesToClipboard
        self.showsPinAction = showsPinAction
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        showsAnnotationToolbar = try values.decodeIfPresent(Bool.self, forKey: .showsAnnotationToolbar) ?? true
        copiesToClipboard = try values.decodeIfPresent(Bool.self, forKey: .copiesToClipboard) ?? true
        showsPinAction = try values.decodeIfPresent(Bool.self, forKey: .showsPinAction) ?? true
    }
}

struct SuperRightFeatureConfiguration: Codable, Equatable, Sendable {
    var opensTerminal: Bool
    var copiesFilePath: Bool
    var cutsFiles: Bool
    var createsFiles: Bool

    init(
        opensTerminal: Bool = true,
        copiesFilePath: Bool = true,
        cutsFiles: Bool = true,
        createsFiles: Bool = true
    ) {
        self.opensTerminal = opensTerminal
        self.copiesFilePath = copiesFilePath
        self.cutsFiles = cutsFiles
        self.createsFiles = createsFiles
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        opensTerminal = try values.decodeIfPresent(Bool.self, forKey: .opensTerminal) ?? true
        copiesFilePath = try values.decodeIfPresent(Bool.self, forKey: .copiesFilePath) ?? true
        cutsFiles = try values.decodeIfPresent(Bool.self, forKey: .cutsFiles) ?? true
        createsFiles = try values.decodeIfPresent(Bool.self, forKey: .createsFiles) ?? true
    }
}

struct FeatureConfigurations: Equatable, Sendable {
    var finder: FinderFeatureConfiguration
    var screenshot: ScreenshotFeatureConfiguration
    var superRight: SuperRightFeatureConfiguration
}

struct FeatureConfigurationStore {
    static let finderID = "me.touch.finder"
    static let screenshotID = "me.touch.screenshot"
    static let superRightID = "me.touch.super-right"

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> FeatureConfigurations {
        FeatureConfigurations(
            finder: load(FinderFeatureConfiguration.self, pluginID: Self.finderID) ?? .init(),
            screenshot: load(ScreenshotFeatureConfiguration.self, pluginID: Self.screenshotID) ?? .init(),
            superRight: load(SuperRightFeatureConfiguration.self, pluginID: Self.superRightID) ?? .init()
        )
    }

    func save(_ configuration: FinderFeatureConfiguration) throws {
        try save(configuration, pluginID: Self.finderID)
    }

    func save(_ configuration: ScreenshotFeatureConfiguration) throws {
        try save(configuration, pluginID: Self.screenshotID)
    }

    func save(_ configuration: SuperRightFeatureConfiguration) throws {
        try save(configuration, pluginID: Self.superRightID)
    }

    static func storageKey(for pluginID: String) -> String {
        "me.touch.features.\(pluginID).configuration.v1"
    }

    private func load<Value: Decodable>(_ type: Value.Type, pluginID: String) -> Value? {
        guard let data = defaults.data(forKey: Self.storageKey(for: pluginID)) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    private func save<Value: Encodable>(_ value: Value, pluginID: String) throws {
        defaults.set(try encoder.encode(value), forKey: Self.storageKey(for: pluginID))
    }
}
