import Foundation

public enum SearchRanking {
    public static func sort(_ results: [SearchResult], query: String) -> [SearchResult] {
        guard !normalized(query).isEmpty else { return [] }

        return results
            .filter { score($0, query: query) > 0 }
            .sorted { lhs, rhs in
                let leftScore = score(lhs, query: query)
                let rightScore = score(rhs, query: query)
                if leftScore == rightScore {
                    return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
                }
                return leftScore > rightScore
            }
    }

    public static func score(_ result: SearchResult, query: String) -> Double {
        let needle = normalized(query)
        guard !needle.isEmpty else { return 0 }

        let fields = [normalized(result.title), normalized(result.pinyin), normalized(result.initials)]
        let fuzzyMatchScore = fields.map { score(field: $0, needle: needle) }.max() ?? 0
        let strictMatchScore = result.strictSearchTerms
            .map { strictScore(field: normalized($0), needle: needle) }
            .max() ?? 0
        let matchScore = max(fuzzyMatchScore, strictMatchScore)
        return matchScore == 0 ? 0 : matchScore + result.baseScore
    }

    private static func score(field: String, needle: String) -> Double {
        guard !field.isEmpty else { return 0 }
        if field == needle { return 1_000 }
        if field.hasPrefix(needle) { return 800 - Double(field.count - needle.count) }
        if let range = field.range(of: needle) { return 600 - Double(field.distance(from: field.startIndex, to: range.lowerBound)) }
        return isSubsequence(needle, of: field) ? 300 : 0
    }

    private static func strictScore(field: String, needle: String) -> Double {
        guard !field.isEmpty else { return 0 }
        if field == needle { return 1_000 }
        if field.hasPrefix(needle) { return 800 - Double(field.count - needle.count) }
        if let range = field.range(of: needle) {
            return 600 - Double(field.distance(from: field.startIndex, to: range.lowerBound))
        }
        return 0
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .replacingOccurrences(of: " ", with: "")
    }

    private static func isSubsequence(_ needle: String, of field: String) -> Bool {
        var fieldIndex = field.startIndex
        for character in needle {
            guard let match = field[fieldIndex...].firstIndex(of: character) else { return false }
            fieldIndex = field.index(after: match)
        }
        return true
    }

}
