import CoreGraphics
import CoreText
import Foundation
import ScreenshotFeature

public struct AnnotationRenderLimits: Equatable, Sendable {
    public let maximumOutputPixelDimension: Int
    public let maximumWorkingBytes: Int

    public init(
        maximumOutputPixelDimension: Int = 32_768,
        maximumWorkingBytes: Int = 512 * 1_024 * 1_024
    ) {
        self.maximumOutputPixelDimension = max(1, maximumOutputPixelDimension)
        self.maximumWorkingBytes = max(1, maximumWorkingBytes)
    }
}

/// 将非破坏性标注图层合成到捕获图像。输入坐标以左上角为原点、单位为 point。
public struct AnnotationRenderer: Sendable {
    private static let maximumInsetPoints = 4_096.0

    private let effects: AnnotationEffects
    private let limits: AnnotationRenderLimits

    public init(
        effects: AnnotationEffects = .shared,
        limits: AnnotationRenderLimits = .init()
    ) {
        self.effects = effects
        self.limits = limits
    }

    public func render(
        image: CGImage,
        pointSize: ScreenshotSize,
        annotations: [ScreenshotAnnotation]
    ) throws -> CGImage {
        let layers = annotations.enumerated().map { index, annotation in
            AnnotationLayer(annotation: annotation, zIndex: index)
        }
        return try render(image: image, pointSize: pointSize, layers: layers)
    }

    /// 编辑器预览和最终导出均可直接使用同一份项目文档与渲染参数。
    public func render(image: CGImage, document: AnnotationDocument) throws -> CGImage {
        try render(image: image, pointSize: document.canvasSize, layers: document.layers)
    }

    public func render(
        image: CGImage,
        pointSize: ScreenshotSize,
        layers: [AnnotationLayer]
    ) throws -> CGImage {
        guard !layers.isEmpty else { return image }
        return try autoreleasepool {
            try renderInAutoreleasePool(image: image, pointSize: pointSize, layers: layers)
        }
    }

