import Foundation
import TouchFeatureAPI

public struct FeatureStorageFactory: @unchecked Sendable {
    private let defaults: UserDefaults
    private let now: @Sendable () -> Date

    public init(
        defaults: UserDefaults = .standard,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.defaults = defaults
        self.now = now
    }

    public func makeStorage(pluginID: String) -> any FeatureStorage {
        UserDefaultsFeatureStorage(
            pluginID: pluginID,
            defaults: defaults,
            now: now
        )
    }
}

private final class UserDefaultsFeatureStorage: FeatureStorage, @unchecked Sendable {
    let pluginID: String

    private let defaults: UserDefaults
    private let now: @Sendable () -> Date
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let lock = NSLock()

    init(
        pluginID: String,
        defaults: UserDefaults,
        now: @escaping @Sendable () -> Date
    ) {
        self.pluginID = pluginID
        self.defaults = defaults
        self.now = now
    }

    func loadConfiguration() throws -> FeatureConfigurationSnapshot? {
        try lock.withLock {
            guard let data = defaults.data(forKey: configurationKey) else { return nil }
            do {
                return try decoder.decode(FeatureConfigurationSnapshot.self, from: data)
            } catch {
                throw FeatureStorageError.corruptConfiguration
            }
        }
    }

    func saveConfiguration(_ snapshot: FeatureConfigurationSnapshot) throws {
        guard snapshot.schemaVersion > 0 else {
            throw FeatureStorageError.invalidSchemaVersion(snapshot.schemaVersion)
        }
        try lock.withLock {
            defaults.set(try encoder.encode(snapshot), forKey: configurationKey)
        }
    }

    func backupConfiguration(reason: String) throws {
        try lock.withLock {
            guard let data = defaults.data(forKey: configurationKey) else { return }
            let snapshot: FeatureConfigurationSnapshot
            do {
                snapshot = try decoder.decode(FeatureConfigurationSnapshot.self, from: data)
            } catch {
                throw FeatureStorageError.corruptConfiguration
            }

            var backups = try loadBackupsWithoutLock()
            backups.append(
                FeatureConfigurationBackup(
                    createdAt: now(),
                    reason: reason,
                    snapshot: snapshot
                )
            )
            defaults.set(try encoder.encode(backups), forKey: backupsKey)
            defaults.removeObject(forKey: configurationKey)
        }
    }

    func configurationBackups() throws -> [FeatureConfigurationBackup] {
        try lock.withLock { try loadBackupsWithoutLock() }
    }

    func resetConfiguration() throws {
        lock.withLock {
            defaults.removeObject(forKey: configurationKey)
        }
    }

    private var configurationKey: String {
        "me.touch.features.\(pluginID).configuration"
    }

    private var backupsKey: String {
        "me.touch.features.\(pluginID).configuration.backups"
    }

    private func loadBackupsWithoutLock() throws -> [FeatureConfigurationBackup] {
        guard let data = defaults.data(forKey: backupsKey) else { return [] }
        do {
            return try decoder.decode([FeatureConfigurationBackup].self, from: data)
        } catch {
            throw FeatureStorageError.corruptBackupHistory
        }
    }
}
