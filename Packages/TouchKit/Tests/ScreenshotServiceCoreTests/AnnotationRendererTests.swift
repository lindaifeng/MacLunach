import CoreGraphics
import ScreenshotFeature
import Testing
@testable import ScreenshotServiceCore

@Suite("截图标注渲染")
struct AnnotationRendererTests {
    @Test("空图层不重建底图")
    func emptyAnnotationsReturnOriginalImage() throws {
        let image = whiteImage(width: 40, height: 30)
        let rendered = try AnnotationRenderer().render(
            image: image,
            pointSize: .init(width: 20, height: 15),
            annotations: []
        )
        #expect(rendered === image)
    }

    @Test("基础绘图、文本、数字点和备注都写入最终像素")
    func everyBasicToolRendersPixels() throws {
        for kind in ScreenshotAnnotationKind.allCases {
            let image = [.mosaic, .blur, .magnifier, .crop].contains(kind)
                ? gradientImage(width: 100, height: 100)
                : whiteImage(width: 100, height: 100)
            let style: ScreenshotAnnotationStyle = kind == .highlighter
                ? .init(color: .yellow, lineWidth: 10)
                : .init(color: .red, lineWidth: 3)
            let rendered = try AnnotationRenderer().render(
                image: image,
                pointSize: .init(width: 100, height: 100),
                annotations: [toolAnnotation(for: kind, style: style)]
            )

            if kind == .crop {
                #expect(rendered.width != image.width || rendered.height != image.height, "裁剪应修改输出尺寸")
            } else if [.mosaic, .blur, .magnifier].contains(kind) {
                #expect(rgbaBytes(rendered) != rgbaBytes(image), "\(kind) 应修改最终图片像素")
            } else {
                #expect(nonWhitePixelCount(in: rendered) > 10, "\(kind) 应修改最终图片像素")
            }
        }
    }

    @Test("point 坐标按 Retina 比例映射且保持左上角原点")
    func pointCoordinatesScaleFromTopLeft() throws {
        let rendered = try AnnotationRenderer().render(
            image: whiteImage(width: 200, height: 100),
            pointSize: .init(width: 100, height: 50),
            annotations: [.init(
                kind: .line,
                points: [.init(x: 5, y: 5), .init(x: 25, y: 5)],
                style: .init(color: .red, lineWidth: 2)
            )]
        )

        #expect(isRed(pixelAtX: 30, y: 10, in: rendered))
        #expect(!isRed(pixelAtX: 30, y: 90, in: rendered))
    }

    @Test("马赛克只像素化画笔覆盖区域并保持选区外像素不变")
    func mosaicPixelatesOnlyBrushedPixels() throws {
        let source = gradientImage(width: 96, height: 64)
        let rendered = try AnnotationRenderer().render(
            image: source,
            pointSize: .init(width: 96, height: 64),
            annotations: [.init(
                kind: .mosaic,
                points: [.init(x: 24, y: 32), .init(x: 72, y: 32)],
                style: .init(color: .red, lineWidth: 20),
                mosaic: .init(blockSize: 8)
            )]
        )

        #expect(pixel(atX: 8, y: 8, in: rendered) == pixel(atX: 8, y: 8, in: source))
        #expect(pixel(atX: 48, y: 32, in: rendered) != pixel(atX: 48, y: 32, in: source))
        #expect(pixel(atX: 48, y: 32, in: rendered) == pixel(atX: 49, y: 32, in: rendered))
    }

