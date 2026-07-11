public protocol FeaturePlugin: Sendable {
    var manifest: FeatureManifest { get }

    func initialState() async -> FeatureState
    func perform() async throws -> FeatureActionResult
}
