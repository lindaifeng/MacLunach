import Foundation
import ScreenshotFeature
@testable import ScreenshotServiceCore
import Testing

@Suite("ScreenshotRecognitionEngine")
struct ScreenshotRecognitionEngineTests {
    @Test("中英文文本按阅读顺序输出并过滤低置信度结果")
    func mixedTextIsFilteredAndSorted() async throws {
        let root = recognitionRoot()
        let artifact = recognitionArtifact(relativePath: "Captures/mixed.png")
        try Data().write(to: try ScreenshotFeaturePaths(rootURL: root).resolve(relativePath: artifact.relativePath))
        let engine = ScreenshotRecognitionEngine(rootURL: root) { _, _ in
            .init(text: [
                .init(text: "Touch 2026", confidence: 0.96, bounds: .init(x: 0.4, y: 0.8, width: 0.4, height: 0.1)),
                .init(text: "你好", confidence: 0.91, bounds: .init(x: 0.1, y: 0.8, width: 0.2, height: 0.1)),
                .init(text: "噪声", confidence: 0.2, bounds: .init(x: 0.1, y: 0.5, width: 0.2, height: 0.1)),
                .init(text: "下一行", confidence: 0.8, bounds: .init(x: 0.1, y: 0.5, width: 0.3, height: 0.1))
            ])
        }

        let result = try await engine.recognize(.init(
            artifact: artifact,
            configuration: .init(minimumTextConfidence: 0.5)
        ))

        #expect(result.fullText == "你好\nTouch 2026\n下一行")
        #expect(result.textBlocks.count == 3)
        #expect(result.artifactID == artifact.id)
    }

    @Test("多个二维码全部返回，只有安全网页地址被分类为 URL")
    func multipleBarcodesPreserveInvalidURLAsText() async throws {
        let root = recognitionRoot()
        let artifact = recognitionArtifact(relativePath: "Captures/qr.png")
        try Data().write(to: try ScreenshotFeaturePaths(rootURL: root).resolve(relativePath: artifact.relativePath))
        let engine = ScreenshotRecognitionEngine(rootURL: root) { _, _ in
            .init(barcodes: [
                .init(payload: "https://touch.example/path", symbology: "QR", bounds: .init(x: 0, y: 0, width: 0.4, height: 0.4)),
                .init(payload: "javascript:alert(1)", symbology: "QR", bounds: .init(x: 0.5, y: 0, width: 0.4, height: 0.4)),
                .init(payload: "普通文本", symbology: "QR", bounds: .init(x: 0, y: 0.5, width: 0.4, height: 0.4))
            ])
        }

        let result = try await engine.recognize(.init(artifact: artifact))

        #expect(result.barcodes.count == 3)
        #expect(result.barcodes[0].safeURL?.absoluteString == "https://touch.example/path")
        #expect(result.barcodes[1].safeURL == nil)
        #expect(result.barcodes[1].payload == "javascript:alert(1)")
        #expect(result.barcodes[2].safeURL == nil)
    }

    @Test("关闭二维码识别时忽略后端二维码观察结果")
    func barcodeRecognitionCanBeDisabled() async throws {
        let root = recognitionRoot()
        let artifact = recognitionArtifact(relativePath: "Captures/no-qr.png")
        try Data().write(to: try ScreenshotFeaturePaths(rootURL: root).resolve(relativePath: artifact.relativePath))
        let engine = ScreenshotRecognitionEngine(rootURL: root) { _, _ in
            .init(barcodes: [
                .init(payload: "https://touch.example", symbology: "QR", bounds: .init(x: 0, y: 0, width: 1, height: 1))
            ])
        }

        let result = try await engine.recognize(.init(
            artifact: artifact,
            configuration: .init(recognizesBarcodes: false)
        ))
        #expect(result.barcodes.isEmpty)
    }

