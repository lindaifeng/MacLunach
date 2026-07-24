import Combine
import Foundation
import ScreenshotFeature

enum AnnotationEditorSaveStatus: Equatable {
    case idle
    case saving
    case failed(message: String)
}

enum AnnotationEditorCloseRequirement: Equatable {
    case closeImmediately
    case confirmUnsavedChanges
}

enum AnnotationEditorCloseChoice: Equatable {
    case save
    case discard
    case cancel
}

enum AnnotationEditorCloseOutcome: Equatable {
    case close
    case remainOpen
}

struct AnnotationEditorEffectValues: Equatable {
    var cornerRadius: Double
    var shadowRadius: Double
    var shadowOpacity: Double
    var shadowOffsetX: Double
    var shadowOffsetY: Double
    var contentInset: Double
    var gradientStart: ScreenshotAnnotationColor
    var gradientEnd: ScreenshotAnnotationColor
    var gradientAngle: Double
}

enum AnnotationEditorTool: String, CaseIterable, Identifiable {
    case select
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

    var id: String { rawValue }

    var annotationKind: ScreenshotAnnotationKind? {
        self == .select ? nil : ScreenshotAnnotationKind(rawValue: rawValue)
    }

    var title: String {
        switch self {
        case .select: "选择"
        case .rectangle: "矩形"
        case .ellipse: "椭圆"
        case .line: "直线"
        case .arrow: "箭头"
        case .freehand: "画笔"
        case .highlighter: "高亮"
        case .text: "文字"
        case .numberedMarker: "序号"
        case .note: "便签"
        case .sticker: "贴纸"
        case .mosaic: "马赛克"
        case .blur: "模糊"
        case .magnifier: "放大镜"
        case .crop: "裁剪"
        case .watermark: "水印"
        case .beautify: "美化"
        }
    }

    var symbolName: String {
        switch self {
        case .select: "arrow.up.left"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .line: "line.diagonal"
        case .arrow: "arrow.up.right"
        case .freehand: "pencil.tip"
        case .highlighter: "highlighter"
        case .text: "textformat"
        case .numberedMarker: "1.circle"
        case .note: "note.text"
        case .sticker: "face.smiling"
        case .mosaic: "square.grid.3x3.fill"
        case .blur: "drop.halffull"
        case .magnifier: "plus.magnifyingglass"
        case .crop: "crop"
        case .watermark: "seal"
        case .beautify: "sparkles.rectangle.stack"
        }
    }

    var keyboardShortcut: String {
        switch self {
        case .select: "v"
        case .rectangle: "r"
        case .ellipse: "o"
        case .line: "l"
        case .arrow: "a"
        case .freehand: "b"
        case .highlighter: "h"
        case .text: "t"
        case .numberedMarker: "n"
        case .note: "q"
        case .sticker: "e"
        case .mosaic: "m"
        case .blur: "u"
        case .magnifier: "g"
        case .crop: "c"
        case .watermark: "w"
        case .beautify: "f"
        }
    }
}

/// 内建截图编辑器的单一会话状态。
///
/// 画布和 Inspector 只通过此对象修改不可变 `AnnotationDocument`；图片像素不进入
/// 撤销栈。保存失败时保留当前文档与历史，用户可直接重试。
@MainActor
final class AnnotationEditorState: ObservableObject {
    typealias SaveHandler = @MainActor (AnnotationDocument) async throws -> Void

    let artifact: ScreenshotArtifact

    @Published private(set) var document: AnnotationDocument
    @Published private(set) var selectedLayerID: UUID?
    @Published private(set) var pendingCropPoints: [ScreenshotAnnotationPoint]?
    @Published var selectedTool: AnnotationEditorTool = .select
    @Published private(set) var saveStatus: AnnotationEditorSaveStatus = .idle

    private var history: AnnotationCommandHistory
    private var savedDocument: AnnotationDocument
    private let saveHandler: SaveHandler

    init(
        artifact: ScreenshotArtifact,
        document: AnnotationDocument? = nil,
        save: @escaping SaveHandler
    ) {
        let initialDocument = document ?? AnnotationDocument(
            id: artifact.id,
            sourceImageRelativePath: artifact.relativePath,
            canvasSize: artifact.pointSize,
            createdAt: artifact.createdAt,
            updatedAt: artifact.createdAt
        )
        self.artifact = artifact
        self.document = initialDocument
        self.history = AnnotationCommandHistory(document: initialDocument)
        self.savedDocument = initialDocument
        self.saveHandler = save
    }

