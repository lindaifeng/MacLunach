import XCTest
import CryptoKit
@testable import ClipboardFeature

final class ClipboardFeatureTests: XCTestCase {
    func testEncryptionRoundTripAndWrongKeyFails() throws {
        let crypto = ClipboardCrypto(), key = SymmetricKey(size: .bits256), data = Data("秘密".utf8)
        let sealed = try crypto.seal(data, using: key)
        XCTAssertNotEqual(sealed, data)
        XCTAssertEqual(try crypto.open(sealed, using: key), data)
        XCTAssertThrowsError(try crypto.open(sealed, using: SymmetricKey(size: .bits256)))
    }

    func testDedupLimitFavoritesClearAndSearch() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("clipboard.sqlite")
        let provider = TestKeyProvider()
        let repo = try EncryptedClipboardRepository(databaseURL: temp, keyProvider: provider)
        let first = try await repo.record(.text("重复"), at: Date(timeIntervalSince1970: 0))
        let duplicateDate = Date(timeIntervalSince1970: 0.5)
        let duplicate = try await repo.record(.text("重复"), at: duplicateDate)
        XCTAssertEqual(first.id, duplicate.id)
        try await repo.setFavorite(true, id: first.id)
        for index in 0..<105 { _ = try await repo.record(.text("text-\(index)"), at: Date(timeIntervalSince1970: Double(index + 1))) }
        let entries = try await repo.entries()
        XCTAssertEqual(entries.filter { !$0.isFavorite }.count, 100)
        XCTAssertTrue(entries.contains { $0.id == first.id && $0.isFavorite })
        let searchResults = try await repo.search(text: "text-104")
        XCTAssertEqual(searchResults.first?.1, "text-104")
        try await repo.clearOrdinaryHistory()
        let entriesAfterClearing = try await repo.entries()
        XCTAssertEqual(entriesAfterClearing, [ClipboardEntry(id: first.id, createdAt: duplicateDate, kind: .text, isFavorite: true)])
    }

    func testRecordingDuplicateRefreshesItsTimestampWithoutCreatingAnotherEntry() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("clipboard.sqlite")
        let repository = try EncryptedClipboardRepository(databaseURL: databaseURL, keyProvider: TestKeyProvider())
        let firstDate = Date(timeIntervalSince1970: 1)
        let latestDate = Date(timeIntervalSince1970: 2)

        let first = try await repository.record(.text("验证码 123456"), at: firstDate)
        let duplicate = try await repository.record(.text("验证码 123456"), at: latestDate)

        XCTAssertEqual(duplicate.id, first.id)
        XCTAssertEqual(duplicate.createdAt, latestDate)
        let entries = try await repository.entries()
        XCTAssertEqual(entries, [
            ClipboardEntry(id: first.id, createdAt: latestDate, kind: .text, isFavorite: false)
        ])
    }

    func testOrdinaryLimitExcludesFavoritesAndAppliesAgainWhenUnfavoriting() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("clipboard.sqlite")
        let repository = try EncryptedClipboardRepository(
            databaseURL: databaseURL,
            keyProvider: TestKeyProvider()
        )
        let favorite = try await repository.record(
            .text("需要永久保留"),
            at: Date(timeIntervalSince1970: 1)
        )
        try await repository.setFavorite(true, id: favorite.id)

        var newestOrdinaryID: UUID?
        var oldestOrdinaryID: UUID?
        for index in 0...EncryptedClipboardRepository.ordinaryLimit {
            let entry = try await repository.record(
                .text("普通历史-\(index)"),
                at: Date(timeIntervalSince1970: Double(index + 2))
            )
            if index == 0 { oldestOrdinaryID = entry.id }
            newestOrdinaryID = entry.id
        }

        let retainedEntries = try await repository.entries()
        XCTAssertEqual(retainedEntries.filter { !$0.isFavorite }.count, 100)
        XCTAssertEqual(retainedEntries.filter(\.isFavorite).map(\.id), [favorite.id])
        XCTAssertEqual(retainedEntries.count, 101)
        XCTAssertFalse(retainedEntries.contains { $0.id == oldestOrdinaryID })
        XCTAssertTrue(retainedEntries.contains { $0.id == newestOrdinaryID })
        let retainedFavoriteContent = try await repository.content(for: favorite.id)
        XCTAssertEqual(retainedFavoriteContent, .text("需要永久保留"))

        try await repository.setFavorite(false, id: favorite.id)

        let entriesAfterUnfavoriting = try await repository.entries()
        XCTAssertEqual(entriesAfterUnfavoriting.count, 100)
        XCTAssertTrue(entriesAfterUnfavoriting.allSatisfy { !$0.isFavorite })
        XCTAssertFalse(entriesAfterUnfavoriting.contains { $0.id == favorite.id })
        let unfavoritedContent = try await repository.content(for: favorite.id)
        XCTAssertNil(unfavoritedContent)
    }

    func testReadableHistorySkipsOnlyEntriesThatCannotBeDecrypted() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("clipboard.sqlite")
        let provider = RotatingTestKeyProvider()
        let repository = try EncryptedClipboardRepository(databaseURL: databaseURL, keyProvider: provider)
        let unreadable = try await repository.record(.text("旧密文"), at: Date(timeIntervalSince1970: 1))

        provider.rotateKey()
        let readable = try await repository.record(.text("可恢复记录"), at: Date(timeIntervalSince1970: 2))

        let history = try await repository.readableHistory()

        XCTAssertEqual(history.entries.map(\.entry.id), [readable.id])
        XCTAssertEqual(history.entries.first?.content, .text("可恢复记录"))
        XCTAssertEqual(history.discardedUnreadableCount, 1)
        let remainingEntries = try await repository.entries()
        let removedContent = try await repository.content(for: unreadable.id)
        XCTAssertEqual(remainingEntries.map(\.id), [readable.id])
        XCTAssertNil(removedContent)
    }

    func testSearchSkipsEntriesThatCannotBeDecrypted() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("clipboard.sqlite")
        let provider = RotatingTestKeyProvider()
        let repository = try EncryptedClipboardRepository(databaseURL: databaseURL, keyProvider: provider)
        _ = try await repository.record(.text("旧搜索记录"), at: Date(timeIntervalSince1970: 1))

        provider.rotateKey()
        let readable = try await repository.record(.text("当前搜索记录"), at: Date(timeIntervalSince1970: 2))

        let results = try await repository.search(text: "搜索")

        XCTAssertEqual(results.map(\.0.id), [readable.id])
        XCTAssertEqual(results.map(\.1), ["当前搜索记录"])
    }

    func testWritebackGateConsumesOnlyOneMatchingEvent() async {
        let gate = ClipboardWritebackGate(); await gate.markWriteback(fingerprint: "x")
        let ignoresMismatchedFingerprint = await gate.shouldIgnore(fingerprint: "y")
        let ignoresMatchingFingerprint = await gate.shouldIgnore(fingerprint: "x")
        let ignoresConsumedFingerprint = await gate.shouldIgnore(fingerprint: "x")
        XCTAssertFalse(ignoresMismatchedFingerprint)
        XCTAssertTrue(ignoresMatchingFingerprint)
        XCTAssertFalse(ignoresConsumedFingerprint)
    }
}
private final class TestKeyProvider: ClipboardKeyProviding, @unchecked Sendable {
    let key = SymmetricKey(size: .bits256)
    func loadOrCreateKey() throws -> SymmetricKey { key }
    func deleteKey() throws {}
}

private final class RotatingTestKeyProvider: ClipboardKeyProviding, @unchecked Sendable {
    private var key = SymmetricKey(size: .bits256)

    func loadOrCreateKey() throws -> SymmetricKey { key }
    func deleteKey() throws {}
    func rotateKey() { key = SymmetricKey(size: .bits256) }
}
