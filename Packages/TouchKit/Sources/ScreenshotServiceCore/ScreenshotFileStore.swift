import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import ImageIO
import ScreenshotFeature
import UniformTypeIdentifiers

public struct ScreenshotImageFormatDescriptor: Equatable, Sendable {
    public let uniformTypeIdentifier: String
    public let filenameExtension: String
    public let preservesAlpha: Bool

    public init(
        uniformTypeIdentifier: String,
        filenameExtension: String,
        preservesAlpha: Bool
    ) {
        self.uniformTypeIdentifier = uniformTypeIdentifier
        self.filenameExtension = filenameExtension
        self.preservesAlpha = preservesAlpha
    }

    public static func `for`(_ format: ScreenshotImageFormat) -> Self {
        switch format {
        case .png:
            .init(
                uniformTypeIdentifier: UTType.png.identifier,
                filenameExtension: "png",
                preservesAlpha: true
            )
        case .jpeg:
            .init(
                uniformTypeIdentifier: UTType.jpeg.identifier,
                filenameExtension: "jpg",
                preservesAlpha: false
            )
        case .heif:
            .init(
                uniformTypeIdentifier: UTType.heic.identifier,
                filenameExtension: "heic",
                preservesAlpha: false
            )
        }
    }
}

public protocol ScreenshotImageEncoding: Sendable {
    func encode(_ image: CGImage, options: ScreenshotOutputOptions) throws -> Data
}

public struct ImageIOScreenshotEncoder: ScreenshotImageEncoding {
    public init() {}

    public func encode(_ image: CGImage, options: ScreenshotOutputOptions) throws -> Data {
        let descriptor = ScreenshotImageFormatDescriptor.for(options.format)
        let imageToEncode = descriptor.preservesAlpha ? image : try flattenedOnWhite(image)
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            descriptor.uniformTypeIdentifier as CFString,
            1,
            nil
        ) else {
            throw ScreenshotFeatureError.encodingFailed
        }
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: min(1, max(0, options.quality))
        ]
        CGImageDestinationAddImage(destination, imageToEncode, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ScreenshotFeatureError.encodingFailed
        }
        return data as Data
    }

    private func flattenedOnWhite(_ image: CGImage) throws -> CGImage {
        guard let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            throw ScreenshotFeatureError.encodingFailed
        }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let flattened = context.makeImage() else {
            throw ScreenshotFeatureError.encodingFailed
        }
        return flattened
    }
}

public enum AtomicFileOperation: Equatable, Sendable {
    case temporaryFileCreated(URL)
    case fileSynchronized(URL)
    case renamed(from: URL, to: URL)
    case directorySynchronized(URL)
}

public protocol ScreenshotAtomicWriting: Sendable {
    func write(_ data: Data, to destinationURL: URL) throws
}

public enum AnnotationProjectLoadStatus: Equatable, Sendable {
    case loaded
    case recoveredFromMissingProject
    case recoveredFromCorruptProject
}

public struct AnnotationProjectLoadResult: Equatable, Sendable {
    public let document: AnnotationDocument
    public let status: AnnotationProjectLoadStatus

    public init(document: AnnotationDocument, status: AnnotationProjectLoadStatus) {
        self.document = document
        self.status = status
    }
}

public struct POSIXAtomicFileWriter: ScreenshotAtomicWriting {
    public typealias Observer = @Sendable (AtomicFileOperation) -> Void
    private let observer: Observer

    public init(observer: @escaping Observer = { _ in }) {
        self.observer = observer
    }

