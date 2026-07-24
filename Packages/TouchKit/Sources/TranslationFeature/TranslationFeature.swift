import Foundation
import TouchFeatureAPI

public struct TranslationLanguage: Codable, Hashable, Identifiable, Sendable {
    public let code: String
    public let displayName: String
    public var id: String { code }
    public init(code: String, displayName: String) { self.code = code; self.displayName = displayName }
}

public enum TranslationAvailability: Equatable, Sendable {
    case installed
    case needsDownload
    case unsupported
    case requiresMacOS15
}

public struct TranslationOutput: Equatable, Sendable {
    public let sourceText: String
    public let translatedText: String
    public let detectedSourceLanguageCode: String?
    public init(sourceText: String, translatedText: String, detectedSourceLanguageCode: String? = nil) {
        self.sourceText = sourceText; self.translatedText = translatedText; self.detectedSourceLanguageCode = detectedSourceLanguageCode
    }
}

public enum TranslationProviderError: Error, Equatable, LocalizedError, Sendable {
    case requiresMacOS15
    case languagePairUnsupported
    case languagePackRequired
    case cancelled
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .requiresMacOS15: "需要 macOS 15 才能使用系统离线翻译"
        case .languagePairUnsupported: "系统不支持该语言组合"
        case .languagePackRequired: "需要先下载对应的系统语言包"
        case .cancelled: "翻译已取消"
        case let .failed(message): message
        }
    }
}

public protocol TranslationProvider: Sendable {
    var identifier: String { get }
    func supportedLanguages() async -> [TranslationLanguage]
    func availability(sourceLanguageCode: String?, targetLanguageCode: String) async -> TranslationAvailability
    func prepare(sourceLanguageCode: String?, targetLanguageCode: String) async throws
    func translate(_ text: String, sourceLanguageCode: String?, targetLanguageCode: String) async throws -> TranslationOutput
}

public struct TranslationFeaturePlugin: FeaturePlugin {
    public static let id = "me.touch.translation"
    private let systemVersion: OperatingSystemVersion

    public init(systemVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) { self.systemVersion = systemVersion }

    public let manifest = FeatureManifest(
        id: Self.id, name: "翻译", summary: "截图识别并使用系统离线翻译", symbolName: "character.book.closed",
        defaultOrder: 9, defaultShortcut: .init(modifiers: [], key: "0"),
        capabilities: .init(required: [.screenCapture]), executionMode: .inProcess,
        primaryAction: .perform, settingsPresentation: .firstPartyProvider
    )

    public func initialState() async -> FeatureState {
        systemVersion.majorVersion >= 15 ? .available : .restricted(message: "需要 macOS 15 才能使用系统离线翻译")
    }
    public func perform() async throws -> FeatureActionResult { .presentPanel(featureID: Self.id) }
}
