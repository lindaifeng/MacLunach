import AppKit
import ScreenshotFeature
import SwiftUI

struct AnnotationCanvasView: View {
    @ObservedObject var state: AnnotationEditorState
    let sourceImage: NSImage
    let appearance: AnnotationEditorAppearance

    @State private var dragStart: ScreenshotAnnotationPoint?
    @State private var draftPoints: [ScreenshotAnnotationPoint] = []
    @State private var movingLayerID: UUID?
    @State private var resizingHandle: AnnotationResizeHandle?
    @State private var resizeOriginalPoints: [ScreenshotAnnotationPoint] = []
    @State private var resizeOriginalBounds: CGRect?
    @State private var resizeCoalescingKey: String?

    var body: some View {
        GeometryReader { geometry in
            let imageRect = fittedImageRect(in: geometry.size)
            ZStack {
                appearance.canvasFill
                Image(nsImage: sourceImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: imageRect.width, height: imageRect.height)
                    .position(x: imageRect.midX, y: imageRect.midY)
                    .accessibilityLabel("截图原图")

                Canvas { context, _ in
                    for layer in state.document.layers {
                        draw(layer, in: &context, imageRect: imageRect)
                    }
                    drawDraft(in: &context, imageRect: imageRect)
                    drawPendingCrop(in: &context, imageRect: imageRect)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)

                ForEach(state.document.layers, id: \.id) { layer in
                    layerAccessibilityOverlay(layer, imageRect: imageRect)
                }

                if state.hasPendingCrop {
                    VStack {
                        Spacer()
                        cropConfirmationBar
                            .padding(.bottom, 16)
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(imageRect: imageRect))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("标注画布")
            .accessibilityHint("拖动以使用当前工具创建或调整标注；选择工具下可点选和移动图层")
            .accessibilityIdentifier("screenshot.annotation.canvas")
        }
    }

    @ViewBuilder
    private func layerAccessibilityOverlay(
        _ layer: AnnotationLayer,
        imageRect: CGRect
    ) -> some View {
        if let rect = accessibilityRect(for: layer, imageRect: imageRect) {
            Rectangle()
                .fill(Color.clear)
                .frame(width: max(1, rect.width), height: max(1, rect.height))
                .position(x: rect.midX, y: rect.midY)
                .allowsHitTesting(false)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityLabel(for: layer))
                .accessibilityValue(layer.id == state.selectedLayerID ? "已选择" : "未选择")
                .accessibilityAddTraits(
                    layer.id == state.selectedLayerID ? .isSelected : []
                )
                .accessibilityHint("选择此图层后可使用属性检查器调整外观，也可使用方向键微调位置")
                .accessibilityIdentifier("screenshot.annotation.canvas.layer.\(layer.id.uuidString)")
                .accessibilityAction(named: "选择") {
                    _ = state.selectLayer(id: layer.id)
                }
                .accessibilityAction(named: "删除") {
                    _ = state.selectLayer(id: layer.id)
                    _ = try? state.deleteSelectedLayer()
                }
                .accessibilityAction(named: "上移一层") {
                    _ = state.selectLayer(id: layer.id)
                    _ = try? state.moveSelectedLayerForward()
                }
                .accessibilityAction(named: "下移一层") {
                    _ = state.selectLayer(id: layer.id)
                    _ = try? state.moveSelectedLayerBackward()
                }
        }
    }

    private func dragGesture(imageRect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard let point = sourcePoint(from: value.location, imageRect: imageRect) else { return }
                if dragStart == nil {
                    NSApp.keyWindow?.makeFirstResponder(nil)
                    dragStart = point
                    if state.selectedTool == .select {
                        if let selectedLayer = state.selectedLayer,
                           let handle = resizeHandle(
                            at: value.location,
                            for: selectedLayer,
                            imageRect: imageRect
                           ) {
                            resizingHandle = handle
                            resizeOriginalPoints = selectedLayer.annotation.points
                            resizeOriginalBounds = sourceBounds(for: selectedLayer.annotation.points)
                            resizeCoalescingKey = "canvas-resize-\(UUID().uuidString)"
                            movingLayerID = selectedLayer.id
                        } else {
                            let id = hitTest(point)
                            _ = state.selectLayer(id: id)
                            movingLayerID = id
                        }
                    } else {
                        draftPoints = [point]
                    }
                }
                if state.selectedTool == .select {
                    if let resizingHandle,
                       let resizeOriginalBounds,
                       !resizeOriginalPoints.isEmpty {
                        _ = try? state.resizeSelectedLayer(
                            to: resizedBounds(
                                original: resizeOriginalBounds,
                                handle: resizingHandle,
                                point: point
                            ),
                            from: resizeOriginalPoints,
                            coalescingKey: resizeCoalescingKey
                        )
                    }
                    return
                }
                if [.freehand, .highlighter, .mosaic, .blur].contains(state.selectedTool) {
                    if draftPoints.last != point { draftPoints.append(point) }
                } else if let dragStart {
                    draftPoints = [dragStart, point]
                }
            }
            .onEnded { value in
                defer { resetGesture() }
                guard let start = dragStart,
                      let end = sourcePoint(from: value.location, imageRect: imageRect) else { return }
                if state.selectedTool == .select {
                    if resizingHandle != nil { return }
                    guard movingLayerID != nil else { return }
                    _ = try? state.nudgeSelectedLayer(
                        deltaX: end.x - start.x,
                        deltaY: end.y - start.y,
                        coalescingKey: "canvas-drag-\(UUID().uuidString)"
                    )
                    return
                }
                guard let kind = state.selectedTool.annotationKind else { return }
                let points = draftPoints.count > 1 ? draftPoints : defaultPoints(at: start, kind: kind)
                if kind == .crop {
                    if !state.stageCrop(points: points) {
                        NSSound.beep()
                    }
                    return
                }
                _ = try? state.createLayer(kind: kind, points: points)
                if kind != .freehand && kind != .highlighter && kind != .mosaic && kind != .blur {
                    state.selectedTool = .select
                }
            }
    }

