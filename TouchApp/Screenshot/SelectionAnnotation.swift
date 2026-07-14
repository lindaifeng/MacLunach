import AppKit
import ScreenshotFeature

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

extension SelectionToolbarItem {
    var isImplementedAnnotationTool: Bool {
        drawableAnnotationKind != nil || self == .text || self == .numberedMarker
            || self == .note || self == .sticker
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
