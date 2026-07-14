import Foundation
import ScreenshotFeature
import ScreenshotServiceCore
import Testing

@Suite("ScreenshotArtifactFileController")
struct ScreenshotArtifactFileControllerTests {
    @Test("导出将私有截图复制到精确目标路径")
    func exportsArtifactToDestination() throws {
        let root = historyTemporaryRoot()
        let artifact = fileOperationArtifact(relativePath: "Captures/2026/07/source.png")
        let source = root.appendingPathComponent(artifact.relativePath)
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("source-bytes".utf8).write(to: source)
        let destination = root.deletingLastPathComponent()
            .appendingPathComponent("Export-\(UUID().uuidString)/nested/result.png")
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent().deletingLastPathComponent()) }
        let controller = ScreenshotArtifactFileController(rootURL: root)

        let result = try controller.export(.init(artifact: artifact, destinationURL: destination))

        #expect(result.destinationURL == destination.standardizedFileURL)
        #expect(try Data(contentsOf: destination) == Data("source-bytes".utf8))
    }

    @Test("路径遍历不能读取功能目录外文件")
    func rejectsTraversalSourcePath() throws {
        let root = historyTemporaryRoot()
        let outside = root.deletingLastPathComponent().appendingPathComponent("outside-\(UUID().uuidString).png")
        try Data("outside".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        let artifact = fileOperationArtifact(relativePath: "../\(outside.lastPathComponent)")
        let destination = root.deletingLastPathComponent().appendingPathComponent("should-not-export-\(UUID().uuidString).png")
        let controller = ScreenshotArtifactFileController(rootURL: root)

        #expect(throws: ScreenshotFeatureError.self) {
            _ = try controller.export(.init(artifact: artifact, destinationURL: destination))
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test("目标已存在时拒绝覆盖")
    func refusesToOverwriteExistingDestination() throws {
        let root = historyTemporaryRoot()
        let artifact = fileOperationArtifact(relativePath: "Captures/source.png")
        let source = root.appendingPathComponent(artifact.relativePath)
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("new".utf8).write(to: source)
        let destination = root.deletingLastPathComponent().appendingPathComponent("existing-\(UUID().uuidString).png")
        try Data("existing".utf8).write(to: destination)
        defer { try? FileManager.default.removeItem(at: destination) }
        let controller = ScreenshotArtifactFileController(rootURL: root)

        #expect(throws: ScreenshotFeatureError.self) {
            _ = try controller.export(.init(artifact: artifact, destinationURL: destination))
        }
        #expect(try Data(contentsOf: destination) == Data("existing".utf8))
    }

    @Test("拒绝伪造的相对导出目标")
    func rejectsRelativeDestinationPath() throws {
        let root = historyTemporaryRoot()
        let artifact = fileOperationArtifact(relativePath: "Captures/source.png")
        let source = root.appendingPathComponent(artifact.relativePath)
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("source".utf8).write(to: source)
        var request = ScreenshotArtifactExportRequest(
            artifact: artifact,
            destinationURL: root.appendingPathComponent("unused.png")
        )
        request.destinationPath = "relative/result.png"
        let controller = ScreenshotArtifactFileController(rootURL: root)

        #expect(throws: ScreenshotFeatureError.self) {
            _ = try controller.export(request)
        }
    }
}

private func fileOperationArtifact(relativePath: String) -> ScreenshotArtifact {
    ScreenshotArtifact(
        id: UUID(),
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        captureMode: .region,
        relativePath: relativePath,
        thumbnailRelativePath: nil,
        pointSize: .init(width: 100, height: 50),
        pixelSize: .init(width: 200, height: 100),
        uniformTypeIdentifier: "public.png",
        sha256: "file-operation-fixture",
        displays: []
    )
}
