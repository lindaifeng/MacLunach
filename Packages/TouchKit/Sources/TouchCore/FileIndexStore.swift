import Foundation
import SQLite3

public struct FileIndexRecord: Hashable, Sendable {
    public let path: String
    public let rootPath: String
    public let fileName: String
    public let contentType: String
    public let size: Int64
    public let createdAt: Date
    public let modifiedAt: Date
    public let isDirectory: Bool

    public init(
        path: String,
        rootPath: String,
        contentType: String,
        size: Int64,
        createdAt: Date,
        modifiedAt: Date,
        isDirectory: Bool
    ) {
        let canonicalURL = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        self.path = canonicalURL.path
        self.rootPath = URL(fileURLWithPath: rootPath).standardizedFileURL.resolvingSymlinksInPath().path
        self.fileName = canonicalURL.lastPathComponent
        self.contentType = contentType
        self.size = size
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.isDirectory = isDirectory
    }
}

public actor FileIndexStore {
    private static let currentSchemaVersion = 2

    public enum IsolationReason: Sendable {
        case rebuild
        case corruption

        fileprivate var filenameComponent: String {
            switch self {
            case .rebuild: "recovery"
            case .corruption: "corrupt"
            }
        }
    }

    // SQLite is only touched by this actor. `nonisolated(unsafe)` is needed so
    // the nonisolated actor deinitializer can release the C handle.
    nonisolated(unsafe) private var database: OpaquePointer?

    public init(databaseURL: URL) throws {
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &handle, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw FileIndexStoreError.openFailed
        }
        do {
            try Self.execute(handle, sql: """
            BEGIN IMMEDIATE TRANSACTION;
            CREATE TABLE IF NOT EXISTS files (
                path TEXT PRIMARY KEY NOT NULL,
                root_path TEXT NOT NULL,
                file_name TEXT NOT NULL,
                normalized_name TEXT NOT NULL,
                content_type TEXT NOT NULL,
                size INTEGER NOT NULL,
                created_at REAL NOT NULL,
                modified_at REAL NOT NULL,
                is_directory INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS files_normalized_name ON files(normalized_name);
            CREATE INDEX IF NOT EXISTS files_root_path ON files(root_path);
            """)
            let version = try Self.schemaVersion(in: handle)
            guard version <= Self.currentSchemaVersion else {
                throw FileIndexStoreError.unsupportedSchemaVersion(version)
            }
            if version < 1 {
                try Self.execute(handle, sql: """
                CREATE VIRTUAL TABLE files_fts USING fts5(
                    normalized_name,
                    content='files',
                    content_rowid='rowid',
                    tokenize='trigram'
                );
                CREATE TRIGGER files_ai AFTER INSERT ON files BEGIN
                    INSERT INTO files_fts(rowid, normalized_name) VALUES (new.rowid, new.normalized_name);
                END;
                CREATE TRIGGER files_ad AFTER DELETE ON files BEGIN
                    INSERT INTO files_fts(files_fts, rowid, normalized_name)
                    VALUES ('delete', old.rowid, old.normalized_name);
                END;
                CREATE TRIGGER files_au AFTER UPDATE ON files BEGIN
                    INSERT INTO files_fts(files_fts, rowid, normalized_name)
                    VALUES ('delete', old.rowid, old.normalized_name);
                    INSERT INTO files_fts(rowid, normalized_name) VALUES (new.rowid, new.normalized_name);
                END;
                INSERT INTO files_fts(files_fts) VALUES ('rebuild');
                PRAGMA user_version = 1;
                """)
            }
            if version < 2 {
                try Self.execute(handle, sql: """
                ALTER TABLE files ADD COLUMN short_search_tokens TEXT NOT NULL DEFAULT '';
                DROP TRIGGER files_au;
                """)
                try Self.populateShortSearchTokens(in: handle)
                try Self.execute(handle, sql: """
                CREATE TRIGGER files_au AFTER UPDATE ON files BEGIN
                    INSERT INTO files_fts(files_fts, rowid, normalized_name)
                    VALUES ('delete', old.rowid, old.normalized_name);
                    INSERT INTO files_fts(rowid, normalized_name) VALUES (new.rowid, new.normalized_name);
                END;
                CREATE VIRTUAL TABLE files_short_fts USING fts5(
                    short_search_tokens,
                    content='files',
                    content_rowid='rowid'
                );
                CREATE TRIGGER files_short_ai AFTER INSERT ON files BEGIN
                    INSERT INTO files_short_fts(rowid, short_search_tokens)
                    VALUES (new.rowid, new.short_search_tokens);
                END;
                CREATE TRIGGER files_short_ad AFTER DELETE ON files BEGIN
                    INSERT INTO files_short_fts(files_short_fts, rowid, short_search_tokens)
                    VALUES ('delete', old.rowid, old.short_search_tokens);
                END;
                CREATE TRIGGER files_short_au AFTER UPDATE ON files BEGIN
                    INSERT INTO files_short_fts(files_short_fts, rowid, short_search_tokens)
                    VALUES ('delete', old.rowid, old.short_search_tokens);
                    INSERT INTO files_short_fts(rowid, short_search_tokens)
                    VALUES (new.rowid, new.short_search_tokens);
                END;
                INSERT INTO files_short_fts(files_short_fts) VALUES ('rebuild');
                PRAGMA user_version = 2;
                """)
            }
            try Self.execute(handle, sql: "COMMIT")
            database = handle
        } catch {
            try? Self.execute(handle, sql: "ROLLBACK")
            sqlite3_close_v2(handle)
            throw error
        }
    }

    deinit {
        if let database { sqlite3_close_v2(database) }
    }

    public static func temporary() throws -> FileIndexStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TouchTests", isDirectory: true)
            .appendingPathComponent("\(UUID().uuidString).sqlite")
        return try FileIndexStore(databaseURL: url)
    }

    public static func openRecovering(
        databaseURL: URL,
        timestamp: Date = .now
    ) throws -> (store: FileIndexStore, didRecover: Bool) {
        do {
            return (try FileIndexStore(databaseURL: databaseURL), false)
        } catch {
            _ = try isolateDatabase(at: databaseURL, reason: .corruption, timestamp: timestamp)
            return (try FileIndexStore(databaseURL: databaseURL), true)
        }
    }

    @discardableResult
    public static func isolateDatabase(
        at databaseURL: URL,
        reason: IsolationReason,
        timestamp: Date = .now
    ) throws -> URL? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: databaseURL.path) else { return nil }
        let timestampValue = Int64((timestamp.timeIntervalSince1970 * 1_000).rounded())
        let baseName = databaseURL.deletingPathExtension().lastPathComponent
        let isolatedURL = databaseURL.deletingLastPathComponent()
            .appendingPathComponent("\(baseName).\(reason.filenameComponent)-\(timestampValue).sqlite")
        try fileManager.moveItem(at: databaseURL, to: isolatedURL)

        for suffix in ["-wal", "-shm"] {
            let source = URL(fileURLWithPath: databaseURL.path + suffix)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            let destination = URL(fileURLWithPath: isolatedURL.path + suffix)
            try fileManager.moveItem(at: source, to: destination)
        }
        return isolatedURL
    }

    public func upsert(_ records: [FileIndexRecord]) throws {
        try Self.execute(database, sql: "BEGIN IMMEDIATE TRANSACTION")
        do {
            let statement = try prepare(Self.upsertSQL)
            defer { sqlite3_finalize(statement) }
            for record in records {
                try bind(record, to: statement)
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw FileIndexStoreError.executionFailed
                }
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
            }
            try Self.execute(database, sql: "COMMIT")
        } catch {
            try? Self.execute(database, sql: "ROLLBACK")
            throw error
        }
    }

    public func search(_ query: String, limit: Int) throws -> [FileIndexRecord] {
        let normalizedQuery = normalize(query)
        let usesTrigramIndex = normalizedQuery.count >= 3
        let usesShortIndex = !normalizedQuery.isEmpty && normalizedQuery.count < 3 && Self.canUseShortIndex(normalizedQuery)
        let indexedSQL = """
        SELECT files.path, files.root_path, files.file_name, files.content_type,
               files.size, files.created_at, files.modified_at, files.is_directory
        FROM INDEX_TABLE
        JOIN files ON files.rowid = INDEX_TABLE.rowid
        WHERE INDEX_TABLE MATCH ?
        ORDER BY CASE
            WHEN files.normalized_name = ? THEN 0
            WHEN files.normalized_name LIKE ? ESCAPE '\\' THEN 1
            ELSE 2
        END, files.file_name COLLATE NOCASE ASC
        LIMIT ?
        """
        let sql: String
        if usesTrigramIndex {
            sql = indexedSQL.replacingOccurrences(of: "INDEX_TABLE", with: "files_fts")
        } else if usesShortIndex {
            sql = indexedSQL.replacingOccurrences(of: "INDEX_TABLE", with: "files_short_fts")
        } else {
            sql = """
        SELECT path, root_path, file_name, content_type, size, created_at, modified_at, is_directory
        FROM files
        WHERE normalized_name LIKE ? ESCAPE '\\'
        ORDER BY CASE
            WHEN normalized_name = ? THEN 0
            WHEN normalized_name LIKE ? ESCAPE '\\' THEN 1
            ELSE 2
        END, file_name COLLATE NOCASE ASC
        LIMIT ?
        """
        }
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        let escapedLikeQuery = escapeLikePattern(normalizedQuery)
        if usesTrigramIndex || usesShortIndex {
            try bind("\"\(normalizedQuery.replacingOccurrences(of: "\"", with: "\"\""))\"", to: statement, index: 1)
        } else {
            try bind("%\(escapedLikeQuery)%", to: statement, index: 1)
        }
        try bind(normalizedQuery, to: statement, index: 2)
        try bind("\(escapedLikeQuery)%", to: statement, index: 3)
        sqlite3_bind_int(statement, 4, Int32(max(1, limit)))

        var records: [FileIndexRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let path = String(cString: sqlite3_column_text(statement, 0))
            let rootPath = String(cString: sqlite3_column_text(statement, 1))
            let record = FileIndexRecord(
                path: path,
                rootPath: rootPath,
                contentType: String(cString: sqlite3_column_text(statement, 3)),
                size: sqlite3_column_int64(statement, 4),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
                modifiedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
                isDirectory: sqlite3_column_int(statement, 7) != 0
            )
            records.append(record)
        }
        return records
    }

    public func recordCount() throws -> Int {
        let statement = try prepare("SELECT COUNT(*) FROM files")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw FileIndexStoreError.executionFailed }
        return Int(sqlite3_column_int64(statement, 0))
    }

    public func schemaVersion() throws -> Int {
        try Self.schemaVersion(in: database)
    }

    public func close() throws {
        guard let database else { return }
        guard sqlite3_close_v2(database) == SQLITE_OK else { throw FileIndexStoreError.closeFailed }
        self.database = nil
    }

    public func delete(root: String) throws {
        let statement = try prepare("DELETE FROM files WHERE root_path = ?")
        defer { sqlite3_finalize(statement) }
        try bind(root, to: statement, index: 1)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw FileIndexStoreError.executionFailed }
    }

    public func delete(path: String) throws {
        let statement = try prepare("DELETE FROM files WHERE path = ?")
        defer { sqlite3_finalize(statement) }
        try bind(path, to: statement, index: 1)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw FileIndexStoreError.executionFailed }
    }

    public func delete(subtree path: String) throws {
        let statement = try prepare("""
        DELETE FROM files
        WHERE path = ? OR substr(path, 1, length(?) + 1) = ? || '/'
        """)
        defer { sqlite3_finalize(statement) }
        try bind(path, to: statement, index: 1)
        try bind(path, to: statement, index: 2)
        try bind(path, to: statement, index: 3)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw FileIndexStoreError.executionFailed }
    }

    private static let upsertSQL = """
        INSERT INTO files (path, root_path, file_name, normalized_name, content_type, size, created_at, modified_at, is_directory, short_search_tokens)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(path) DO UPDATE SET
          root_path = excluded.root_path,
          file_name = excluded.file_name,
          normalized_name = excluded.normalized_name,
          content_type = excluded.content_type,
          size = excluded.size,
          created_at = excluded.created_at,
          modified_at = excluded.modified_at,
          is_directory = excluded.is_directory,
          short_search_tokens = excluded.short_search_tokens
        """

    private func bind(_ record: FileIndexRecord, to statement: OpaquePointer) throws {
        try bind(record.path, to: statement, index: 1)
        try bind(record.rootPath, to: statement, index: 2)
        try bind(record.fileName, to: statement, index: 3)
        try bind(normalize(record.fileName), to: statement, index: 4)
        try bind(record.contentType, to: statement, index: 5)
        sqlite3_bind_int64(statement, 6, record.size)
        sqlite3_bind_double(statement, 7, record.createdAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 8, record.modifiedAt.timeIntervalSince1970)
        sqlite3_bind_int(statement, 9, record.isDirectory ? 1 : 0)
        try bind(Self.shortSearchTokens(for: normalize(record.fileName)), to: statement, index: 10)
    }

    private static func canUseShortIndex(_ query: String) -> Bool {
        query.unicodeScalars.allSatisfy(CharacterSet.alphanumerics.contains)
    }

    private static func shortSearchTokens(for normalizedName: String) -> String {
        let characters = Array(normalizedName)
        guard !characters.isEmpty else { return "" }
        var tokens = characters.map(String.init)
        if characters.count > 1 {
            tokens.append(contentsOf: (0..<(characters.count - 1)).map {
                String(characters[$0...($0 + 1)])
            })
        }
        return tokens.joined(separator: " ")
    }

    private static func populateShortSearchTokens(in database: OpaquePointer?) throws {
        var selectStatement: OpaquePointer?
        var updateStatement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT rowid, normalized_name FROM files", -1, &selectStatement, nil) == SQLITE_OK,
              let selectStatement,
              sqlite3_prepare_v2(database, "UPDATE files SET short_search_tokens = ? WHERE rowid = ?", -1, &updateStatement, nil) == SQLITE_OK,
              let updateStatement else {
            sqlite3_finalize(selectStatement)
            sqlite3_finalize(updateStatement)
            throw FileIndexStoreError.executionFailed
        }
        defer {
            sqlite3_finalize(selectStatement)
            sqlite3_finalize(updateStatement)
        }

        let destructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        while sqlite3_step(selectStatement) == SQLITE_ROW {
            let rowID = sqlite3_column_int64(selectStatement, 0)
            let normalizedName = String(cString: sqlite3_column_text(selectStatement, 1))
            let tokens = shortSearchTokens(for: normalizedName)
            guard sqlite3_bind_text(updateStatement, 1, tokens, -1, destructor) == SQLITE_OK else {
                throw FileIndexStoreError.executionFailed
            }
            sqlite3_bind_int64(updateStatement, 2, rowID)
            guard sqlite3_step(updateStatement) == SQLITE_DONE else {
                throw FileIndexStoreError.executionFailed
            }
            sqlite3_reset(updateStatement)
            sqlite3_clear_bindings(updateStatement)
        }
    }

    private static func execute(_ database: OpaquePointer?, sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw FileIndexStoreError.executionFailed }
    }

    private static func schemaVersion(in database: OpaquePointer?) throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw FileIndexStoreError.executionFailed }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw FileIndexStoreError.executionFailed }
        return Int(sqlite3_column_int(statement, 0))
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw FileIndexStoreError.executionFailed
        }
        return statement
    }

    private func bind(_ value: String, to statement: OpaquePointer, index: Int32) throws {
        let destructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(statement, index, value, -1, destructor) == SQLITE_OK else {
            throw FileIndexStoreError.executionFailed
        }
    }

    private func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .replacingOccurrences(of: " ", with: "")
    }


    private func escapeLikePattern(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}

public enum FileIndexStoreError: Error, Sendable {
    case openFailed
    case executionFailed
    case closeFailed
    case unsupportedSchemaVersion(Int)
}
