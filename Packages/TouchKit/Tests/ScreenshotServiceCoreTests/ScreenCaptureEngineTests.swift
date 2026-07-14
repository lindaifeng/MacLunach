import CoreGraphics
import Foundation
import ImageIO
import ScreenshotFeature
import ScreenshotServiceCore
import Testing

@Suite("ScreenCaptureEngine")
struct ScreenCaptureEngineTests {
    @Test("多屏 fixture 覆盖负坐标与不同缩放布局")
    func mixedScaleFixtureProducesStableLayout() throws {
        struct Fixture: Decodable { let displays: [ScreenshotDisplayDescriptor] }
        let url = try #require(Bundle.module.url(
            forResource: "mixed-scale-displays",
            withExtension: "json",
            subdirectory: "Fixtures"
        ))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))

        let layout = try DisplayGeometry.compositeLayout(for: fixture.displays)

        #expect(layout.pointBounds == .init(x: -1280, y: -200, width: 2792, height: 1224))
        #expect(layout.scaleFactor == 2)
        #expect(layout.pixelSize == .init(width: 5584, height: 2448))
    }

    @Test("区域坐标在负坐标与 Retina 显示器上按像素边界裁剪")
    func regionGeometryClipsAndScales() throws {
        let display = descriptor(
            id: 2,
            frame: .init(x: -100, y: -50, width: 200, height: 100),
            pixels: .init(width: 400, height: 200),
            scale: 2
        )

        let geometry = try DisplayGeometry.captureGeometry(
            for: .init(x: -110.25, y: -40.25, width: 30.5, height: 20.5),
            on: display
        )

        #expect(geometry.globalRect == .init(x: -100, y: -40.5, width: 20.5, height: 21))
        #expect(geometry.sourceRect == .init(x: 0, y: 9.5, width: 20.5, height: 21))
        #expect(geometry.pixelSize == .init(width: 41, height: 42))
    }

    @Test("区域完全位于显示器外时目标不可用")
    func regionOutsideDisplayIsUnavailable() {
        let display = descriptor(id: 1, frame: .init(x: 0, y: 0, width: 100, height: 100))

        #expect(throws: ScreenshotFeatureError.targetUnavailable) {
            try DisplayGeometry.captureGeometry(
                for: .init(x: 120, y: 10, width: 5, height: 5),
                on: display
            )
        }
    }

    @Test("Retina 取色按物理像素对齐并返回中心像素")
    func colorSampleUsesRetinaPixelGeometry() async throws {
        let display = descriptor(
            id: 7,
            frame: .init(x: 100, y: 50, width: 10, height: 8),
            pixels: .init(width: 20, height: 16),
            scale: 2
        )
        let backend = RecordingCaptureBackend(
            snapshot: .init(displays: [display], windows: []),
            images: [7: solidImage(width: 5, height: 5, red: 12, green: 34, blue: 56)]
        )
        let fixture = try makeEngineFixture(backend: backend)

        let sample = try await fixture.engine.sampleColor(.init(
            displayID: 7,
            desktopPoint: .init(x: 102.25, y: 51.75),
            loupePixelDiameter: 5
        ))

        let plan = try #require(await backend.recordedPlans.first)
        #expect(plan.sourceRect == .init(x: 1, y: 0.5, width: 2.5, height: 2.5))
        #expect(plan.pixelSize == .init(width: 5, height: 5))
        #expect(sample.centerPixel == .init(x: 2, y: 2))
        #expect(sample.color == .init(red: 12, green: 34, blue: 56))
        #expect(sample.loupeRGBA.count == 5 * 5 * 4)
    }

    @Test("屏幕边缘取色平移采样框且中心索引保持目标像素")
    func colorSampleClampsAtDisplayEdge() async throws {
        let display = descriptor(
            id: 8,
            frame: .init(x: -10, y: -8, width: 10, height: 8),
            pixels: .init(width: 20, height: 16),
            scale: 2
        )
        let backend = RecordingCaptureBackend(
            snapshot: .init(displays: [display], windows: []),
            images: [8: solidImage(width: 5, height: 5, red: 200, green: 100, blue: 50)]
        )
        let fixture = try makeEngineFixture(backend: backend)

        let sample = try await fixture.engine.sampleColor(.init(
            displayID: 8,
            desktopPoint: .init(x: -0.01, y: -0.01),
            loupePixelDiameter: 5
        ))

        let plan = try #require(await backend.recordedPlans.first)
        #expect(plan.sourceRect == .init(x: 7.5, y: 5.5, width: 2.5, height: 2.5))
        #expect(sample.centerPixel == .init(x: 4, y: 4))
        #expect(sample.color == .init(red: 200, green: 100, blue: 50))
    }

    @Test("Display P3 采样统一转换为标准 sRGB")
    func colorSampleConvertsDisplayP3ToSRGB() async throws {
        let display = descriptor(id: 9, frame: .init(x: 0, y: 0, width: 1, height: 1))
        let components: [CGFloat] = [0.8, 0.4, 0.2, 1]
        let backend = RecordingCaptureBackend(
            snapshot: .init(displays: [display], windows: []),
            images: [9: try p3SolidImage(components: components)]
        )
        let fixture = try makeEngineFixture(backend: backend)
        let sample = try await fixture.engine.sampleColor(.init(
            displayID: 9,
            desktopPoint: .init(x: 0.5, y: 0.5),
            loupePixelDiameter: 1
        ))
        let p3 = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        let sRGB = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let source = try #require(CGColor(colorSpace: p3, components: components))
        let converted = try #require(source.converted(
            to: sRGB,
            intent: .relativeColorimetric,
            options: nil
        )?.components)

        #expect(abs(Int(sample.color.red) - Int((converted[0] * 255).rounded())) <= 1)
        #expect(abs(Int(sample.color.green) - Int((converted[1] * 255).rounded())) <= 1)
        #expect(abs(Int(sample.color.blue) - Int((converted[2] * 255).rounded())) <= 1)
    }

    @Test("窗口捕获使用独立窗口 filter 并控制阴影")
    func windowCaptureUsesDesktopIndependentFilterAndShadowPolicy() async throws {
        let window = ScreenshotWindowDescriptor(
            id: 55,
            ownerBundleIdentifier: "com.example.notes",
            title: "Notes",
            frame: .init(x: 10, y: 10, width: 80, height: 60),
            isOnScreen: true
        )
        let backend = RecordingCaptureBackend(
            snapshot: .init(
                displays: [descriptor(id: 1, frame: .init(x: 0, y: 0, width: 100, height: 100))],
                windows: [window]
            ),
            images: [55: solidImage(width: 80, height: 60, red: 255, green: 0, blue: 0)]
        )
        let fixture = try makeEngineFixture(backend: backend)
        let request = ScreenshotCaptureRequest(
            mode: .window,
            target: .window(windowID: 55),
            windowShadow: .excluded
        )

        _ = try await fixture.engine.capture(request)

        let plans = await backend.recordedPlans
        #expect(plans.count == 1)
        #expect(plans[0].filter == .desktopIndependentWindow(windowID: 55))
        #expect(plans[0].ignoresWindowShadow)
    }

    @Test("全屏只捕获指定 display，不回退主屏")
    func fullScreenUsesExactDisplay() async throws {
        let backend = RecordingCaptureBackend(
            snapshot: .init(
                displays: [
                    descriptor(id: 1, frame: .init(x: 0, y: 0, width: 100, height: 100)),
                    descriptor(id: 2, frame: .init(x: 100, y: 0, width: 100, height: 100))
                ],
                windows: []
            ),
            images: [2: solidImage(width: 100, height: 100, red: 0, green: 255, blue: 0)]
        )
        let fixture = try makeEngineFixture(backend: backend)

        _ = try await fixture.engine.capture(.init(mode: .fullScreen, target: .display(displayID: 2)))

        let plans = await backend.recordedPlans
        #expect(plans.map(\.filter) == [.display(displayID: 2)])
    }

    @Test("指定 display 消失时返回 targetUnavailable")
    func missingDisplayDoesNotFallback() async throws {
        let backend = RecordingCaptureBackend(
            snapshot: .init(
                displays: [descriptor(id: 1, frame: .init(x: 0, y: 0, width: 100, height: 100))],
                windows: []
            ),
            images: [:]
        )
        let fixture = try makeEngineFixture(backend: backend)

        await #expect(throws: ScreenshotFeatureError.targetUnavailable) {
            try await fixture.engine.capture(.init(mode: .fullScreen, target: .display(displayID: 2)))
        }
        #expect(await backend.recordedPlans.isEmpty)
    }

    @Test("多屏合成保留布局、透明空洞和每屏元数据")
    func allDisplaysCompositeHasTransparentHoles() async throws {
        let first = descriptor(id: 1, frame: .init(x: 0, y: 0, width: 100, height: 100))
        let second = descriptor(
            id: 2,
            frame: .init(x: 200, y: 50, width: 100, height: 100),
            pixels: .init(width: 200, height: 200),
            scale: 2
        )
        let backend = RecordingCaptureBackend(
            snapshot: .init(displays: [first, second], windows: []),
            images: [
                1: solidImage(width: 100, height: 100, red: 255, green: 0, blue: 0),
                2: solidImage(width: 200, height: 200, red: 0, green: 0, blue: 255)
            ]
        )
        let fixture = try makeEngineFixture(backend: backend)

        let artifact = try await fixture.engine.capture(.init(
            mode: .allDisplays,
            target: .allDisplays(displayIDs: [1, 2])
        ))
        let imageURL = fixture.root.appendingPathComponent(artifact.relativePath)
        let image = try #require(CGImageSourceCreateWithURL(imageURL as CFURL, nil).flatMap {
            CGImageSourceCreateImageAtIndex($0, 0, nil)
        })

        #expect(artifact.pointSize == .init(width: 300, height: 150))
        #expect(artifact.pixelSize == .init(width: 600, height: 300))
        #expect(artifact.displays == [first, second])
        #expect(alpha(atX: 300, y: 50, in: image) == 0)
        #expect(alpha(atX: 100, y: 100, in: image) == 255)
        #expect(alpha(atX: 500, y: 200, in: image) == 255)
    }

    @Test("所有显示器合成保持每屏图像的上下方向")
    func allDisplaysCompositePreservesVerticalOrientation() async throws {
        let display = descriptor(id: 1, frame: .init(x: 0, y: 0, width: 2, height: 2))
        let source = verticalBandsImage(
            width: 2,
            height: 2,
            top: (red: 255, green: 0, blue: 0),
            bottom: (red: 0, green: 0, blue: 255)
        )
        let backend = RecordingCaptureBackend(
            snapshot: .init(displays: [display], windows: []),
            images: [1: source]
        )
        let fixture = try makeEngineFixture(backend: backend)

        let artifact = try await fixture.engine.capture(.init(
            mode: .allDisplays,
            target: .allDisplays(displayIDs: [1])
        ))
        let imageURL = fixture.root.appendingPathComponent(artifact.relativePath)
        let composite = try #require(CGImageSourceCreateWithURL(imageURL as CFURL, nil).flatMap {
            CGImageSourceCreateImageAtIndex($0, 0, nil)
        })

        #expect(rgba(atX: 0, y: 0, in: composite) == rgba(atX: 0, y: 0, in: source))
        #expect(rgba(atX: 0, y: 1, in: composite) == rgba(atX: 0, y: 1, in: source))
        #expect(rgba(atX: 0, y: 0, in: composite) != rgba(atX: 0, y: 1, in: composite))
    }

    @Test("主程序、XPC、缩略图、编辑器和钉图都进入排除计划")
    func touchWindowsAndProcessesAreExcluded() async throws {
        let backend = RecordingCaptureBackend(
            snapshot: .init(
                displays: [descriptor(id: 1, frame: .init(x: 0, y: 0, width: 10, height: 10))],
                windows: []
            ),
            images: [1: solidImage(width: 10, height: 10, red: 0, green: 0, blue: 0)]
        )
        let fixture = try makeEngineFixture(
            backend: backend,
            exclusions: .init(
                applicationBundleIdentifiers: ["me.touch.launcher"],
                serviceBundleIdentifiers: ["me.touch.launcher.ScreenshotService"],
                thumbnailWindowIDs: [101],
                editorWindowIDs: [102],
                pinnedWindowIDs: [103, 104]
            )
        )

        _ = try await fixture.engine.capture(.init(mode: .fullScreen, target: .display(displayID: 1)))

        let plan = try #require(await backend.recordedPlans.first)
        #expect(Set(plan.excludedApplicationBundleIdentifiers) == [
            "me.touch.launcher", "me.touch.launcher.ScreenshotService"
        ])
        #expect(Set(plan.excludedWindowIDs) == [101, 102, 103, 104])
    }

    @Test("标注通过捕获引擎写入最终截图产物")
    func annotationsAreRenderedIntoStoredArtifact() async throws {
        let display = descriptor(id: 1, frame: .init(x: 0, y: 0, width: 20, height: 20))
        let backend = RecordingCaptureBackend(
            snapshot: .init(displays: [display], windows: []),
            images: [1: solidImage(width: 20, height: 20, red: 255, green: 255, blue: 255)]
        )
        let fixture = try makeEngineFixture(backend: backend)
        let annotation = ScreenshotAnnotation(
            kind: .line,
            points: [.init(x: 2, y: 2), .init(x: 18, y: 2)],
            style: .init(color: .red, lineWidth: 3)
        )

        let artifact = try await fixture.engine.capture(.init(
            mode: .fullScreen,
            target: .display(displayID: 1),
            annotations: [annotation]
        ))

        let artifactURL = fixture.root.appendingPathComponent(artifact.relativePath)
        let source = try #require(CGImageSourceCreateWithURL(artifactURL as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let markedPixel = rgba(atX: 10, y: 2, in: image)
        #expect(markedPixel.red > 200)
        #expect(markedPixel.green < 100)
        #expect(markedPixel.blue < 100)
    }

    @Test("美化后的产物同时记录扩展后的 point 与 pixel 尺寸")
    func beautifyUpdatesStoredArtifactDimensions() async throws {
        let display = descriptor(
            id: 1,
            frame: .init(x: 0, y: 0, width: 40, height: 20),
            pixels: .init(width: 80, height: 40),
            scale: 2
        )
        let backend = RecordingCaptureBackend(
            snapshot: .init(displays: [display], windows: []),
            images: [1: solidImage(width: 80, height: 40, red: 255, green: 255, blue: 255)]
        )
        let fixture = try makeEngineFixture(backend: backend)
        let beautify = ScreenshotAnnotation(
            kind: .beautify,
            points: [.init(x: 0, y: 0), .init(x: 40, y: 20)],
            style: .init(color: .red, lineWidth: 1),
            beautify: .init(
                cornerRadius: 6,
                shadowRadius: 4,
                shadowOpacity: 0.2,
                shadowOffsetX: 0,
                shadowOffsetY: 2,
                insets: .init(top: 5, right: 10, bottom: 15, left: 20),
                backgroundGradient: .init(
                    colors: [
                        .init(red: 0.2, green: 0.3, blue: 0.8),
                        .init(red: 0.2, green: 0.8, blue: 0.7)
                    ],
                    angleDegrees: 0
                )
            )
        )

        let artifact = try await fixture.engine.capture(.init(
            mode: .fullScreen,
            target: .display(displayID: 1),
            annotations: [beautify]
        ))

        #expect(artifact.pointSize == .init(width: 70, height: 40))
        #expect(artifact.pixelSize == .init(width: 140, height: 80))
    }

    @Test("裁剪后的产物同时记录裁剪后的 point 与 Retina pixel 尺寸")
    func cropUpdatesStoredArtifactDimensions() async throws {
        let display = descriptor(
            id: 1,
            frame: .init(x: 0, y: 0, width: 100, height: 80),
            pixels: .init(width: 200, height: 160),
            scale: 2
        )
        let backend = RecordingCaptureBackend(
            snapshot: .init(displays: [display], windows: []),
            images: [1: solidImage(width: 200, height: 160, red: 255, green: 255, blue: 255)]
        )
        let fixture = try makeEngineFixture(backend: backend)
        let crop = ScreenshotAnnotation(
            kind: .crop,
            points: [.init(x: 20, y: 10), .init(x: 80, y: 60)],
            style: .init(color: .red, lineWidth: 1)
        )

        let artifact = try await fixture.engine.capture(.init(
            mode: .fullScreen,
            target: .display(displayID: 1),
            annotations: [crop]
        ))

        #expect(artifact.pointSize == .init(width: 60, height: 50))
        #expect(artifact.pixelSize == .init(width: 120, height: 100))

        let artifactURL = fixture.root.appendingPathComponent(artifact.relativePath)
        let source = try #require(CGImageSourceCreateWithURL(artifactURL as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 120)
        #expect(image.height == 100)
    }

    @Test("取消会停止捕获且不会写文件或记录历史")
    func cancellationDoesNotCreateArtifactOrHistory() async throws {
        let display = descriptor(id: 1, frame: .init(x: 0, y: 0, width: 10, height: 10))
        let backend = SuspendedCaptureBackend(snapshot: .init(displays: [display], windows: []))
        let recorder = ArtifactRecorder()
        let fixture = try makeEngineFixture(backend: backend, recorder: recorder)
        let task = Task {
            try await fixture.engine.capture(.init(mode: .fullScreen, target: .display(displayID: 1)))
        }
        await backend.waitUntilCaptureStarted()

        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }

        #expect(await recorder.artifacts.isEmpty)
        let captures = fixture.root.appendingPathComponent("Captures", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: captures.path)) ?? []
        #expect(files.isEmpty)
    }

    @Test("原子写入完成时收到取消会回滚文件且不记录历史")
    func cancellationAfterAtomicWriteRollsBackArtifactAndHistory() async throws {
        let display = descriptor(id: 1, frame: .init(x: 0, y: 0, width: 10, height: 10))
        let backend = RecordingCaptureBackend(
            snapshot: .init(displays: [display], windows: []),
            images: [1: solidImage(width: 10, height: 10, red: 255, green: 0, blue: 0)]
        )
        let recorder = ArtifactRecorder()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TouchEngineTests-\(UUID().uuidString)", isDirectory: true)
        let store = ScreenshotFileStore(rootURL: root, writer: CancellingAtomicWriter())
        let engine = ScreenCaptureEngine(
            backend: backend,
            fileStore: store,
            artifactRecorder: recorder
        )
        let task = Task {
            try await engine.capture(.init(mode: .fullScreen, target: .display(displayID: 1)))
        }

        await #expect(throws: CancellationError.self) { try await task.value }

        #expect(await recorder.artifacts.isEmpty)
        #expect(recursiveFiles(at: root).isEmpty)
    }
}

