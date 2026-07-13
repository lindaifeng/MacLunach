import TouchFeatureAPI

public struct FeaturePreferences: Codable, Equatable, Sendable {
    public var order: [String]
    public var hidden: Set<String>
    public var disabled: Set<String>
    public var shortcuts: [String: KeyboardShortcut]

    public init(
        order: [String] = [],
        hidden: Set<String> = [],
        disabled: Set<String> = [],
        shortcuts: [String: KeyboardShortcut] = [:]
    ) {
        self.order = order
        self.hidden = hidden
        self.disabled = disabled
        self.shortcuts = shortcuts
    }

    private enum CodingKeys: String, CodingKey {
        case order
        case hidden
        case disabled
        case shortcuts
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        order = try container.decodeIfPresent([String].self, forKey: .order) ?? []
        hidden = try container.decodeIfPresent(Set<String>.self, forKey: .hidden) ?? []
        disabled = try container.decodeIfPresent(Set<String>.self, forKey: .disabled) ?? []
        shortcuts = try container.decodeIfPresent(
            [String: KeyboardShortcut].self,
            forKey: .shortcuts
        ) ?? [:]
    }
}
