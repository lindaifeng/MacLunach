import AppKit
import ScreenshotFeature

enum SelectionCalloutLayout {
    static let minimumSize = CGSize(width: 48, height: 28)
    static let maximumWidth: CGFloat = 320
    static let contentInset = CGSize(width: 6, height: 5)

    static func size(
        text: String,
        fontSize: Double,
        maximumSize: CGSize
    ) -> CGSize {
        let font = NSFont.systemFont(ofSize: CGFloat(fontSize), weight: .semibold)
        let horizontalPadding = contentInset.width * 2
        let verticalPadding = contentInset.height * 2
        let widthLimit = min(maximumWidth, maximumSize.width)
        let innerLimit = max(1, widthLimit - horizontalPadding)
        let measuredText = text.isEmpty ? " " : text
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let unconstrained = (measuredText as NSString).boundingRect(
            with: CGSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            ),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        ).size
        let innerWidth = min(innerLimit, max(36, ceil(unconstrained.width)))
        let wrapped = (measuredText as NSString).boundingRect(
            with: CGSize(width: innerWidth, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        ).size
        return CGSize(
            width: min(widthLimit, max(minimumSize.width, ceil(innerWidth) + horizontalPadding)),
            height: min(
                maximumSize.height,
                max(minimumSize.height, ceil(wrapped.height) + verticalPadding)
            )
        )
    }
}

struct SelectionAnnotation: Equatable {
    var id: UUID
    var kind: ScreenshotAnnotationKind
    var points: [CGPoint]
    var style: ScreenshotAnnotationStyle
    var text: ScreenshotAnnotationText?
    var mosaic: ScreenshotAnnotationMosaic?
    var blur: ScreenshotAnnotationBlur?
    var magnifier: ScreenshotAnnotationMagnifier?
    var sticker: ScreenshotAnnotationSticker?
    var watermark: ScreenshotAnnotationWatermark?
    var beautify: ScreenshotAnnotationBeautify?

    init(
        id: UUID = UUID(),
        kind: ScreenshotAnnotationKind,
        points: [CGPoint],
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

    func captureAnnotation(relativeTo selection: CGRect) -> ScreenshotAnnotation {
        ScreenshotAnnotation(
            id: id,
            kind: kind,
            points: points.map {
                .init(x: Double($0.x - selection.minX), y: Double($0.y - selection.minY))
            },
            style: style,
            text: text,
            mosaic: mosaic,
            blur: blur,
            magnifier: magnifier,
            sticker: sticker,
            watermark: watermark,
            beautify: beautify
        )
    }
}

extension SelectionAnnotation {
    /// 箭头编辑手柄的命中检测。端点 0 是箭尾，端点 1 是箭头。
    func arrowEndpoint(at point: CGPoint, hitRadius: CGFloat = 10) -> Int? {
        guard kind == .arrow, points.count >= 2 else { return nil }
        let endpoints = [points[0], points[points.count - 1]]
        return endpoints.enumerated().first { _, endpoint in
            hypot(endpoint.x - point.x, endpoint.y - point.y) <= hitRadius
        }?.offset
    }

    /// 返回可以直接拖动的几何控制点索引。批注只允许调整红色文本框，不移动定位点和连线端点。
    func editablePointIndex(at point: CGPoint, hitRadius: CGFloat = 10) -> Int? {
        let indexes: [Int]
        switch kind {
        case .arrow, .line, .rectangle, .ellipse:
            guard points.count >= 2 else { return nil }
            indexes = [0, points.count - 1]
        case .callout:
            guard points.count >= 4 else { return nil }
            indexes = [2, 3]
        case .sticker:
            guard points.count >= 2 else { return nil }
            indexes = [1]
        default:
            return nil
        }
        return indexes.first { index in
            let endpoint = points[index]
            return hypot(endpoint.x - point.x, endpoint.y - point.y) <= hitRadius
        }
    }

    func containsCalloutBox(_ point: CGPoint) -> Bool {
        calloutBoxRect?.insetBy(dx: -2, dy: -2).contains(point) == true
    }

    var calloutBoxRect: CGRect? {
        guard kind == .callout, points.count >= 4 else { return nil }
        return CGRect(
            x: min(points[2].x, points[3].x),
            y: min(points[2].y, points[3].y),
            width: abs(points[3].x - points[2].x),
            height: abs(points[3].y - points[2].y)
        )
    }

    func containsCalloutBorder(_ point: CGPoint, thickness: CGFloat = 7) -> Bool {
        guard let rect = calloutBoxRect else { return false }
        let outer = rect.insetBy(dx: -thickness, dy: -thickness)
        let inner = rect.insetBy(dx: thickness, dy: thickness)
        return outer.contains(point) && (!inner.contains(point) || inner.isEmpty)
    }

    func containsCalloutContent(_ point: CGPoint, borderInset: CGFloat = 7) -> Bool {
        guard let rect = calloutBoxRect else { return false }
        return rect.insetBy(dx: borderInset, dy: borderInset).contains(point)
    }
}

extension SelectionToolbarItem {
    var isImplementedAnnotationTool: Bool {
        drawableAnnotationKind != nil || self == .text || self == .numberedMarker
            || self == .callout || self == .note || self == .sticker
    }

    var drawableAnnotationKind: ScreenshotAnnotationKind? {
        switch self {
        case .rectangle: .rectangle
        case .ellipse: .ellipse
        case .line: .line
        case .arrow: .arrow
        case .freehand: .freehand
        case .highlighter: .highlighter
        case .mosaic: .mosaic
        default: nil
        }
    }
}

struct SelectionAnnotationHistory: Equatable {
    private(set) var annotations: [SelectionAnnotation] = []
    private(set) var redoStack: [SelectionAnnotation] = []

    mutating func reset() {
        annotations.removeAll()
        redoStack.removeAll()
    }

    mutating func add(_ annotation: SelectionAnnotation) {
        annotations.append(annotation)
        redoStack.removeAll()
    }

    mutating func update(id: UUID, _ body: (inout SelectionAnnotation) -> Void) -> Bool {
        guard let index = annotations.firstIndex(where: { $0.id == id }) else { return false }
        body(&annotations[index])
        return true
    }

    @discardableResult
    mutating func remove(id: UUID) -> SelectionAnnotation? {
        guard let index = annotations.firstIndex(where: { $0.id == id }) else { return nil }
        return annotations.remove(at: index)
    }


    mutating func removeAll(where shouldRemove: (SelectionAnnotation) -> Bool) {
        annotations.removeAll(where: shouldRemove)
        redoStack.removeAll()
    }

    mutating func undo() -> SelectionAnnotation? {
        guard let annotation = annotations.popLast() else { return nil }
        redoStack.append(annotation)
        return annotation
    }

    mutating func redo() -> SelectionAnnotation? {
        guard let annotation = redoStack.popLast() else { return nil }
        annotations.append(annotation)
        return annotation
    }
}
