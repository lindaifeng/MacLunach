import CoreGraphics
import ScreenshotFeature
import Testing
@testable import ScreenshotServiceCore

@Suite("截图高级效果")
struct AnnotationEffectsTests {
    @Test("高斯模糊只修改矩形 mask 内像素且边界裁剪稳定")
    func blurIsClippedToSelection() throws {
        let source = splitImage(width: 100, height: 60)
        let rendered = try AnnotationRenderer().render(
            image: source,
            pointSize: .init(width: 100, height: 60),
            annotations: [.init(
                kind: .blur,
                points: [.init(x: 30, y: 10), .init(x: 70, y: 50)],
                style: .init(color: .red, lineWidth: 1),
                blur: .init(radius: 8)
            )]
        )

        #expect(pixel(atX: 10, y: 30, in: rendered) == pixel(atX: 10, y: 30, in: source))
        #expect(pixel(atX: 49, y: 30, in: rendered) != pixel(atX: 49, y: 30, in: source))
        #expect(pixel(atX: 90, y: 30, in: rendered) == pixel(atX: 90, y: 30, in: source))
    }

    @Test("放大镜按倍率重采样且圆形 mask 外保持原像素")
    func magnifierUsesCircularMask() throws {
        let source = gradientImage(width: 100, height: 100)
        let rendered = try AnnotationRenderer().render(
            image: source,
            pointSize: .init(width: 100, height: 100),
            annotations: [.init(
                kind: .magnifier,
                points: [.init(x: 50, y: 50)],
                style: .init(color: .red, lineWidth: 2),
                magnifier: .init(magnification: 2, diameter: 40, borderWidth: 2)
            )]
        )

        #expect(pixel(atX: 60, y: 50, in: rendered) != pixel(atX: 60, y: 50, in: source))
        #expect(pixel(atX: 69, y: 69, in: rendered) == pixel(atX: 69, y: 69, in: source))
    }

