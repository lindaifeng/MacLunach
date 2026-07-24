public enum TouchTheme: String, Codable, CaseIterable, Hashable, Sendable {
    case defaultGlass = "default"
    case night
    case graphite
    case day

    public var next: Self {
        let values = Self.allCases
        guard let index = values.firstIndex(of: self) else { return .defaultGlass }
        return values[(index + 1) % values.count]
    }

    public init?(persistedValue: String) {
        if let current = Self(rawValue: persistedValue) {
            self = current
            return
        }

        switch persistedValue {
        case "crystal": self = .defaultGlass
        case "obsidian": self = .night
        case "graphite-gray": self = .graphite
        case "amber": self = .day
        default: return nil
        }
    }
}
