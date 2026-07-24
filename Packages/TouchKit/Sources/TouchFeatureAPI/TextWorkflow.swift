import Foundation

public enum TextWorkflowSource: String, Codable, Hashable, Sendable {
    case screenCapture
    case ocrWorkspace
    case external
}

public struct TextTranslationRequest: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public let version: Int
    public let text: String
    public let source: TextWorkflowSource
    public let recognizedLanguageCode: String?

    public init(version: Int = currentVersion, text: String, source: TextWorkflowSource, recognizedLanguageCode: String? = nil) {
        self.version = version
        self.text = text
        self.source = source
        self.recognizedLanguageCode = recognizedLanguageCode
    }
}

public enum TextWorkflowError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedVersion(Int)
    case emptyText
    case noTranslationHandler

    public var errorDescription: String? {
        switch self {
        case let .unsupportedVersion(version): "不支持的文本工作流版本：\(version)"
        case .emptyText: "没有可处理的文字"
        case .noTranslationHandler: "翻译功能当前不可用"
        }
    }
}

public actor TextWorkflowRouter {
    public typealias TranslationHandler = @Sendable (TextTranslationRequest) async throws -> Void
    private var translationHandler: TranslationHandler?

    public init() {}

    public func registerTranslationHandler(_ handler: @escaping TranslationHandler) {
        translationHandler = handler
    }

    public func unregisterTranslationHandler() {
        translationHandler = nil
    }

    public func routeToTranslation(_ request: TextTranslationRequest) async throws {
        guard request.version == TextTranslationRequest.currentVersion else {
            throw TextWorkflowError.unsupportedVersion(request.version)
        }
        guard !request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TextWorkflowError.emptyText
        }
        guard let translationHandler else { throw TextWorkflowError.noTranslationHandler }
        try await translationHandler(request)
    }
}

public struct ScreenTextCaptureResult: Equatable, Sendable {
    public let text: String
    public let recognizedLanguageCode: String?
    /// 仅供当前文字工作台展示的内存预览，不代表持久化截图历史。
    public let previewImageData: Data?

    public init(
        text: String,
        recognizedLanguageCode: String? = nil,
        previewImageData: Data? = nil
    ) {
        self.text = text
        self.recognizedLanguageCode = recognizedLanguageCode
        self.previewImageData = previewImageData
    }
}

public enum ScreenTextCaptureError: Error, Equatable, LocalizedError, Sendable {
    case permissionRequired
    case cancelled
    case noText
    case busy
    case timedOut
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .permissionRequired: "需要在设置 → 权限中开启屏幕录制权限"
        case .cancelled: "已取消截图"
        case .noText: "选区中没有识别到文字"
        case .busy: "已有截图任务正在进行"
        case .timedOut: "文字识别超时，请重试"
        case let .unavailable(message): message
        }
    }
}

public protocol ScreenTextCapturing: Sendable {
    func captureText() async throws -> ScreenTextCaptureResult
    func cancelCapture() async
}
