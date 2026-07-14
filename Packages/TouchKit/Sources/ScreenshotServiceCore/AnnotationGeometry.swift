import CoreGraphics
import Foundation
import ScreenshotFeature

/// 标注画布（左上角、point）与 Core Graphics（左下角、pixel）之间的唯一几何转换入口。
public enum AnnotationGeometry {
    public static func pixelPoints(
        for points: [ScreenshotAnnotationPoint],
        pointSize: ScreenshotSize,
        pixelWidth: Int,
        pixelHeight: Int
    ) -> [CGPoint] {
        guard pointSize.width.isFinite,
              pointSize.height.isFinite,
              pointSize.width > 0,
              pointSize.height > 0,
              pixelWidth > 0,
              pixelHeight > 0 else { return [] }
        let scaleX = Double(pixelWidth) / pointSize.width
        let scaleY = Double(pixelHeight) / pointSize.height
        return points.compactMap { point in
            guard point.x.isFinite, point.y.isFinite else { return nil }
            return CGPoint(
                x: point.x * scaleX,
                y: Double(pixelHeight) - point.y * scaleY
            )
        }
    }

    public static func boundingRect(_ points: [CGPoint]) -> CGRect? {
        guard let first = points.first, let last = points.last,
              first.x.isFinite, first.y.isFinite,
              last.x.isFinite, last.y.isFinite else { return nil }
        return CGRect(
            x: min(first.x, last.x),
            y: min(first.y, last.y),
            width: abs(last.x - first.x),
            height: abs(last.y - first.y)
        )
    }

    public static func effectiveCropRect(
        source: ScreenshotSize,
        annotations: [ScreenshotAnnotation]
    ) -> CGRect? {
        guard source.width.isFinite,
              source.height.isFinite,
              source.width > 0,
              source.height > 0,
              let annotation = annotations.last(where: { $0.kind == .crop }),
              annotation.points.count >= 2,
              let first = annotation.points.first,
              let last = annotation.points.last,
              first.x.isFinite,
              first.y.isFinite,
              last.x.isFinite,
              last.y.isFinite else { return nil }

        let minX = min(max(min(first.x, last.x), 0), source.width)
        let maxX = min(max(max(first.x, last.x), 0), source.width)
        let minY = min(max(min(first.y, last.y), 0), source.height)
        let maxY = min(max(max(first.y, last.y), 0), source.height)
        guard maxX - minX >= 1, maxY - minY >= 1 else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// `CGImage.cropping(to:)` 的坐标与截图画布同为从图像左上读取，直接按比例换算。
    public static func pixelCropRect(
        sourcePointSize: ScreenshotSize,
        imageWidth: Int,
        imageHeight: Int,
        cropRect: CGRect
    ) -> CGRect? {
        guard sourcePointSize.width.isFinite,
              sourcePointSize.height.isFinite,
              sourcePointSize.width > 0,
              sourcePointSize.height > 0,
              imageWidth > 0,
              imageHeight > 0 else { return nil }
        let scaleX = Double(imageWidth) / sourcePointSize.width
        let scaleY = Double(imageHeight) / sourcePointSize.height
        let minX = floor(Double(cropRect.minX) * scaleX)
        let maxX = ceil(Double(cropRect.maxX) * scaleX)
        let minY = floor(Double(cropRect.minY) * scaleY)
        let maxY = ceil(Double(cropRect.maxY) * scaleY)
        let bounds = CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight)
        let result = CGRect(
            x: minX,
            y: minY,
            width: maxX - minX,
            height: maxY - minY
        ).intersection(bounds)
        guard !result.isNull, result.width >= 1, result.height >= 1 else { return nil }
        return result
    }

    public static func arrowHeadPoints(
        from start: CGPoint,
        to end: CGPoint,
        size: Double
    ) -> (first: CGPoint, second: CGPoint)? {
        guard start.x.isFinite, start.y.isFinite,
              end.x.isFinite, end.y.isFinite,
              size.isFinite, size > 0 else { return nil }
        let dx = Double(end.x - start.x)
        let dy = Double(end.y - start.y)
        guard hypot(dx, dy) > 0.5 else { return nil }
        let angle = atan2(dy, dx)
        let spread = Double.pi / 7
        return (
            CGPoint(
                x: end.x - CGFloat(cos(angle - spread) * size),
                y: end.y - CGFloat(sin(angle - spread) * size)
            ),
            CGPoint(
                x: end.x - CGFloat(cos(angle + spread) * size),
                y: end.y - CGFloat(sin(angle + spread) * size)
            )
        )
    }
}
