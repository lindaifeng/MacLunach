import Foundation
import XCTest
@testable import OCRFeature
import TouchFeatureAPI

private final class OCRMemoryStorage: FeatureStorage, @unchecked Sendable {
    let pluginID = OCRFeaturePlugin.id
    private let lock = NSLock()
    private var snapshot: FeatureConfigurationSnapshot?
    private var backups: [FeatureConfigurationBackup] = []

    func loadConfiguration() throws -> FeatureConfigurationSnapshot? {
        lock.withLock { snapshot }
    }

    func saveConfiguration(_ snapshot: FeatureConfigurationSnapshot) throws {
        lock.withLock { self.snapshot = snapshot }
    }

    func backupConfiguration(reason: String) throws {
        lock.withLock {
            guard let snapshot else { return }
            backups.append(.init(createdAt: .now, reason: reason, snapshot: snapshot))
            self.snapshot = nil
        }
    }

    func configurationBackups() throws -> [FeatureConfigurationBackup] {
        lock.withLock { backups }
    }

    func resetConfiguration() throws {
        lock.withLock { snapshot = nil }
    }

    func seed(_ snapshot: FeatureConfigurationSnapshot) {
        lock.withLock { self.snapshot = snapshot }
    }
}

final class OCRFeatureTests: XCTestCase {
    func testManifestUsesScreenCaptureButNotNetwork() {
        let manifest = OCRFeaturePlugin().manifest
        XCTAssertTrue(manifest.capabilities.required.contains(.screenCapture))
        XCTAssertFalse(manifest.capabilities.required.contains(.network))
        XCTAssertEqual(manifest.configurationSchemaVersion, OCRConfigurationRepository.schemaVersion)
    }

    func testConfigurationDefaultsToAutomaticallyCopyingRecognizedText() throws {
        let repository = OCRConfigurationRepository(storage: OCRMemoryStorage())

        XCTAssertTrue(try repository.load().automaticallyCopiesRecognizedText)
    }

    func testConfigurationPersistsAutoCopyPreference() throws {
        let storage = OCRMemoryStorage()
        let repository = OCRConfigurationRepository(storage: storage)

        try repository.save(.init(automaticallyCopiesRecognizedText: false))

        XCTAssertEqual(
            try repository.load(),
            .init(automaticallyCopiesRecognizedText: false)
        )
    }

    func testUnsupportedConfigurationSchemaFallsBackToDefaults() throws {
        let storage = OCRMemoryStorage()
        storage.seed(.init(schemaVersion: 999, data: Data("{}".utf8)))

        let configuration = try OCRConfigurationRepository(storage: storage).load()

        XCTAssertEqual(configuration, .init())
    }

    @MainActor
    func testSettingsProviderOnlyExistsWhenStorageIsAvailable() {
        XCTAssertNil(OCRFeaturePlugin().settingsProvider)
        XCTAssertNotNil(OCRFeaturePlugin(storage: OCRMemoryStorage()).settingsProvider)
    }
}
