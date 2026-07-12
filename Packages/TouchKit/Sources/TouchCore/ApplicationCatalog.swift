import Foundation

public struct ApplicationRecord: Hashable, Sendable {
    public let bundleIdentifier: String
    public let name: String
    public let localizedName: String
    public let path: String
    public let iconCacheKey: String
    public let isUserInstalled: Bool
    public let pinyin: String
    public let initials: String

    public init(
        bundleIdentifier: String,
        name: String,
        localizedName: String? = nil,
        path: String,
        iconCacheKey: String? = nil,
        isUserInstalled: Bool,
        pinyin: String = "",
        initials: String = ""
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.localizedName = localizedName ?? name
        self.path = path
        self.iconCacheKey = iconCacheKey ?? "\(bundleIdentifier)|\(path)"
        self.isUserInstalled = isUserInstalled
        self.pinyin = pinyin
        self.initials = initials
    }
}

public protocol ApplicationDiscovering: Sendable {
    func discoverApplications() async -> [ApplicationRecord]
}

public protocol ApplicationLaunching: Sendable {
    func openApplication(at url: URL) async throws
}

public enum SearchActionError: Error, Equatable, Sendable {
    case applicationNotFound(bundleIdentifier: String)
    case cannotOpen(path: String)
}

public actor ApplicationCatalog {
    private let discoverer: any ApplicationDiscovering
    private let launcher: (any ApplicationLaunching)?
    private var applications: [ApplicationRecord] = []
    private var usage: [String: ApplicationUsage] = [:]

    public init(discoverer: any ApplicationDiscovering, launcher: (any ApplicationLaunching)? = nil) {
        self.discoverer = discoverer
        self.launcher = launcher
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

    public func launch(bundleIdentifier: String) async throws {
        guard let application = applications.first(where: { $0.bundleIdentifier == bundleIdentifier }) else {
            throw SearchActionError.applicationNotFound(bundleIdentifier: bundleIdentifier)
        }
        guard let launcher else {
            throw SearchActionError.cannotOpen(path: application.path)
        }
        do {
            try await launcher.openApplication(at: URL(fileURLWithPath: application.path))
        } catch {
            throw SearchActionError.cannotOpen(path: application.path)
        }
        recordLaunch(bundleIdentifier: bundleIdentifier, at: Date())
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
                title: application.localizedName,
                subtitle: application.path,
                path: application.path,
                iconCacheKey: application.iconCacheKey,
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

public struct ApplicationSearchRoot: Hashable, Sendable {
    public let url: URL
    public let isUserInstalled: Bool

    public init(url: URL, isUserInstalled: Bool) {
        self.url = url
        self.isUserInstalled = isUserInstalled
    }
}

public struct FileSystemApplicationDiscoverer: ApplicationDiscovering {
    public let roots: [ApplicationSearchRoot]

    public init(roots: [ApplicationSearchRoot] = Self.defaultRoots) {
        self.roots = roots
    }

    public func discoverApplications() async -> [ApplicationRecord] {
        let roots = roots
        return await Task.detached(priority: .utility) {
            roots.flatMap(Self.discoverApplications(in:))
        }.value
    }

    public static var defaultRoots: [ApplicationSearchRoot] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            ApplicationSearchRoot(url: home.appendingPathComponent("Applications", isDirectory: true), isUserInstalled: true),
            ApplicationSearchRoot(url: URL(fileURLWithPath: "/Applications", isDirectory: true), isUserInstalled: true),
            ApplicationSearchRoot(url: URL(fileURLWithPath: "/System/Applications", isDirectory: true), isUserInstalled: false)
        ]
    }

    private static func discoverApplications(in root: ApplicationSearchRoot) -> [ApplicationRecord] {
        if root.url.pathExtension.caseInsensitiveCompare("app") == .orderedSame {
            return applicationRecord(at: root.url, isUserInstalled: root.isUserInstalled).map { [$0] } ?? []
        }

        guard let enumerator = FileManager.default.enumerator(
            at: root.url,
            includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else { return [] }

        var records: [ApplicationRecord] = []
        while let url = enumerator.nextObject() as? URL {
            guard url.pathExtension.caseInsensitiveCompare("app") == .orderedSame else { continue }
            enumerator.skipDescendants()
            guard let record = applicationRecord(at: url, isUserInstalled: root.isUserInstalled) else { continue }
            records.append(record)
        }
        return records
    }

    private static func applicationRecord(at url: URL, isUserInstalled: Bool) -> ApplicationRecord? {
        let infoURL = url.appendingPathComponent("Contents/Info.plist")
        guard
            let data = try? Data(contentsOf: infoURL),
            let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
            let info = object as? [String: Any],
            let bundleIdentifier = info["CFBundleIdentifier"] as? String,
            !bundleIdentifier.isEmpty
        else { return nil }

        let name = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        let localizedInfo = Bundle(url: url)?.localizedInfoDictionary
        let localizedName = (localizedInfo?["CFBundleDisplayName"] as? String)
            ?? (localizedInfo?["CFBundleName"] as? String)
            ?? name
        let searchableNames = localizedName == name ? name : "\(localizedName) \(name)"
        let searchKeys = transliterationKeys(for: searchableNames)
        return ApplicationRecord(
            bundleIdentifier: bundleIdentifier,
            name: name,
            localizedName: localizedName,
            path: url.path,
            iconCacheKey: "\(bundleIdentifier)|\(url.resolvingSymlinksInPath().path)",
            isUserInstalled: isUserInstalled,
            pinyin: searchKeys.pinyin,
            initials: searchKeys.initials
        )
    }

    private static func transliterationKeys(for value: String) -> (pinyin: String, initials: String) {
        let latin = value.applyingTransform(.toLatin, reverse: false) ?? value
        let folded = latin.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: .current)
        let words = folded.split(whereSeparator: { $0.isWhitespace || $0 == "-" })
        return (
            words.joined(separator: " "),
            String(words.compactMap(\.first))
        )
    }
}
