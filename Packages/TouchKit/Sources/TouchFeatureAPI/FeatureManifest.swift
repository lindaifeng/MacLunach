public struct FeatureVersion: Hashable, Sendable, Comparable {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

public struct FeatureAPIVersion: Hashable, Sendable, Comparable {
    public let major: Int

    public init(major: Int) {
        self.major = major
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.major < rhs.major
    }
}

public enum FeatureCapability: String, CaseIterable, Hashable, Sendable {
    case finderMenu
    case fileSystemRead
    case fileSystemWrite
    case pasteboardWrite
    case applicationLaunch
    case screenCapture
    case notifications
    case network
}

public struct FeatureCapabilities: Hashable, Sendable {
    public let required: Set<FeatureCapability>
    public let optional: Set<FeatureCapability>

    public init(
        required: Set<FeatureCapability> = [],
        optional: Set<FeatureCapability> = []
    ) {
        self.required = required
        self.optional = optional
    }
}

public enum FeatureExecutionMode: Hashable, Sendable {
    case inProcess
    case xpcService
    case standaloneApplication
    case declarativeWorkflow
}

public enum FeaturePrimaryAction: Hashable, Sendable {
    case perform
    case openSettings
}

public enum FeatureSettingsPresentation: Hashable, Sendable {
    case none
    case declarative
    case firstPartyProvider
}

public struct FeatureManifest: Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let summary: String
    public let symbolName: String
    public let defaultOrder: Int
    public let defaultShortcut: KeyboardShortcut
    public let pluginVersion: FeatureVersion
    public let featureAPIVersion: FeatureAPIVersion
    public let minimumHostVersion: FeatureVersion
    public let maximumTestedHostVersion: FeatureVersion
    public let configurationSchemaVersion: Int
    public let capabilities: FeatureCapabilities
    public let executionMode: FeatureExecutionMode
    public let primaryAction: FeaturePrimaryAction
    public let settingsPresentation: FeatureSettingsPresentation

    public init(
        id: String,
        name: String,
        summary: String,
        symbolName: String,
        defaultOrder: Int,
        defaultShortcut: KeyboardShortcut,
        pluginVersion: FeatureVersion = .init(major: 1, minor: 0, patch: 0),
        featureAPIVersion: FeatureAPIVersion = .init(major: 1),
        minimumHostVersion: FeatureVersion = .init(major: 1, minor: 0, patch: 0),
        maximumTestedHostVersion: FeatureVersion = .init(major: 1, minor: 0, patch: 0),
        configurationSchemaVersion: Int = 1,
        capabilities: FeatureCapabilities = .init(),
        executionMode: FeatureExecutionMode = .inProcess,
        primaryAction: FeaturePrimaryAction = .perform,
        settingsPresentation: FeatureSettingsPresentation = .none
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.symbolName = symbolName
        self.defaultOrder = defaultOrder
        self.defaultShortcut = defaultShortcut
        self.pluginVersion = pluginVersion
        self.featureAPIVersion = featureAPIVersion
        self.minimumHostVersion = minimumHostVersion
        self.maximumTestedHostVersion = maximumTestedHostVersion
        self.configurationSchemaVersion = configurationSchemaVersion
        self.capabilities = capabilities
        self.executionMode = executionMode
        self.primaryAction = primaryAction
        self.settingsPresentation = settingsPresentation
    }
}
