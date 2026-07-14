import CoreGraphics
import Darwin
import Foundation
import ScreenshotFeature
import Testing
@testable import ScreenshotServiceCore

@Suite("截图 6K 连续导出内存", .serialized)
struct AnnotationEffectsMemoryTests {
    private static let runEnvironmentKey = "TOUCH_RUN_6K_EXPORT_TEST"
    private static let iterationEnvironmentKey = "TOUCH_6K_EXPORT_ITERATIONS"

    @Test(
        "6K fixture 连续导出不会出现线性内存增长",
        .enabled(if: ProcessInfo.processInfo.environment[runEnvironmentKey] == "1")
    )
    func repeated6KExportsHaveBoundedMemoryGrowth() async throws {
        let environment = ProcessInfo.processInfo.environment
        let requestedIterations = Int(environment[Self.iterationEnvironmentKey] ?? "")
        let iterations = min(100, max(1, requestedIterations ?? 30))
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Touch6KExportMemoryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let image = try make6KFixture()
        let display = ScreenshotDisplayDescriptor(
            id: 1,
            frame: .init(x: 0, y: 0, width: 3_072, height: 1_728),
            pixelSize: .init(width: 6_144, height: 3_456),
            scaleFactor: 2
        )
        let backend = Fixed6KCaptureBackend(image: image, display: display)
        let engine = ScreenCaptureEngine(
            backend: backend,
            fileStore: ScreenshotFileStore(rootURL: root)
        )
        let annotations = representativeEffects()
        var samples: [ProcessMemorySample] = []
        samples.reserveCapacity(iterations)

        print("[Touch6KMemory] 配置：6144x3456，PNG，blur+mosaic+magnifier+crop+beautify，\(iterations) 轮")
        for iteration in 1...iterations {
            let artifact = try await engine.capture(.init(
                mode: .fullScreen,
                target: .display(displayID: display.id),
                annotations: annotations
            ))
            #expect(artifact.pixelSize == .init(width: 5_728, height: 3_168))
            #expect(artifact.pointSize == .init(width: 2_864, height: 1_584))

            try removeArtifactFiles(artifact, root: root)
            await Task.yield()

            let sample = try ProcessMemorySample.current()
            samples.append(sample)
            print(
                String(
                    format: "[Touch6KMemory] %02d/%02d footprint=%.1f MiB resident=%.1f MiB peakResident=%.1f MiB",
                    iteration,
                    iterations,
                    sample.physicalFootprintMiB,
                    sample.residentMiB,
                    sample.peakResidentMiB
                )
            )
        }

        let peakResidentMiB = samples.map(\.peakResidentMiB).max() ?? 0
        let peakFootprintMiB = samples.map(\.physicalFootprintMiB).max() ?? 0
        print(String(
            format: "[Touch6KMemory] 峰值：resident=%.1f MiB，采样 footprint=%.1f MiB",
            peakResidentMiB,
            peakFootprintMiB
        ))

        // 短循环只用于本地快速检查编译和导出链路；正式门槛固定使用默认 30 轮。
        guard iterations >= 20 else {
            print("[Touch6KMemory] 短循环仅检查链路，跳过稳定窗口趋势判定")
            return
        }

        let stableSamples = Array(samples.dropFirst(10)).map(\.physicalFootprintMiB)
        let slope = linearRegressionSlope(stableSamples)
        let headMean = mean(Array(stableSamples.prefix(5)))
        let tailMean = mean(Array(stableSamples.suffix(5)))
        let tailGrowth = tailMean - headMean
        print(String(
            format: "[Touch6KMemory] 稳定窗口：slope=%.3f MiB/轮，首5均值=%.1f MiB，末5均值=%.1f MiB，增长=%.1f MiB",
            slope,
            headMean,
            tailMean,
            tailGrowth
        ))

        // macOS 的 CoreGraphics/CoreImage 与 malloc 会保留可复用缓存，因此不要求 RSS 每轮下降。
        // 这两个宽松阈值用于捕获按大图缓冲区逐轮累积的真实泄漏，而不把缓存抖动误判为缺陷。
        #expect(slope <= 8, "稳定窗口内存斜率超过 8 MiB/轮，疑似随导出次数线性增长")
        #expect(tailGrowth <= 128, "稳定窗口末端比起始端增长超过 128 MiB，疑似缓冲区未释放")
    }

