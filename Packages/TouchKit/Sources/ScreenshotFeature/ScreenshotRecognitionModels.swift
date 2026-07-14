import Foundation

public struct ScreenshotRecognitionRequest: Codable, Equatable, Sendable {
    public var artifact: ScreenshotArtifact
    public var configuration: ScreenshotOCRConfiguration

    public init(
        artifact: ScreenshotArtifact,
        configuration: ScreenshotOCRConfiguration = .init()
    ) {
        self.artifact = artifact
        self.configuration = configuration
    }
}

public struct ScreenshotRecognizedTextBlock: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var text: String
    public var confidence: Double
    /// Vision 坐标系中的规范化边界（左下角为原点，数值范围 0...1）。
    public var normalizedBounds: ScreenshotRect

    public init(
        id: UUID = UUID(),
        text: String,
        confidence: Double,
        normalizedBounds: ScreenshotRect
    ) {
        self.id = id
        self.text = text
        self.confidence = confidence
        self.normalizedBounds = normalizedBounds
    }
}

public struct ScreenshotRecognizedBarcode: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var payload: String
    public var symbology: String
    /// Vision 坐标系中的规范化边界（左下角为原点，数值范围 0...1）。
    public var normalizedBounds: ScreenshotRect
    /// 仅 http/https 且包含主机名时才提供。调用方仍必须在打开前取得用户确认。
    public var safeURL: URL?

    public init(
        id: UUID = UUID(),
        payload: String,
        symbology: String,
        normalizedBounds: ScreenshotRect,
        safeURL: URL? = nil
    ) {
        self.id = id
        self.payload = payload
        self.symbology = symbology
        self.normalizedBounds = normalizedBounds
        self.safeURL = safeURL ?? Self.validatedURL(from: payload)
    }

    public static func validatedURL(from payload: String) -> URL? {
        guard let components = URLComponents(string: payload),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.isEmpty == false else { return nil }
        return components.url
    }
}

public struct ScreenshotRecognitionResult: Codable, Equatable, Sendable {
    public var artifactID: UUID
    public var fullText: String
    public var textBlocks: [ScreenshotRecognizedTextBlock]
    public var barcodes: [ScreenshotRecognizedBarcode]

    public init(
        artifactID: UUID,
        fullText: String,
        textBlocks: [ScreenshotRecognizedTextBlock],
        barcodes: [ScreenshotRecognizedBarcode]
    ) {
        self.artifactID = artifactID
        self.fullText = fullText
        self.textBlocks = textBlocks
        self.barcodes = barcodes
    }
}