    var selectedLayer: AnnotationLayer? {
        guard let selectedLayerID else { return nil }
        return document.layers.first { $0.id == selectedLayerID }
    }

    var selectedEffects: AnnotationEditorEffectValues? {
        guard let layer = selectedLayer else { return nil }
        if let beautify = layer.annotation.beautify {
            let colors = normalizedGradientColors(beautify.backgroundGradient.colors)
            return .init(
                cornerRadius: beautify.cornerRadius,
                shadowRadius: beautify.shadowRadius,
                shadowOpacity: beautify.shadowOpacity,
                shadowOffsetX: beautify.shadowOffsetX,
                shadowOffsetY: beautify.shadowOffsetY,
                contentInset: beautify.insets.top,
                gradientStart: colors.0,
                gradientEnd: colors.1,
                gradientAngle: beautify.backgroundGradient.angleDegrees
            )
        }

        let shadow = layer.shadow
        let colors = normalizedGradientColors(layer.backgroundGradient?.colors ?? [])
        return .init(
            cornerRadius: layer.cornerRadius,
            shadowRadius: shadow?.radius ?? 0,
            shadowOpacity: shadow?.color.alpha ?? 0,
            shadowOffsetX: shadow?.offsetX ?? 0,
            shadowOffsetY: shadow?.offsetY ?? 0,
            contentInset: layer.contentInsets?.top ?? 0,
            gradientStart: colors.0,
            gradientEnd: colors.1,
            gradientAngle: layer.backgroundGradient?.angleDegrees ?? 135
        )
    }

    var hasPendingCrop: Bool { pendingCropPoints != nil }
    var canUndo: Bool { hasPendingCrop || history.canUndo }
    var canRedo: Bool { history.canRedo }
    var isSaving: Bool { saveStatus == .saving }
    var isDirty: Bool { document != savedDocument }

    var closeRequirement: AnnotationEditorCloseRequirement {
        isDirty ? .confirmUnsavedChanges : .closeImmediately
    }

    @discardableResult
    func selectLayer(id: UUID?) -> Bool {
        guard let id else {
            selectedLayerID = nil
            return true
        }
        guard document.layers.contains(where: { $0.id == id }) else { return false }
        selectedLayerID = id
        return true
    }

    /// 按文档层级顺序选择下一个图层，并在末尾回绕。没有当前选择时从最底层开始，
    /// 供纯键盘用户在不依赖画布点按的情况下进入图层编辑流程。
    @discardableResult
    func selectNextLayer() -> Bool {
        selectAdjacentLayer(step: 1)
    }

    /// 按文档层级顺序选择上一个图层，并在开头回绕。没有当前选择时从最顶层开始。
    @discardableResult
    func selectPreviousLayer() -> Bool {
        selectAdjacentLayer(step: -1)
    }

    func add(_ layer: AnnotationLayer, at index: Int? = nil) throws {
        if layer.kind == .crop {
            try history.setCrop(layer)
        } else {
            history.add(layer, at: index)
        }
        synchronizeDocument()
        selectedLayerID = layer.id
    }

    var canMoveSelectedLayerBackward: Bool {
        guard let selectedLayerID,
              let index = document.layers.firstIndex(where: { $0.id == selectedLayerID }) else {
            return false
        }
        return index > document.layers.startIndex
    }

    var canMoveSelectedLayerForward: Bool {
        guard let selectedLayerID,
              let index = document.layers.firstIndex(where: { $0.id == selectedLayerID }) else {
            return false
        }
        return index < document.layers.index(before: document.layers.endIndex)
    }

    @discardableResult
    func moveSelectedLayerBackward() throws -> Bool {
        guard let selectedLayerID,
              let index = document.layers.firstIndex(where: { $0.id == selectedLayerID }),
              index > document.layers.startIndex else {
            return false
        }
        try history.reorder(id: selectedLayerID, to: index - 1)
        synchronizeDocument()
        return true
    }

    @discardableResult
    func moveSelectedLayerForward() throws -> Bool {
        guard let selectedLayerID,
              let index = document.layers.firstIndex(where: { $0.id == selectedLayerID }),
              index < document.layers.index(before: document.layers.endIndex) else {
            return false
        }
        try history.reorder(id: selectedLayerID, to: index + 1)
        synchronizeDocument()
        return true
    }

