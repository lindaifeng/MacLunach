public enum TouchTheme: String, Codable, CaseIterable, Sendable {
    case crystal
    case obsidian
    case amber

    public var next: Self {
        let values = Self.allCases
        guard let index = values.firstIndex(of: self) else { return .crystal }
        return values[(index + 1) % values.count]
    }
}
