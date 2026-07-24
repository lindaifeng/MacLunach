import Foundation

public enum SearchKind: Sendable, Hashable {
    case action
    case application
    case file
}

public struct SearchResult: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let path: String
    public let iconCacheKey: String
    public let pinyin: String
    public let initials: String
    public let strictSearchTerms: [String]
    public let kind: SearchKind
    public let baseScore: Double

    public init(
        id: String? = nil,
        title: String,
        subtitle: String = "",
        path: String = "",
        iconCacheKey: String? = nil,
        pinyin: String = "",
        initials: String = "",
        strictSearchTerms: [String] = [],
        kind: SearchKind,
        baseScore: Double = 0
    ) {
        let resolvedID = id ?? (path.isEmpty ? "\(kind)-\(title)" : path)
        self.id = resolvedID
        self.title = title
        self.subtitle = subtitle
        self.path = path
        self.iconCacheKey = iconCacheKey ?? (path.isEmpty ? resolvedID : path)
        self.pinyin = pinyin
        self.initials = initials
        self.strictSearchTerms = strictSearchTerms
        self.kind = kind
        self.baseScore = baseScore
    }
}
