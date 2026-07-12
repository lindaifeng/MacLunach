import Foundation

public enum SearchKind: Sendable, Hashable {
    case application
    case file
}

public struct SearchResult: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let path: String
    public let pinyin: String
    public let initials: String
    public let kind: SearchKind
    public let baseScore: Double

    public init(
        id: String? = nil,
        title: String,
        subtitle: String = "",
        path: String = "",
        pinyin: String = "",
        initials: String = "",
        kind: SearchKind,
        baseScore: Double = 0
    ) {
        self.id = id ?? (path.isEmpty ? "\(kind)-\(title)" : path)
        self.title = title
        self.subtitle = subtitle
        self.path = path
        self.pinyin = pinyin
        self.initials = initials
        self.kind = kind
        self.baseScore = baseScore
    }
}
