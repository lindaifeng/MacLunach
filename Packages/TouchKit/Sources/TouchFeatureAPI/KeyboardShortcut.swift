public struct KeyboardShortcut: Codable, Hashable, Sendable {
    public enum Modifier: String, Codable, Hashable, Sendable {
        case command
        case option
        case control
        case shift
    }

    public let modifiers: Set<Modifier>
    public let key: String

    public init(modifiers: Set<Modifier>, key: String) {
        self.modifiers = modifiers
        self.key = key.lowercased()
    }

    public var displayValue: String {
        let orderedModifiers: [(Modifier, String)] = [
            (.control, "⌃"),
            (.option, "⌥"),
            (.shift, "⇧"),
            (.command, "⌘")
        ]

        let displayKey = key == "space" ? "Space" : key.uppercased()
        return orderedModifiers
            .filter { modifiers.contains($0.0) }
            .map(\.1)
            .joined() + displayKey
    }
}