    @discardableResult
    func sendSelectedLayerToBack() throws -> Bool {
        guard let selectedLayerID,
              let index = document.layers.firstIndex(where: { $0.id == selectedLayerID }),
              index > document.layers.startIndex else {
            return false
        }
        try history.reorder(id: selectedLayerID, to: document.layers.startIndex)
        synchronizeDocument()
        return true
    }

    @discardableResult
    func bringSelectedLayerToFront() throws -> Bool {
        guard let selectedLayerID,
              let index = document.layers.firstIndex(where: { $0.id == selectedLayerID }),
              index < document.layers.index(before: document.layers.endIndex) else {
            return false
        }
        try history.reorder(id: selectedLayerID, to: document.layers.count - 1)
        synchronizeDocument()
        return true
    }

    /// 暂存一个尚未应用的裁剪框。暂存阶段不修改文档，也不会令项目变为 dirty。
    /// 用户确认后才会把裁剪作为唯一 crop 图层写入命令历史。
    @discardableResult
    func stageCrop(points: [ScreenshotAnnotationPoint]) -> Bool {
        guard let first = points.first, let last = points.last else { return false }
        let canvasWidth = max(0, document.canvasSize.width)
        let canvasHeight = max(0, document.canvasSize.height)
        let minX = min(canvasWidth, max(0, min(first.x, last.x)))
        let minY = min(canvasHeight, max(0, min(first.y, last.y)))
        let maxX = min(canvasWidth, max(0, max(first.x, last.x)))
        let maxY = min(canvasHeight, max(0, max(first.y, last.y)))
        guard maxX - minX >= 1, maxY - minY >= 1 else { return false }

        pendingCropPoints = [
            .init(x: minX, y: minY),
            .init(x: maxX, y: maxY)
        ]
        return true
    }

    @discardableResult
    func confirmPendingCrop() throws -> AnnotationLayer? {
        guard let pendingCropPoints else { return nil }
        let layer = try createLayer(kind: .crop, points: pendingCropPoints)
        self.pendingCropPoints = nil
        selectedTool = .select
        return layer
    }

    @discardableResult
    func cancelPendingCrop() -> Bool {
        guard pendingCropPoints != nil else { return false }
        pendingCropPoints = nil
        return true
    }

    @discardableResult
    func createLayer(
        kind: ScreenshotAnnotationKind,
        points: [ScreenshotAnnotationPoint]
    ) throws -> AnnotationLayer {
        let normalizedPoints = points.isEmpty ? [.init(x: 0, y: 0)] : points
        let annotation = ScreenshotAnnotation(
            kind: kind,
            points: normalizedPoints,
            style: .init(
                color: kind == .highlighter ? .yellow : .red,
                lineWidth: kind == .highlighter ? 14 : 3
            ),
            text: defaultText(for: kind),
            mosaic: kind == .mosaic ? .init() : nil,
            blur: kind == .blur ? .init() : nil,
            magnifier: kind == .magnifier ? .init() : nil,
            sticker: kind == .sticker ? .init(value: "😊", size: 48) : nil,
            watermark: kind == .watermark
                ? .init(value: "一念", fontSize: 20, opacity: 0.25, angleDegrees: -25, spacing: 120)
                : nil,
            beautify: kind == .beautify ? defaultBeautify() : nil
        )
        let layer = AnnotationLayer(
            annotation: annotation,
            opacity: kind == .highlighter ? 0.55 : 1,
            font: [.text, .numberedMarker, .callout, .note].contains(kind)
                ? .init(size: 18)
                : nil,
            cornerRadius: kind == .note ? 10 : 0,
            contentInsets: kind == .note ? .uniform(10) : nil
        )
        try add(layer)
        return layer
    }

    func update(_ layer: AnnotationLayer, coalescingKey: String? = nil) throws {
        try history.update(layer, coalescingKey: coalescingKey)
        synchronizeDocument()
    }

    func updateSelectedAppearance(
        color: ScreenshotAnnotationColor? = nil,
        lineWidth: Double? = nil,
        opacity: Double? = nil,
        fontSize: Double? = nil,
        coalescingKey: String? = nil
    ) throws {
        guard let layer = selectedLayer else { return }
        var annotation = layer.annotation
        if let color { annotation.style.color = color }
        if let lineWidth { annotation.style.lineWidth = min(100, max(1, lineWidth)) }
        let font = fontSize.map {
            AnnotationFontStyle(
                familyName: layer.font?.familyName,
                size: min(200, max(6, $0)),
                weight: layer.font?.weight ?? 0
            )
        } ?? layer.font
        let updated = AnnotationLayer(
            annotation: annotation,
            opacity: min(1, max(0.05, opacity ?? layer.opacity)),
            zIndex: layer.zIndex,
            font: font,
            cornerRadius: layer.cornerRadius,
            shadow: layer.shadow,
            contentInsets: layer.contentInsets,
            backgroundGradient: layer.backgroundGradient
        )
        try update(updated, coalescingKey: coalescingKey)
    }