private struct EngineFixture {
    let root: URL
    let engine: ScreenCaptureEngine
}

private func makeEngineFixture(
    backend: any ScreenCaptureBackend,
    exclusions: ScreenshotCaptureExclusions = .touchDefaults,
    recorder: any ScreenshotArtifactRecording = NullScreenshotArtifactRecorder()
) throws -> EngineFixture {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("TouchEngineTests-\(UUID().uuidString)", isDirectory: true)
    let store = ScreenshotFileStore(rootURL: root)
    return EngineFixture(
        root: root,
        engine: ScreenCaptureEngine(
            backend: backend,
            fileStore: store,
            exclusions: exclusions,
            artifactRecorder: recorder
        )
    )
}

private actor RecordingCaptureBackend: ScreenCaptureBackend {
    let snapshot: ScreenCaptureContentSnapshot
    let images: [UInt32: CGImage]
    private(set) var recordedPlans: [ScreenCapturePlan] = []

    init(snapshot: ScreenCaptureContentSnapshot, images: [UInt32: CGImage]) {
        self.snapshot = snapshot
        self.images = images
    }

    func availableContent() async throws -> ScreenCaptureContentSnapshot { snapshot }

    func capture(_ plan: ScreenCapturePlan) async throws -> CapturedScreenImage {
        recordedPlans.append(plan)
        let id: UInt32
        switch plan.filter {
        case let .display(displayID): id = displayID
        case let .desktopIndependentWindow(windowID): id = windowID
        }
        guard let image = images[id] else { throw ScreenshotFeatureError.targetUnavailable }
        return CapturedScreenImage(image: image)
    }
}

