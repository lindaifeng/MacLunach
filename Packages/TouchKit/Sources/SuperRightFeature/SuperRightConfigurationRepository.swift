import Foundation
import TouchFeatureAPI

public struct SuperRightConfigurationRepository: Sendable {
    public static let schemaVersion = 3

    private let storage: any FeatureStorage

    public init(storage: any FeatureStorage) {
        self.storage = storage
    }

    public func load() throws -> SuperRightFeatureConfiguration {
        guard let snapshot = try storage.loadConfiguration() else {
            return .init()
        }

        switch snapshot.schemaVersion {
        case Self.schemaVersion:
            return try JSONDecoder().decode(
                SuperRightFeatureConfiguration.self,
                from: snapshot.data
            )
        case 2:
            do {
                let legacy = try JSONDecoder().decode(LegacyV2Configuration.self, from: snapshot.data)
                let migrated = SuperRightFeatureConfiguration(
                    actions: legacy.actions,
                    fileFormats: legacy.fileFormats
                )
                try save(migrated)
                return migrated
            } catch is DecodingError {
                try storage.backupConfiguration(reason: "migration-failed")
                let fallback = SuperRightFeatureConfiguration()
                try save(fallback)
                return fallback
            }
        case 1:
            do {
                let legacy = try JSONDecoder().decode(LegacyConfiguration.self, from: snapshot.data)
                let migrated = SuperRightFeatureConfiguration(
                    actions: [
                        .init(id: .newFile, isEnabled: legacy.createsFiles),
                        .init(id: .newFolder, isEnabled: true),
                        .init(id: .cut, isEnabled: legacy.cutsFiles),
                        .init(id: .copyPath, isEnabled: legacy.copiesFilePath),
                        .init(id: .openTerminal, isEnabled: legacy.opensTerminal)
                    ]
                )
                try save(migrated)
                return migrated
            } catch is DecodingError {
                try storage.backupConfiguration(reason: "migration-failed")
                let fallback = SuperRightFeatureConfiguration()
                try save(fallback)
                return fallback
            }
        default:
            return .init()
        }
    }

    public func save(_ configuration: SuperRightFeatureConfiguration) throws {
        try storage.saveConfiguration(
            .init(
                schemaVersion: Self.schemaVersion,
                data: try JSONEncoder().encode(configuration)
            )
        )
    }
}

private struct LegacyConfiguration: Decodable {
    let opensTerminal: Bool
    let copiesFilePath: Bool
    let cutsFiles: Bool
    let createsFiles: Bool
}

private struct LegacyV2Configuration: Decodable {
    let actions: [SuperRightActionConfiguration]
    let fileFormats: [NewFileFormatDefinition]
}
