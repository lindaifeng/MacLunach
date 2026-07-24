import TouchCore

struct ThemeRegistry {
    static let shared = ThemeRegistry()

    private let definitions: [TouchTheme: ThemeDefinition]

    init(definitions: [ThemeDefinition] = [
        DefaultGlassTheme.definition,
        NightTheme.definition,
        GraphiteTheme.definition,
        DayTheme.definition
    ]) {
        self.definitions = Dictionary(uniqueKeysWithValues: definitions.map { ($0.id, $0) })
    }

    var allDefinitions: [ThemeDefinition] {
        TouchTheme.allCases.compactMap { definitions[$0] }
    }

    func definition(for theme: TouchTheme) -> ThemeDefinition {
        definitions[theme] ?? DefaultGlassTheme.definition
    }
}
