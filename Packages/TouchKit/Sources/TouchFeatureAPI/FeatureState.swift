public enum FeatureState: Equatable, Sendable {
    case unloaded
    case available
    case running
    case restricted(message: String)
    case failed(message: String)
    case disabled

    public var isSelectable: Bool {
        switch self {
        case .available:
            true
        case .unloaded, .running, .restricted, .failed, .disabled:
            false
        }
    }
}
