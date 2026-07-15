import AppKit
import ScreenshotFeature

/// 将一次截图作为同一个剪贴板项目写入 PNG、TIFF 与文件 URL。
///
/// 所有图片数据会在修改剪贴板前准备完成；系统写入失败时会尽力恢复原有项目，
/// 避免因为截图异常清空用户原剪贴板。
@MainActor
final class ScreenshotPasteboardWriter: ScreenshotClipboardWriting {
    typealias PathsProvider = () throws -> ScreenshotFeaturePaths

    private struct PasteboardItemSnapshot {
        var values: [(NSPasteboard.PasteboardType, Data)]
    }

    private let pathsProvider: PathsProvider
    private let pasteboard: NSPasteboard

    init(
        pathsProvider: @escaping PathsProvider = { try ScreenshotFeaturePaths.applicationSupport() },
        pasteboard: NSPasteboard = .general
    ) {
        self.pathsProvider = pathsProvider
        self.pasteboard = pasteboard
    }

    func write(_ artifact: ScreenshotArtifact) throws {
        let imageURL = try pathsProvider().resolve(relativePath: artifact.relativePath)
        try writeImage(
            at: imageURL,
            includesFileURL: true,
            unreadablePath: artifact.relativePath
        )
    }

    /// 将已经渲染完成的图片写入剪贴板。临时渲染文件不会作为 file URL 暴露，
    /// 因而调用方可以在此方法返回后立即安全删除临时文件。
    func writeImage(at imageURL: URL) throws {
        try writeImage(
            at: imageURL,
            includesFileURL: false,
            unreadablePath: imageURL.path
        )
    }

    private func writeImage(
        at imageURL: URL,
        includesFileURL: Bool,
        unreadablePath: String
    ) throws {
        guard let image = NSImage(contentsOf: imageURL),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw ScreenshotClipboardError.imageUnreadable(relativePath: unreadablePath)
        }

        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        item.setData(tiff, forType: .tiff)
        if includesFileURL {
            item.setString(imageURL.absoluteString, forType: .fileURL)
        }

        let previousItems = snapshotItems()
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else {
            restore(previousItems)
            throw ScreenshotClipboardError.pasteboardWriteFailed
        }
    }

    private func snapshotItems() -> [PasteboardItemSnapshot] {
        (pasteboard.pasteboardItems ?? []).map { item in
            PasteboardItemSnapshot(values: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            })
        }
    }

    private func restore(_ snapshots: [PasteboardItemSnapshot]) {
        pasteboard.clearContents()
        let items = snapshots.map { snapshot in
            let item = NSPasteboardItem()
            for (type, data) in snapshot.values {
                item.setData(data, forType: type)
            }
            return item
        }
        if !items.isEmpty {
            _ = pasteboard.writeObjects(items)
        }
    }
}
