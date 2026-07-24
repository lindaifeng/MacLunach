import Foundation

public struct FeatureConfigurationSnapshot: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let data: Data

    public init(schemaVersion: Int, data: Data) {
        self.schemaVersion = schemaVersion
        self.data = data
    }
}

public struct FeatureConfigurationBackup: Codable, Equatable, Sendable {
    public let createdAt: Date
    public let reason: String
    public let snapshot: FeatureConfigurationSnapshot

    public init(
        createdAt: Date,
        reason: String,
        snapshot: FeatureConfigurationSnapshot
    ) {
        self.createdAt = createdAt
        self.reason = reason
        self.snapshot = snapshot
    }
}

public protocol FeatureStorage: Sendable {
    var pluginID: String { get }

    func loadConfiguration() throws -> FeatureConfigurationSnapshot?
    func saveConfiguration(_ snapshot: FeatureConfigurationSnapshot) throws
    func backupConfiguration(reason: String) throws
    func configurationBackups() throws -> [FeatureConfigurationBackup]
    func resetConfiguration() throws
}

public enum FeatureStorageError: Error, Equatable, Sendable {
    case invalidSchemaVersion(Int)
    case corruptConfiguration
    case corruptBackupHistory
}
