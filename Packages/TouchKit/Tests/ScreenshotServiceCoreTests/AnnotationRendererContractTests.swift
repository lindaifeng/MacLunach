import CoreGraphics
import ScreenshotFeature
import Testing
@testable import ScreenshotServiceCore

@Suite("标注渲染契约")
struct AnnotationRendererContractTests {
    @Test("文档图层按 z-order 渲染并应用图层透明度")
    func documentLayersApplyOrderAndOpacity() throws {
        let source = solidImage(width: 24, height: 24, colorSpace: rgbColorSpace)
        let red = AnnotationLayer(
            annotation: line(color: .red),
            opacity: 1,
            zIndex: 0
        )
        let blue = AnnotationLayer(
            annotation: line(color: .init(red: 0, green: 0, blue: 1)),
            opacity: 0.5,
            zIndex: 1
        )
        let document = AnnotationDocument(
            sourceImageRelativePath: "Artifacts/source.png",
            canvasSize: .init(width: 24, height: 24),
            layers: [red, blue]
        )

        let renderer = AnnotationRenderer()
        let rendered = try renderer.render(image: source, document: document)
        let reorderedInput = try renderer.render(
            image: source,
            pointSize: document.canvasSize,
            layers: [blue, red]
        )
        let redOnly = try renderer.render(
            image: source,
            pointSize: document.canvasSize,
            layers: [red]
        )
        let opaqueBlue = AnnotationLayer(
            annotation: blue.annotation,
            opacity: 1,
            zIndex: blue.zIndex
        )
        let blueOnly = try renderer.render(
            image: source,
            pointSize: document.canvasSize,
            layers: [opaqueBlue]
        )
        let center = pixel(atX: 12, y: 12, in: rendered)
        let redCenter = pixel(atX: 12, y: 12, in: redOnly)
        let blueCenter = pixel(atX: 12, y: 12, in: blueOnly)

        #expect(center != redCenter)
        #expect(center != blueCenter)
        #expect(center[0] > min(redCenter[0], blueCenter[0]))
        #expect(center[0] < max(redCenter[0], blueCenter[0]))
        #expect(center[2] > min(redCenter[2], blueCenter[2]))
        #expect(center[2] < max(redCenter[2], blueCenter[2]))
        #expect(center[3] == 255)
        #expect(rgbaBytes(rendered) == rgbaBytes(reorderedInput))
        #expect(renderer.outputPointSize(document: document) == document.canvasSize)
    }

    @Test("相同输入重复渲染得到确定的像素结果")
    func repeatedRenderingIsDeterministic() throws {
        let source = solidImage(width: 64, height: 48, colorSpace: rgbColorSpace)
        let annotations: [ScreenshotAnnotation] = [
            .init(
                kind: .rectangle,
                points: [.init(x: 5, y: 6), .init(x: 40, y: 30)],
                style: .init(color: .red, lineWidth: 3)
            ),
            .init(
                kind: .arrow,
                points: [.init(x: 8, y: 36), .init(x: 52, y: 12)],
                style: .init(color: .init(red: 0, green: 0.25, blue: 1), lineWidth: 2)
            )
        ]

        let first = try AnnotationRenderer().render(
            image: source,
            pointSize: .init(width: 64, height: 48),
            annotations: annotations
        )
        let second = try AnnotationRenderer().render(
            image: source,
            pointSize: .init(width: 64, height: 48),
            annotations: annotations
        )

        #expect(rgbaBytes(first) == rgbaBytes(second))
        #expect(pixel(atX: 5, y: 18, in: first)[0] > 180)
        #expect(pixel(atX: 25, y: 18, in: first) == [255, 255, 255, 255])
    }

    @Test("输出保留原图 Display P3 色彩空间")
    func outputPreservesSourceColorSpace() throws {
        let displayP3 = CGColorSpace(name: CGColorSpace.displayP3)!
        let source = solidImage(width: 20, height: 20, colorSpace: displayP3)
        let rendered = try AnnotationRenderer().render(
            image: source,
            pointSize: .init(width: 20, height: 20),
            annotations: [line(color: .red)]
        )

        #expect(rendered.colorSpace?.name == displayP3.name)
    }

