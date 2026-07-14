import Foundation
import ScreenshotFeature

final class ScreenshotThumbnailFixtureEventRecorder: @unchecked Sendable {
    private let outputURL: URL
    private let lock = NSLock()

    init(outputURL: URL) {
        self.outputURL = outputURL
        try? FileManager.default.removeItem(at: outputURL)
    }

    func record(_ name: String, artifactID: UUID? = nil) {
        let fields = [name, artifactID?.uuidString].compactMap { $0 }
        let line = fields.joined(separator: " ") + "\n"
        lock.withLock {
            let directory = outputURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: outputURL.path) {
                try? Data(line.utf8).write(to: outputURL, options: .atomic)
                return
            }
            guard let handle = try? FileHandle(forWritingTo: outputURL) else { return }
            defer { try? handle.close() }
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(line.utf8))
            } catch {
                NSLog("Unable to append screenshot thumbnail fixture event: %@", error.localizedDescription)
            }
        }
    }
}

final class ScreenshotThumbnailFixtureCaptureService: ScreenshotCapturing, @unchecked Sendable {
    private static let pngData = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAUAAAADICAIAAAAWZq/8AAABuUlEQVR42u3TQQ0AAAjEMMC/50MEL5JWwpJ1kgJ+GgnAwICBAQODgQEDAwYGDAwGBgwMGBgMDBgYMDBgYDAwYGDAwICBwcCAgQEDg4EBAwMGBgwMBgYMDBgYMDAYGDAwYGAwMGBgwMCAgcHAgIEBA4OBAQMDBgYMDAYGDAwYGDAwGBgwMGBgMDBgYMDAgIHBwICBAQMDBgYDAwYGDAwGBgwMGBgwMBgYMDBgYMDAYGDAwICBwcCAgQEDAwYGAwMGBgwMBgYMDBgYMDAYGDAwYGDAwGBgwMCAgcHAgIEBAwMGBgMDBgYMDBgYDAwYGDAwGBgwMGBgwMBgYMDAgIEBA4OBAQMDBgYDAwYGDAwYGAwMGBgwMBgYMDBgYMDAYGDAwICBAQODgQEDAwYGAwMGBgwMGBgMDBgYMDBgYDAwYGDAwGBgwMCAgQEDg4EBAwMGBgMDBgYMDBgYDAwYGDAwYGAwMGBgwMBgYMDAgIEBA4OBAQMDBgYMDAYGDAwYGAwMGBgwMGBgMDBgYMDAgIHBwICBAQODgQEDAwYGDAwGBgwMGBgMDBgYMDBgYDAwYGDAwICBwcCAgYGLBaa1BI2J6vhGAAAAAElFTkSuQmCC"
    )!

    private let content: ScreenshotSelectionContent
    private let paths: ScreenshotFeaturePaths
    private let recorder: ScreenshotThumbnailFixtureEventRecorder

    init(
        content: ScreenshotSelectionContent,
        paths: ScreenshotFeaturePaths,
        recorder: ScreenshotThumbnailFixtureEventRecorder
    ) {
        self.content = content
        self.paths = paths
        self.recorder = recorder
    }

    func availableSelectionContent() async throws -> ScreenshotSelectionContent {
        content
    }

    func capture(_ request: ScreenshotCaptureRequest) async throws {
        _ = try await captureArtifact(request)
    }

    func captureArtifact(_ request: ScreenshotCaptureRequest) async throws -> ScreenshotArtifact? {
        let id = UUID()
        let captureRelativePath = "Captures/Fixture/\(id.uuidString).png"
        let thumbnailRelativePath = "Thumbnails/\(id.uuidString).png"
        let captureURL = try paths.resolve(relativePath: captureRelativePath)
        let thumbnailURL = try paths.resolve(relativePath: thumbnailRelativePath)
        try FileManager.default.createDirectory(
            at: captureURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: thumbnailURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Self.pngData.write(to: captureURL, options: .atomic)
        try Self.pngData.write(to: thumbnailURL, options: .atomic)

        let artifact = ScreenshotArtifact(
            id: id,
            createdAt: Date(),
            captureMode: request.mode,
            relativePath: captureRelativePath,
            thumbnailRelativePath: thumbnailRelativePath,
            pointSize: .init(width: 640, height: 360),
            pixelSize: .init(width: 1280, height: 720),
            uniformTypeIdentifier: "public.png",
            sha256: String(repeating: "0", count: 64),
            displays: content.displays
        )
        recorder.record("capture", artifactID: id)
        return artifact
    }

    func sampleColor(_ request: ScreenshotColorSampleRequest) async throws -> ScreenshotColorSample {
        throw ScreenshotFeatureError.targetUnavailable
    }

    func recognize(_ request: ScreenshotRecognitionRequest) async throws -> ScreenshotRecognitionResult {
        recorder.record("recognize", artifactID: request.artifact.id)
        return .init(
            artifactID: request.artifact.id,
            fullText: "缩略图夹具",
            textBlocks: [],
            barcodes: []
        )
    }

    func exportArtifact(_ artifact: ScreenshotArtifact, to destinationURL: URL) async throws -> URL {
        let sourceURL = try paths.resolve(relativePath: artifact.relativePath)
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        recorder.record("export", artifactID: artifact.id)
        return destinationURL
    }

    func deleteArtifact(_ artifact: ScreenshotArtifact) async throws {
        let sourceURL = try paths.resolve(relativePath: artifact.relativePath)
        if FileManager.default.fileExists(atPath: sourceURL.path) {
            try FileManager.default.removeItem(at: sourceURL)
        }
        if let thumbnailRelativePath = artifact.thumbnailRelativePath {
            let thumbnailURL = try paths.resolve(relativePath: thumbnailRelativePath)
            if FileManager.default.fileExists(atPath: thumbnailURL.path) {
                try FileManager.default.removeItem(at: thumbnailURL)
            }
        }
        recorder.record("delete", artifactID: artifact.id)
    }

    func capturePrimaryDisplay() async throws {
        guard let display = content.displays.first else {
            throw ScreenshotFeatureError.noDisplayAvailable
        }
        try await capture(.init(mode: .fullScreen, target: .display(displayID: display.id)))
    }
}

@MainActor
final class ScreenshotThumbnailFixtureClipboardWriter: ScreenshotClipboardWriting {
    private let writer: ScreenshotPasteboardWriter
    private let recorder: ScreenshotThumbnailFixtureEventRecorder

    init(
        paths: ScreenshotFeaturePaths,
        recorder: ScreenshotThumbnailFixtureEventRecorder
    ) {
        writer = ScreenshotPasteboardWriter(pathsProvider: { paths })
        self.recorder = recorder
    }

    func write(_ artifact: ScreenshotArtifact) throws {
        try writer.write(artifact)
        recorder.record("copy", artifactID: artifact.id)
    }
}

@MainActor
final class ScreenshotThumbnailFixtureAnnotationPresenter: ScreenshotArtifactAnnotationPresenting {
    private let recorder: ScreenshotThumbnailFixtureEventRecorder

    init(recorder: ScreenshotThumbnailFixtureEventRecorder) {
        self.recorder = recorder
    }

    func presentForAnnotation(_ artifact: ScreenshotArtifact) throws {
        recorder.record("annotate", artifactID: artifact.id)
    }
}
