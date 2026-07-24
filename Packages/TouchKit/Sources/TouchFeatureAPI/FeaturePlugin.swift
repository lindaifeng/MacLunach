public protocol FeaturePlugin: Sendable {
    var manifest: FeatureManifest { get }

    @MainActor
    var settingsProvider: (any FeatureSettingsProvider)? { get }

    func initialState() async -> FeatureState
    func perform() async throws -> FeatureActionResult
}

public extension FeaturePlugin {
    @MainActor
    var settingsProvider: (any FeatureSettingsProvider)? { nil }
}

/// Optional lifecycle hooks owned exclusively by `FeatureRegistry`.
///
/// Hiding a feature card does not invoke these hooks. They are reserved for
/// actually enabling or disabling a feature and its private resources.
public protocol FeatureLifecycleHandling: Sendable {
    func featureDidEnable() async
    func featureDidDisable() async
}
