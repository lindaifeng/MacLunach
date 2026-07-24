import Foundation

@MainActor
final class SearchDiagnostics: ObservableObject {
    static let defaultExclusionRules = ["废纸篓", "Library/Caches", "系统目录"]

    enum Status: Equatable {
        case waiting
        case indexing
        case rebuilding
        case ready
        case unavailable(String)

        var label: String {
            switch self {
            case .waiting: "等待首次构建"
            case .indexing: "正在建立索引"
            case .rebuilding: "正在重建"
            case .ready: "索引已就绪"
            case .unavailable: "索引不可用"
            }
        }
    }

    @Published private(set) var roots: [URL]
    @Published private(set) var fileCount: Int
    @Published private(set) var databaseSize: Int64
    @Published private(set) var lastUpdatedAt: Date?
    @Published private(set) var status: Status
    @Published private(set) var exclusionRules: [String]
    @Published private(set) var indexingProgress: Double?
    @Published private(set) var indexingRootName: String?

    init(
        roots: [URL],
        fileCount: Int = 0,
        databaseSize: Int64 = 0,
        lastUpdatedAt: Date? = nil,
        status: Status = .waiting,
        exclusionRules: [String] = SearchDiagnostics.defaultExclusionRules,
        indexingProgress: Double? = nil,
        indexingRootName: String? = nil
    ) {
        self.roots = roots
        self.fileCount = fileCount
        self.databaseSize = databaseSize
        self.lastUpdatedAt = lastUpdatedAt
        self.status = status
        self.exclusionRules = exclusionRules
        self.indexingProgress = indexingProgress
        self.indexingRootName = indexingRootName
    }

    var rootNames: [String] {
        roots.map { url in
            let name = url.lastPathComponent
            return name.isEmpty ? url.deletingLastPathComponent().lastPathComponent : name
        }
    }

    var visibleSummary: String {
        "目录：\(rootNames.joined(separator: "、"))；文件：\(fileCount)；数据库：\(databaseSize) 字节"
    }

    func update(
        roots: [URL]? = nil,
        fileCount: Int? = nil,
        databaseSize: Int64? = nil,
        lastUpdatedAt: Date?? = nil,
        status: Status? = nil,
        exclusionRules: [String]? = nil
    ) {
        if let roots { self.roots = roots }
        if let fileCount { self.fileCount = fileCount }
        if let databaseSize { self.databaseSize = databaseSize }
        if let lastUpdatedAt { self.lastUpdatedAt = lastUpdatedAt }
        if let status {
            self.status = status
            if status != .indexing, status != .rebuilding {
                indexingProgress = nil
                indexingRootName = nil
            }
        }
        if let exclusionRules { self.exclusionRules = exclusionRules }
    }

    func updateIndexingProgress(_ progress: Double, rootName: String?) {
        indexingProgress = min(max(progress, 0), 1)
        indexingRootName = rootName
    }

    var isActivelyIndexing: Bool {
        status == .indexing || status == .rebuilding
    }
}
