import Foundation
import ScreenshotFeature
import ScreenshotServiceCore
import Testing

@Suite("Annotation project persistence")
struct AnnotationProjectPersistenceTests {
    @Test("项目 JSON 原子保存且不会改写原图")
    func projectIsSavedAtomicallyAndSeparatelyFromSource() async throws {
        let root = annotationTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Captures/source.png")
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let originalBytes = Data("original-image-bytes".utf8)
        try originalBytes.write(to: source)
        let operations = AnnotationAtomicOperationRecorder()
        let store = ScreenshotFileStore(
            rootURL: root,
            writer: POSIXAtomicFileWriter(observer: { operations.append($0) })
        )
        let document = annotationProjectDocument()

        let relativePath = try await store.saveAnnotationProject(document)
        let projectURL = root.appendingPathComponent(relativePath)

        #expect(relativePath == "Projects/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa.touch-annotation.json")
        #expect(try Data(contentsOf: source) == originalBytes)
        #expect(FileManager.default.fileExists(atPath: projectURL.path))
        #expect(operations.values.contains { operation in
            if case let .renamed(_, destination) = operation {
                return destination == projectURL
            }
            return false
        })

        let loaded = try await store.loadAnnotationProject(
            relativePath: relativePath,
            fallbackDocument: document.restoringOriginalImage(updatedAt: document.updatedAt)
        )
        #expect(loaded.status == .loaded)
        #expect(loaded.document == document)
    }

    @Test("项目损坏或缺失时回退原图并丢弃可疑图层")
    func corruptOrMissingProjectFallsBackToOriginal() async throws {
        let root = annotationTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ScreenshotFileStore(rootURL: root)
        let document = annotationProjectDocument()
        let relativePath = try await store.saveAnnotationProject(document)
        let projectURL = root.appendingPathComponent(relativePath)
        try Data("{broken-json".utf8).write(to: projectURL)

        let corrupt = try await store.loadAnnotationProject(
            relativePath: relativePath,
            fallbackDocument: document
        )
        #expect(corrupt.status == .recoveredFromCorruptProject)
        #expect(corrupt.document.sourceImageRelativePath == document.sourceImageRelativePath)
        #expect(corrupt.document.layers.isEmpty)

        try FileManager.default.removeItem(at: projectURL)
        let missing = try await store.loadAnnotationProject(
            relativePath: relativePath,
            fallbackDocument: document
        )
        #expect(missing.status == .recoveredFromMissingProject)
        #expect(missing.document.layers.isEmpty)
    }

    @Test("项目读取拒绝越过截图插件目录")
    func projectPathCannotEscapePluginRoot() async {
        let store = ScreenshotFileStore(rootURL: annotationTemporaryDirectory())
        do {
            _ = try await store.loadAnnotationProject(
                relativePath: "Projects/../outside.touch-annotation.json",
                fallbackDocument: annotationProjectDocument()
            )
            Issue.record("预期非法路径被拒绝")
        } catch let error as ScreenshotFeatureError {
            guard case .storageFailed = error else {
                Issue.record("错误类型不正确：\(error)")
                return
            }
        } catch {
            Issue.record("错误类型不正确：\(error)")
        }
    }
}

private func annotationProjectDocument() -> AnnotationDocument {
    AnnotationDocument(
        id: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
        sourceImageRelativePath: "Captures/source.png",
        canvasSize: .init(width: 800, height: 600),
        layers: [
            AnnotationLayer(
                annotation: ScreenshotAnnotation(
                    id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                    kind: .rectangle,
                    points: [.init(x: 10, y: 20), .init(x: 120, y: 90)],
                    style: .init(color: .red, lineWidth: 3)
                )
            )
        ],
        createdAt: Date(timeIntervalSince1970: 100),
        updatedAt: Date(timeIntervalSince1970: 200)
    )
}

private func annotationTemporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("TouchAnnotationProjectTests-\(UUID().uuidString)", isDirectory: true)
}

private final class AnnotationAtomicOperationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var operations: [AtomicFileOperation] = []

    func append(_ operation: AtomicFileOperation) {
        lock.lock()
        operations.append(operation)
        lock.unlock()
    }

    var values: [AtomicFileOperation] {
        lock.lock()
        defer { lock.unlock() }
        return operations
    }
}