    private func representativeEffects() -> [ScreenshotAnnotation] {
        let style = ScreenshotAnnotationStyle(color: .red, lineWidth: 24)
        return [
            .init(
                kind: .blur,
                points: [.init(x: 420, y: 280), .init(x: 1_620, y: 1_120)],
                style: style,
                blur: .init(radius: 12)
            ),
            .init(
                kind: .mosaic,
                points: [.init(x: 320, y: 1_300), .init(x: 900, y: 1_480)],
                style: style,
                mosaic: .init(blockSize: 18)
            ),
            .init(
                kind: .magnifier,
                points: [.init(x: 2_380, y: 540)],
                style: style,
                magnifier: .init(magnification: 2, diameter: 180, borderWidth: 3)
            ),
            .init(
                kind: .crop,
                points: [.init(x: 128, y: 96), .init(x: 2_944, y: 1_632)],
                style: style
            ),
            .init(
                kind: .beautify,
                points: [.init(x: 0, y: 0), .init(x: 3_072, y: 1_728)],
                style: style,
                beautify: .init(
                    cornerRadius: 24,
                    shadowRadius: 18,
                    shadowOpacity: 0.28,
                    shadowOffsetX: 0,
                    shadowOffsetY: 8,
                    insets: .uniform(24),
                    backgroundGradient: .init(
                        colors: [
                            .init(red: 0.14, green: 0.31, blue: 0.91),
                            .init(red: 0.64, green: 0.24, blue: 0.92),
                            .init(red: 0.98, green: 0.42, blue: 0.34)
                        ],
                        angleDegrees: 28
                    )
                )
            )
        ]
    }

    private func make6KFixture() throws -> CGImage {
        let width = 6_144
        let height = 3_456
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

        context.setFillColor(CGColor(red: 0.06, green: 0.08, blue: 0.14, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let stripeWidth = CGFloat(width) / 24
        for index in 0..<24 {
            let hue = CGFloat(index) / 24
            context.setFillColor(CGColor(
                red: 0.15 + hue * 0.7,
                green: 0.72 - hue * 0.42,
                blue: 0.28 + hue * 0.5,
                alpha: 1
            ))
            context.fill(CGRect(
                x: CGFloat(index) * stripeWidth,
                y: CGFloat((index % 4) * 180),
                width: stripeWidth + 1,
                height: CGFloat(height - (index % 4) * 180)
            ))
        }
        guard let image = context.makeImage() else {
            throw ScreenshotFeatureError.encodingFailed
        }
        return image
    }

    private func removeArtifactFiles(_ artifact: ScreenshotArtifact, root: URL) throws {
        let paths = [artifact.relativePath, artifact.thumbnailRelativePath].compactMap { $0 }
        for path in paths {
            try FileManager.default.removeItem(at: root.appendingPathComponent(path))
        }
    }

    private func linearRegressionSlope(_ values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        let xMean = Double(values.count - 1) / 2
        let yMean = mean(values)
        var numerator = 0.0
        var denominator = 0.0
        for (index, value) in values.enumerated() {
            let centeredX = Double(index) - xMean
            numerator += centeredX * (value - yMean)
            denominator += centeredX * centeredX
        }
        return denominator > 0 ? numerator / denominator : 0
    }

    private func mean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }
}

private actor Fixed6KCaptureBackend: ScreenCaptureBackend {
    private let image: CGImage
    private let snapshot: ScreenCaptureContentSnapshot

    init(image: CGImage, display: ScreenshotDisplayDescriptor) {
        self.image = image
        snapshot = .init(displays: [display], windows: [])
    }

    func availableContent() async throws -> ScreenCaptureContentSnapshot { snapshot }

    func capture(_ plan: ScreenCapturePlan) async throws -> CapturedScreenImage {
        guard plan.filter == .display(displayID: 1) else {
            throw ScreenshotFeatureError.targetUnavailable
        }
        return CapturedScreenImage(image: image)
    }
}

private struct ProcessMemorySample {
    let physicalFootprintBytes: UInt64
    let residentBytes: UInt64
    let peakResidentBytes: UInt64

    var physicalFootprintMiB: Double { Double(physicalFootprintBytes) / 1_048_576 }
    var residentMiB: Double { Double(residentBytes) / 1_048_576 }
    var peakResidentMiB: Double { Double(peakResidentBytes) / 1_048_576 }

    static func current() throws -> Self {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(TASK_VM_INFO),
                    $0,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else {
            throw NSError(
                domain: NSMachErrorDomain,
                code: Int(result),
                userInfo: [NSLocalizedDescriptionKey: "task_info(TASK_VM_INFO) failed: \(result)"]
            )
        }
        return .init(
            physicalFootprintBytes: info.phys_footprint,
            residentBytes: info.resident_size,
            peakResidentBytes: info.resident_size_peak
        )
    }
}
