import Foundation
import CryptoKit
import SQLite3
#if canImport(Security)
import Security
#endif

public struct KeychainClipboardKeyProvider: ClipboardKeyProviding, @unchecked Sendable {
    private let service: String
    private let account: String
    public init(service: String = "me.touch.launcher.clipboard", account: String = "encryption-key-v1") {
        self.service = service; self.account = account
    }

    public func loadOrCreateKey() throws -> SymmetricKey {
        #if canImport(Security)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, data.count == 32 { return SymmetricKey(data: data) }
        guard status == errSecItemNotFound else { throw ClipboardRepositoryError.keyUnavailable }
        let data = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
        var add = query
        add.removeValue(forKey: kSecReturnData as String)
        add.removeValue(forKey: kSecMatchLimit as String)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw ClipboardRepositoryError.keyUnavailable }
        return SymmetricKey(data: data)
        #else
        throw ClipboardRepositoryError.keyUnavailable
        #endif
    }

    public func deleteKey() throws {
        #if canImport(Security)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ClipboardRepositoryError.keyUnavailable }
        #endif
    }
}

public actor EncryptedClipboardRepository {
    public static let ordinaryLimit = 100
    nonisolated(unsafe) private var database: OpaquePointer?
    private let keyProvider: any ClipboardKeyProviding
    private let crypto = ClipboardCrypto()

    public init(databaseURL: URL, keyProvider: any ClipboardKeyProviding) throws {
        self.keyProvider = keyProvider
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK else { throw ClipboardRepositoryError.corruptStore("无法打开数据库") }
        guard sqlite3_exec(database, "PRAGMA secure_delete=ON; PRAGMA journal_mode=WAL; CREATE TABLE IF NOT EXISTS entries(id TEXT PRIMARY KEY, created REAL NOT NULL, favorite INTEGER NOT NULL, kind TEXT NOT NULL, fingerprint TEXT NOT NULL UNIQUE, payload BLOB NOT NULL);", nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(database); database = nil; throw ClipboardRepositoryError.corruptStore("无法初始化数据库")
        }
    }

    deinit { if let database { sqlite3_close(database) } }

    @discardableResult
    public func record(_ content: ClipboardContent, at date: Date = Date()) throws -> ClipboardEntry {
        let data = content.data
        let fingerprint = crypto.fingerprint(data)
        if let existing = try entry(fingerprint: fingerprint) {
            try updateCreatedDate(date, id: existing.id)
            return .init(
                id: existing.id,
                createdAt: date,
                kind: existing.kind,
                isFavorite: existing.isFavorite
            )
        }
        let key = try keyProvider.loadOrCreateKey()
        let sealed = try crypto.seal(data, using: key)
        let entry = ClipboardEntry(createdAt: date, kind: content.kind)
        let sql = "INSERT INTO entries(id,created,favorite,kind,fingerprint,payload) VALUES(?,?,?,?,?,?)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw storeError() }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, entry.id.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(statement, 2, date.timeIntervalSince1970)
        sqlite3_bind_int(statement, 3, 0)
        sqlite3_bind_text(statement, 4, entry.kind.rawValue, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 5, fingerprint, -1, SQLITE_TRANSIENT)
        _ = sealed.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, 6, bytes.baseAddress, Int32(bytes.count), SQLITE_TRANSIENT)
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw storeError() }
        try trimOrdinaryHistory()
        return entry
    }

    public func entries() throws -> [ClipboardEntry] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT id,created,favorite,kind FROM entries ORDER BY created DESC", -1, &statement, nil) == SQLITE_OK else { throw storeError() }
        defer { sqlite3_finalize(statement) }
        var result: [ClipboardEntry] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idText = sqlite3_column_text(statement, 0), let id = UUID(uuidString: String(cString: idText)), let kindText = sqlite3_column_text(statement, 3), let kind = ClipboardEntry.Kind(rawValue: String(cString: kindText)) else { continue }
            result.append(.init(id: id, createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)), kind: kind, isFavorite: sqlite3_column_int(statement, 2) != 0))
        }
        return result
    }

    public func content(for id: UUID) throws -> ClipboardContent? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT kind,payload FROM entries WHERE id=?", -1, &statement, nil) == SQLITE_OK else { throw storeError() }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, id.uuidString, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(statement) == SQLITE_ROW, let kindText = sqlite3_column_text(statement, 0), let kind = ClipboardEntry.Kind(rawValue: String(cString: kindText)), let bytes = sqlite3_column_blob(statement, 1) else { return nil }
        let sealed = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 1)))
        let opened = try crypto.open(sealed, using: keyProvider.loadOrCreateKey())
        switch kind { case .text: return String(data: opened, encoding: .utf8).map(ClipboardContent.text); case .image: return .image(opened) }
    }

    /// 读取所有仍可由当前应用专属密钥解密的历史。
    ///
    /// 旧版本、密钥轮换或异常中断可能留下不可恢复的单条密文。该类记录不应阻断
    /// 其他历史；在确认当前密钥可用且仅该条认证失败时，安全删除这条无效记录。
    /// 若钥匙串整体不可用，错误会原样抛出，调用方可提示用户解锁后重试。
    public func readableHistory() throws -> ClipboardReadableHistory {
        var readable: [ClipboardHistoryItem] = []
        var unreadableIDs: [UUID] = []

        for entry in try entries() {
            do {
                guard let content = try content(for: entry.id) else { continue }
                readable.append(.init(entry: entry, content: content))
            } catch ClipboardRepositoryError.invalidCiphertext {
                unreadableIDs.append(entry.id)
            }
        }

        for id in unreadableIDs {
            try delete(id: id)
        }
        return .init(entries: readable, discardedUnreadableCount: unreadableIDs.count)
    }

    public func setFavorite(_ favorite: Bool, id: UUID) throws {
        try execute("UPDATE entries SET favorite=? WHERE id=?", int: favorite ? 1 : 0, text: id.uuidString)
        if !favorite {
            try trimOrdinaryHistory()
        }
    }
    public func delete(id: UUID) throws { try execute("DELETE FROM entries WHERE id=?", textOnly: id.uuidString) }
    public func clearOrdinaryHistory() throws { try executeRaw("DELETE FROM entries WHERE favorite=0") }
    public func clearFavorites() throws { try executeRaw("DELETE FROM entries WHERE favorite=1") }
    public func clearAll() throws { try executeRaw("DELETE FROM entries") }
    public func resetPluginData() throws { try clearAll(); try keyProvider.deleteKey(); try executeRaw("VACUUM") }

    public func search(text query: String, limit: Int = 100) throws -> [(ClipboardEntry, String)] {
        let needle = query.localizedLowercase
        return try readableHistory().entries.prefix(max(0, limit)).compactMap { item in
            guard case let .text(value) = item.content, needle.isEmpty || value.localizedLowercase.contains(needle) else { return nil }
            return (item.entry, value)
        }
    }

    private func entry(fingerprint: String) throws -> ClipboardEntry? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT id,created,favorite,kind FROM entries WHERE fingerprint=?", -1, &statement, nil) == SQLITE_OK else { throw storeError() }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, fingerprint, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(statement) == SQLITE_ROW, let idText = sqlite3_column_text(statement, 0), let id = UUID(uuidString: String(cString: idText)), let kindText = sqlite3_column_text(statement, 3), let kind = ClipboardEntry.Kind(rawValue: String(cString: kindText)) else { return nil }
        return .init(id: id, createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)), kind: kind, isFavorite: sqlite3_column_int(statement, 2) != 0)
    }

    private func trimOrdinaryHistory() throws {
        try executeRaw("DELETE FROM entries WHERE id IN (SELECT id FROM entries WHERE favorite=0 ORDER BY created DESC LIMIT -1 OFFSET \(Self.ordinaryLimit))")
    }
    private func updateCreatedDate(_ date: Date, id: UUID) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "UPDATE entries SET created=? WHERE id=?", -1, &statement, nil) == SQLITE_OK else { throw storeError() }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
        sqlite3_bind_text(statement, 2, id.uuidString, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw storeError() }
    }
    private func executeRaw(_ sql: String) throws { guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw storeError() } }
    private func execute(_ sql: String, int: Int32, text: String) throws {
        var statement: OpaquePointer?; guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw storeError() }; defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, int); sqlite3_bind_text(statement, 2, text, -1, SQLITE_TRANSIENT); guard sqlite3_step(statement) == SQLITE_DONE else { throw storeError() }
    }
    private func execute(_ sql: String, textOnly: String) throws {
        var statement: OpaquePointer?; guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw storeError() }; defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, textOnly, -1, SQLITE_TRANSIENT); guard sqlite3_step(statement) == SQLITE_DONE else { throw storeError() }
    }
    private func storeError() -> ClipboardRepositoryError { .corruptStore(database.flatMap { sqlite3_errmsg($0) }.map(String.init(cString:)) ?? "未知数据库错误") }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