    @Test("识别任务取消后返回统一取消错误")
    func cancellationStopsRecognition() async throws {
        let root = recognitionRoot()
        let artifact = recognitionArtifact(relativePath: "Captures/cancel.png")
        try Data().write(to: try ScreenshotFeaturePaths(rootURL: root).resolve(relativePath: artifact.relativePath))
        let engine = ScreenshotRecognitionEngine(rootURL: root) { _, _ in
            try await Task.sleep(for: .seconds(10))
            return .init()
        }
        let task = Task { try await engine.recognize(.init(artifact: artifact)) }
        await Task.yield()
        task.cancel()

        await #expect(throws: ScreenshotFeatureError.cancelled) {
            _ = try await task.value
        }
    }

    @Test("真实 Vision 可识别中英文和数字 fixture")
    func visionRecognizesMixedLanguageFixture() async throws {
        let (root, artifact) = try copiedRecognitionFixture(
            name: "ocr-zh-en",
            extension: "png"
        )
        let engine = ScreenshotRecognitionEngine(rootURL: root)

        let result = try await engine.recognize(.init(
            artifact: artifact,
            configuration: .init(
                recognitionLanguages: ["zh-Hans", "en-US"],
                minimumTextConfidence: 0.2
            )
        ))

        #expect(result.fullText.localizedCaseInsensitiveContains("Touch"))
        #expect(result.fullText.localizedCaseInsensitiveContains("OCR"))
        #expect(result.fullText.contains("2026"))
        #expect(result.fullText.contains("你好") || result.fullText.contains("触达"))
    }

    @Test("真实 Vision 会按图片方向元数据校正后识别")
    func visionHonorsImageOrientationMetadata() async throws {
        let (root, artifact) = try copiedRecognitionFixture(
            name: "ocr-oriented",
            extension: "jpg"
        )
        let engine = ScreenshotRecognitionEngine(rootURL: root)

        let result = try await engine.recognize(.init(
            artifact: artifact,
            configuration: .init(recognitionLanguages: ["zh-Hans", "en-US"])
        ))

        #expect(result.fullText.localizedCaseInsensitiveContains("Touch"))
        #expect(result.fullText.localizedCaseInsensitiveContains("OCR"))
        #expect(result.fullText.contains("2026"))
    }

    @Test("空图返回空结果而不是失败或伪造内容")
    func blankImageReturnsEmptyResult() async throws {
        let (root, artifact) = try copiedRecognitionFixture(
            name: "blank",
            extension: "png"
        )
        let engine = ScreenshotRecognitionEngine(rootURL: root)

        let result = try await engine.recognize(.init(artifact: artifact))

        #expect(result.fullText.isEmpty)
        #expect(result.textBlocks.isEmpty)
        #expect(result.barcodes.isEmpty)
    }

    @Test("真实 Vision 可返回多个二维码且不自动信任普通文本")
    func visionRecognizesMultipleQRCodeFixture() async throws {
        let (root, artifact) = try copiedRecognitionFixture(
            name: "qr",
            extension: "png"
        )
        let engine = ScreenshotRecognitionEngine(rootURL: root)

        let result = try await engine.recognize(.init(artifact: artifact))
        let payloads = Set(result.barcodes.map(\.payload))

        #expect(payloads == ["https://touch.example/ocr", "普通二维码文本"])
        #expect(result.barcodes.first { $0.payload == "https://touch.example/ocr" }?.safeURL != nil)
        #expect(result.barcodes.first { $0.payload == "普通二维码文本" }?.safeURL == nil)
    }

    @Test("后台识别队列不会超过配置的并发数")
    func recognitionQueueLimitsConcurrency() async throws {
        let root = recognitionRoot()
        let artifact = recognitionArtifact(relativePath: "Captures/concurrency.png")
        try Data().write(to: try ScreenshotFeaturePaths(rootURL: root).resolve(relativePath: artifact.relativePath))
        let probe = RecognitionConcurrencyProbe()
        let engine = ScreenshotRecognitionEngine(
            rootURL: root,
            maximumConcurrentRecognitions: 2
        ) { _, _ in
            await probe.begin()
            do {
                try await Task.sleep(for: .milliseconds(80))
                await probe.end()
                return .init()
            } catch {
                await probe.end()
                throw error
            }
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    _ = try await engine.recognize(.init(artifact: artifact))
                }
            }
            try await group.waitForAll()
        }

        #expect(await probe.maximumActiveCount == 2)
        #expect(await probe.activeCount == 0)
    }

    @Test("等待并发许可的任务取消后会立即退出且不会泄漏许可")
    func cancellingQueuedRecognitionDoesNotLeakPermit() async throws {
        let root = recognitionRoot()
        let artifact = recognitionArtifact(relativePath: "Captures/queued-cancel.png")
        try Data().write(to: try ScreenshotFeaturePaths(rootURL: root).resolve(relativePath: artifact.relativePath))
        let gate = RecognitionWorkerGate()
        let engine = ScreenshotRecognitionEngine(
            rootURL: root,
            maximumConcurrentRecognitions: 1
        ) { _, _ in
            try await gate.enterAndWaitIfNeeded()
            return .init()
        }
        let first = Task { try await engine.recognize(.init(artifact: artifact)) }
        await gate.waitUntilFirstWorkerStarts()
        let cancellation = RecognitionCancellationProbe()
        let queued = Task {
            do {
                _ = try await engine.recognize(.init(artifact: artifact))
            } catch ScreenshotFeatureError.cancelled {
                await cancellation.markCompleted()
            } catch {
                // 非取消错误会由完成标记缺失暴露为断言失败。
            }
        }

        await Task.yield()
        queued.cancel()
        try await Task.sleep(for: .milliseconds(40))
        #expect(await cancellation.isCompleted)

        await gate.releaseFirstWorker()
        _ = try await first.value
        await queued.value
        _ = try await engine.recognize(.init(artifact: artifact))
        #expect(await gate.startCount == 2)
    }
}