    @Test("文本基线从左上角锚点稳定映射")
    func textBaselineUsesTopLeftAnchor() throws {
        let source = solidImage(width: 120, height: 60, colorSpace: rgbColorSpace)
        let rendered = try AnnotationRenderer().render(
            image: source,
            pointSize: .init(width: 120, height: 60),
            annotations: [.init(
                kind: .text,
                points: [.init(x: 8, y: 10)],
                style: .init(color: .red, lineWidth: 1),
                text: .init(value: "Touch", fontSize: 18)
            )]
        )
        let bounds = changedPixelBounds(in: rendered)

        #expect(bounds != nil)
        #expect(bounds!.minX >= 7 && bounds!.minX <= 10)
        #expect(bounds!.minY >= 8 && bounds!.minY <= 16)
        #expect(bounds!.maxY < 36)
    }

    @Test("空路径、非有限点和极小图片安全退化")
    func degenerateGeometryIsIgnored() throws {
        let source = solidImage(width: 1, height: 1, colorSpace: rgbColorSpace)
        let rendered = try AnnotationRenderer().render(
            image: source,
            pointSize: .init(width: 1, height: 1),
            annotations: [
                .init(kind: .freehand, points: [], style: .init(color: .red, lineWidth: 2)),
                .init(
                    kind: .line,
                    points: [.init(x: .nan, y: 0), .init(x: .infinity, y: 1)],
                    style: .init(color: .red, lineWidth: .infinity)
                )
            ]
        )

        #expect(rendered.width == 1)
        #expect(rendered.height == 1)
        #expect(pixel(atX: 0, y: 0, in: rendered) == [255, 255, 255, 255])
    }

    @Test("预先取消的渲染任务立即停止")
    func renderingObservesCancellation() async {
        let wasCancelled = await Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try AnnotationRenderer().render(
                    image: solidImage(width: 16, height: 16, colorSpace: rgbColorSpace),
                    pointSize: .init(width: 16, height: 16),
                    annotations: [line(color: .red)]
                )
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }.value

        #expect(wasCancelled)
    }

    @Test("工作内存上限在分配渲染画布前生效")
    func workingMemoryLimitIsEnforced() throws {
        let renderer = AnnotationRenderer(limits: .init(
            maximumOutputPixelDimension: 100,
            maximumWorkingBytes: 128
        ))
        let source = solidImage(width: 8, height: 8, colorSpace: rgbColorSpace)

        #expect(throws: ScreenshotFeatureError.encodingFailed) {
            _ = try renderer.render(
                image: source,
                pointSize: .init(width: 8, height: 8),
                annotations: [line(color: .red)]
            )
        }
    }

    private func line(color: ScreenshotAnnotationColor) -> ScreenshotAnnotation {
        .init(
            kind: .line,
            points: [.init(x: 2, y: 12), .init(x: 22, y: 12)],
            style: .init(color: color, lineWidth: 6)
        )
    }

    private var rgbColorSpace: CGColorSpace {
        CGColorSpace(name: CGColorSpace.sRGB)!
    }

    private func solidImage(width: Int, height: Int, colorSpace: CGColorSpace) -> CGImage {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(colorSpace: colorSpace, components: [1, 1, 1, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    private func changedPixelBounds(in image: CGImage) -> CGRect? {
        let bytes = rgbaBytes(image)
        var minX = image.width
        var minY = image.height
        var maxX = -1
        var maxY = -1
        for y in 0..<image.height {
            for x in 0..<image.width {
                let index = (y * image.width + x) * 4
                if bytes[index] < 245 || bytes[index + 1] < 245 || bytes[index + 2] < 245 {
                    minX = min(minX, x)
                    minY = min(minY, y)
                    maxX = max(maxX, x)
                    maxY = max(maxY, y)
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func pixel(atX x: Int, y: Int, in image: CGImage) -> [UInt8] {
        let bytes = rgbaBytes(image)
        let index = (y * image.width + x) * 4
        return Array(bytes[index..<(index + 4)])
    }

    private func rgbaBytes(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(
            data: &bytes,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: image.width * 4,
            space: rgbColorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return bytes
    }
}
