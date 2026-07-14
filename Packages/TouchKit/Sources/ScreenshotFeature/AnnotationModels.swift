import Foundation

/// 截图标注使用的画布坐标，原点位于捕获结果左上角，单位为 point。
public struct ScreenshotAnnotationPoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct ScreenshotAnnotationColor: Codable, Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public static let red = ScreenshotAnnotationColor(red: 1, green: 0.12, blue: 0.12)
    public static let yellow = ScreenshotAnnotationColor(red: 1, green: 0.88, blue: 0.08, alpha: 0.45)
}

public struct ScreenshotAnnotationStyle: Codable, Equatable, Sendable {
    public var color: ScreenshotAnnotationColor
    public var lineWidth: Double

    public init(color: ScreenshotAnnotationColor, lineWidth: Double) {
        self.color = color
        self.lineWidth = lineWidth
    }
}

public enum ScreenshotAnnotationKind: String, Codable, CaseIterable, Equatable, Sendable {
    case rectangle
    case ellipse
    case line
    case arrow
    case freehand
    case highlighter
    case text
    case numberedMarker
    case note
    case sticker
    case mosaic
    case blur
    case magnifier
    case crop
    case watermark
    case beautify
}

/// 文本类标注的内容与字号。数字点复用该结构保存自动编号。
public struct ScreenshotAnnotationText: Codable, Equatable, Sendable {
    public var value: String
    public var fontSize: Double

    public init(value: String, fontSize: Double) {
        self.value = value
        self.fontSize = fontSize
    }
}

/// 马赛克画笔的像素化参数。blockSize 使用截图画布的 point 单位。
public struct ScreenshotAnnotationMosaic: Codable, Equatable, Sendable {
    public var blockSize: Double

    public init(blockSize: Double = 10) {
        self.blockSize = blockSize
    }
}

/// 局部高斯模糊参数。radius 使用截图画布的 point 单位。
public struct ScreenshotAnnotationBlur: Codable, Equatable, Sendable {
    public var radius: Double

    public init(radius: Double = 12) {
        self.radius = radius
    }
}

/// 圆形放大镜参数。diameter、borderWidth 使用截图画布的 point 单位。
public struct ScreenshotAnnotationMagnifier: Codable, Equatable, Sendable {
    public var magnification: Double
    public var diameter: Double
    public var borderWidth: Double

    public init(
        magnification: Double = 2,
        diameter: Double = 120,
        borderWidth: Double = 3
    ) {
        self.magnification = magnification
        self.diameter = diameter
        self.borderWidth = borderWidth
    }
}

/// 贴纸内容。V1 先使用系统可渲染的 emoji，保持 XPC 载荷轻量且无需传输位图。
public struct ScreenshotAnnotationSticker: Codable, Equatable, Sendable {
    public var value: String
    public var size: Double

    public init(value: String, size: Double) {
        self.value = value
        self.size = size
    }
}

/// 重复文字水印参数。角度单位为度，spacing 与 fontSize 使用画布 point。
public struct ScreenshotAnnotationWatermark: Codable, Equatable, Sendable {
    public var value: String
    public var fontSize: Double
    public var opacity: Double
    public var angleDegrees: Double
    public var spacing: Double

    public init(
        value: String,
        fontSize: Double,
        opacity: Double,
        angleDegrees: Double,
        spacing: Double
    ) {
        self.value = value
        self.fontSize = fontSize
        self.opacity = opacity
        self.angleDegrees = angleDegrees
        self.spacing = spacing
    }
}

/// 图片美化画布的四边边距，单位为截图画布 point。
public struct ScreenshotAnnotationInsets: Codable, Equatable, Sendable {
    public var top: Double
    public var right: Double
    public var bottom: Double
    public var left: Double

    public init(top: Double, right: Double, bottom: Double, left: Double) {
        self.top = top
        self.right = right
        self.bottom = bottom
        self.left = left
    }

    public static func uniform(_ value: Double) -> Self {
        .init(top: value, right: value, bottom: value, left: value)
    }
}

/// 图片美化背景的线性渐变。颜色按数组顺序均匀分布，角度单位为度。
public struct ScreenshotAnnotationGradient: Codable, Equatable, Sendable {
    public var colors: [ScreenshotAnnotationColor]
    public var angleDegrees: Double

    public init(colors: [ScreenshotAnnotationColor], angleDegrees: Double) {
        self.colors = colors
        self.angleDegrees = angleDegrees
    }
}

/// 图片美化参数。边距会扩展导出画布，圆角和阴影应用于原截图本体。
public struct ScreenshotAnnotationBeautify: Codable, Equatable, Sendable {
    public var cornerRadius: Double
    public var shadowRadius: Double
    public var shadowOpacity: Double
    public var shadowOffsetX: Double
    public var shadowOffsetY: Double
    public var insets: ScreenshotAnnotationInsets
    public var backgroundGradient: ScreenshotAnnotationGradient

    public init(
        cornerRadius: Double,
        shadowRadius: Double,
        shadowOpacity: Double,
        shadowOffsetX: Double,
        shadowOffsetY: Double,
        insets: ScreenshotAnnotationInsets,
        backgroundGradient: ScreenshotAnnotationGradient
    ) {
        self.cornerRadius = cornerRadius
        self.shadowRadius = shadowRadius
        self.shadowOpacity = shadowOpacity
        self.shadowOffsetX = shadowOffsetX
        self.shadowOffsetY = shadowOffsetY
        self.insets = insets
        self.backgroundGradient = backgroundGradient
    }
}

/// 非破坏性标注图层。points 均为捕获结果左上角坐标系中的 point。
public struct ScreenshotAnnotation: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var kind: ScreenshotAnnotationKind
    public var points: [ScreenshotAnnotationPoint]
    public var style: ScreenshotAnnotationStyle
    public var text: ScreenshotAnnotationText?
    public var mosaic: ScreenshotAnnotationMosaic?
    public var blur: ScreenshotAnnotationBlur?
    public var magnifier: ScreenshotAnnotationMagnifier?
    public var sticker: ScreenshotAnnotationSticker?
    public var watermark: ScreenshotAnnotationWatermark?
    public var beautify: ScreenshotAnnotationBeautify?

    public init(
        id: UUID = UUID(),
        kind: ScreenshotAnnotationKind,
        points: [ScreenshotAnnotationPoint],
        style: ScreenshotAnnotationStyle,
        text: ScreenshotAnnotationText? = nil,
        mosaic: ScreenshotAnnotationMosaic? = nil,
        blur: ScreenshotAnnotationBlur? = nil,
        magnifier: ScreenshotAnnotationMagnifier? = nil,
        sticker: ScreenshotAnnotationSticker? = nil,
        watermark: ScreenshotAnnotationWatermark? = nil,
        beautify: ScreenshotAnnotationBeautify? = nil
    ) {
        self.id = id
        self.kind = kind
        self.points = points
        self.style = style
        self.text = text
        self.mosaic = mosaic
        self.blur = blur
        self.magnifier = magnifier
        self.sticker = sticker
        self.watermark = watermark
        self.beautify = beautify
    }
}