    public func write(_ data: Data, to destinationURL: URL) throws {
        let directory = destinationURL.deletingLastPathComponent()
        let temporaryURL = directory.appendingPathComponent(
            ".\(destinationURL.lastPathComponent).tmp-\(UUID().uuidString)"
        )
        let descriptor = Darwin.open(temporaryURL.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw posixError(path: temporaryURL.path) }
        observer(.temporaryFileCreated(temporaryURL))

        var isOpen = true
        var shouldRemoveTemporary = true
        defer {
            if isOpen { _ = Darwin.close(descriptor) }
            if shouldRemoveTemporary { _ = Darwin.unlink(temporaryURL.path) }
        }

        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var remaining = rawBuffer.count
            var pointer = baseAddress
            while remaining > 0 {
                let written = Darwin.write(descriptor, pointer, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw posixError(path: temporaryURL.path)
                }
                guard written > 0 else { throw posixError(path: temporaryURL.path) }
                remaining -= written
                pointer = pointer.advanced(by: written)
            }
        }

        guard Darwin.fsync(descriptor) == 0 else { throw posixError(path: temporaryURL.path) }
        observer(.fileSynchronized(temporaryURL))
        guard Darwin.close(descriptor) == 0 else { throw posixError(path: temporaryURL.path) }
        isOpen = false

        guard Darwin.rename(temporaryURL.path, destinationURL.path) == 0 else {
            throw posixError(path: destinationURL.path)
        }
        shouldRemoveTemporary = false
        observer(.renamed(from: temporaryURL, to: destinationURL))

        let directoryDescriptor = Darwin.open(directory.path, O_RDONLY)
        guard directoryDescriptor >= 0 else { throw posixError(path: directory.path) }
        defer { _ = Darwin.close(directoryDescriptor) }
        guard Darwin.fsync(directoryDescriptor) == 0 else { throw posixError(path: directory.path) }
        observer(.directorySynchronized(directory))
    }

    private func posixError(path: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno),
            userInfo: [NSFilePathErrorKey: path]
        )
    }
}

