import Foundation
import CryptoKit
import TouchFeatureAPI

public enum ClipboardContent: Equatable, Sendable {
    case text(String)
    case image(Data)

    public var kind: ClipboardEntry.Kind { switch self { case .text: .text; case .image: .image } }
    var data: Data { switch self { case let .text(value): Data(value.utf8); case let .image(value): value } }
}

public struct ClipboardEntry: Identifiable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case text, image }
    public let id: UUID
    public let createdAt: Date
    public let kind: Kind
    public var isFavorite: Bool
    public init(id: UUID = UUID(), createdAt: Date = Date(), kind: Kind, isFavorite: Bool = false) {
        self.id = id; self.createdAt = createdAt; self.kind = kind; self.isFavorite = isFavorite
    }
}

public struct ClipboardHistoryItem: Equatable, Sendable {
    public let entry: ClipboardEntry
    public let content: ClipboardContent

    public init(entry: ClipboardEntry, content: ClipboardContent) {
        self.entry = entry
        self.content = content
    }
}

public struct ClipboardReadableHistory: Equatable, Sendable {
    public let entries: [ClipboardHistoryItem]
    public let discardedUnreadableCount: Int

    public init(entries: [ClipboardHistoryItem], discardedUnreadableCount: Int) {
        self.entries = entries
        self.discardedUnreadableCount = discardedUnreadableCount
    }
}

public enum ClipboardRepositoryError: Error, Equatable, Sendable {
    case keyUnavailable
    case invalidCiphertext
    case corruptStore(String)
}

public protocol ClipboardKeyProviding: Sendable {
    func loadOrCreateKey() throws -> SymmetricKey
    func deleteKey() throws
}

public struct ClipboardCrypto: Sendable {
    public init() {}
    public func seal(_ data: Data, using key: SymmetricKey) throws -> Data {
        guard let combined = try AES.GCM.seal(data, using: key).combined else { throw ClipboardRepositoryError.invalidCiphertext }
        return combined
    }
    public func open(_ data: Data, using key: SymmetricKey) throws -> Data {
        do { return try AES.GCM.open(try AES.GCM.SealedBox(combined: data), using: key) }
        catch { throw ClipboardRepositoryError.invalidCiphertext }
    }
    public func fingerprint(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

public actor ClipboardWritebackGate {
    private var fingerprint: String?
    public init() {}
    public func markWriteback(fingerprint: String) { self.fingerprint = fingerprint }
    public func shouldIgnore(fingerprint: String) -> Bool {
        guard self.fingerprint == fingerprint else { return false }
        self.fingerprint = nil
        return true
    }
}

public struct ClipboardFeaturePlugin: FeaturePlugin {
    public static let id = "me.touch.clipboard"
    public init() {}
    public let manifest = FeatureManifest(
        id: Self.id, name: "剪贴板", summary: "加密保存文本与图片历史", symbolName: "clipboard",
        defaultOrder: 8, defaultShortcut: .init(modifiers: [], key: "9"),
        capabilities: .init(required: [.pasteboardWrite]), executionMode: .inProcess,
        primaryAction: .perform, settingsPresentation: .firstPartyProvider
    )
    public func initialState() async -> FeatureState { .available }
    public func perform() async throws -> FeatureActionResult { .presentPanel(featureID: Self.id) }
}
