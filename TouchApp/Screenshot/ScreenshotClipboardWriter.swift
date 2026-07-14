import AppKit
import ScreenshotFeature

@MainActor
protocol ScreenshotClipboardWriting: AnyObject {
    func write(_ artifact: ScreenshotArtifact) throws
}

enum ScreenshotClipboardError: Error, Equatable {
    case imageUnreadable(relativePath: String)
    case pasteboardWriteFailed
}

/// 将截图服务返回的相对路径安全解析为图片，并写入系统剪贴板。
@MainActor
final class SystemScreenshotClipboardWriter: ScreenshotClipboardWriting {
    typealias PathsProvider = () throws -> ScreenshotFeaturePaths
    typealias ImageWriter = (NSImage) -> Bool

    private let pathsProvider: PathsProvider
    private let imageWriter: ImageWriter

    init(
        pathsProvider: @escaping PathsProvider = { try ScreenshotFeaturePaths.applicationSupport() },
        pasteboard: NSPasteboard = .general
    ) {
        self.pathsProvider = pathsProvider
        imageWriter = { image in
            pasteboard.clearContents()
            return pasteboard.writeObjects([image])
        }
    }

    init(
        pathsProvider: @escaping PathsProvider,
        imageWriter: @escaping ImageWriter
    ) {
        self.pathsProvider = pathsProvider
        self.imageWriter = imageWriter
    }

    func write(_ artifact: ScreenshotArtifact) throws {
        let imageURL = try pathsProvider().resolve(relativePath: artifact.relativePath)
        guard let image = NSImage(contentsOf: imageURL) else {
            throw ScreenshotClipboardError.imageUnreadable(relativePath: artifact.relativePath)
        }

        guard imageWriter(image) else {
            throw ScreenshotClipboardError.pasteboardWriteFailed
        }
    }
}