    private func resetGesture() {
        dragStart = nil
        draftPoints = []
        movingLayerID = nil
        resizingHandle = nil
        resizeOriginalPoints = []
        resizeOriginalBounds = nil
        resizeCoalescingKey = nil
    }

    private func sourcePoint(from location: CGPoint, imageRect: CGRect) -> ScreenshotAnnotationPoint? {
        guard imageRect.contains(location), imageRect.width > 0, imageRect.height > 0 else { return nil }
        return .init(
            x: (location.x - imageRect.minX) / imageRect.width * state.document.canvasSize.width,
            y: (location.y - imageRect.minY) / imageRect.height * state.document.canvasSize.height
        )
    }

    private func viewPoint(_ point: ScreenshotAnnotationPoint, imageRect: CGRect) -> CGPoint {
        CGPoint(
            x: imageRect.minX + point.x / max(1, state.document.canvasSize.width) * imageRect.width,
            y: imageRect.minY + point.y / max(1, state.document.canvasSize.height) * imageRect.height
        )
    }

    private func fittedImageRect(in available: CGSize) -> CGRect {
        let width = max(1, state.document.canvasSize.width)
        let height = max(1, state.document.canvasSize.height)
        let scale = min(available.width / width, available.height / height)
        let size = CGSize(width: width * scale, height: height * scale)
        return CGRect(
            x: (available.width - size.width) / 2,
            y: (available.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    private func hitTest(_ point: ScreenshotAnnotationPoint) -> UUID? {
        state.document.layers.reversed().first { layer in
            guard let bounds = sourceBounds(for: layer.annotation.points) else { return false }
            return bounds.insetBy(dx: -10, dy: -10).contains(CGPoint(x: point.x, y: point.y))
        }?.id
    }

    private func draw(
        _ layer: AnnotationLayer,
        in context: inout GraphicsContext,
        imageRect: CGRect
    ) {
        let annotation = layer.annotation
        let points = annotation.points.map { viewPoint($0, imageRect: imageRect) }
        guard !points.isEmpty else { return }
        let scale = imageRect.width / max(1, state.document.canvasSize.width)
        let color = Color(annotation.style.color).opacity(layer.opacity)
        let lineWidth = max(1, annotation.style.lineWidth * scale)

        switch annotation.kind {
        case .rectangle, .crop, .mosaic, .blur, .note, .beautify:
            if let rect = bounds(for: points) {
                let path = Path(rect)
                if annotation.kind == .note {
                    context.fill(path, with: .color(Color.yellow.opacity(0.32)))
                } else if annotation.kind == .mosaic || annotation.kind == .blur {
                    context.fill(path, with: .color(Color.gray.opacity(0.24)))
                }
                context.stroke(
                    path,
                    with: .color(color),
                    style: StrokeStyle(lineWidth: lineWidth, dash: annotation.kind == .crop ? [6, 4] : [])
                )
            }
        case .ellipse, .magnifier, .numberedMarker:
            if let rect = bounds(for: points) {
                let ellipse = Path(ellipseIn: rect.width < 8 || rect.height < 8
                    ? CGRect(x: rect.midX - 18, y: rect.midY - 18, width: 36, height: 36)
                    : rect)
                context.stroke(ellipse, with: .color(color), lineWidth: lineWidth)
                if annotation.kind == .numberedMarker, let text = annotation.text?.value {
                    context.draw(Text(text).font(.headline).foregroundStyle(color), at: CGPoint(x: rect.midX, y: rect.midY))
                }
            }
        case .line, .arrow, .freehand, .highlighter:
            var path = Path()
            path.move(to: points[0])
            for point in points.dropFirst() { path.addLine(to: point) }
            context.stroke(
                path,
                with: .color(color),
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
            )
            if annotation.kind == .arrow, points.count >= 2 {
                drawArrowHead(from: points[points.count - 2], to: points[points.count - 1], color: color, lineWidth: lineWidth, context: &context)
            }
        case .callout:
            guard points.count >= 2 else { break }
            var connector = Path()
            connector.move(to: points[0])
            connector.addLine(to: points[1])
            context.stroke(connector, with: .color(color), lineWidth: lineWidth)
            context.fill(
                Path(ellipseIn: CGRect(x: points[0].x - 5, y: points[0].y - 5, width: 10, height: 10)),
                with: .color(color)
            )
            if points.count >= 4, let rect = bounds(for: Array(points[2...3])) {
                context.fill(Path(roundedRect: rect, cornerRadius: 8), with: .color(color))
                if let value = annotation.text?.value, !value.isEmpty {
                    context.draw(
                        Text(value)
                            .font(.system(size: max(8, (annotation.text?.fontSize ?? 16) * scale)))
                            .foregroundStyle(.white),
                        at: CGPoint(x: rect.minX + 10, y: rect.minY + 8),
                        anchor: .topLeading
                    )
                }
            }
        case .text, .sticker, .watermark:
            let value = annotation.text?.value
                ?? annotation.sticker?.value
                ?? annotation.watermark?.value
                ?? ""
            let fontSize = (layer.font?.size ?? annotation.text?.fontSize ?? annotation.sticker?.size ?? 18) * scale
            context.draw(
                Text(value).font(.system(size: max(8, fontSize))).foregroundStyle(color),
                at: points[0],
                anchor: .topLeading
            )
        }

        if layer.id == state.selectedLayerID, let rect = bounds(for: points) {
            context.stroke(
                Path(rect.insetBy(dx: -4, dy: -4)),
                with: .color(appearance.selectionStroke),
                style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])
            )
            for point in resizeHandlePoints(for: rect).map(\.point) {
                let handleRect = CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)
                context.fill(Path(ellipseIn: handleRect), with: .color(.white))
                context.stroke(Path(ellipseIn: handleRect), with: .color(appearance.selectionStroke), lineWidth: 1.5)
            }
        }
    }

