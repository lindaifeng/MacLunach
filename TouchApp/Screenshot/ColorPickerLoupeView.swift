import AppKit
import ScreenshotFeature

/// 无状态绘制器：在透明取色层上绘制 QQ 风格像素放大镜与颜色文本。
enum ColorPickerLoupeView {
    private static let panelSize = CGSize(width: 176, height: 194)
    private static let imageRect = CGRect(x: 10, y: 74, width: 156, height: 110)

    static func draw(
        sample: ScreenshotColorSample?,
        errorMessage: String?,
        at pointer: CGPoint,
        in bounds: CGRect
    ) {
        let frame = positionedFrame(near: pointer, in: bounds)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }

        NSColor.black.withAlphaComponent(0.88).setFill()
        NSBezierPath(roundedRect: frame, xRadius: 10, yRadius: 10).fill()
        NSColor.white.withAlphaComponent(0.18).setStroke()
        NSBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10).stroke()

        if let sample {
            drawPixels(sample, in: imageRect.offsetBy(dx: frame.minX, dy: frame.minY))
            drawText(sample.color.hexString, at: CGPoint(x: frame.minX + 12, y: frame.minY + 48), bold: true)
            drawText(sample.color.rgbString, at: CGPoint(x: frame.minX + 12, y: frame.minY + 29))
            drawText(sample.color.hslString, at: CGPoint(x: frame.minX + 12, y: frame.minY + 12))
        } else {
            drawText(errorMessage ?? "移动鼠标选择颜色", at: CGPoint(x: frame.minX + 12, y: frame.minY + 34))
            drawText("单击复制 HEX · Esc 取消", at: CGPoint(x: frame.minX + 12, y: frame.minY + 14))
        }
    }

    private static func positionedFrame(near point: CGPoint, in bounds: CGRect) -> CGRect {
        var origin = CGPoint(x: point.x + 18, y: point.y - panelSize.height - 18)
        if origin.x + panelSize.width > bounds.maxX - 8 {
            origin.x = point.x - panelSize.width - 18
        }
        if origin.y < bounds.minY + 8 {
            origin.y = point.y + 18
        }
        origin.x = min(max(bounds.minX + 8, origin.x), bounds.maxX - panelSize.width - 8)
        origin.y = min(max(bounds.minY + 8, origin.y), bounds.maxY - panelSize.height - 8)
        return CGRect(origin: origin, size: panelSize)
    }

    private static func drawPixels(_ sample: ScreenshotColorSample, in rect: CGRect) {
        let width = Int(sample.loupePixelSize.width)
        let height = Int(sample.loupePixelSize.height)
        guard width > 0, height > 0, sample.loupeRGBA.count >= width * height * 4 else { return }
        let bytes = [UInt8](sample.loupeRGBA)
        let cellWidth = rect.width / CGFloat(width)
        let cellHeight = rect.height / CGFloat(height)
        for row in 0..<height {
            for column in 0..<width {
                let offset = ((row * width) + column) * 4
                NSColor(
                    srgbRed: CGFloat(bytes[offset]) / 255,
                    green: CGFloat(bytes[offset + 1]) / 255,
                    blue: CGFloat(bytes[offset + 2]) / 255,
                    alpha: CGFloat(bytes[offset + 3]) / 255
                ).setFill()
                NSBezierPath(rect: CGRect(
                    x: rect.minX + CGFloat(column) * cellWidth,
                    y: rect.maxY - CGFloat(row + 1) * cellHeight,
                    width: ceil(cellWidth),
                    height: ceil(cellHeight)
                )).fill()
            }
        }
        let centerRect = CGRect(
            x: rect.minX + CGFloat(sample.centerPixel.x) * cellWidth,
            y: rect.maxY - CGFloat(sample.centerPixel.y + 1) * cellHeight,
            width: cellWidth,
            height: cellHeight
        )
        NSColor.white.setStroke()
        let path = NSBezierPath(rect: centerRect.insetBy(dx: -1, dy: -1))
        path.lineWidth = 2
        path.stroke()
        NSColor.black.withAlphaComponent(0.7).setStroke()
        NSBezierPath(rect: centerRect.insetBy(dx: 1, dy: 1)).stroke()
    }

    private static func drawText(_ value: String, at point: CGPoint, bold: Bool = false) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: bold ? NSFont.monospacedSystemFont(ofSize: 14, weight: .semibold)
                : NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.white
        ]
        value.draw(at: point, withAttributes: attributes)
    }
}
