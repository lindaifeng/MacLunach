import CoreGraphics
import Foundation
import ImageIO
import ScreenshotFeature
import Testing
@testable import ScreenshotServiceCore

@Suite("标注文档导出")
struct AnnotationDocumentExportTests {
    @Test("通过统一渲染器原子导出 PNG 且不覆盖已有文件")
    func exportsRenderedPNGWithoutOverwriting() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TouchAnnotationExportTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let captures = root.appendingPathComponent("Captures", isDirectory: true)
        try FileManager.default.createDirectory(at: captures, withIntermediateDirectories: true)

        let sourceImage = try whiteImage(width: 32, height: 24)
        let sourceData = try ImageIOScreenshotEncoder().encode(
            sourceImage,
            options: .init(format: .png, quality: 1)
        )
        try sourceData.write(to: captures.appendingPathComponent("source.png"))

        let document = AnnotationDocument(
            sourceImageRelativePath: "Captures/source.png",
            canvasSize: .init(width: 32, height: 24),
            layers: [AnnotationLayer(annotation: ScreenshotAnnotation(
                kind: .line,
                points: [.init(x: 2, y: 2), .init(x: 28, y: 20)],
                style: .init(color: .red, lineWidth: 3)
            ))]
        )
        let destination = root.appendingPathComponent("Exports/annotated.png")
        let request = AnnotationDocumentExportRequest(
            document: document,
            destinationURL: destination,
            output: .init(format: .png, quality: 1)
        )
        let store = ScreenshotFileStore(rootURL: root)

        let result = try await store.exportAnnotationDocument(request)
        #expect(result.destinationURL == destination.standardizedFileURL)
        #expect(FileManager.default.fileExists(atPath: destination.path))
        let source = CGImageSourceCreateWithURL(destination as CFURL, nil)
        let exported = source.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
        #expect(exported?.width == 32)
        #expect(exported?.height == 24)

        var refusedOverwrite = false
        do {
            _ = try await store.exportAnnotationDocument(request)
        } catch {
            refusedOverwrite = true
        }
        #expect(refusedOverwrite)

        let replacementRequest = AnnotationDocumentExportRequest(
            document: document,
            destinationURL: destination,
            output: .init(format: .png, quality: 1),
            allowsOverwrite: true
        )
        let replacement = try await store.exportAnnotationDocument(replacementRequest)
        #expect(replacement.destinationURL == destination.standardizedFileURL)
        #expect(FileManager.default.fileExists(atPath: destination.path))
    }

    @Test("即使允许覆盖也拒绝将目录作为导出目标")
    func neverOverwritesDirectory() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TouchAnnotationExportDirectoryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let captures = root.appendingPathComponent("Captures", isDirectory: true)
        try FileManager.default.createDirectory(at: captures, withIntermediateDirectories: true)
        let sourceData = try ImageIOScreenshotEncoder().encode(
            whiteImage(width: 10, height: 10),
            options: .init(format: .png, quality: 1)
        )
        try sourceData.write(to: captures.appendingPathComponent("source.png"))
        let destination = root.appendingPathComponent("existing.png", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let request = AnnotationDocumentExportRequest(
            document: AnnotationDocument(
                sourceImageRelativePath: "Captures/source.png",
                canvasSize: .init(width: 10, height: 10)
            ),
            destinationURL: destination,
            output: .init(format: .png, quality: 1),
            allowsOverwrite: true
        )

        do {
            _ = try await ScreenshotFileStore(rootURL: root).exportAnnotationDocument(request)
            Issue.record("预期目录目标被拒绝")
        } catch let error as ScreenshotFeatureError {
            guard case .storageFailed = error else {
                Issue.record("错误类型不正确：\(error)")
                return
            }
        }
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }

    @Test("覆盖完成后收到取消不会删除导出目标")
    func cancellationAfterOverwriteKeepsDestination() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TouchAnnotationExportCancellationTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let captures = root.appendingPathComponent("Captures", isDirectory: true)
        try FileManager.default.createDirectory(at: captures, withIntermediateDirectories: true)
        let sourceData = try ImageIOScreenshotEncoder().encode(
            whiteImage(width: 10, height: 10),
            options: .init(format: .png, quality: 1)
        )
        try sourceData.write(to: captures.appendingPathComponent("source.png"))
        let destination = root.appendingPathComponent("existing.png")
        let original = Data("existing-user-file".utf8)
        try original.write(to: destination)
        let request = AnnotationDocumentExportRequest(
            document: AnnotationDocument(
                sourceImageRelativePath: "Captures/source.png",
                canvasSize: .init(width: 10, height: 10)
            ),
            destinationURL: destination,
            output: .init(format: .png, quality: 1),
            allowsOverwrite: true
        )
        let store = ScreenshotFileStore(
            rootURL: root,
            writer: CancellingExportWriter()
        )

        await #expect(throws: CancellationError.self) {
            _ = try await store.exportAnnotationDocument(request)
        }
        #expect(FileManager.default.fileExists(atPath: destination.path))
        #expect(try Data(contentsOf: destination) != original)
    }

    @Test("拒绝原图路径遍历和格式不匹配")
    func rejectsUnsafeSourceAndMismatchedExtension() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TouchAnnotationExportSafetyTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = ScreenshotFileStore(rootURL: root)
        let unsafe = AnnotationDocument(
            sourceImageRelativePath: "../outside.png",
            canvasSize: .init(width: 10, height: 10)
        )
        let request = AnnotationDocumentExportRequest(
            document: unsafe,
            destinationURL: root.appendingPathComponent("unsafe.png"),
            output: .init(format: .png, quality: 1)
        )

        var rejectedTraversal = false
        do {
            _ = try await store.exportAnnotationDocument(request)
        } catch {
            rejectedTraversal = true
        }
        #expect(rejectedTraversal)

        let captures = root.appendingPathComponent("Captures", isDirectory: true)
        try FileManager.default.createDirectory(at: captures, withIntermediateDirectories: true)
        let sourceData = try ImageIOScreenshotEncoder().encode(
            whiteImage(width: 10, height: 10),
            options: .init(format: .png, quality: 1)
        )
        try sourceData.write(to: captures.appendingPathComponent("source.png"))
        let validDocument = AnnotationDocument(
            sourceImageRelativePath: "Captures/source.png",
            canvasSize: .init(width: 10, height: 10)
        )
        let mismatchedRequest = AnnotationDocumentExportRequest(
            document: validDocument,
            destinationURL: root.appendingPathComponent("mismatched.jpg"),
            output: .init(format: .png, quality: 1)
        )

        var rejectedMismatchedExtension = false
        do {
            _ = try await store.exportAnnotationDocument(mismatchedRequest)
        } catch {
            rejectedMismatchedExtension = true
        }
        #expect(rejectedMismatchedExtension)
        #expect(!FileManager.default.fileExists(atPath: mismatchedRequest.destinationPath))
    }

    private func whiteImage(width: Int, height: Int) throws -> CGImage {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ScreenshotFeatureError.encodingFailed
        }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else {
            throw ScreenshotFeatureError.encodingFailed
        }
        return image
    }
}

private struct CancellingExportWriter: ScreenshotAtomicWriting {
    func write(
        _ data: Data,
        to destinationURL: URL,
        replacingExisting: Bool
    ) throws {
        guard replacingExisting else {
            throw ScreenshotFeatureError.storageFailed(message: "测试预期允许覆盖")
        }
        try data.write(to: destinationURL, options: .atomic)
        withUnsafeCurrentTask { task in
            task?.cancel()
        }
    }
}
