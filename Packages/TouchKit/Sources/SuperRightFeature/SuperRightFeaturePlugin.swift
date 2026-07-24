import Foundation
@preconcurrency import FinderSync
import TouchFeatureAPI

public struct SuperRightFeaturePlugin: FeaturePlugin {
    public static let id = "me.touch.super-right"
    public static let monitoredDirectoryURLs: Set<URL> = [
        URL(fileURLWithPath: "/", isDirectory: true)
    ]

    private let storage: any FeatureStorage
    private let extensionManagement: FinderExtensionManagement

    public init(storage: any FeatureStorage) {
        self.storage = storage
        extensionManagement = .system
    }

    init(
        storage: any FeatureStorage,
        isFinderExtensionEnabled: @escaping @Sendable () -> Bool
    ) {
        self.storage = storage
        extensionManagement = FinderExtensionManagement(
            isEnabled: isFinderExtensionEnabled
        )
    }

    public let manifest = FeatureManifest(
        id: SuperRightFeaturePlugin.id,
        name: "超级右键",
        summary: "增强 Finder 右键菜单",
        symbolName: "ellipsis",
        defaultOrder: 2,
        defaultShortcut: .init(modifiers: [], key: "3"),
        pluginVersion: .init(major: 1, minor: 0, patch: 0),
        featureAPIVersion: .init(major: 1),
        minimumHostVersion: .init(major: 1, minor: 0, patch: 0),
        maximumTestedHostVersion: .init(major: 1, minor: 0, patch: 0),
        configurationSchemaVersion: SuperRightConfigurationRepository.schemaVersion,
        capabilities: .init(
            required: [.finderMenu, .fileSystemRead],
            optional: [.fileSystemWrite, .pasteboardWrite, .applicationLaunch]
        ),
        executionMode: .xpcService,
        primaryAction: .openSettings,
        settingsPresentation: .firstPartyProvider
    )

    @MainActor
    public var settingsProvider: (any FeatureSettingsProvider)? {
        SuperRightSettingsProvider(storage: storage)
    }

    public func initialState() async -> FeatureState {
        extensionManagement.isEnabled()
            ? .available
            : .restricted(message: "需要启用 Finder 扩展")
    }

    public func perform() async throws -> FeatureActionResult {
        .requiresSetup(message: "请在功能区中配置超级右键")
    }
}

struct FinderExtensionManagement: Sendable {
    let isEnabled: @Sendable () -> Bool

    static let system = FinderExtensionManagement(
        isEnabled: { FIFinderSyncController.isExtensionEnabled }
    )
}