    /// 编辑文字、便签、序号、贴纸和水印的真实内容，且仍作为一次可撤销图层更新。
    @discardableResult
    func updateSelectedContent(
        _ value: String,
        coalescingKey: String? = nil
    ) throws -> Bool {
        guard let layer = selectedLayer else { return false }
        var annotation = layer.annotation
        switch layer.kind {
        case .text, .numberedMarker, .callout, .note:
            guard var text = annotation.text else { return false }
            text.value = value
            annotation.text = text
        case .sticker:
            guard var sticker = annotation.sticker else { return false }
            sticker.value = value
            annotation.sticker = sticker
        case .watermark:
            guard var watermark = annotation.watermark else { return false }
            watermark.value = value
            annotation.watermark = watermark
        default:
            return false
        }
        try update(
            layer.replacingAnnotation(annotation),
            coalescingKey: coalescingKey
        )
        return true
    }

    /// 更新圆角、阴影、统一边距和双色渐变。美化图层写入其专属载荷，其他
    /// 图层写入通用图层属性，确保最终 XPC renderer 能读取同一份文档状态。
    func updateSelectedEffects(
        cornerRadius: Double? = nil,
        shadowRadius: Double? = nil,
        shadowOpacity: Double? = nil,
        shadowOffsetX: Double? = nil,
        shadowOffsetY: Double? = nil,
        contentInset: Double? = nil,
        gradientStart: ScreenshotAnnotationColor? = nil,
        gradientEnd: ScreenshotAnnotationColor? = nil,
        gradientAngle: Double? = nil,
        coalescingKey: String? = nil
    ) throws {
        guard let layer = selectedLayer else { return }
        var annotation = layer.annotation

        if var beautify = annotation.beautify {
            let colors = normalizedGradientColors(beautify.backgroundGradient.colors)
            beautify.cornerRadius = bounded(cornerRadius, fallback: beautify.cornerRadius, range: 0...240)
            beautify.shadowRadius = bounded(shadowRadius, fallback: beautify.shadowRadius, range: 0...240)
            beautify.shadowOpacity = bounded(shadowOpacity, fallback: beautify.shadowOpacity, range: 0...1)
            beautify.shadowOffsetX = bounded(shadowOffsetX, fallback: beautify.shadowOffsetX, range: -240...240)
            beautify.shadowOffsetY = bounded(shadowOffsetY, fallback: beautify.shadowOffsetY, range: -240...240)
            beautify.insets = .uniform(bounded(contentInset, fallback: beautify.insets.top, range: 0...240))
            beautify.backgroundGradient = .init(
                colors: [gradientStart ?? colors.0, gradientEnd ?? colors.1],
                angleDegrees: bounded(
                    gradientAngle,
                    fallback: beautify.backgroundGradient.angleDegrees,
                    range: -360...360
                )
            )
            annotation.beautify = beautify
            try update(
                layer.replacingAnnotation(annotation),
                coalescingKey: coalescingKey
            )
            return
        }

        let existingShadow = layer.shadow
        let existingShadowColor = existingShadow?.color
            ?? ScreenshotAnnotationColor(red: 0, green: 0, blue: 0, alpha: 0)
        let shouldUpdateShadow = shadowRadius != nil
            || shadowOpacity != nil
            || shadowOffsetX != nil
            || shadowOffsetY != nil
        let shadow = shouldUpdateShadow
            ? AnnotationShadowStyle(
                color: .init(
                    red: existingShadowColor.red,
                    green: existingShadowColor.green,
                    blue: existingShadowColor.blue,
                    alpha: bounded(shadowOpacity, fallback: existingShadowColor.alpha, range: 0...1)
                ),
                radius: bounded(shadowRadius, fallback: existingShadow?.radius ?? 0, range: 0...240),
                offsetX: bounded(shadowOffsetX, fallback: existingShadow?.offsetX ?? 0, range: -240...240),
                offsetY: bounded(shadowOffsetY, fallback: existingShadow?.offsetY ?? 0, range: -240...240)
            )
            : existingShadow
        let existingColors = normalizedGradientColors(layer.backgroundGradient?.colors ?? [])
        let shouldUpdateGradient = gradientStart != nil || gradientEnd != nil || gradientAngle != nil
        let gradient = shouldUpdateGradient
            ? ScreenshotAnnotationGradient(
                colors: [gradientStart ?? existingColors.0, gradientEnd ?? existingColors.1],
                angleDegrees: bounded(
                    gradientAngle,
                    fallback: layer.backgroundGradient?.angleDegrees ?? 135,
                    range: -360...360
                )
            )
            : layer.backgroundGradient
        let updated = AnnotationLayer(
            annotation: annotation,
            opacity: layer.opacity,
            zIndex: layer.zIndex,
            font: layer.font,
            cornerRadius: bounded(cornerRadius, fallback: layer.cornerRadius, range: 0...240),
            shadow: shadow,
            contentInsets: contentInset.map {
                .uniform(bounded($0, fallback: layer.contentInsets?.top ?? 0, range: 0...240))
            } ?? layer.contentInsets,
            backgroundGradient: gradient
        )
        try update(updated, coalescingKey: coalescingKey)
    }

