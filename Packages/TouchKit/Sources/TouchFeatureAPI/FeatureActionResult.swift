public enum FeatureActionResult: Equatable, Sendable {
    case completed
    case requiresSetup(message: String)
}
