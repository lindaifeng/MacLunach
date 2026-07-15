import AppKit
import Foundation
import ScreenshotFeature

/// 标注编辑器 UI 测试夹具。所有保存和导出都在本地完成，不连接截图 XPC 服务，
/// 因而不会触发录屏权限、指纹确认或污染用户的真实截图项目。
@MainActor
enum ScreenshotAnnotationFixture {
    static func makeController(
        outputURL: URL,
        exportDestination: URL? = nil,
        themeStore: ThemeStore = ThemeStore(),
        failFirstExport: Bool = false,
        failFirstCopy: Bool = false
    ) -> AnnotationEditorController {
        let recorder = ScreenshotAnnotationFixtureEventRecorder(outputURL: outputURL)
        let image = makeSourceImage()
        let artifact = ScreenshotArtifact(
            id: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
            createdAt: Date(timeIntervalSince1970: 100),
            captureMode: .region,
            relativePath: "Captures/fixture.png",
            thumbnailRelativePath: nil,
            pointSize: .init(width: 800, height: 600),
            pixelSize: .init(width: 1_600, height: 1_200),
            uniformTypeIdentifier: "public.png",
            sha256: "fixture",
            displays: []
        )
        let exportSelectionProvider: AnnotationEditorController.ExportSelectionProvider?
        if let exportDestination {
            exportSelectionProvider = { _ in
                (
                    destination: exportDestination,
                    output: ScreenshotOutputOptions(format: .png, quality: 1),
                    allowsOverwrite: FileManager.default.fileExists(atPath: exportDestination.path)
                )
            }
        } else {
            exportSelectionProvider = nil
        }

        return AnnotationEditorController(
            artifact: artifact,
            sourceImage: image,
            sourceURL: URL(fileURLWithPath: "/tmp/fixture.png"),
            themeStore: themeStore,
            saveProject: { document in
                recorder.record("save \(document.layers.count)")
            },
            exportDocument: { document, destination, output, allowsOverwrite in
                let operation = destination.path.contains("/TouchAnnotationClipboard/")
                    ? "copy"
                    : "export"
                recorder.record(
                    "\(operation)-attempt \(document.layers.count) \(output.format.rawValue) \(allowsOverwrite)"
                )
                let shouldFail = operation == "copy" ? failFirstCopy : failFirstExport
                if shouldFail, recorder.consumeFirstFailure(for: operation) {
                    recorder.record("\(operation)-failed \(document.layers.count)")
                    throw ScreenshotFeatureError.storageFailed(
                        message: "夹具模拟\(operation == "copy" ? "复制" : "导出")失败"
                    )
                }

                let directory = destination.deletingLastPathComponent()
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
                guard let data = image.tiffRepresentation else {
                    throw ScreenshotFeatureError.encodingFailed
                }
                if !allowsOverwrite, FileManager.default.fileExists(atPath: destination.path) {
                    throw ScreenshotFeatureError.storageFailed(message: "目标文件已存在")
                }
                try data.write(to: destination, options: .atomic)
                recorder.record("\(operation)-success \(document.layers.count)")
                recorder.record("export \(output.format.rawValue) \(allowsOverwrite)")
            },
            exportSelectionProvider: exportSelectionProvider,
            onClose: { artifactID in
                recorder.record("close \(artifactID.uuidString)")
            }
        )
    }

    private static func makeSourceImage() -> NSImage {
        NSImage(size: NSSize(width: 800, height: 600), flipped: false) { rect in
            NSColor(calibratedRed: 0.12, green: 0.16, blue: 0.24, alpha: 1).setFill()
            rect.fill()
            NSColor(calibratedRed: 0.25, green: 0.55, blue: 0.95, alpha: 1).setFill()
            NSBezierPath(
                roundedRect: rect.insetBy(dx: 120, dy: 100),
                xRadius: 28,
                yRadius: 28
            ).fill()
            return true
        }
    }
}

private final class ScreenshotAnnotationFixtureEventRecorder: @unchecked Sendable {
    private let outputURL: URL
    private let lock = NSLock()
    private var failedOperations: Set<String> = []

    init(outputURL: URL) {
        self.outputURL = outputURL
        try? FileManager.default.removeItem(at: outputURL)
    }

    func record(_ event: String) {
        let data = Data((event + "\n").utf8)
        lock.withLock {
            try? FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: outputURL.path) {
                try? data.write(to: outputURL, options: .atomic)
                return
            }
            guard let handle = try? FileHandle(forWritingTo: outputURL) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }

    func consumeFirstFailure(for operation: String) -> Bool {
        lock.withLock {
            failedOperations.insert(operation).inserted
        }
    }
}