    private func renderInAutoreleasePool(
        image: CGImage,
        pointSize: ScreenshotSize,
        layers: [AnnotationLayer]
    ) throws -> CGImage {
        try Task.checkCancellation()
        let orderedLayers = layers.enumerated().sorted { lhs, rhs in
            if lhs.element.zIndex == rhs.element.zIndex { return lhs.offset < rhs.offset }
            return lhs.element.zIndex < rhs.element.zIndex
        }.map(\.element)
        let annotations = orderedLayers.map(\.annotation)
        let workingBufferCount = annotations.contains(where: {
            [.mosaic, .blur, .magnifier, .beautify].contains($0.kind)
        }) ? 4 : 2
        guard image.width > 0,
              image.height > 0,
              pointSize.width.isFinite,
              pointSize.height.isFinite,
              pointSize.width > 0,
              pointSize.height > 0 else {
            throw ScreenshotFeatureError.encodingFailed
        }
        try validateBufferSize(
            width: image.width,
            height: image.height,
            concurrentBuffers: workingBufferCount
        )
        guard let context = CGContext(
                data: nil,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: outputColorSpace(for: image),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw ScreenshotFeatureError.encodingFailed
        }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))

        let scaleX = Double(image.width) / pointSize.width
        let scaleY = Double(image.height) / pointSize.height
        let lineScale = (scaleX + scaleY) / 2
        for layer in orderedLayers where layer.kind != .beautify && layer.kind != .crop {
            try Task.checkCancellation()
            let pixelSource: CGImage
            switch layer.kind {
            case .mosaic, .blur, .magnifier:
                pixelSource = context.makeImage() ?? image
            default:
                pixelSource = image
            }
            try draw(
                layer,
                sourceImage: pixelSource,
                in: context,
                pointSize: pointSize,
                scaleX: scaleX,
                scaleY: scaleY,
                lineScale: lineScale
            )
        }

        guard var rendered = context.makeImage() else {
            throw ScreenshotFeatureError.encodingFailed
        }
        var renderedPointSize = pointSize
        if let cropRect = effectiveCropRect(source: pointSize, annotations: annotations) {
            rendered = try crop(
                image: rendered,
                sourcePointSize: pointSize,
                cropRect: cropRect
            )
            renderedPointSize = .init(width: cropRect.width, height: cropRect.height)
        }
        guard let beautify = annotations.last(where: { $0.kind == .beautify })?.beautify else {
            return rendered
        }
        try Task.checkCancellation()
        return try drawBeautifiedCanvas(
            sourceImage: rendered,
            sourcePointSize: renderedPointSize,
            beautify: beautify
        )
    }

    /// 返回最终导出图片对应的 point 尺寸。普通标注不改变尺寸，美化会按最后一个效果图层扩展画布。
    public func outputPointSize(
        source: ScreenshotSize,
        annotations: [ScreenshotAnnotation]
    ) -> ScreenshotSize {
        outputPointSize(
            source: source,
            layers: annotations.enumerated().map { index, annotation in
                AnnotationLayer(annotation: annotation, zIndex: index)
            }
        )
    }

    /// 与 `render(image:document:)` 配套，供预览和导出从同一项目文档计算最终画布尺寸。
    public func outputPointSize(document: AnnotationDocument) -> ScreenshotSize {
        outputPointSize(source: document.canvasSize, layers: document.layers)
    }

    public func outputPointSize(source: ScreenshotSize, layers: [AnnotationLayer]) -> ScreenshotSize {
        guard source.width.isFinite,
              source.height.isFinite,
              source.width > 0,
              source.height > 0 else {
            return source
        }
        let orderedLayers = layers.enumerated().sorted { lhs, rhs in
            if lhs.element.zIndex == rhs.element.zIndex { return lhs.offset < rhs.offset }
            return lhs.element.zIndex < rhs.element.zIndex
        }.map(\.element)
        let annotations = orderedLayers.map(\.annotation)
        let croppedSize = effectiveCropRect(source: source, annotations: annotations).map {
            ScreenshotSize(width: Double($0.width), height: Double($0.height))
        } ?? source
        guard let beautify = annotations.last(where: { $0.kind == .beautify })?.beautify else {
            return croppedSize
        }
        let insets = sanitizedInsets(beautify.insets)
        return ScreenshotSize(
            width: croppedSize.width + insets.left + insets.right,
            height: croppedSize.height + insets.top + insets.bottom
        )
    }

    private func draw(
        _ layer: AnnotationLayer,
        sourceImage: CGImage,
        in context: CGContext,
        pointSize: ScreenshotSize,
        scaleX: Double,
        scaleY: Double,
        lineScale: Double
    ) throws {
        let annotation = layer.annotation
        let points = AnnotationGeometry.pixelPoints(
            for: annotation.points,
            pointSize: pointSize,
            pixelWidth: context.width,
            pixelHeight: context.height
        )
        guard !points.isEmpty else { return }

        let color = annotation.style.color
        context.saveGState()
        defer { context.restoreGState() }
        context.setShouldAntialias(true)
        context.setAllowsAntialiasing(true)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setAlpha(CGFloat(clamp(finite(layer.opacity, fallback: 1))))
        context.setLineWidth(max(1, finiteNonnegative(annotation.style.lineWidth, maximum: 4_096) * lineScale))
        if let shadow = layer.shadow {
            context.setShadow(
                offset: CGSize(
                    width: finite(shadow.offsetX, fallback: 0) * scaleX,
                    height: -finite(shadow.offsetY, fallback: 0) * scaleY
                ),
                blur: finiteNonnegative(shadow.radius, maximum: 2_048) * lineScale,
                color: cgColor(shadow.color)
            )
        }
        context.setStrokeColor(cgColor(color))

        switch annotation.kind {
        case .rectangle:
            guard let rect = AnnotationGeometry.boundingRect(points) else { return }
            let radius = min(
                finiteNonnegative(layer.cornerRadius, maximum: 2_048) * lineScale,
                Double(min(rect.width, rect.height)) / 2
            )
            if radius > 0 {
                context.addPath(CGPath(
                    roundedRect: rect,
                    cornerWidth: radius,
                    cornerHeight: radius,
                    transform: nil
                ))
                context.strokePath()
            } else {
                context.stroke(rect)
            }
        case .ellipse:
            guard let rect = AnnotationGeometry.boundingRect(points) else { return }
            context.strokeEllipse(in: rect)
        case .line:
            guard points.count >= 2 else { return }
            strokeLine(from: points[0], to: points[points.count - 1], in: context)
        case .arrow:
            guard points.count >= 2 else { return }
            let start = points[0]
            let end = points[points.count - 1]
            strokeLine(from: start, to: end, in: context)
            strokeArrowHead(
                from: start,
                to: end,
                size: max(8 * lineScale, annotation.style.lineWidth * lineScale * 3.2),
                in: context
            )
        case .freehand, .highlighter:
            guard points.count >= 2 else { return }
            context.beginPath()
            context.move(to: points[0])
            for point in points.dropFirst() { context.addLine(to: point) }
            context.strokePath()
        case .mosaic:
            guard points.count >= 2 else { return }
            drawMosaic(
                along: points,
                sourceImage: sourceImage,
                blockSize: max(2, (annotation.mosaic?.blockSize ?? 10) * lineScale),
                in: context
            )
        case .blur:
            guard let rect = AnnotationGeometry.boundingRect(points), let blur = annotation.blur else { return }
            let clippedRect = rect.intersection(CGRect(
                x: 0,
                y: 0,
                width: context.width,
                height: context.height
            ))
            guard !clippedRect.isNull, clippedRect.width >= 1, clippedRect.height >= 1 else { return }
            let blurred: CGImage
            do {
                blurred = try effects.gaussianBlur(
                    image: sourceImage,
                    radius: max(0, blur.radius * lineScale)
                )
            } catch {
                throw ScreenshotFeatureError.serviceFailed(
                    message: "标注图层 \(annotation.id.uuidString) 模糊渲染失败"
                )
            }
            context.clip(to: clippedRect)
            context.draw(blurred, in: CGRect(
                x: 0,
                y: 0,
                width: context.width,
                height: context.height
            ))
        case .magnifier:
            guard let center = points.first, let magnifier = annotation.magnifier else { return }
            drawMagnifier(
                magnifier,
                at: center,
                sourceImage: sourceImage,
                scale: lineScale,
                borderColor: cgColor(annotation.style.color),
                context: context
            )
        case .crop:
            return
        case .sticker:
            guard let center = points.first, let sticker = annotation.sticker else { return }
            drawSticker(sticker.value, at: center, size: sticker.size * lineScale, in: context)
        case .watermark:
            guard let rect = AnnotationGeometry.boundingRect(points), let watermark = annotation.watermark else { return }
            drawWatermark(
                watermark,
                in: rect,
                scale: lineScale,
                color: annotation.style.color,
                context: context
            )
        case .beautify:
            return
        case .text:
            guard let anchor = points.first, let text = annotation.text else { return }
            drawSingleLineText(
                text.value,
                at: anchor,
                fontStyle: layer.font,
                fallbackFontSize: text.fontSize * lineScale,
                color: cgColor(annotation.style.color),
                in: context
            )
        case .numberedMarker:
            guard let center = points.first, let text = annotation.text else { return }
            drawNumberedMarker(
                text.value,
                at: center,
                fontStyle: layer.font,
                fallbackFontSize: text.fontSize * lineScale,
                color: cgColor(annotation.style.color),
                in: context
            )
        case .callout:
            guard points.count >= 2 else { return }
            drawCallout(
                annotation.text?.value ?? "",
                points: points,
                fontStyle: layer.font,
                fallbackFontSize: (annotation.text?.fontSize ?? 16) * lineScale,
                color: cgColor(annotation.style.color),
                in: context
            )
        case .note:
            guard let rect = AnnotationGeometry.boundingRect(points), let text = annotation.text else { return }
            drawNote(
                text.value,
                in: rect,
                fontStyle: layer.font,
                fallbackFontSize: text.fontSize * lineScale,
                cornerRadius: layer.cornerRadius * lineScale,
                contentInsets: layer.contentInsets,
                backgroundGradient: layer.backgroundGradient,
                scaleX: scaleX,
                scaleY: scaleY,
                context: context
            )
        }
    }

    private func drawMagnifier(
        _ magnifier: ScreenshotAnnotationMagnifier,
        at center: CGPoint,
        sourceImage: CGImage,
        scale: Double,
        borderColor: CGColor,
        context: CGContext
    ) {
        let magnification = min(max(finite(magnifier.magnification, fallback: 2), 1), 8)
        let diameter = min(
            max(finite(magnifier.diameter, fallback: 120) * scale, 8),
            4_096
        )
        let radius = diameter / 2
        let circle = CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: diameter,
            height: diameter
        )

        context.saveGState()
        context.addEllipse(in: circle)
        context.clip()
        let magnifiedRect = CGRect(
            x: center.x - center.x * magnification,
            y: center.y - center.y * magnification,
            width: Double(sourceImage.width) * magnification,
            height: Double(sourceImage.height) * magnification
        )
        context.interpolationQuality = .high
        context.draw(sourceImage, in: magnifiedRect)
        context.restoreGState()

        context.setStrokeColor(borderColor)
        context.setLineWidth(max(1, finite(magnifier.borderWidth, fallback: 3) * scale))
        context.strokeEllipse(in: circle.insetBy(dx: 0.5, dy: 0.5))
    }

    private func effectiveCropRect(
        source: ScreenshotSize,
        annotations: [ScreenshotAnnotation]
    ) -> CGRect? {
        AnnotationGeometry.effectiveCropRect(source: source, annotations: annotations)
    }

    private func crop(
        image: CGImage,
        sourcePointSize: ScreenshotSize,
        cropRect: CGRect
    ) throws -> CGImage {
        guard let pixelRect = AnnotationGeometry.pixelCropRect(
                sourcePointSize: sourcePointSize,
                imageWidth: image.width,
                imageHeight: image.height,
                cropRect: cropRect
              ),
              let output = image.cropping(to: pixelRect) else {
            throw ScreenshotFeatureError.encodingFailed
        }
        return output
    }

    private func drawBeautifiedCanvas(
        sourceImage: CGImage,
        sourcePointSize: ScreenshotSize,
        beautify: ScreenshotAnnotationBeautify
    ) throws -> CGImage {
        let scaleX = Double(sourceImage.width) / sourcePointSize.width
        let scaleY = Double(sourceImage.height) / sourcePointSize.height
        let averageScale = (scaleX + scaleY) / 2
        let insets = sanitizedInsets(beautify.insets)
        let left = Int((insets.left * scaleX).rounded())
        let right = Int((insets.right * scaleX).rounded())
        let top = Int((insets.top * scaleY).rounded())
        let bottom = Int((insets.bottom * scaleY).rounded())
        let width = sourceImage.width + left + right
        let height = sourceImage.height + top + bottom

        try validateBufferSize(width: width, height: height, concurrentBuffers: 2)
        guard let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: outputColorSpace(for: sourceImage),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw ScreenshotFeatureError.encodingFailed
        }

        let canvas = CGRect(x: 0, y: 0, width: width, height: height)
        drawGradient(beautify.backgroundGradient, in: canvas, context: context)

        let imageRect = CGRect(
            x: left,
            y: bottom,
            width: sourceImage.width,
            height: sourceImage.height
        )
        let requestedRadius = finiteNonnegative(beautify.cornerRadius, maximum: 2_048) * averageScale
        let cornerRadius = min(
            requestedRadius,
            Double(min(sourceImage.width, sourceImage.height)) / 2
        )
        let roundedImage = try makeRoundedImage(
            sourceImage,
            cornerRadius: CGFloat(cornerRadius)
        )

        context.saveGState()
        context.setShadow(
            offset: CGSize(
                width: finite(beautify.shadowOffsetX, fallback: 0) * scaleX,
                height: -finite(beautify.shadowOffsetY, fallback: 0) * scaleY
            ),
            blur: finiteNonnegative(beautify.shadowRadius, maximum: 2_048) * averageScale,
            color: CGColor(
                gray: 0,
                alpha: CGFloat(clamp(finite(beautify.shadowOpacity, fallback: 0)))
            )
        )
        context.interpolationQuality = .high
        context.draw(roundedImage, in: imageRect)
        context.restoreGState()

        guard let output = context.makeImage() else {
            throw ScreenshotFeatureError.encodingFailed
        }
        return output
    }

    private func makeRoundedImage(
        _ sourceImage: CGImage,
        cornerRadius: CGFloat
    ) throws -> CGImage {
        try validateBufferSize(
            width: sourceImage.width,
            height: sourceImage.height,
            concurrentBuffers: 2
        )
        guard let context = CGContext(
            data: nil,
            width: sourceImage.width,
            height: sourceImage.height,
            bitsPerComponent: 8,
            bytesPerRow: sourceImage.width * 4,
            space: outputColorSpace(for: sourceImage),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ScreenshotFeatureError.encodingFailed
        }
        let rect = CGRect(x: 0, y: 0, width: sourceImage.width, height: sourceImage.height)
        context.addPath(CGPath(
            roundedRect: rect,
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        ))
        context.clip()
        context.interpolationQuality = .high
        context.draw(sourceImage, in: rect)
        guard let output = context.makeImage() else {
            throw ScreenshotFeatureError.encodingFailed
        }
        return output
    }

    private func drawGradient(
        _ gradient: ScreenshotAnnotationGradient,
        in rect: CGRect,
        context: CGContext
    ) {
        var colors = gradient.colors.map(cgColor)
        if colors.isEmpty {
            colors = [
                CGColor(red: 0.16, green: 0.20, blue: 0.32, alpha: 1),
                CGColor(red: 0.42, green: 0.28, blue: 0.76, alpha: 1)
            ]
        } else if colors.count == 1 {
            colors.append(colors[0])
        }
        guard let cgGradient = CGGradient(
            colorsSpace: context.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
            colors: colors as CFArray,
            locations: nil
        ) else {
            context.setFillColor(colors[0])
            context.fill(rect)
            return
        }

        let angle = finite(gradient.angleDegrees, fallback: 0) * .pi / 180
        let direction = CGPoint(x: cos(angle), y: sin(angle))
        let halfLength = abs(direction.x) * rect.width / 2 + abs(direction.y) * rect.height / 2
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let start = CGPoint(
            x: center.x - direction.x * halfLength,
            y: center.y - direction.y * halfLength
        )
        let end = CGPoint(
            x: center.x + direction.x * halfLength,
            y: center.y + direction.y * halfLength
        )
        context.drawLinearGradient(cgGradient, start: start, end: end, options: [])
    }

    private func sanitizedInsets(
        _ insets: ScreenshotAnnotationInsets
    ) -> ScreenshotAnnotationInsets {
        .init(
            top: finiteNonnegative(insets.top, maximum: Self.maximumInsetPoints),
            right: finiteNonnegative(insets.right, maximum: Self.maximumInsetPoints),
            bottom: finiteNonnegative(insets.bottom, maximum: Self.maximumInsetPoints),
            left: finiteNonnegative(insets.left, maximum: Self.maximumInsetPoints)
        )
    }

    private func finiteNonnegative(_ value: Double, maximum: Double) -> Double {
        min(max(finite(value, fallback: 0), 0), maximum)
    }

    private func finite(_ value: Double, fallback: Double) -> Double {
        value.isFinite ? value : fallback
    }

    private func drawSticker(
        _ value: String,
        at center: CGPoint,
        size: Double,
        in context: CGContext
    ) {
        guard !value.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(
                "AppleColorEmoji" as CFString,
                CGFloat(max(12, size)),
                nil
            )
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: value, attributes: attributes))
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        context.textPosition = CGPoint(
            x: center.x - width / 2,
            y: center.y - (ascent - descent) / 2
        )
        CTLineDraw(line, context)
    }

    private func drawWatermark(
        _ watermark: ScreenshotAnnotationWatermark,
        in rect: CGRect,
        scale: Double,
        color: ScreenshotAnnotationColor,
        context: CGContext
    ) {
        guard !watermark.value.isEmpty, rect.width > 1, rect.height > 1 else { return }
        let fontSize = max(9, watermark.fontSize * scale)
        let line = makeLine(
            watermark.value,
            fontSize: fontSize,
            color: CGColor(
                red: CGFloat(clamp(finite(color.red, fallback: 0))),
                green: CGFloat(clamp(finite(color.green, fallback: 0))),
                blue: CGFloat(clamp(finite(color.blue, fallback: 0))),
                alpha: CGFloat(clamp(finite(color.alpha * watermark.opacity, fallback: 1)))
            )
        )
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        let spacing = max(18, watermark.spacing * scale)
        let stepX = max(width + spacing, 36)
        let stepY = max(CGFloat(fontSize * 2.4), spacing)
        let radians = CGFloat(watermark.angleDegrees * .pi / 180)

        context.clip(to: rect)
        var row = 0
        var y = rect.minY - stepY
        while y <= rect.maxY + stepY {
            let offset = row.isMultiple(of: 2) ? 0 : stepX / 2
            var x = rect.minX - stepX + offset
            while x <= rect.maxX + stepX {
                context.saveGState()
                context.translateBy(x: x, y: y)
                context.rotate(by: radians)
                context.textPosition = CGPoint(
                    x: -width / 2,
                    y: -(ascent - descent) / 2
                )
                CTLineDraw(line, context)
                context.restoreGState()
                x += stepX
            }
            row += 1
            y += stepY
        }
    }

    private func drawMosaic(
        along points: [CGPoint],
        sourceImage: CGImage,
        blockSize: Double,
        in context: CGContext
    ) {
        guard let pixelated = pixelatedImage(sourceImage, blockSize: blockSize) else { return }
        context.beginPath()
        context.move(to: points[0])
        for point in points.dropFirst() { context.addLine(to: point) }
        context.replacePathWithStrokedPath()
        context.clip()
        context.interpolationQuality = .none
        context.draw(
            pixelated,
            in: CGRect(x: 0, y: 0, width: context.width, height: context.height)
        )
    }

    private func pixelatedImage(_ image: CGImage, blockSize: Double) -> CGImage? {
        let width = max(1, Int(ceil(Double(image.width) / blockSize)))
        let height = max(1, Int(ceil(Double(image.height) / blockSize)))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: outputColorSpace(for: image),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private func drawSingleLineText(
        _ value: String,
        at anchor: CGPoint,
        fontStyle: AnnotationFontStyle?,
        fallbackFontSize: Double,
        color: CGColor,
        in context: CGContext
    ) {
        guard !value.isEmpty else { return }
        let font = makeFont(style: fontStyle, fallbackSize: fallbackFontSize, defaultBold: true)
        let line = makeLine(value, font: font, color: color)
        var ascent: CGFloat = 0
        CTLineGetTypographicBounds(line, &ascent, nil, nil)
        context.textPosition = CGPoint(x: anchor.x, y: anchor.y - ascent)
        CTLineDraw(line, context)
    }

    private func drawNumberedMarker(
        _ value: String,
        at center: CGPoint,
        fontStyle: AnnotationFontStyle?,
        fallbackFontSize: Double,
        color: CGColor,
        in context: CGContext
    ) {
        let font = makeFont(style: fontStyle, fallbackSize: fallbackFontSize, defaultBold: true)
        let fontSize = CTFontGetSize(font)
        let radius = CGFloat(max(10, fontSize * 0.78))
        context.setFillColor(color)
        context.fillEllipse(in: CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        ))
        let line = makeLine(value, font: font, color: CGColor(gray: 1, alpha: 1))
        let bounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
        context.textPosition = CGPoint(
            x: center.x - bounds.width / 2 - bounds.minX,
            y: center.y - bounds.height / 2 - bounds.minY
        )
        CTLineDraw(line, context)
    }

    /// 点—线—面的批注：首点为定位点，第二点为连线端点，后两点定义文本框。
    private func drawCallout(
        _ value: String,
        points: [CGPoint],
        fontStyle: AnnotationFontStyle?,
        fallbackFontSize: Double,
        color: CGColor,
        in context: CGContext
    ) {
        let anchor = points[0]
        let connector = points[1]
        context.setStrokeColor(color)
        context.beginPath()
        context.move(to: anchor)
        context.addLine(to: connector)
        context.strokePath()
        let dotRadius = CGFloat(max(5, fallbackFontSize * 0.25))
        context.setFillColor(color)
        context.fillEllipse(in: CGRect(
            x: anchor.x - dotRadius,
            y: anchor.y - dotRadius,
            width: dotRadius * 2,
            height: dotRadius * 2
        ))

        guard points.count >= 4,
              let rect = AnnotationGeometry.boundingRect(Array(points[2...3])),
              rect.width > 4,
              rect.height > 4 else { return }
        let radius = min(5, min(rect.width, rect.height) / 2)
        context.addPath(CGPath(
            roundedRect: rect,
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        ))
        context.setFillColor(color)
        context.fillPath()
        guard !value.isEmpty else { return }

        let inset = rect.insetBy(dx: 6, dy: 4)
        guard inset.width > 0, inset.height > 0 else { return }
        let font = makeFont(style: fontStyle, fallbackSize: fallbackFontSize, defaultBold: false)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1)
        ]
        let framesetter = CTFramesetterCreateWithAttributedString(
            NSAttributedString(string: value, attributes: attributes)
        )
        let frame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: 0),
            CGPath(rect: inset, transform: nil),
            nil
        )
        CTFrameDraw(frame, context)
    }

    private func drawNote(
        _ value: String,
        in rect: CGRect,
        fontStyle: AnnotationFontStyle?,
        fallbackFontSize: Double,
        cornerRadius: Double,
        contentInsets: ScreenshotAnnotationInsets?,
        backgroundGradient: ScreenshotAnnotationGradient?,
        scaleX: Double,
        scaleY: Double,
        context: CGContext
    ) {
        guard rect.width > 2, rect.height > 2 else { return }
        let requestedRadius = cornerRadius > 0 ? cornerRadius : 8
        let radius = min(requestedRadius, min(rect.width, rect.height) / 2)
        let roundedPath = CGPath(
            roundedRect: rect,
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        )
        context.saveGState()
        context.addPath(roundedPath)
        context.clip()
        if let backgroundGradient {
            drawGradient(backgroundGradient, in: rect, context: context)
        } else {
            context.setFillColor(CGColor(red: 1, green: 0.91, blue: 0.35, alpha: 0.96))
            context.fill(rect)
        }
        context.restoreGState()

        let safeInsets = contentInsets.map(sanitizedInsets)
            ?? .init(top: 7, right: 8, bottom: 7, left: 8)
        let inset = CGRect(
            x: rect.minX + safeInsets.left * scaleX,
            y: rect.minY + safeInsets.top * scaleY,
            width: rect.width - (safeInsets.left + safeInsets.right) * scaleX,
            height: rect.height - (safeInsets.top + safeInsets.bottom) * scaleY
        )
        guard inset.width > 0, inset.height > 0 else { return }
        let font = makeFont(style: fontStyle, fallbackSize: fallbackFontSize, defaultBold: false)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.12, alpha: 1)
        ]
        let framesetter = CTFramesetterCreateWithAttributedString(
            NSAttributedString(string: value, attributes: attributes)
        )
        let frame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: 0),
            CGPath(rect: inset, transform: nil),
            nil
        )
        CTFrameDraw(frame, context)
    }

    private func makeLine(_ value: String, fontSize: Double, color: CGColor) -> CTLine {
        makeLine(
            value,
            font: makeFont(style: nil, fallbackSize: fontSize, defaultBold: true),
            color: color
        )
    }

    private func makeLine(_ value: String, font: CTFont, color: CGColor) -> CTLine {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: value, attributes: attributes))
    }

    private func makeFont(
        style: AnnotationFontStyle?,
        fallbackSize: Double,
        defaultBold: Bool
    ) -> CTFont {
        let requestedSize = style?.size ?? fallbackSize
        let safeFallback = finite(fallbackSize, fallback: 12)
        let size = CGFloat(max(1, finite(requestedSize, fallback: safeFallback)))
        let name = style?.familyName ?? (defaultBold ? "Helvetica-Bold" : "Helvetica")
        let base = CTFontCreateWithName(name as CFString, size, nil)
        guard let style else { return base }
        let weight = CGFloat(min(max(finite(style.weight, fallback: 0), -1), 1))
        let traits = [kCTFontWeightTrait: weight] as CFDictionary
        let attributes = [kCTFontTraitsAttribute: traits] as CFDictionary
        let descriptor = CTFontDescriptorCreateWithAttributes(attributes)
        return CTFontCreateCopyWithAttributes(base, size, nil, descriptor)
    }

    private func cgColor(_ color: ScreenshotAnnotationColor) -> CGColor {
        CGColor(
            red: CGFloat(clamp(finite(color.red, fallback: 0))),
            green: CGFloat(clamp(finite(color.green, fallback: 0))),
            blue: CGFloat(clamp(finite(color.blue, fallback: 0))),
            alpha: CGFloat(clamp(finite(color.alpha, fallback: 1)))
        )
    }

    private func strokeLine(from start: CGPoint, to end: CGPoint, in context: CGContext) {
        context.beginPath()
        context.move(to: start)
        context.addLine(to: end)
        context.strokePath()
    }

    private func strokeArrowHead(
        from start: CGPoint,
        to end: CGPoint,
        size: Double,
        in context: CGContext
    ) {
        guard let head = AnnotationGeometry.arrowHeadPoints(from: start, to: end, size: size) else {
            return
        }
        context.beginPath()
        context.move(to: head.first)
        context.addLine(to: end)
        context.addLine(to: head.second)
        context.strokePath()
    }

    private func validateBufferSize(
        width: Int,
        height: Int,
        concurrentBuffers: Int
    ) throws {
        guard width > 0,
              height > 0,
              width <= limits.maximumOutputPixelDimension,
              height <= limits.maximumOutputPixelDimension else {
            throw ScreenshotFeatureError.encodingFailed
        }
        let (pixelCount, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        let (byteCount, byteOverflow) = pixelCount.multipliedReportingOverflow(by: 4)
        let (workingBytes, workingOverflow) = byteCount.multipliedReportingOverflow(
            by: max(1, concurrentBuffers)
        )
        guard !pixelOverflow,
              !byteOverflow,
              !workingOverflow,
              workingBytes <= limits.maximumWorkingBytes else {
            throw ScreenshotFeatureError.encodingFailed
        }
    }

    private func outputColorSpace(for image: CGImage) -> CGColorSpace {
        if let colorSpace = image.colorSpace, colorSpace.model == .rgb {
            return colorSpace
        }
        return CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    }

    private func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}