    @discardableResult
    func deleteSelectedLayer() throws -> Bool {
        guard let selectedLayerID else { return false }
        _ = try history.remove(id: selectedLayerID)
        synchronizeDocument()
        self.selectedLayerID = nil
        return true
    }

    @discardableResult
    func undo() -> Bool {
        if cancelPendingCrop() {
            return true
        }
        guard history.undo() else { return false }
        synchronizeDocument()
        reconcileSelection()
        return true
    }

    @discardableResult
    func redo() -> Bool {
        guard history.redo() else { return false }
        synchronizeDocument()
        reconcileSelection()
        return true
    }

    /// 以画布 point 微调选中图层。整层统一平移并限制在画布内，避免边界处改变形状。
    @discardableResult
    func nudgeSelectedLayer(
        deltaX: Double,
        deltaY: Double,
        coalescingKey: String? = nil
    ) throws -> Bool {
        guard let layer = selectedLayer, !layer.annotation.points.isEmpty else { return false }

        let points = layer.annotation.points
        let minX = points.map(\.x).min() ?? 0
        let maxX = points.map(\.x).max() ?? 0
        let minY = points.map(\.y).min() ?? 0
        let maxY = points.map(\.y).max() ?? 0
        let canvasWidth = max(0, document.canvasSize.width)
        let canvasHeight = max(0, document.canvasSize.height)
        let clampedX = min(max(deltaX, -minX), canvasWidth - maxX)
        let clampedY = min(max(deltaY, -minY), canvasHeight - maxY)

        guard clampedX != 0 || clampedY != 0 else { return false }
        var annotation = layer.annotation
        annotation.points = points.map {
            .init(x: $0.x + clampedX, y: $0.y + clampedY)
        }
        try update(
            layer.replacingAnnotation(annotation),
            coalescingKey: coalescingKey
        )
        return true
    }

    /// 将选中图层的全部控制点按原始边界等比映射到新边界。
    /// `originalPoints` 用于拖动手势持续更新时固定基线，配合稳定的 coalescingKey
    /// 可把整次拖动合并为一个撤销步骤。
    @discardableResult
    func resizeSelectedLayer(
        to requestedBounds: CGRect,
        from originalPoints: [ScreenshotAnnotationPoint]? = nil,
        coalescingKey: String? = nil
    ) throws -> Bool {
        guard let layer = selectedLayer else { return false }
        let sourcePoints = originalPoints ?? layer.annotation.points
        guard let sourceBounds = annotationBounds(for: sourcePoints) else { return false }

        let canvasBounds = CGRect(
            x: 0,
            y: 0,
            width: max(0, document.canvasSize.width),
            height: max(0, document.canvasSize.height)
        )
        let newBounds = requestedBounds.standardized.intersection(canvasBounds)
        guard !newBounds.isNull, newBounds.width >= 1, newBounds.height >= 1 else { return false }
        guard sourceBounds != newBounds else { return false }

        var annotation = layer.annotation
        annotation.points = sourcePoints.map { point in
            let normalizedX = sourceBounds.width > 0
                ? (point.x - sourceBounds.minX) / sourceBounds.width
                : 0.5
            let normalizedY = sourceBounds.height > 0
                ? (point.y - sourceBounds.minY) / sourceBounds.height
                : 0.5
            return .init(
                x: newBounds.minX + normalizedX * newBounds.width,
                y: newBounds.minY + normalizedY * newBounds.height
            )
        }
        try update(
            layer.replacingAnnotation(annotation),
            coalescingKey: coalescingKey
        )
        return true
    }

