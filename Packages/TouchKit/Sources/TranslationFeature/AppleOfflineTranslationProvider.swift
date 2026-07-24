import Foundation
import TouchFeatureAPI

#if canImport(Translation)
@preconcurrency import Translation
#endif

/// 系统离线翻译的可替换 Provider。
///
/// `TranslationSession` 只能由 SwiftUI 的 `translationTask` 生命周期创建，因此
/// 实际会话由主应用注入。此类型负责版本门槛、系统语言包可用性和禁止网络降级的边界。
public actor AppleOfflineTranslationProvider: TranslationProvider {
    public typealias SessionTranslator = @Sendable (
        _ text: String,
        _ sourceLanguageCode: String?,
        _ targetLanguageCode: String
    ) async throws -> TranslationOutput

    public nonisolated let identifier = "apple-on-device"

    private let systemVersion: OperatingSystemVersion
    private var sessionTranslator: SessionTranslator?

    public init(systemVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) {
        self.systemVersion = systemVersion
    }

    public func installSessionTranslator(_ translator: @escaping SessionTranslator) {
        sessionTranslator = translator
    }

    public func clearSessionTranslator() {
        sessionTranslator = nil
    }

    public func supportedLanguages() async -> [TranslationLanguage] {
        guard systemVersion.majorVersion >= 15 else { return [] }

        #if canImport(Translation)
        if #available(macOS 15, *) {
            let languages = await LanguageAvailability().supportedLanguages
            return languages.map { language in
                guard let code = language.languageCode?.identifier else { return nil }
                let name = Locale.current.localizedString(forLanguageCode: code) ?? code
                return TranslationLanguage(code: code, displayName: name)
            }
            .compactMap { $0 }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        }
        #endif

        return []
    }

    public func availability(
        sourceLanguageCode: String?,
        targetLanguageCode: String
    ) async -> TranslationAvailability {
        guard systemVersion.majorVersion >= 15 else { return .requiresMacOS15 }

        #if canImport(Translation)
        if #available(macOS 15, *), let sourceLanguageCode {
            let status = await LanguageAvailability().status(
                from: Locale.Language(identifier: sourceLanguageCode),
                to: Locale.Language(identifier: targetLanguageCode)
            )
            switch status {
            case .installed: return .installed
            case .supported: return .needsDownload
            case .unsupported: return .unsupported
            @unknown default: return .unsupported
            }
        }
        #endif

        // 源语言自动检测时，系统只能在拿到原文后决定准确的语言组合；
        // SwiftUI 会话会继续报告并下载所需语言包。
        return .installed
    }

    public func prepare(sourceLanguageCode: String?, targetLanguageCode: String) async throws {
        switch await availability(sourceLanguageCode: sourceLanguageCode, targetLanguageCode: targetLanguageCode) {
        case .installed: return
        case .needsDownload: throw TranslationProviderError.languagePackRequired
        case .unsupported: throw TranslationProviderError.languagePairUnsupported
        case .requiresMacOS15: throw TranslationProviderError.requiresMacOS15
        }
    }

    public func translate(
        _ text: String,
        sourceLanguageCode: String?,
        targetLanguageCode: String
    ) async throws -> TranslationOutput {
        guard systemVersion.majorVersion >= 15 else {
            throw TranslationProviderError.requiresMacOS15
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranslationProviderError.failed("没有可翻译的文字")
        }
        guard let sessionTranslator else {
            throw TranslationProviderError.failed("系统翻译会话尚未准备好")
        }

        do {
            return try await sessionTranslator(text, sourceLanguageCode, targetLanguageCode)
        } catch is CancellationError {
            throw TranslationProviderError.cancelled
        } catch let error as TranslationProviderError {
            throw error
        } catch {
            throw TranslationProviderError.failed(error.localizedDescription)
        }
    }
}
