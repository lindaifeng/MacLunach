import CoreGraphics
import Foundation
import ImageIO
import ScreenshotFeature
import ScreenshotServiceCore
import Testing
import UniformTypeIdentifiers

@Suite("ScreenshotFileStore")
struct ScreenshotFileStoreTests {
    @Test("应用支持目录可用时使用持久化截图根目录")
    func storageRootUsesApplicationSupportDirectoryWhenAvailable() {
        let applicationSupport = URL(fileURLWithPath: "/tmp/Application Support", isDirectory: true)
        let temporaryDirectory = URL(fileURLWithPath: "/tmp/Temporary", isDirectory: true)

        let storageRoot = ScreenshotServiceStorageRoot(
            applicationSupport: .success(applicationSupport),
            temporaryDirectory: temporaryDirectory
        )

        #expect(storageRoot.url == applicationSupport
            .appendingPathComponent("Touch", isDirectory: true)
            .appendingPathComponent("Features", isDirectory: true)
            .appendingPathComponent("me.touch.screenshot", isDirectory: true))
        #expect(!storageRoot.isEphemeral)
    }

    @Test("应用支持目录不可用时降级到临时截图根目录")
    func storageRootFallsBackToTemporaryDirectoryWhenApplicationSupportFails() {
        struct ExpectedFailure: Error {}
        let temporaryDirectory = URL(fileURLWithPath: "/tmp/Temporary", isDirectory: true)

        let storageRoot = ScreenshotServiceStorageRoot(
            applicationSupport: .failure(ExpectedFailure()),
            temporaryDirectory: temporaryDirectory
        )

        #expect(storageRoot.url == temporaryDirectory
            .appendingPathComponent("Touch", isDirectory: true)
            .appendingPathComponent("Features", isDirectory: true)
            .appendingPathComponent("me.touch.screenshot", isDirectory: true))
        #expect(storageRoot.isEphemeral)
    }

    @Test("格式的 UTType、扩展名和 alpha 策略一致")
    func imageFormatDescriptorsAreConsistent() {
        #expect(ScreenshotImageFormatDescriptor.for(.png) == .init(
            uniformTypeIdentifier: UTType.png.identifier,
            filenameExtension: "png",
            preservesAlpha: true
        ))
        #expect(ScreenshotImageFormatDescriptor.for(.jpeg) == .init(
            uniformTypeIdentifier: UTType.jpeg.identifier,
            filenameExtension: "jpg",
            preservesAlpha: false
        ))
        #expect(ScreenshotImageFormatDescriptor.for(.heif) == .init(
            uniformTypeIdentifier: UTType.heic.identifier,
            filenameExtension: "heic",
            preservesAlpha: false
        ))
    }

    @Test("捕获时生成有尺寸上限的独立 PNG 缩略图")
    func captureGeneratesBoundedThumbnail() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ScreenshotFileStore(rootURL: root)
        let image = solidImage(width: 1_200, height: 800)
        let request = ScreenshotCaptureRequest(
            id: UUID(uuidString: "77777777-7777-7777-7777-777777777777")!,
            mode: .region,
            target: .region(displayID: 1, rect: .init(x: 0, y: 0, width: 1_200, height: 800))
        )

        let artifact = try await store.store(
            image: image,
            request: request,
            pointSize: .init(width: 1_200, height: 800),
            displays: []
        )

        let relativePath = try #require(artifact.thumbnailRelativePath)
        #expect(relativePath == "Thumbnails/77777777-7777-7777-7777-777777777777.png")
        let thumbnail = try loadImage(root.appendingPathComponent(relativePath))
        #expect(thumbnail.width == 360)
        #expect(thumbnail.height == 240)
        #expect(root.appendingPathComponent(artifact.relativePath) != root.appendingPathComponent(relativePath))
    }

    @Test("原子写入使用同目录临时文件、fsync 和 rename")
    func atomicWriterSynchronizesAndRenamesInSameDirectory() throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("capture.png")
        let operations = AtomicOperationRecorder()
        let writer = POSIXAtomicFileWriter(observer: { operations.append($0) })
        let bytes = Data("complete-image".utf8)

        try writer.write(bytes, to: destination, replacingExisting: false)

        #expect(try Data(contentsOf: destination) == bytes)
        let events = operations.values
        let temporary = try #require(events.compactMap { operation -> URL? in
            if case let .temporaryFileCreated(url) = operation { return url }
            return nil
        }.first)
        #expect(temporary.deletingLastPathComponent() == destination.deletingLastPathComponent())
        #expect(events.contains(.fileSynchronized(temporary)))
        #expect(events.contains(.renamed(from: temporary, to: destination)))
        #expect(events.contains(.directorySynchronized(directory)))
        #expect(!FileManager.default.fileExists(atPath: temporary.path))
    }

    @Test("原子写入排他模式拒绝覆盖已有文件")
    func atomicWriterCanRejectExistingDestination() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("existing.png")
        let original = Data("original".utf8)
        try original.write(to: destination)

        do {
            try POSIXAtomicFileWriter().write(
                Data("replacement".utf8),
                to: destination,
                replacingExisting: false
            )
            Issue.record("预期排他 rename 拒绝已有目标")
        } catch let error as NSError {
            #expect(error.domain == NSPOSIXErrorDomain)
            #expect(error.code == Int(EEXIST))
        }

        #expect(try Data(contentsOf: destination) == original)
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        #expect(files.map(\.lastPathComponent) == [destination.lastPathComponent])
    }

    @Test("原子写入可在明确允许时替换已有文件")
    func atomicWriterCanReplaceExistingDestination() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("existing.png")
        try Data("original".utf8).write(to: destination)
        let replacement = Data("replacement".utf8)

        try POSIXAtomicFileWriter().write(
            replacement,
            to: destination,
            replacingExisting: true
        )

        #expect(try Data(contentsOf: destination) == replacement)
    }

    @Test("编码失败不创建最终文件或半文件")
    func encodingFailureLeavesNoPartialFile() async throws {
        struct ExpectedFailure: Error {}
        let root = temporaryDirectory()
        let store = ScreenshotFileStore(
            rootURL: root,
            encoder: FailingEncoder(error: ExpectedFailure())
        )
        let request = ScreenshotCaptureRequest(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            mode: .fullScreen,
            target: .display(displayID: 1)
        )

        await #expect(throws: ExpectedFailure.self) {
            try await store.store(
                image: solidTransparentImage(),
                request: request,
                pointSize: .init(width: 2, height: 2),
                displays: []
            )
        }

        let files = recursiveFiles(at: root)
        #expect(files.isEmpty)
    }

    @Test("PNG 保留 alpha，JPEG 输出不透明且 artifact 元数据匹配")
    func realEncodingAppliesAlphaPolicyAndMetadata() async throws {
        let root = temporaryDirectory()
        let store = ScreenshotFileStore(rootURL: root)
        let image = solidTransparentImage()
        let pngRequest = ScreenshotCaptureRequest(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            mode: .region,
            target: .region(displayID: 1, rect: .init(x: 0, y: 0, width: 2, height: 2)),
            output: .init(format: .png, quality: 1)
        )
        let jpegRequest = ScreenshotCaptureRequest(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            mode: .region,
            target: .region(displayID: 1, rect: .init(x: 0, y: 0, width: 2, height: 2)),
            output: .init(format: .jpeg, quality: 1)
        )

        let png = try await store.store(
            image: image,
            request: pngRequest,
            pointSize: .init(width: 2, height: 2),
            displays: []
        )
        let jpeg = try await store.store(
            image: image,
            request: jpegRequest,
            pointSize: .init(width: 2, height: 2),
            displays: []
        )

        #expect(png.relativePath.hasSuffix(".png"))
        #expect(png.uniformTypeIdentifier == UTType.png.identifier)
        #expect(jpeg.relativePath.hasSuffix(".jpg"))
        #expect(jpeg.uniformTypeIdentifier == UTType.jpeg.identifier)
        #expect(!png.sha256.isEmpty && !jpeg.sha256.isEmpty)
        let pngImage = try loadImage(root.appendingPathComponent(png.relativePath))
        let jpegImage = try loadImage(root.appendingPathComponent(jpeg.relativePath))
        #expect(pngImage.alphaInfo != .none && pngImage.alphaInfo != .noneSkipFirst && pngImage.alphaInfo != .noneSkipLast)
        #expect(jpegImage.alphaInfo == .none || jpegImage.alphaInfo == .noneSkipFirst || jpegImage.alphaInfo == .noneSkipLast)
    }

    @Test("HEIF 使用 HEIC 文件扩展名、UTType 并输出不透明图像")
    func heifEncodingProducesDecodableOpaqueImage() async throws {
        let root = temporaryDirectory()
        let store = ScreenshotFileStore(rootURL: root)
        let request = ScreenshotCaptureRequest(
            id: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
            mode: .fullScreen,
            target: .display(displayID: 1),
            output: .init(format: .heif, quality: 0.9)
        )

        let artifact = try await store.store(
            image: solidTransparentImage(),
            request: request,
            pointSize: .init(width: 2, height: 2),
            displays: []
        )

        #expect(artifact.relativePath.hasSuffix(".heic"))
        #expect(artifact.uniformTypeIdentifier == UTType.heic.identifier)
        let image = try loadImage(root.appendingPathComponent(artifact.relativePath))
        #expect(image.alphaInfo == .none || image.alphaInfo == .noneSkipFirst || image.alphaInfo == .noneSkipLast)
    }
}

private struct FailingEncoder: ScreenshotImageEncoding, @unchecked Sendable {
    let error: any Error
    func encode(_ image: CGImage, options: ScreenshotOutputOptions) throws -> Data { throw error }
}

private final class AtomicOperationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var operations: [AtomicFileOperation] = []
    func append(_ operation: AtomicFileOperation) { lock.withLock { operations.append(operation) } }
    var values: [AtomicFileOperation] { lock.withLock { operations } }
}

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("TouchFileStoreTests-\(UUID().uuidString)", isDirectory: true)
}

private func recursiveFiles(at root: URL) -> [URL] {
    guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
    return enumerator.compactMap { $0 as? URL }.filter {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }
}

private func solidTransparentImage() -> CGImage {
    let context = CGContext(
        data: nil,
        width: 2,
        height: 2,
        bitsPerComponent: 8,
        bytesPerRow: 8,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(red: 1, green: 0, blue: 0, alpha: 0.25)
    context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
    return context.makeImage()!
}

private func solidImage(width: Int, height: Int) -> CGImage {
    let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(red: 0.1, green: 0.4, blue: 0.9, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}

private func loadImage(_ url: URL) throws -> CGImage {
    let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
}
