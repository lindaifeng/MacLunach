import AppKit
import ScreenshotFeature

enum ColorPickerLoupeAction {
    case confirm
}

/// 无状态绘制器：在透明取色层上绘制像素放大镜、颜色信息和确认控件。
enum ColorPickerLoupeView {
    private static let panelSize = CGSize(width: 196, height: 210)
    private static let imageRect = CGRect(x: 10, y: 80, width: 176, height: 116)
    private static let confirmRect = CGRect(x: 152, y: 12, width: 32, height: 26)

    static func draw(
        sample: ScreenshotColorSample?,
        errorMessage: String?,
        isLocked: Bool,
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
            drawColorSwatch(sample.color, at: CGPoint(x: frame.minX + 12, y: frame.minY + 50))
            drawText(sample.color.hexString, at: CGPoint(x: frame.minX + 38, y: frame.minY + 54), bold: true)
            drawText(sample.color.rgbString, at: CGPoint(x: frame.minX + 12, y: frame.minY + 33))
            if isLocked {
                drawText("已锁定 · 点击 ✓ 复制 RGB", at: CGPoint(x: frame.minX + 12, y: frame.minY + 14))
                drawConfirmButton(in: confirmRect.offsetBy(dx: frame.minX, dy: frame.minY))
            } else {
                drawText("单击锁定 · Esc 取消", at: CGPoint(x: frame.minX + 12, y: frame.minY + 14))
            }
        } else {
            drawText(errorMessage ?? "移动鼠标选择颜色", at: CGPoint(x: frame.minX + 12, y: frame.minY + 34))
            drawText("单击锁定 · Esc 取消", at: CGPoint(x: frame.minX + 12, y: frame.minY + 14))
        }
    }

    static func action(at point: CGPoint, near pointer: CGPoint, in bounds: CGRect) -> ColorPickerLoupeAction? {
        let frame = positionedFrame(near: pointer, in: bounds)
        return confirmRect.offsetBy(dx: frame.minX, dy: frame.minY).contains(point) ? .confirm : nil
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

    private static func drawColorSwatch(_ color: ScreenshotColor, at point: CGPoint) {
        let rect = CGRect(origin: point, size: CGSize(width: 17, height: 17))
        NSColor(
            srgbRed: CGFloat(color.red) / 255,
            green: CGFloat(color.green) / 255,
            blue: CGFloat(color.blue) / 255,
            alpha: CGFloat(color.alpha) / 255
        ).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
        NSColor.white.withAlphaComponent(0.65).setStroke()
        NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 3.5, yRadius: 3.5).stroke()
    }

    private static func drawConfirmButton(in rect: CGRect) {
        NSColor.systemBlue.withAlphaComponent(0.95).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
        drawText("✓", at: CGPoint(x: rect.minX + 9, y: rect.minY + 5), bold: true)
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