    @Test("非破坏裁剪改变输出尺寸并保持左上角坐标映射")
    func cropChangesOutputDimensions() throws {
        let source = gradientImage(width: 100, height: 80)
        let crop = ScreenshotAnnotation(
            kind: .crop,
            points: [.init(x: 20, y: 10), .init(x: 80, y: 60)],
            style: .init(color: .red, lineWidth: 1)
        )
        let renderer = AnnotationRenderer()
        let rendered = try renderer.render(
            image: source,
            pointSize: .init(width: 100, height: 80),
            annotations: [crop]
        )

        #expect(rendered.width == 60)
        #expect(rendered.height == 50)
        #expect(renderer.outputPointSize(
            source: .init(width: 100, height: 80),
            annotations: [crop]
        ) == .init(width: 60, height: 50))
        #expect(pixel(atX: 0, y: 0, in: rendered) == pixel(atX: 20, y: 10, in: source))
        #expect(pixel(atX: 59, y: 49, in: rendered) == pixel(atX: 79, y: 59, in: source))
    }

    @Test("越界裁剪被夹紧，无效裁剪回退原尺寸")
    func cropBoundsAreSanitized() throws {
        let source = gradientImage(width: 100, height: 80)
        let renderer = AnnotationRenderer()
        let clipped = ScreenshotAnnotation(
            kind: .crop,
            points: [.init(x: -20, y: -10), .init(x: 40, y: 30)],
            style: .init(color: .red, lineWidth: 1)
        )
        let invalid = ScreenshotAnnotation(
            kind: .crop,
            points: [.init(x: 50, y: 50), .init(x: 50, y: 50)],
            style: .init(color: .red, lineWidth: 1)
        )

        let clippedImage = try renderer.render(
            image: source,
            pointSize: .init(width: 100, height: 80),
            annotations: [clipped]
        )
        let invalidImage = try renderer.render(
            image: source,
            pointSize: .init(width: 100, height: 80),
            annotations: [invalid]
        )

        #expect(clippedImage.width == 40)
        #expect(clippedImage.height == 30)
        #expect(invalidImage.width == source.width)
        #expect(invalidImage.height == source.height)
    }

    @Test("多个裁剪只使用最后一个，裁剪后再应用美化边距")
    func latestCropPrecedesBeautify() throws {
        let source = gradientImage(width: 100, height: 80)
        let firstCrop = ScreenshotAnnotation(
            kind: .crop,
            points: [.init(x: 0, y: 0), .init(x: 90, y: 70)],
            style: .init(color: .red, lineWidth: 1)
        )
        let latestCrop = ScreenshotAnnotation(
            kind: .crop,
            points: [.init(x: 20, y: 10), .init(x: 80, y: 60)],
            style: .init(color: .red, lineWidth: 1)
        )
        let beautify = ScreenshotAnnotation(
            kind: .beautify,
            points: [.init(x: 0, y: 0), .init(x: 100, y: 80)],
            style: .init(color: .red, lineWidth: 1),
            beautify: .init(
                cornerRadius: 0,
                shadowRadius: 0,
                shadowOpacity: 0,
                shadowOffsetX: 0,
                shadowOffsetY: 0,
                insets: .init(top: 2, right: 3, bottom: 4, left: 5),
                backgroundGradient: .init(
                    colors: [.red, .init(red: 0, green: 0, blue: 1)],
                    angleDegrees: 0
                )
            )
        )
        let renderer = AnnotationRenderer()

        let rendered = try renderer.render(
            image: source,
            pointSize: .init(width: 100, height: 80),
            annotations: [firstCrop, beautify, latestCrop]
        )

        #expect(rendered.width == 68)
        #expect(rendered.height == 56)
        #expect(renderer.outputPointSize(
            source: .init(width: 100, height: 80),
            annotations: [firstCrop, beautify, latestCrop]
        ) == .init(width: 68, height: 56))
    }

    @Test("模糊与放大镜对透明图和非有限参数保持稳定")
    func effectsSanitizeTransparentAndNonFiniteInputs() throws {
        let source = transparentImage(width: 32, height: 24)
        let annotations = [
            ScreenshotAnnotation(
                kind: .blur,
                points: [.init(x: 1, y: 1), .init(x: 2, y: 2)],
                style: .init(color: .red, lineWidth: 1),
                blur: .init(radius: .infinity)
            ),
            ScreenshotAnnotation(
                kind: .magnifier,
                points: [.init(x: 1, y: 1)],
                style: .init(color: .red, lineWidth: 1),
                magnifier: .init(
                    magnification: .nan,
                    diameter: .infinity,
                    borderWidth: .nan
                )
            )
        ]

        let rendered = try AnnotationRenderer().render(
            image: source,
            pointSize: .init(width: 32, height: 24),
            annotations: annotations
        )

        #expect(rendered.width == 32)
        #expect(rendered.height == 24)
        #expect(pixel(atX: 31, y: 23, in: rendered) == [0, 0, 0, 0])
    }

    private func splitImage(width: Int, height: Int) -> CGImage {
        let context = bitmapContext(width: width, height: height)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: width / 2, y: 0, width: width / 2, height: height))
        return context.makeImage()!
    }

    private func gradientImage(width: Int, height: Int) -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                bytes[index] = UInt8((x * 3 + y) % 256)
                bytes[index + 1] = UInt8((x + y * 5) % 256)
                bytes[index + 2] = UInt8((x * 7 + y * 2) % 256)
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

    private func transparentImage(width: Int, height: Int) -> CGImage {
        let context = bitmapContext(width: width, height: height)
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    private func bitmapContext(width: Int, height: Int) -> CGContext {
        CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
    }

    private func pixel(atX x: Int, y: Int, in image: CGImage) -> [UInt8] {
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
        let offset = (y * image.width + x) * 4
        return Array(bytes[offset..<(offset + 4)])
    }
}
