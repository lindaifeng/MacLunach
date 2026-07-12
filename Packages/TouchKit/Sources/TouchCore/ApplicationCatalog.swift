import Foundation

public struct ApplicationRecord: Hashable, Sendable {
    public let bundleIdentifier: String
    public let name: String
    public let path: String
    public let isUserInstalled: Bool
    public let pinyin: String
    public let initials: String

    public init(
        bundleIdentifier: String,
        name: String,
        path: String,
        isUserInstalled: Bool,
        pinyin: String = "",
        initials: String = ""
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.path = path
        self.isUserInstalled = isUserInstalled
        self.pinyin = pinyin
        self.initials = initials
    }
}

public protocol ApplicationDiscovering: Sendable {
    func discoverApplications() async -> [ApplicationRecord]
}

public actor ApplicationCatalog {
    private let discoverer: any ApplicationDiscovering
    private var applications: [ApplicationRecord] = []
    private var usage: [String: ApplicationUsage] = [:]

    public init(discoverer: any ApplicationDiscovering) {
        self.discoverer = discoverer
    }

    public func refresh() async -> [ApplicationRecord] {
        let discovered = await discoverer.discoverApplications()
        var deduplicated: [String: ApplicationRecord] = [:]
        for application in discovered {
            guard let existing = deduplicated[application.bundleIdentifier] else {
                deduplicated[application.bundleIdentifier] = application
                continue
            }
            if application.isUserInstalled && !existing.isUserInstalled {
                deduplicated[application.bundleIdentifier] = application
            }
        }
        applications = deduplicated.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return applications
    }

    public func recordLaunch(bundleIdentifier: String, at date: Date) {
        var value = usage[bundleIdentifier] ?? ApplicationUsage(count: 0, lastLaunched: .distantPast)
        value.count += 1
        value.lastLaunched = date
        usage[bundleIdentifier] = value
    }

    public func search(query: String) -> [SearchResult] {
        SearchRanking.sort(applications.map { application in
            let usageValue = usage[application.bundleIdentifier] ?? ApplicationUsage(count: 0, lastLaunched: .distantPast)
            return SearchResult(
                id: application.bundleIdentifier,
                title: application.name,
                subtitle: application.path,
                path: application.path,
                pinyin: application.pinyin,
                initials: application.initials,
                kind: .application,
                baseScore: usageValue.score
            )
        }, query: query)
    }
}

private struct ApplicationUsage: Sendable {
    var count: Int
    var lastLaunched: Date

    var score: Double {
        let recency = max(0, 1 - Date().timeIntervalSince(lastLaunched) / 86_400)
        return Double(count) * 10 + recency
    }
}
