import Foundation

/// 标注文字的可编辑字体属性。`weight` 使用 AppKit/CoreText 通用的 -1...1 语义，
/// 避免领域模型依赖 UI 框架。
public struct AnnotationFontStyle: Codable, Equatable, Sendable {
    public let familyName: String?
    public let size: Double
    public let weight: Double

    public init(familyName: String? = nil, size: Double, weight: Double = 0) {
        self.familyName = familyName
        self.size = size
        self.weight = weight
    }
}

/// 非破坏性图层的阴影参数，单位均为画布 point。
public struct AnnotationShadowStyle: Codable, Equatable, Sendable {
    public let color: ScreenshotAnnotationColor
    public let radius: Double
    public let offsetX: Double
    public let offsetY: Double

    public init(
        color: ScreenshotAnnotationColor,
        radius: Double,
        offsetX: Double,
        offsetY: Double
    ) {
        self.color = color
        self.radius = radius
        self.offsetX = offsetX
        self.offsetY = offsetY
    }
}

/// 可持久化的非破坏性标注图层。
///
/// `annotation` 保存几何和各工具特有载荷；外层保存编辑器通用的外观及层级属性。
/// 模型只引用原图路径，不持有或复制位图。
public struct AnnotationLayer: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID { annotation.id }
    public var kind: ScreenshotAnnotationKind { annotation.kind }

    public let annotation: ScreenshotAnnotation
    public let opacity: Double
    public let zIndex: Int
    public let font: AnnotationFontStyle?
    public let cornerRadius: Double
    public let shadow: AnnotationShadowStyle?
    public let contentInsets: ScreenshotAnnotationInsets?
    public let backgroundGradient: ScreenshotAnnotationGradient?

    public init(
        annotation: ScreenshotAnnotation,
        opacity: Double = 1,
        zIndex: Int = 0,
        font: AnnotationFontStyle? = nil,
        cornerRadius: Double = 0,
        shadow: AnnotationShadowStyle? = nil,
        contentInsets: ScreenshotAnnotationInsets? = nil,
        backgroundGradient: ScreenshotAnnotationGradient? = nil
    ) {
        self.annotation = annotation
        self.opacity = opacity
        self.zIndex = zIndex
        self.font = font
        self.cornerRadius = cornerRadius
        self.shadow = shadow
        self.contentInsets = contentInsets
        self.backgroundGradient = backgroundGradient
    }

    public func replacingAnnotation(_ annotation: ScreenshotAnnotation) -> Self {
        Self(
            annotation: annotation,
            opacity: opacity,
            zIndex: zIndex,
            font: font,
            cornerRadius: cornerRadius,
            shadow: shadow,
            contentInsets: contentInsets,
            backgroundGradient: backgroundGradient
        )
    }

    public func replacingZIndex(_ zIndex: Int) -> Self {
        Self(
            annotation: annotation,
            opacity: opacity,
            zIndex: zIndex,
            font: font,
            cornerRadius: cornerRadius,
            shadow: shadow,
            contentInsets: contentInsets,
            backgroundGradient: backgroundGradient
        )
    }

    private enum CodingKeys: String, CodingKey {
        case annotation
        case opacity
        case zIndex
        case font
        case cornerRadius
        case shadow
        case contentInsets
        case backgroundGradient
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        annotation = try container.decode(ScreenshotAnnotation.self, forKey: .annotation)
        opacity = try container.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
        zIndex = try container.decodeIfPresent(Int.self, forKey: .zIndex) ?? 0
        font = try container.decodeIfPresent(AnnotationFontStyle.self, forKey: .font)
        cornerRadius = try container.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? 0
        shadow = try container.decodeIfPresent(AnnotationShadowStyle.self, forKey: .shadow)
        contentInsets = try container.decodeIfPresent(
            ScreenshotAnnotationInsets.self,
            forKey: .contentInsets
        )
        backgroundGradient = try container.decodeIfPresent(
            ScreenshotAnnotationGradient.self,
            forKey: .backgroundGradient
        )
    }
}
