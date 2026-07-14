import Foundation
import ScreenshotFeature

public protocol ScreenshotArtifactExportFileOperating: Sendable {
    func createDirectory(at url: URL) throws
    func copyItem(at source: URL, to destination: URL) throws
    func fileExists(at url: URL) -> Bool
}

public struct LocalScreenshotArtifactExportFileOperations: ScreenshotArtifactExportFileOperating, @unchecked Sendable {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func createDirectory(at url: URL) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    public func copyItem(at source: URL, to destination: URL) throws {
        try fileManager.copyItem(at: source, to: destination)
    }

    public func fileExists(at url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
    }
}

public struct ScreenshotArtifactFileController: Sendable {
    private let paths: ScreenshotFeaturePaths
    private let fileOperations: any ScreenshotArtifactExportFileOperating

    public init(
        rootURL: URL,
        fileOperations: any ScreenshotArtifactExportFileOperating = LocalScreenshotArtifactExportFileOperations()
    ) {
        paths = ScreenshotFeaturePaths(rootURL: rootURL)
        self.fileOperations = fileOperations
    }

    /// 将服务私有目录内的截图复制到用户选定的精确目标路径。
    /// 为避免覆盖用户文件，目标已存在时始终失败。
    public func export(_ request: ScreenshotArtifactExportRequest) throws -> ScreenshotArtifactExportResult {
        let source: URL
        do {
            source = try paths.resolve(relativePath: request.artifact.relativePath)
        } catch {
            throw ScreenshotFeatureError.storageFailed(message: "截图源路径无效：\(error)")
        }
        guard fileOperations.fileExists(at: source) else {
            throw ScreenshotFeatureError.targetUnavailable
        }

        guard NSString(string: request.destinationPath).isAbsolutePath else {
            throw ScreenshotFeatureError.storageFailed(message: "导出目标必须是绝对路径")
        }
        let destination = request.destinationURL.standardizedFileURL
        guard !fileOperations.fileExists(at: destination) else {
            throw ScreenshotFeatureError.storageFailed(message: "目标文件已存在")
        }

        do {
            try fileOperations.createDirectory(at: destination.deletingLastPathComponent())
            try fileOperations.copyItem(at: source, to: destination)
            return ScreenshotArtifactExportResult(destinationURL: destination)
        } catch let error as ScreenshotFeatureError {
            throw error
        } catch {
            throw ScreenshotFeatureError.storageFailed(message: "导出截图失败：\(error)")
        }
    }
}
