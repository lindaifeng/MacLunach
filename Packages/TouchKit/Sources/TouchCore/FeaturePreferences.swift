import TouchFeatureAPI

public struct FeaturePreferences: Codable, Equatable, Sendable {
    public var order: [String]
    public var hidden: Set<String>
    public var shortcuts: [String: KeyboardShortcut]

    public init(
        order: [String] = [],
        hidden: Set<String> = [],
        shortcuts: [String: KeyboardShortcut] = [:]
    ) {
        self.order = order
        self.hidden = hidden
        self.shortcuts = shortcuts
    }
}