private actor SuspendedCaptureBackend: ScreenCaptureBackend {
    let snapshot: ScreenCaptureContentSnapshot
    private var started = false

    init(snapshot: ScreenCaptureContentSnapshot) { self.snapshot = snapshot }

    func availableContent() async throws -> ScreenCaptureContentSnapshot { snapshot }

    func capture(_ plan: ScreenCapturePlan) async throws -> CapturedScreenImage {
        started = true
        try await Task.sleep(for: .seconds(60))
        throw CancellationError()
    }

    func waitUntilCaptureStarted() async {
        while !started { await Task.yield() }
    }
}

private actor ArtifactRecorder: ScreenshotArtifactRecording {
    private(set) var artifacts: [ScreenshotArtifact] = []
    func record(_ artifact: ScreenshotArtifact) async throws { artifacts.append(artifact) }
}

private struct CancellingAtomicWriter: ScreenshotAtomicWriting {
    func write(_ data: Data, to destinationURL: URL) throws {
        try data.write(to: destinationURL, options: .atomic)
        withUnsafeCurrentTask { task in
            task?.cancel()
        }
    }
}

private func recursiveFiles(at root: URL) -> [URL] {
    guard let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: nil
    ) else { return [] }
    return enumerator.compactMap { $0 as? URL }.filter { url in
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }
}