    /// 保存当前快照。保存期间仍允许 UI 保留会话；若用户继续编辑，成功后只有已写入的
    /// 快照成为新基线，较新的编辑仍保持 dirty，不会被错误标记为已保存。
    @discardableResult
    func save() async -> Bool {
        guard !isSaving else { return false }
        guard isDirty else {
            saveStatus = .idle
            return true
        }

        let snapshot = document
        saveStatus = .saving
        do {
            try await saveHandler(snapshot)
            savedDocument = snapshot
            saveStatus = .idle
            return true
        } catch {
            saveStatus = .failed(message: error.localizedDescription)
            return false
        }
    }

    @discardableResult
    func retrySave() async -> Bool {
        await save()
    }

    func resolveClose(choice: AnnotationEditorCloseChoice) async -> AnnotationEditorCloseOutcome {
        guard isDirty else { return .close }
        switch choice {
        case .save:
            return await save() ? .close : .remainOpen
        case .discard:
            return .close
        case .cancel:
            return .remainOpen
        }
    }

    private func synchronizeDocument() {
        document = history.document
        if case .failed = saveStatus {
            saveStatus = .idle
        }
    }

    private func selectAdjacentLayer(step: Int) -> Bool {
        guard !document.layers.isEmpty else { return false }
        guard let selectedLayerID,
              let index = document.layers.firstIndex(where: { $0.id == selectedLayerID }) else {
            self.selectedLayerID = step > 0 ? document.layers.first?.id : document.layers.last?.id
            return true
        }
        let count = document.layers.count
        let nextIndex = (index + step + count) % count
        self.selectedLayerID = document.layers[nextIndex].id
        return true
    }

    private func reconcileSelection() {
        guard let selectedLayerID else { return }
        if !document.layers.contains(where: { $0.id == selectedLayerID }) {
            self.selectedLayerID = nil
        }
    }

    private func defaultText(for kind: ScreenshotAnnotationKind) -> ScreenshotAnnotationText? {
        switch kind {
        case .text: .init(value: "双击编辑文字", fontSize: 18)
        case .numberedMarker:
            .init(
                value: String(document.layers.filter { $0.kind == .numberedMarker }.count + 1),
                fontSize: 16
            )
        case .callout: .init(value: "批注", fontSize: 16)
        case .note: .init(value: "便签", fontSize: 18)
        default: nil
        }
    }

    private func defaultBeautify() -> ScreenshotAnnotationBeautify {
        .init(
            cornerRadius: 18,
            shadowRadius: 24,
            shadowOpacity: 0.22,
            shadowOffsetX: 0,
            shadowOffsetY: 12,
            insets: .uniform(36),
            backgroundGradient: .init(
                colors: [
                    .init(red: 0.22, green: 0.35, blue: 0.95),
                    .init(red: 0.68, green: 0.32, blue: 0.92)
                ],
                angleDegrees: 135
            )
        )
    }

    private func normalizedGradientColors(
        _ colors: [ScreenshotAnnotationColor]
    ) -> (ScreenshotAnnotationColor, ScreenshotAnnotationColor) {
        let fallbackStart = ScreenshotAnnotationColor(red: 1, green: 0.91, blue: 0.35)
        let fallbackEnd = ScreenshotAnnotationColor(red: 1, green: 0.72, blue: 0.22)
        switch colors.count {
        case 0: return (fallbackStart, fallbackEnd)
        case 1: return (colors[0], colors[0])
        default: return (colors[0], colors[colors.count - 1])
        }
    }

    private func bounded(
        _ requested: Double?,
        fallback: Double,
        range: ClosedRange<Double>
    ) -> Double {
        guard let requested, requested.isFinite else { return fallback }
        return min(range.upperBound, max(range.lowerBound, requested))
    }

    private func annotationBounds(
        for points: [ScreenshotAnnotationPoint]
    ) -> CGRect? {
        guard let first = points.first else { return nil }
        let minX = points.dropFirst().reduce(first.x) { min($0, $1.x) }
        let maxX = points.dropFirst().reduce(first.x) { max($0, $1.x) }
        let minY = points.dropFirst().reduce(first.y) { min($0, $1.y) }
        let maxY = points.dropFirst().reduce(first.y) { max($0, $1.y) }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
