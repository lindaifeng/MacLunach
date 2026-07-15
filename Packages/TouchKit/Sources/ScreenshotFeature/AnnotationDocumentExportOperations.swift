import Foundation

public struct AnnotationDocumentExportRequest: Codable, Equatable, Sendable {
    public var document: AnnotationDocument
    public var destinationPath: String
    public var output: ScreenshotOutputOptions
    /// 仅在用户已经通过系统保存面板确认覆盖时设为 true。
    public var allowsOverwrite: Bool

    public init(
        document: AnnotationDocument,
        destinationURL: URL,
        output: ScreenshotOutputOptions,
        allowsOverwrite: Bool = false
    ) {
        self.document = document
        destinationPath = destinationURL.path
        self.output = output
        self.allowsOverwrite = allowsOverwrite
    }

    public var destinationURL: URL {
        URL(fileURLWithPath: destinationPath)
    }
}

public struct AnnotationDocumentExportResult: Codable, Equatable, Sendable {
    public var destinationPath: String

    public init(destinationURL: URL) {
        destinationPath = destinationURL.path
    }

    public var destinationURL: URL {
        URL(fileURLWithPath: destinationPath)
    }
}