private func descriptor(
    id: UInt32,
    frame: ScreenshotRect,
    pixels: ScreenshotSize? = nil,
    scale: Double = 1
) -> ScreenshotDisplayDescriptor {
    .init(
        id: id,
        frame: frame,
        pixelSize: pixels ?? .init(width: frame.width * scale, height: frame.height * scale),
        scaleFactor: scale
    )
}

private func solidImage(width: Int, height: Int, red: UInt8, green: UInt8, blue: UInt8) -> CGImage {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(red: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}

private func p3SolidImage(components: [CGFloat]) throws -> CGImage {
    let colorSpace = try #require(CGColorSpace(name: CGColorSpace.displayP3))
    let context = try #require(CGContext(
        data: nil,
        width: 1,
        height: 1,
        bitsPerComponent: 8,
        bytesPerRow: 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(try #require(CGColor(colorSpace: colorSpace, components: components)))
    context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
    return try #require(context.makeImage())
}

private func verticalBandsImage(
    width: Int,
    height: Int,
    top: (red: UInt8, green: UInt8, blue: UInt8),
    bottom: (red: UInt8, green: UInt8, blue: UInt8)
) -> CGImage {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(
        red: CGFloat(bottom.red) / 255,
        green: CGFloat(bottom.green) / 255,
        blue: CGFloat(bottom.blue) / 255,
        alpha: 1
    )
    context.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))
    context.setFillColor(
        red: CGFloat(top.red) / 255,
        green: CGFloat(top.green) / 255,
        blue: CGFloat(top.blue) / 255,
        alpha: 1
    )
    context.fill(CGRect(x: 0, y: height / 2, width: width, height: height - height / 2))
    return context.makeImage()!
}

private func alpha(atX x: Int, y: Int, in image: CGImage) -> UInt8 {
    rgba(atX: x, y: y, in: image).alpha
}

private func rgba(atX x: Int, y: Int, in image: CGImage) -> (
    red: UInt8,
    green: UInt8,
    blue: UInt8,
    alpha: UInt8
) {
    var pixel = [UInt8](repeating: 0, count: 4)
    let context = CGContext(
        data: &pixel,
        width: 1,
        height: 1,
        bitsPerComponent: 8,
        bytesPerRow: 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.draw(image, in: CGRect(x: -x, y: -(image.height - y - 1), width: image.width, height: image.height))
    return (red: pixel[0], green: pixel[1], blue: pixel[2], alpha: pixel[3])
}