    private func drawDraft(in context: inout GraphicsContext, imageRect: CGRect) {
        guard !draftPoints.isEmpty else { return }
        let points = draftPoints.map { viewPoint($0, imageRect: imageRect) }
        var path = Path()
        path.move(to: points[0])
        if points.count == 2,
           ![.line, .arrow, .freehand, .highlighter, .mosaic, .blur].contains(state.selectedTool),
           let rect = bounds(for: points) {
            path = state.selectedTool == .ellipse ? Path(ellipseIn: rect) : Path(rect)
        } else {
            for point in points.dropFirst() { path.addLine(to: point) }
        }
        context.stroke(path, with: .color(appearance.selectionStroke), style: .init(lineWidth: 2, dash: [5, 3]))
    }

    private func drawPendingCrop(in context: inout GraphicsContext, imageRect: CGRect) {
        guard let pendingCropPoints = state.pendingCropPoints else { return }
        let points = pendingCropPoints.map { viewPoint($0, imageRect: imageRect) }
        guard let cropRect = bounds(for: points) else { return }

        let shade = Color.black.opacity(0.38)
        let shadeRects = [
            CGRect(
                x: imageRect.minX,
                y: imageRect.minY,
                width: imageRect.width,
                height: max(0, cropRect.minY - imageRect.minY)
            ),
            CGRect(
                x: imageRect.minX,
                y: cropRect.maxY,
                width: imageRect.width,
                height: max(0, imageRect.maxY - cropRect.maxY)
            ),
            CGRect(
                x: imageRect.minX,
                y: cropRect.minY,
                width: max(0, cropRect.minX - imageRect.minX),
                height: cropRect.height
            ),
            CGRect(
                x: cropRect.maxX,
                y: cropRect.minY,
                width: max(0, imageRect.maxX - cropRect.maxX),
                height: cropRect.height
            )
        ]
        for rect in shadeRects where rect.width > 0 && rect.height > 0 {
            context.fill(Path(rect), with: .color(shade))
        }
        context.stroke(
            Path(cropRect),
            with: .color(.white),
            style: .init(lineWidth: 1.5, dash: [6, 4])
        )
    }

