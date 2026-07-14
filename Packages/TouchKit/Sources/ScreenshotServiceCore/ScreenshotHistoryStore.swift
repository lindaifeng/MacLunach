import Foundation
import SQLite3
import ScreenshotFeature

public enum ScreenshotHistoryStoreError: Error, Equatable, Sendable {
    case openFailed
    case executionFailed(String)
    case unsupportedSchemaVersion(Int)
    case corruptDatabase
    case invalidRelativePath(String)
    case invalidPinReferenceCount(Int)
    case recordNotFound(UUID)
}

public struct ScreenshotHistoryItem: Equatable, Sendable, Identifiable {
    public var artifact: ScreenshotArtifact
    public var ocrSummary: String
    public var pinReferenceCount: Int
    public var deletedAt: Date?
    public var trashRelativePath: String?

    public var id: UUID { artifact.id }

    public init(
        artifact: ScreenshotArtifact,
        ocrSummary: String = "",
        pinReferenceCount: Int = 0,
        deletedAt: Date? = nil,
        trashRelativePath: String? = nil
    ) {
        self.artifact = artifact
        self.ocrSummary = ocrSummary
        self.pinReferenceCount = pinReferenceCount
        self.deletedAt = deletedAt
        self.trashRelativePath = trashRelativePath
    }
}

public struct ScreenshotHistoryQuery: Equatable, Sendable {
    public var createdAfter: Date?
    public var createdBefore: Date?
    public var minimumPointWidth: Double?
    public var maximumPointWidth: Double?
    public var minimumPointHeight: Double?
    public var maximumPointHeight: Double?
    public var ocrText: String?
    public var includesDeleted: Bool
    public var limit: Int

    public init(
        createdAfter: Date? = nil,
        createdBefore: Date? = nil,
        minimumPointWidth: Double? = nil,
        maximumPointWidth: Double? = nil,
        minimumPointHeight: Double? = nil,
        maximumPointHeight: Double? = nil,
        ocrText: String? = nil,
        includesDeleted: Bool = false,
        limit: Int = 500
    ) {
        self.createdAfter = createdAfter
        self.createdBefore = createdBefore
        self.minimumPointWidth = minimumPointWidth
        self.maximumPointWidth = maximumPointWidth
        self.minimumPointHeight = minimumPointHeight
        self.maximumPointHeight = maximumPointHeight
        self.ocrText = ocrText
        self.includesDeleted = includesDeleted
        self.limit = limit
    }
}

