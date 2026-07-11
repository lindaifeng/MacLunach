public struct FeatureManifest: Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let summary: String
    public let symbolName: String
    public let defaultOrder: Int
    public let defaultShortcut: KeyboardShortcut

    public init(
        id: String,
        name: String,
        summary: String,
        symbolName: String,
        defaultOrder: Int,
        defaultShortcut: KeyboardShortcut
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.symbolName = symbolName
        self.defaultOrder = defaultOrder
        self.defaultShortcut = defaultShortcut
    }
}