    private var cropConfirmationBar: some View {
        HStack(spacing: 8) {
            Text("确认裁剪范围")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("取消") {
                _ = state.cancelPendingCrop()
            }
            .help("取消本次裁剪（Esc）")
            .accessibilityHint("放弃当前尚未应用的裁剪范围")
            .accessibilityIdentifier("screenshot.annotation.crop.cancel")
            .buttonStyle(.annotationEditorSecondaryAction(appearance: appearance))

            Button("应用裁剪") {
                do {
                    _ = try state.confirmPendingCrop()
                } catch {
                    NSSound.beep()
                }
            }
            .keyboardShortcut(.defaultAction)
            .accessibilityHint("将当前裁剪范围写入标注项目")
            .accessibilityIdentifier("screenshot.annotation.crop.confirm")
            .buttonStyle(.annotationEditorPrimaryAction(appearance: appearance))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(appearance.cropBarFill, in: Capsule())
        .overlay(Capsule().stroke(appearance.border, lineWidth: 1))
        .shadow(
            color: appearance.increasedContrast ? .clear : .black.opacity(0.25),
            radius: 8,
            y: 3
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("裁剪确认")
    }

    private func drawArrowHead(
        from: CGPoint,
        to: CGPoint,
        color: Color,
        lineWidth: CGFloat,
        context: inout GraphicsContext
    ) {
        let angle = atan2(to.y - from.y, to.x - from.x)
        let length = max(8, lineWidth * 4)
        var path = Path()
        path.move(to: to)
        path.addLine(to: CGPoint(x: to.x - length * cos(angle - .pi / 6), y: to.y - length * sin(angle - .pi / 6)))
        path.move(to: to)
        path.addLine(to: CGPoint(x: to.x - length * cos(angle + .pi / 6), y: to.y - length * sin(angle + .pi / 6)))
        context.stroke(path, with: .color(color), lineWidth: lineWidth)
    }

    private func defaultPoints(
        at point: ScreenshotAnnotationPoint,
        kind: ScreenshotAnnotationKind
    ) -> [ScreenshotAnnotationPoint] {
        let width = kind == .magnifier ? 120.0 : 80.0
        return [
            point,
            .init(
                x: min(state.document.canvasSize.width, point.x + width),
                y: min(state.document.canvasSize.height, point.y + width * 0.65)
            )
        ]
    }

    private func bounds(for points: [CGPoint]) -> CGRect? {
        guard let first = points.first else { return nil }
        return points.dropFirst().reduce(CGRect(origin: first, size: .zero)) { rect, point in
            rect.union(CGRect(origin: point, size: .zero))
        }
    }

    private func sourceBounds(for points: [ScreenshotAnnotationPoint]) -> CGRect? {
        guard let first = points.first else { return nil }
        return points.dropFirst().reduce(
            CGRect(x: first.x, y: first.y, width: 1, height: 1)
        ) { rect, point in
            rect.union(CGRect(x: point.x, y: point.y, width: 1, height: 1))
        }
    }

    private func accessibilityRect(
        for layer: AnnotationLayer,
        imageRect: CGRect
    ) -> CGRect? {
        guard let sourceRect = sourceBounds(for: layer.annotation.points) else { return nil }
        let first = viewPoint(
            .init(x: sourceRect.minX, y: sourceRect.minY),
            imageRect: imageRect
        )
        let last = viewPoint(
            .init(x: sourceRect.maxX, y: sourceRect.maxY),
            imageRect: imageRect
        )
        return CGRect(
            x: min(first.x, last.x),
            y: min(first.y, last.y),
            width: abs(last.x - first.x),
            height: abs(last.y - first.y)
        ).insetBy(dx: -4, dy: -4)
    }

    private func accessibilityLabel(for layer: AnnotationLayer) -> String {
        let title = AnnotationEditorTool(rawValue: layer.kind.rawValue)?.title ?? "未知"
        let content = layer.annotation.text?.value
            ?? layer.annotation.sticker?.value
            ?? layer.annotation.watermark?.value
        guard let content, !content.isEmpty else { return "\(title)标注" }
        return "\(title)标注，内容：\(content)"
    }

    private func resizeHandle(
        at location: CGPoint,
        for layer: AnnotationLayer,
        imageRect: CGRect
    ) -> AnnotationResizeHandle? {
        let points = layer.annotation.points.map { viewPoint($0, imageRect: imageRect) }
        guard let rect = bounds(for: points) else { return nil }
        return resizeHandlePoints(for: rect).first { candidate in
            hypot(candidate.point.x - location.x, candidate.point.y - location.y) <= 10
        }?.handle
    }

    private func resizeHandlePoints(
        for rect: CGRect
    ) -> [(handle: AnnotationResizeHandle, point: CGPoint)] {
        [
            (.topLeft, .init(x: rect.minX, y: rect.minY)),
            (.topRight, .init(x: rect.maxX, y: rect.minY)),
            (.bottomLeft, .init(x: rect.minX, y: rect.maxY)),
            (.bottomRight, .init(x: rect.maxX, y: rect.maxY)),
            (.top, .init(x: rect.midX, y: rect.minY)),
            (.bottom, .init(x: rect.midX, y: rect.maxY)),
            (.left, .init(x: rect.minX, y: rect.midY)),
            (.right, .init(x: rect.maxX, y: rect.midY))
        ]
    }

    private func resizedBounds(
        original: CGRect,
        handle: AnnotationResizeHandle,
        point: ScreenshotAnnotationPoint
    ) -> CGRect {
        var minX = original.minX
        var maxX = original.maxX
        var minY = original.minY
        var maxY = original.maxY
        if handle.movesLeft { minX = point.x }
        if handle.movesRight { maxX = point.x }
        if handle.movesTop { minY = point.y }
        if handle.movesBottom { maxY = point.y }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).standardized
    }
}

private enum AnnotationResizeHandle {
    case topLeft
    case top
    case topRight
    case left
    case right
    case bottomLeft
    case bottom
    case bottomRight

    var movesLeft: Bool { self == .topLeft || self == .left || self == .bottomLeft }
    var movesRight: Bool { self == .topRight || self == .right || self == .bottomRight }
    var movesTop: Bool { self == .topLeft || self == .top || self == .topRight }
    var movesBottom: Bool { self == .bottomLeft || self == .bottom || self == .bottomRight }
}

private extension Color {
    init(_ color: ScreenshotAnnotationColor) {
        self.init(
            red: min(1, max(0, color.red)),
            green: min(1, max(0, color.green)),
            blue: min(1, max(0, color.blue)),
            opacity: min(1, max(0, color.alpha))
        )
    }
}