public actor ScreenshotFileStore {
    private let rootURL: URL
    private let encoder: any ScreenshotImageEncoding
    private let writer: any ScreenshotAtomicWriting
    private let fileManager: FileManager
    private let now: @Sendable () -> Date

    public init(
        rootURL: URL,
        encoder: any ScreenshotImageEncoding = ImageIOScreenshotEncoder(),
        writer: any ScreenshotAtomicWriting = POSIXAtomicFileWriter(),
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.rootURL = rootURL.standardizedFileURL
        self.encoder = encoder
        self.writer = writer
        self.fileManager = fileManager
        self.now = now
    }

    public func store(
        image: CGImage,
        request: ScreenshotCaptureRequest,
        pointSize: ScreenshotSize,
        displays: [ScreenshotDisplayDescriptor]
    ) throws -> ScreenshotArtifact {
        try Task.checkCancellation()
        let descriptor = ScreenshotImageFormatDescriptor.for(request.output.format)
        let encoded = try encoder.encode(image, options: request.output)
        try Task.checkCancellation()

        let createdAt = now()
        let components = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: createdAt)
        let year = String(format: "%04d", components.year ?? 0)
        let month = String(format: "%02d", components.month ?? 0)
        let relativeDirectory = "Captures/\(year)/\(month)"
        let directory = rootURL.appendingPathComponent(relativeDirectory, isDirectory: true)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw ScreenshotFeatureError.storageFailed(message: String(describing: error))
        }
        let filename = "\(request.id.uuidString.lowercased()).\(descriptor.filenameExtension)"
        let destination = directory.appendingPathComponent(filename)
        do {
            try writer.write(encoded, to: destination)
            try Task.checkCancellation()
        } catch is CancellationError {
            try? fileManager.removeItem(at: destination)
            throw CancellationError()
        } catch {
            throw ScreenshotFeatureError.storageFailed(message: String(describing: error))
        }

        var thumbnailRelativePath: String?
        do {
            thumbnailRelativePath = try storeThumbnail(image: image, artifactID: request.id)
            try Task.checkCancellation()
        } catch is CancellationError {
            try? fileManager.removeItem(at: destination)
            if let thumbnailRelativePath {
                try? fileManager.removeItem(at: rootURL.appendingPathComponent(thumbnailRelativePath))
            }
            throw CancellationError()
        } catch {
            // 缩略图只用于捕获后的即时预览；生成失败不能覆盖已经成功的原图。
            thumbnailRelativePath = nil
        }

        let digest = SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
        return ScreenshotArtifact(
            id: request.id,
            createdAt: createdAt,
            captureMode: request.mode,
            relativePath: "\(relativeDirectory)/\(filename)",
            thumbnailRelativePath: thumbnailRelativePath,
            pointSize: pointSize,
            pixelSize: .init(width: Double(image.width), height: Double(image.height)),
            uniformTypeIdentifier: descriptor.uniformTypeIdentifier,
            sha256: digest,
            displays: displays
        )
    }

    /// 将项目 JSON 与原图分离，并复用截图文件的 fsync + rename 原子写入协议。
    @discardableResult
    public func saveAnnotationProject(_ document: AnnotationDocument) throws -> String {
        try Task.checkCancellation()
        let relativePath = "Projects/\(document.id.uuidString.lowercased()).touch-annotation.json"
        let destination = try projectURL(for: relativePath)
        do {
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .millisecondsSince1970
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(document)
            try Task.checkCancellation()
            try writer.write(data, to: destination)
            return relativePath
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ScreenshotFeatureError.storageFailed(message: String(describing: error))
        }
    }

    /// 读取失败或 JSON 损坏时返回仅含原图引用的文档，让编辑器仍能打开原截图。
    public func loadAnnotationProject(
        relativePath: String,
        fallbackDocument: AnnotationDocument
    ) throws -> AnnotationProjectLoadResult {
        let source = try projectURL(for: relativePath)
        guard fileManager.fileExists(atPath: source.path) else {
            return .init(
                document: fallbackDocument.restoringOriginalImage(
                    updatedAt: fallbackDocument.updatedAt
                ),
                status: .recoveredFromMissingProject
            )
        }
        do {
            let data = try Data(contentsOf: source, options: [.mappedIfSafe])
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            let document = try decoder.decode(AnnotationDocument.self, from: data)
            return .init(document: document, status: .loaded)
        } catch {
            return .init(
                document: fallbackDocument.restoringOriginalImage(
                    updatedAt: fallbackDocument.updatedAt
                ),
                status: .recoveredFromCorruptProject
            )
        }
    }

    private func projectURL(for relativePath: String) throws -> URL {
        let components = NSString(string: relativePath).pathComponents
        guard components.count == 2,
              components.first == "Projects",
              relativePath.hasSuffix(".touch-annotation.json") else {
            throw ScreenshotFeatureError.storageFailed(message: "Invalid annotation project path")
        }
        do {
            return try ScreenshotFeaturePaths(rootURL: rootURL).resolve(relativePath: relativePath)
        } catch {
            throw ScreenshotFeatureError.storageFailed(message: String(describing: error))
        }
    }

    private func storeThumbnail(image: CGImage, artifactID: UUID) throws -> String {
        try Task.checkCancellation()
        let thumbnail = try Self.makeThumbnail(image)
        let bytes = try ImageIOScreenshotEncoder().encode(
            thumbnail,
            options: .init(format: .png, quality: 1)
        )
        let relativeDirectory = "Thumbnails"
        let directory = rootURL.appendingPathComponent(relativeDirectory, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let filename = "\(artifactID.uuidString.lowercased()).png"
        let destination = directory.appendingPathComponent(filename)
        do {
            try writer.write(bytes, to: destination)
            try Task.checkCancellation()
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
        return "\(relativeDirectory)/\(filename)"
    }

    private static func makeThumbnail(_ image: CGImage) throws -> CGImage {
        let maximumWidth = 360.0
        let maximumHeight = 240.0
        let scale = min(
            1,
            maximumWidth / Double(max(1, image.width)),
            maximumHeight / Double(max(1, image.height))
        )
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ScreenshotFeatureError.encodingFailed
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let thumbnail = context.makeImage() else {
            throw ScreenshotFeatureError.encodingFailed
        }
        return thumbnail
    }
}