private actor RecognitionConcurrencyProbe {
    private(set) var activeCount = 0
    private(set) var maximumActiveCount = 0

    func begin() {
        activeCount += 1
        maximumActiveCount = max(maximumActiveCount, activeCount)
    }

    func end() {
        activeCount -= 1
    }
}

private actor RecognitionCancellationProbe {
    private(set) var isCompleted = false
    func markCompleted() { isCompleted = true }
}

private actor RecognitionWorkerGate {
    private(set) var startCount = 0
    private var firstWorkerReleased = false

    func enterAndWaitIfNeeded() async throws {
        startCount += 1
        guard startCount == 1 else { return }
        while !firstWorkerReleased {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func waitUntilFirstWorkerStarts() async {
        while startCount == 0 { await Task.yield() }
    }

    func releaseFirstWorker() {
        firstWorkerReleased = true
    }
}

private func recognitionRoot() -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("TouchRecognitionTests-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(
        at: root.appendingPathComponent("Captures", isDirectory: true),
        withIntermediateDirectories: true
    )
    return root
}

private func recognitionArtifact(relativePath: String) -> ScreenshotArtifact {
    .init(
        id: UUID(),
        createdAt: Date(),
        captureMode: .ocrRegion,
        relativePath: relativePath,
        thumbnailRelativePath: nil,
        pointSize: .init(width: 640, height: 480),
        pixelSize: .init(width: 1280, height: 960),
        uniformTypeIdentifier: "public.png",
        sha256: "fixture",
        displays: []
    )
}

private func copiedRecognitionFixture(
    name: String,
    extension fileExtension: String
) throws -> (root: URL, artifact: ScreenshotArtifact) {
    let source = try #require(Bundle.module.url(
        forResource: name,
        withExtension: fileExtension,
        subdirectory: "Fixtures"
    ))
    let root = recognitionRoot()
    let relativePath = "Captures/\(name).\(fileExtension)"
    let destination = try ScreenshotFeaturePaths(rootURL: root).resolve(relativePath: relativePath)
    try FileManager.default.copyItem(at: source, to: destination)
    return (root, recognitionArtifact(relativePath: relativePath))
}