public actor ScreenshotHistoryStore {
    public static let currentSchemaVersion = 2

    private let rootURL: URL
    private let databaseURL: URL
    private let fileManager: FileManager
    private let now: @Sendable () -> Date
    nonisolated(unsafe) private var database: OpaquePointer?

    public init(
        rootURL: URL,
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = Date.init
    ) throws {
        let canonicalRoot = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        self.rootURL = canonicalRoot
        self.databaseURL = canonicalRoot.appendingPathComponent("History/history.sqlite")
        self.fileManager = fileManager
        self.now = now
        self.database = nil

        try fileManager.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        do {
            let handle = try Self.openDatabase(at: databaseURL)
            do {
                try Self.prepareDatabase(handle)
                database = handle
            } catch {
                sqlite3_close_v2(handle)
                throw error
            }
        } catch let error as ScreenshotHistoryStoreError {
            if case .unsupportedSchemaVersion = error { throw error }
            try Self.isolateDatabase(
                at: databaseURL,
                fileManager: fileManager,
                now: now()
            )
            let handle = try Self.openDatabase(at: databaseURL)
            do {
                try Self.prepareDatabase(handle)
                database = handle
            } catch {
                sqlite3_close_v2(handle)
                throw error
            }
        }
    }

    deinit {
        if let database { sqlite3_close_v2(database) }
    }

    public func schemaVersion() throws -> Int {
        try Self.readSchemaVersion(database)
    }

    public func recordCount() throws -> Int {
        let statement = try prepare("SELECT COUNT(*) FROM history_items")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw lastError() }
        return Int(sqlite3_column_int64(statement, 0))
    }

    public func insert(
        _ artifact: ScreenshotArtifact,
        ocrSummary: String = "",
        pinReferenceCount: Int = 0
    ) throws {
        guard pinReferenceCount >= 0 else {
            throw ScreenshotHistoryStoreError.invalidPinReferenceCount(pinReferenceCount)
        }
        try validate(relativePath: artifact.relativePath)
        if let thumbnailRelativePath = artifact.thumbnailRelativePath {
            try validate(relativePath: thumbnailRelativePath)
        }
        let displaysData = try JSONEncoder().encode(artifact.displays)
        let statement = try prepare("""
        INSERT INTO history_items (
            id, created_at, capture_mode, relative_path, thumbnail_relative_path,
            point_width, point_height, pixel_width, pixel_height,
            uniform_type_identifier, sha256, displays_json, ocr_summary,
            pin_reference_count, deleted_at, trash_relative_path
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, NULL)
        ON CONFLICT(id) DO UPDATE SET
            created_at = excluded.created_at,
            capture_mode = excluded.capture_mode,
            relative_path = excluded.relative_path,
            thumbnail_relative_path = excluded.thumbnail_relative_path,
            point_width = excluded.point_width,
            point_height = excluded.point_height,
            pixel_width = excluded.pixel_width,
            pixel_height = excluded.pixel_height,
            uniform_type_identifier = excluded.uniform_type_identifier,
            sha256 = excluded.sha256,
            displays_json = excluded.displays_json,
            ocr_summary = excluded.ocr_summary,
            pin_reference_count = excluded.pin_reference_count,
            deleted_at = NULL,
            trash_relative_path = NULL
        """)
        defer { sqlite3_finalize(statement) }
        try bind(artifact.id.uuidString.lowercased(), to: statement, at: 1)
        sqlite3_bind_double(statement, 2, artifact.createdAt.timeIntervalSince1970)
        try bind(artifact.captureMode.rawValue, to: statement, at: 3)
        try bind(artifact.relativePath, to: statement, at: 4)
        try bindOptional(artifact.thumbnailRelativePath, to: statement, at: 5)
        sqlite3_bind_double(statement, 6, artifact.pointSize.width)
        sqlite3_bind_double(statement, 7, artifact.pointSize.height)
        sqlite3_bind_double(statement, 8, artifact.pixelSize.width)
        sqlite3_bind_double(statement, 9, artifact.pixelSize.height)
        try bind(artifact.uniformTypeIdentifier, to: statement, at: 10)
        try bind(artifact.sha256, to: statement, at: 11)
        let bindDisplaysResult = displaysData.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, 12, bytes.baseAddress, Int32(bytes.count), sqliteTransient)
        }
        guard bindDisplaysResult == SQLITE_OK else { throw lastError() }
        try bind(ocrSummary, to: statement, at: 13)
        sqlite3_bind_int64(statement, 14, sqlite3_int64(pinReferenceCount))
        guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError() }
    }

    public func updateOCRSummary(id: UUID, summary: String) throws {
        let statement = try prepare("UPDATE history_items SET ocr_summary = ? WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        try bind(summary, to: statement, at: 1)
        try bind(id.uuidString.lowercased(), to: statement, at: 2)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError() }
        guard sqlite3_changes(database) == 1 else {
            throw ScreenshotHistoryStoreError.recordNotFound(id)
        }
    }

    public func item(id: UUID) throws -> ScreenshotHistoryItem? {
        let statement = try prepare("SELECT \(Self.selectColumns) FROM history_items WHERE id = ? LIMIT 1")
        defer { sqlite3_finalize(statement) }
        try bind(id.uuidString.lowercased(), to: statement, at: 1)
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return try decodeItem(from: statement)
        case SQLITE_DONE: return nil
        default: throw lastError()
        }
    }

    public func search(_ query: ScreenshotHistoryQuery = .init()) throws -> [ScreenshotHistoryItem] {
        var clauses: [String] = []
        var bindings: [HistoryBinding] = []
        if !query.includesDeleted { clauses.append("deleted_at IS NULL") }
        if let value = query.createdAfter {
            clauses.append("created_at >= ?")
            bindings.append(.double(value.timeIntervalSince1970))
        }
        if let value = query.createdBefore {
            clauses.append("created_at <= ?")
            bindings.append(.double(value.timeIntervalSince1970))
        }
        if let value = query.minimumPointWidth {
            clauses.append("point_width >= ?")
            bindings.append(.double(value))
        }
        if let value = query.maximumPointWidth {
            clauses.append("point_width <= ?")
            bindings.append(.double(value))
        }
        if let value = query.minimumPointHeight {
            clauses.append("point_height >= ?")
            bindings.append(.double(value))
        }
        if let value = query.maximumPointHeight {
            clauses.append("point_height <= ?")
            bindings.append(.double(value))
        }
        if let value = query.ocrText?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            clauses.append("ocr_summary LIKE ? ESCAPE '\\' COLLATE NOCASE")
            bindings.append(.text("%\(Self.escapeLike(value))%"))
        }
        let predicate = clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")
        let statement = try prepare("""
        SELECT \(Self.selectColumns) FROM history_items\(predicate)
        ORDER BY created_at DESC, id ASC LIMIT ?
        """)
        defer { sqlite3_finalize(statement) }
        for (offset, binding) in bindings.enumerated() {
            try bind(binding, to: statement, at: Int32(offset + 1))
        }
        sqlite3_bind_int64(statement, Int32(bindings.count + 1), sqlite3_int64(max(1, query.limit)))
        return try collect(statement)
    }

    public func updatePinReferenceCount(id: UUID, count: Int) throws {
        guard count >= 0 else { throw ScreenshotHistoryStoreError.invalidPinReferenceCount(count) }
        let statement = try prepare("UPDATE history_items SET pin_reference_count = ? WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, sqlite3_int64(count))
        try bind(id.uuidString.lowercased(), to: statement, at: 2)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError() }
        guard sqlite3_changes(database) == 1 else { throw ScreenshotHistoryStoreError.recordNotFound(id) }
    }

    public func retentionCandidates(
        olderThan cutoff: Date,
        maximumItemCount: Int,
        limit: Int
    ) throws -> [ScreenshotHistoryItem] {
        let statement = try prepare("""
        SELECT \(Self.selectColumns) FROM history_items
        WHERE deleted_at IS NULL ORDER BY created_at DESC, id ASC
        """)
        defer { sqlite3_finalize(statement) }
        let active = try collect(statement)
        let overflowStart = max(0, maximumItemCount)
        let overflowIDs = Set(active.dropFirst(overflowStart).map(\.id))
        return active
            .filter { $0.pinReferenceCount == 0 && ($0.artifact.createdAt < cutoff || overflowIDs.contains($0.id)) }
            .sorted { $0.artifact.createdAt < $1.artifact.createdAt }
            .prefix(max(0, limit))
            .map { $0 }
    }

    public func activeItems(preservingPinned: Bool, limit: Int = 500) throws -> [ScreenshotHistoryItem] {
        let pinClause = preservingPinned ? " AND pin_reference_count = 0" : ""
        let statement = try prepare("""
        SELECT \(Self.selectColumns) FROM history_items
        WHERE deleted_at IS NULL\(pinClause)
        ORDER BY created_at ASC, id ASC LIMIT ?
        """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, sqlite3_int64(max(1, limit)))
        return try collect(statement)
    }

    public func deletedItems(before cutoff: Date, limit: Int = 100) throws -> [ScreenshotHistoryItem] {
        let statement = try prepare("""
        SELECT \(Self.selectColumns) FROM history_items
        WHERE deleted_at IS NOT NULL AND deleted_at <= ?
        ORDER BY deleted_at ASC, id ASC LIMIT ?
        """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, cutoff.timeIntervalSince1970)
        sqlite3_bind_int64(statement, 2, sqlite3_int64(max(1, limit)))
        return try collect(statement)
    }

    public func markDeleted(_ trashPaths: [UUID: String], at date: Date) throws {
        try transaction {
            let statement = try prepare("""
            UPDATE history_items SET deleted_at = ?, trash_relative_path = ?
            WHERE id = ? AND deleted_at IS NULL
            """)
            defer { sqlite3_finalize(statement) }
            for (id, path) in trashPaths {
                try validate(relativePath: path)
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
                try bind(path, to: statement, at: 2)
                try bind(id.uuidString.lowercased(), to: statement, at: 3)
                guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError() }
                guard sqlite3_changes(database) == 1 else {
                    throw ScreenshotHistoryStoreError.recordNotFound(id)
                }
            }
        }
    }

    public func restoreRecord(id: UUID) throws {
        let statement = try prepare("""
        UPDATE history_items SET deleted_at = NULL, trash_relative_path = NULL
        WHERE id = ? AND deleted_at IS NOT NULL
        """)
        defer { sqlite3_finalize(statement) }
        try bind(id.uuidString.lowercased(), to: statement, at: 1)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError() }
        guard sqlite3_changes(database) == 1 else { throw ScreenshotHistoryStoreError.recordNotFound(id) }
    }

    public func removePermanently(ids: [UUID]) throws {
        try transaction {
            let statement = try prepare("DELETE FROM history_items WHERE id = ? AND deleted_at IS NOT NULL")
            defer { sqlite3_finalize(statement) }
            for id in ids {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                try bind(id.uuidString.lowercased(), to: statement, at: 1)
                guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError() }
                guard sqlite3_changes(database) == 1 else {
                    throw ScreenshotHistoryStoreError.recordNotFound(id)
                }
            }
        }
    }

    public func close() throws {
        guard let database else { return }
        guard sqlite3_close_v2(database) == SQLITE_OK else { throw lastError() }
        self.database = nil
    }

    private static let selectColumns = """
    id, created_at, capture_mode, relative_path, thumbnail_relative_path,
    point_width, point_height, pixel_width, pixel_height,
    uniform_type_identifier, sha256, displays_json, ocr_summary,
    pin_reference_count, deleted_at, trash_relative_path
    """

    private static func openDatabase(at url: URL) throws -> OpaquePointer {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close_v2(handle) }
            throw ScreenshotHistoryStoreError.openFailed
        }
        sqlite3_busy_timeout(handle, 2_000)
        return handle
    }

    private static func prepareDatabase(_ database: OpaquePointer?) throws {
        try checkIntegrity(database)
        let version = try readSchemaVersion(database)
        guard version <= currentSchemaVersion else {
            throw ScreenshotHistoryStoreError.unsupportedSchemaVersion(version)
        }
        try execute(database, sql: "BEGIN IMMEDIATE TRANSACTION")
        do {
            if version < 1 {
                try execute(database, sql: """
                CREATE TABLE history_items (
                    id TEXT PRIMARY KEY NOT NULL,
                    created_at REAL NOT NULL,
                    capture_mode TEXT NOT NULL,
                    relative_path TEXT NOT NULL UNIQUE,
                    thumbnail_relative_path TEXT,
                    point_width REAL NOT NULL,
                    point_height REAL NOT NULL,
                    pixel_width REAL NOT NULL,
                    pixel_height REAL NOT NULL,
                    uniform_type_identifier TEXT NOT NULL,
                    sha256 TEXT NOT NULL
                );
                PRAGMA user_version = 1;
                """)
            }
            if version < 2 {
                try execute(database, sql: """
                ALTER TABLE history_items ADD COLUMN displays_json BLOB NOT NULL DEFAULT X'5B5D';
                ALTER TABLE history_items ADD COLUMN ocr_summary TEXT NOT NULL DEFAULT '';
                ALTER TABLE history_items ADD COLUMN pin_reference_count INTEGER NOT NULL DEFAULT 0 CHECK(pin_reference_count >= 0);
                ALTER TABLE history_items ADD COLUMN deleted_at REAL;
                ALTER TABLE history_items ADD COLUMN trash_relative_path TEXT;
                CREATE INDEX history_created_at ON history_items(created_at DESC);
                CREATE INDEX history_deleted_at ON history_items(deleted_at);
                CREATE INDEX history_point_size ON history_items(point_width, point_height);
                PRAGMA user_version = 2;
                """)
            }
            try execute(database, sql: "COMMIT")
        } catch {
            try? execute(database, sql: "ROLLBACK")
            throw error
        }
        try execute(database, sql: "PRAGMA foreign_keys = ON; PRAGMA journal_mode = WAL;")
    }

    private static func checkIntegrity(_ database: OpaquePointer?) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA quick_check(1)", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw ScreenshotHistoryStoreError.corruptDatabase }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let text = sqlite3_column_text(statement, 0),
              String(cString: text) == "ok" else {
            throw ScreenshotHistoryStoreError.corruptDatabase
        }
    }

    private static func isolateDatabase(
        at databaseURL: URL,
        fileManager: FileManager,
        now: Date
    ) throws {
        guard fileManager.fileExists(atPath: databaseURL.path) else { return }
        let backupDirectory = databaseURL.deletingLastPathComponent().appendingPathComponent("Backups", isDirectory: true)
        try fileManager.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        let stamp = String(Int(now.timeIntervalSince1970 * 1_000))
        let backupURL = backupDirectory.appendingPathComponent("history-corrupt-\(stamp).sqlite")
        try fileManager.moveItem(at: databaseURL, to: backupURL)
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: databaseURL.path + suffix)
            if fileManager.fileExists(atPath: sidecar.path) {
                try? fileManager.moveItem(
                    at: sidecar,
                    to: backupDirectory.appendingPathComponent(backupURL.lastPathComponent + suffix)
                )
            }
        }
    }

    private static func readSchemaVersion(_ database: OpaquePointer?) throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw ScreenshotHistoryStoreError.executionFailed("read schema version")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw ScreenshotHistoryStoreError.executionFailed("read schema version")
        }
        return Int(sqlite3_column_int(statement, 0))
    }

    private static func execute(_ database: OpaquePointer?, sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &message)
        defer { if let message { sqlite3_free(message) } }
        guard result == SQLITE_OK else {
            throw ScreenshotHistoryStoreError.executionFailed(
                message.map { String(cString: $0) } ?? "sqlite code \(result)"
            )
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw lastError() }
        return statement
    }

    private func bind(_ value: String, to statement: OpaquePointer, at index: Int32) throws {
        guard sqlite3_bind_text(statement, index, value, -1, sqliteTransient) == SQLITE_OK else {
            throw lastError()
        }
    }

    private func bindOptional(_ value: String?, to statement: OpaquePointer, at index: Int32) throws {
        if let value { try bind(value, to: statement, at: index) }
        else { sqlite3_bind_null(statement, index) }
    }

    private func bind(_ value: HistoryBinding, to statement: OpaquePointer, at index: Int32) throws {
        switch value {
        case let .text(text): try bind(text, to: statement, at: index)
        case let .double(number): sqlite3_bind_double(statement, index, number)
        }
    }

    private func collect(_ statement: OpaquePointer) throws -> [ScreenshotHistoryItem] {
        var items: [ScreenshotHistoryItem] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: items.append(try decodeItem(from: statement))
            case SQLITE_DONE: return items
            default: throw lastError()
            }
        }
    }

    private func decodeItem(from statement: OpaquePointer) throws -> ScreenshotHistoryItem {
        guard let id = UUID(uuidString: text(statement, 0)),
              let mode = ScreenshotCaptureMode(rawValue: text(statement, 2)) else {
            throw ScreenshotHistoryStoreError.executionFailed("invalid history row")
        }
        let displaysData: Data
        if let bytes = sqlite3_column_blob(statement, 11) {
            displaysData = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 11)))
        } else {
            displaysData = Data("[]".utf8)
        }
        let displays = (try? JSONDecoder().decode([ScreenshotDisplayDescriptor].self, from: displaysData)) ?? []
        let artifact = ScreenshotArtifact(
            id: id,
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
            captureMode: mode,
            relativePath: text(statement, 3),
            thumbnailRelativePath: optionalText(statement, 4),
            pointSize: .init(
                width: sqlite3_column_double(statement, 5),
                height: sqlite3_column_double(statement, 6)
            ),
            pixelSize: .init(
                width: sqlite3_column_double(statement, 7),
                height: sqlite3_column_double(statement, 8)
            ),
            uniformTypeIdentifier: text(statement, 9),
            sha256: text(statement, 10),
            displays: displays
        )
        return ScreenshotHistoryItem(
            artifact: artifact,
            ocrSummary: text(statement, 12),
            pinReferenceCount: Int(sqlite3_column_int64(statement, 13)),
            deletedAt: sqlite3_column_type(statement, 14) == SQLITE_NULL
                ? nil
                : Date(timeIntervalSince1970: sqlite3_column_double(statement, 14)),
            trashRelativePath: optionalText(statement, 15)
        )
    }

    private func transaction(_ body: () throws -> Void) throws {
        try Self.execute(database, sql: "BEGIN IMMEDIATE TRANSACTION")
        do {
            try body()
            try Self.execute(database, sql: "COMMIT")
        } catch {
            try? Self.execute(database, sql: "ROLLBACK")
            throw error
        }
    }

    private func validate(relativePath: String) throws {
        do {
            _ = try ScreenshotFeaturePaths(rootURL: rootURL).resolve(relativePath: relativePath)
        } catch {
            throw ScreenshotHistoryStoreError.invalidRelativePath(relativePath)
        }
    }

    private func lastError() -> ScreenshotHistoryStoreError {
        ScreenshotHistoryStoreError.executionFailed(
            database.map { String(cString: sqlite3_errmsg($0)) } ?? "database closed"
        )
    }

    private func text(_ statement: OpaquePointer, _ index: Int32) -> String {
        guard let value = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: value)
    }

    private func optionalText(_ statement: OpaquePointer, _ index: Int32) -> String? {
        sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : text(statement, index)
    }

    private static func escapeLike(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}

private enum HistoryBinding {
    case text(String)
    case double(Double)
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