    @Test("美化增加确定边距并绘制圆角阴影渐变画布")
    func beautifyWrapsImageInStyledCanvas() throws {
        let source = gradientImage(width: 80, height: 40)
        let beautify = ScreenshotAnnotationBeautify(
            cornerRadius: 8,
            shadowRadius: 6,
            shadowOpacity: 0.3,
            shadowOffsetX: 0,
            shadowOffsetY: 3,
            insets: .init(top: 10, right: 20, bottom: 30, left: 40),
            backgroundGradient: .init(
                colors: [
                    .init(red: 0.2, green: 0.1, blue: 0.8),
                    .init(red: 0.1, green: 0.8, blue: 0.9)
                ],
                angleDegrees: 0
            )
        )
        let renderer = AnnotationRenderer()
        let annotation = ScreenshotAnnotation(
            kind: .beautify,
            points: [.init(x: 0, y: 0), .init(x: 40, y: 20)],
            style: .init(color: .red, lineWidth: 1),
            beautify: beautify
        )

        let rendered = try renderer.render(
            image: source,
            pointSize: .init(width: 40, height: 20),
            annotations: [annotation]
        )

        #expect(rendered.width == 200)
        #expect(rendered.height == 120)
        #expect(renderer.outputPointSize(
            source: .init(width: 40, height: 20),
            annotations: [annotation]
        ) == .init(width: 100, height: 60))
        #expect(pixel(atX: 2, y: 2, in: rendered) != pixel(atX: 197, y: 2, in: rendered))
        #expect(pixel(atX: 100, y: 50, in: rendered) != pixel(atX: 2, y: 2, in: rendered))
    }

    @Test("便签使用图层圆角边距和背景渐变")
    func noteUsesLayerLayoutAndGradient() throws {
        let note = AnnotationLayer(
            annotation: .init(
                kind: .note,
                points: [.init(x: 10, y: 10), .init(x: 90, y: 90)],
                style: .init(color: .red, lineWidth: 2),
                text: .init(value: "", fontSize: 14)
            ),
            cornerRadius: 20,
            contentInsets: .uniform(18),
            backgroundGradient: .init(
                colors: [
                    .init(red: 0.1, green: 0.2, blue: 0.9),
                    .init(red: 0.2, green: 0.8, blue: 0.9)
                ],
                angleDegrees: 90
            )
        )
        let document = AnnotationDocument(
            sourceImageRelativePath: "Captures/source.png",
            canvasSize: .init(width: 100, height: 100),
            layers: [note]
        )

        let rendered = try AnnotationRenderer().render(
            image: whiteImage(width: 100, height: 100),
            document: document
        )
        let center = Array(pixel(atX: 50, y: 50, in: rendered))

        #expect(center[2] > 180)
        #expect(center[0] < 100)
        #expect(center[1] > 60)
    }

    private func toolAnnotation(
        for kind: ScreenshotAnnotationKind,
        style: ScreenshotAnnotationStyle
    ) -> ScreenshotAnnotation {
        switch kind {
        case .rectangle, .ellipse:
            .init(
                kind: kind,
                points: [.init(x: 20, y: 20), .init(x: 75, y: 70)],
                style: style
            )
        case .line, .arrow:
            .init(
                kind: kind,
                points: [.init(x: 15, y: 20), .init(x: 80, y: 75)],
                style: style
            )
        case .freehand, .highlighter, .mosaic:
            .init(
                kind: kind,
                points: [
                    .init(x: 10, y: 70),
                    .init(x: 30, y: 40),
                    .init(x: 55, y: 60),
                    .init(x: 85, y: 25)
                ],
                style: kind == .mosaic
                    ? .init(color: .red, lineWidth: 24)
                    : style,
                mosaic: kind == .mosaic ? .init(blockSize: 8) : nil
            )
        case .blur:
            .init(
                kind: kind,
                points: [.init(x: 20, y: 20), .init(x: 80, y: 80)],
                style: style,
                blur: .init(radius: 8)
            )
        case .magnifier:
            .init(
                kind: kind,
                points: [.init(x: 50, y: 50)],
                style: style,
                magnifier: .init(magnification: 2, diameter: 48, borderWidth: 3)
            )
        case .crop:
            .init(
                kind: kind,
                points: [.init(x: 10, y: 10), .init(x: 90, y: 85)],
                style: style
            )
        case .text:
            .init(
                kind: kind,
                points: [.init(x: 15, y: 20)],
                style: style,
                text: .init(value: "Touch", fontSize: 18)
            )
        case .numberedMarker:
            .init(
                kind: kind,
                points: [.init(x: 50, y: 50)],
                style: style,
                text: .init(value: "1", fontSize: 15)
            )
        case .callout:
            .init(
                kind: kind,
                points: [
                    .init(x: 12, y: 18),
                    .init(x: 34, y: 36),
                    .init(x: 34, y: 28),
                    .init(x: 88, y: 78)
                ],
                style: style,
                text: .init(value: "批注内容", fontSize: 14)
            )
        case .note:
            .init(
                kind: kind,
                points: [.init(x: 15, y: 15), .init(x: 85, y: 80)],
                style: style,
                text: .init(value: "备注内容", fontSize: 14)
            )
        case .sticker:
            .init(
                kind: kind,
                points: [.init(x: 50, y: 50)],
                style: style,
                sticker: .init(value: "🎉", size: 34)
            )
        case .watermark:
            .init(
                kind: kind,
                points: [.init(x: 5, y: 5), .init(x: 95, y: 95)],
                style: style,
                watermark: .init(
                    value: "Touch",
                    fontSize: 12,
                    opacity: 0.35,
                    angleDegrees: -24,
                    spacing: 24
                )
            )
        case .beautify:
            .init(
                kind: kind,
                points: [.init(x: 0, y: 0), .init(x: 100, y: 100)],
                style: style,
                beautify: .init(
                    cornerRadius: 8,
                    shadowRadius: 6,
                    shadowOpacity: 0.25,
                    shadowOffsetX: 0,
                    shadowOffsetY: 3,
                    insets: .uniform(12),
                    backgroundGradient: .init(
                        colors: [
                            .init(red: 0.3, green: 0.2, blue: 0.8),
                            .init(red: 0.2, green: 0.8, blue: 0.9)
                        ],
                        angleDegrees: 20
                    )
                )
            )
        }
    }

    private func whiteImage(width: Int, height: Int) -> CGImage {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    private func gradientImage(width: Int, height: Int) -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                bytes[index] = UInt8((x * 17 + y * 3) % 256)
                bytes[index + 1] = UInt8((x * 5 + y * 11) % 256)
                bytes[index + 2] = UInt8((x * 13 + y * 7) % 256)
            }
        }
        let context = CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return context.makeImage()!
    }

    private func nonWhitePixelCount(in image: CGImage) -> Int {
        let bytes = rgbaBytes(image)
        var count = 0
        for index in Swift.stride(from: 0, to: bytes.count, by: 4) {
            if bytes[index] < 245 || bytes[index + 1] < 245 || bytes[index + 2] < 245 {
                count += 1
            }
        }
        return count
    }

    private func isRed(pixelAtX x: Int, y: Int, in image: CGImage) -> Bool {
        let bytes = rgbaBytes(image)
        let index = (y * image.width + x) * 4
        return bytes[index] > 180 && bytes[index + 1] < 120 && bytes[index + 2] < 120
    }

    private func pixel(atX x: Int, y: Int, in image: CGImage) -> ArraySlice<UInt8> {
        let bytes = rgbaBytes(image)
        let index = (y * image.width + x) * 4
        return bytes[index..<(index + 4)]
    }

    private func rgbaBytes(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(
            data: &bytes,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return bytes
    }
}
