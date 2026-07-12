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
        self.path = path
        self.rootPath = rootPath
        self.fileName = URL(fileURLWithPath: path).lastPathComponent
        self.contentType = contentType
        self.size = size
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.isDirectory = isDirectory
    }
}

public actor FileIndexStore {
    private var database: OpaquePointer?

    public init(databaseURL: URL) throws {
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &handle, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw FileIndexStoreError.openFailed
        }
        database = handle
        try Self.execute(handle, sql: """
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
    }

    public static func temporary() throws -> FileIndexStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TouchTests", isDirectory: true)
            .appendingPathComponent("\(UUID().uuidString).sqlite")
        return try FileIndexStore(databaseURL: url)
    }

    public func upsert(_ records: [FileIndexRecord]) throws {
        try Self.execute(database, sql: "BEGIN IMMEDIATE TRANSACTION")
        do {
            for record in records { try upsert(record) }
            try Self.execute(database, sql: "COMMIT")
        } catch {
            try? Self.execute(database, sql: "ROLLBACK")
            throw error
        }
    }

    public func search(_ query: String, limit: Int) throws -> [FileIndexRecord] {
        let statement = try prepare("""
        SELECT path, root_path, file_name, content_type, size, created_at, modified_at, is_directory
        FROM files
        WHERE normalized_name LIKE ?
        ORDER BY file_name COLLATE NOCASE ASC
        LIMIT ?
        """)
        defer { sqlite3_finalize(statement) }
        try bind("%\(normalize(query))%", to: statement, index: 1)
        sqlite3_bind_int(statement, 2, Int32(max(1, limit)))

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

    private func upsert(_ record: FileIndexRecord) throws {
        let statement = try prepare("""
        INSERT INTO files (path, root_path, file_name, normalized_name, content_type, size, created_at, modified_at, is_directory)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(path) DO UPDATE SET
          root_path = excluded.root_path,
          file_name = excluded.file_name,
          normalized_name = excluded.normalized_name,
          content_type = excluded.content_type,
          size = excluded.size,
          created_at = excluded.created_at,
          modified_at = excluded.modified_at,
          is_directory = excluded.is_directory
        """)
        defer { sqlite3_finalize(statement) }
        try bind(record.path, to: statement, index: 1)
        try bind(record.rootPath, to: statement, index: 2)
        try bind(record.fileName, to: statement, index: 3)
        try bind(normalize(record.fileName), to: statement, index: 4)
        try bind(record.contentType, to: statement, index: 5)
        sqlite3_bind_int64(statement, 6, record.size)
        sqlite3_bind_double(statement, 7, record.createdAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 8, record.modifiedAt.timeIntervalSince1970)
        sqlite3_bind_int(statement, 9, record.isDirectory ? 1 : 0)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw FileIndexStoreError.executionFailed }
    }

    private static func execute(_ database: OpaquePointer?, sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw FileIndexStoreError.executionFailed }
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
}

public enum FileIndexStoreError: Error, Sendable {
    case openFailed
    case executionFailed
}
