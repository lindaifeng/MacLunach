import AppKit
import ScreenshotFeature

@MainActor
final class SelectionOverlayView: NSView {
    private let display: ScreenshotDisplayDescriptor
    private weak var controller: SelectionOverlayController?
    private let sizeLabel = NSTextField(labelWithString: "")
    private let toolbar: SelectionToolbarView
    private var selection: CGRect?
    private var pointer = CGPoint.zero
    private var scaleFactor: CGFloat = 1
    private var showsLabel = false
    private var annotations: [SelectionAnnotation] = []
    private var trackingAreaReference: NSTrackingArea?
    private var inlineTextEditor: SelectionInlineTextEditor?

    init(display: ScreenshotDisplayDescriptor, controller: SelectionOverlayController) {
        self.display = display
        self.controller = controller
        toolbar = SelectionToolbarView(delegate: controller)
        super.init(frame: .zero)
        wantsLayer = true
        identifier = NSUserInterfaceItemIdentifier("screenshot.selection.overlay-view")
        setAccessibilityElement(true)
        setAccessibilityLabel("截图区域选择")
        setAccessibilityHelp("拖动选择区域，空格移动，方向键微调，回车完成，Escape 取消")

        sizeLabel.identifier = NSUserInterfaceItemIdentifier("screenshot.selection.size-label")
        sizeLabel.setAccessibilityIdentifier("screenshot.selection.size-label")
        sizeLabel.setAccessibilityLabel("选区尺寸")
        sizeLabel.textColor = .white
        sizeLabel.backgroundColor = NSColor.black.withAlphaComponent(0.78)
        sizeLabel.drawsBackground = true
        sizeLabel.isBordered = false
        sizeLabel.alignment = .center
        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        sizeLabel.wantsLayer = true
        sizeLabel.layer?.cornerRadius = 5
        sizeLabel.isHidden = true
        addSubview(sizeLabel)

        toolbar.isHidden = true
        addSubview(toolbar)
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    override func updateTrackingAreas() {
        if let trackingAreaReference { removeTrackingArea(trackingAreaReference) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaReference = area
        super.updateTrackingAreas()
    }

    func update(
        selection: CGRect?,
        pointer: CGPoint,
        scaleFactor: CGFloat,
        showsLabel: Bool,
        showsToolbar: Bool,
        selectedToolbarItem: SelectionToolbarItem?,
        windowShadowIncluded: Bool,
        showsWindowShadow: Bool,
        toolbarStatus: String,
        annotations: [SelectionAnnotation]
    ) {
        self.selection = selection
        self.pointer = pointer
        self.scaleFactor = scaleFactor
        self.showsLabel = showsLabel && !showsToolbar
        self.annotations = annotations
        updateSizeLabel()
        updateToolbar(
            showsToolbar: showsToolbar,
            selectedItem: selectedToolbarItem,
            windowShadowIncluded: windowShadowIncluded,
            showsWindowShadow: showsWindowShadow,
            status: toolbarStatus
        )
        needsDisplay = true
    }

    @discardableResult
    func beginTextEditing(
        at desktopPoint: CGPoint,
        kind: ScreenshotAnnotationKind,
        completion: @escaping (String, CGRect) -> Void
    ) -> Bool {
        guard kind == .text || kind == .note,
              let selection,
              let localSelection = localRect(for: selection) else { return false }
        commitInlineTextEditing()

        let preferredSize = kind == .note
            ? CGSize(width: 220, height: 96)
            : CGSize(width: 240, height: 34)
        let size = CGSize(
            width: min(preferredSize.width, localSelection.width),
            height: min(preferredSize.height, localSelection.height)
        )
        guard size.width >= 40, size.height >= 24 else { return false }
        let localAnchor = localPoint(for: desktopPoint)
        let origin = CGPoint(
            x: min(max(localAnchor.x, localSelection.minX), localSelection.maxX - size.width),
            y: min(max(localAnchor.y - size.height, localSelection.minY), localSelection.maxY - size.height)
        )
        let editor = SelectionInlineTextEditor(kind: kind)
        editor.frame = CGRect(origin: origin, size: size)
        editor.onFinish = { [weak self, weak editor] value in
            guard let self, let editor else { return }
            let desktopRect = self.desktopRect(for: editor.frame)
            editor.removeFromSuperview()
            if self.inlineTextEditor === editor { self.inlineTextEditor = nil }
            guard let value else { return }
            completion(value, desktopRect)
        }
        inlineTextEditor = editor
        addSubview(editor)
        window?.makeFirstResponder(editor)
        return true
    }

    func commitInlineTextEditing() {
        inlineTextEditor?.finish(commit: true)
    }

    func cancelInlineTextEditing() {
        inlineTextEditor?.finish(commit: false)
    }

    private func desktopRect(for local: CGRect) -> CGRect {
        CGRect(
            x: display.frame.x + local.minX,
            y: display.frame.y + (bounds.height - local.maxY),
            width: local.width,
            height: local.height
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let mask = NSBezierPath(rect: bounds)
        if let selection, let localSelection = localRect(for: selection) {
            mask.appendRect(localSelection)
        }
        mask.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.38).setFill()
        mask.fill()

        guard let selection, let localSelection = localRect(for: selection) else { return }

        drawAnnotations(annotations, clippedTo: localSelection)

        NSColor.white.setStroke()
        let border = NSBezierPath(rect: localSelection.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        border.stroke()

        for center in SelectionGeometry.handleCenters(for: selection).values {
            guard displayBounds.contains(center) else { continue }
            let local = localPoint(for: center)
            let handleRect = CGRect(x: local.x - 3, y: local.y - 3, width: 6, height: 6)
            NSColor.white.setFill()
            NSBezierPath(ovalIn: handleRect).fill()
            NSColor.black.withAlphaComponent(0.6).setStroke()
            NSBezierPath(ovalIn: handleRect).stroke()
        }
    }

    private func drawAnnotations(
        _ annotations: [SelectionAnnotation],
        clippedTo localSelection: CGRect
    ) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: localSelection).addClip()

        for annotation in annotations {
            let points = annotation.points.map(localPoint(for:))
            guard !points.isEmpty else { continue }
            let color = annotation.style.color
            NSColor(
                calibratedRed: color.red,
                green: color.green,
                blue: color.blue,
                alpha: color.alpha
            ).setStroke()
            let path = NSBezierPath()
            path.lineWidth = max(1, annotation.style.lineWidth)
            path.lineCapStyle = .round
            path.lineJoinStyle = .round

            switch annotation.kind {
            case .rectangle:
                guard let rect = annotationRect(points) else { continue }
                path.appendRect(rect)
            case .ellipse:
                guard let rect = annotationRect(points) else { continue }
                path.appendOval(in: rect)
            case .line:
                guard points.count >= 2 else { continue }
                path.move(to: points[0])
                path.line(to: points[points.count - 1])
            case .arrow:
                guard points.count >= 2 else { continue }
                appendArrow(
                    from: points[0],
                    to: points[points.count - 1],
                    lineWidth: path.lineWidth,
                    to: path
                )
            case .freehand, .highlighter, .mosaic:
                guard points.count >= 2 else { continue }
                path.move(to: points[0])
                for point in points.dropFirst() { path.line(to: point) }
                if annotation.kind == .mosaic {
                    mosaicPreviewColor(
                        blockSize: CGFloat(annotation.mosaic?.blockSize ?? 9)
                    ).setStroke()
                }
            case .blur:
                guard let rect = annotationRect(points) else { continue }
                NSColor.systemBlue.withAlphaComponent(0.20).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
                path.appendRoundedRect(rect, xRadius: 6, yRadius: 6)
            case .magnifier:
                guard let center = points.first, let magnifier = annotation.magnifier else { continue }
                let diameter = CGFloat(max(8, magnifier.diameter))
                path.appendOval(in: CGRect(
                    x: center.x - diameter / 2,
                    y: center.y - diameter / 2,
                    width: diameter,
                    height: diameter
                ))
                path.lineWidth = CGFloat(max(1, magnifier.borderWidth))
            case .crop:
                guard let rect = annotationRect(points) else { continue }
                path.appendRect(rect)
                path.setLineDash([6, 4], count: 2, phase: 0)
            case .text:
                drawTextAnnotation(annotation, points: points)
                continue
            case .numberedMarker:
                drawNumberedMarker(annotation, points: points)
                continue
            case .note:
                drawNoteAnnotation(annotation, points: points)
                continue
            case .sticker:
                drawStickerAnnotation(annotation, points: points)
                continue
            case .watermark:
                drawWatermarkAnnotation(annotation, points: points)
                continue
            case .beautify:
                drawBeautifyAnnotation(annotation, points: points)
                continue
            }
            path.stroke()
        }
    }

    private func mosaicPreviewColor(blockSize: CGFloat) -> NSColor {
        let block = max(4, blockSize)
        let image = NSImage(size: CGSize(width: block * 2, height: block * 2))
        image.lockFocus()
        NSColor(calibratedWhite: 0.3, alpha: 0.82).setFill()
        NSBezierPath(rect: CGRect(x: 0, y: 0, width: block, height: block)).fill()
        NSBezierPath(rect: CGRect(x: block, y: block, width: block, height: block)).fill()
        NSColor(calibratedWhite: 0.72, alpha: 0.82).setFill()
        NSBezierPath(rect: CGRect(x: block, y: 0, width: block, height: block)).fill()
        NSBezierPath(rect: CGRect(x: 0, y: block, width: block, height: block)).fill()
        image.unlockFocus()
        return NSColor(patternImage: image)
    }

    private func drawTextAnnotation(_ annotation: SelectionAnnotation, points: [CGPoint]) {
        guard let anchor = points.first, let text = annotation.text, !text.value.isEmpty else { return }
        let color = annotation.style.color
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: text.fontSize, weight: .semibold),
            .foregroundColor: NSColor(
                calibratedRed: color.red,
                green: color.green,
                blue: color.blue,
                alpha: color.alpha
            )
        ]
        let value = NSAttributedString(string: text.value, attributes: attributes)
        value.draw(at: CGPoint(x: anchor.x, y: anchor.y - value.size().height))
    }

    private func drawNumberedMarker(_ annotation: SelectionAnnotation, points: [CGPoint]) {
        guard let center = points.first, let text = annotation.text else { return }
        let radius = max(10, text.fontSize * 0.78)
        let color = annotation.style.color
        NSColor(
            calibratedRed: color.red,
            green: color.green,
            blue: color.blue,
            alpha: color.alpha
        ).setFill()
        NSBezierPath(ovalIn: CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        )).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: text.fontSize, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        let value = NSAttributedString(string: text.value, attributes: attributes)
        let size = value.size()
        value.draw(at: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2))
    }

    private func drawNoteAnnotation(_ annotation: SelectionAnnotation, points: [CGPoint]) {
        guard let rect = annotationRect(points), let text = annotation.text else { return }
        NSColor(calibratedRed: 1, green: 0.91, blue: 0.35, alpha: 0.96).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: text.fontSize),
            .foregroundColor: NSColor(calibratedWhite: 0.12, alpha: 1),
            .paragraphStyle: paragraph
        ]
        NSAttributedString(string: text.value, attributes: attributes).draw(
            in: rect.insetBy(dx: 8, dy: 7)
        )
    }

    private func drawStickerAnnotation(_ annotation: SelectionAnnotation, points: [CGPoint]) {
        guard let center = points.first,
              let sticker = annotation.sticker,
              !sticker.value.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont(name: "Apple Color Emoji", size: sticker.size)
                ?? NSFont.systemFont(ofSize: sticker.size)
        ]
        let value = NSAttributedString(string: sticker.value, attributes: attributes)
        let size = value.size()
        value.draw(at: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2))
    }

    private func drawWatermarkAnnotation(_ annotation: SelectionAnnotation, points: [CGPoint]) {
        guard let rect = annotationRect(points),
              let watermark = annotation.watermark,
              !watermark.value.isEmpty,
              rect.width > 1,
              rect.height > 1,
              let context = NSGraphicsContext.current?.cgContext else { return }
        let color = annotation.style.color
        let fontSize = CGFloat(max(9, watermark.fontSize))
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
            .foregroundColor: NSColor(
                calibratedRed: color.red,
                green: color.green,
                blue: color.blue,
                alpha: min(1, max(0, color.alpha * watermark.opacity))
            )
        ]
        let value = NSAttributedString(string: watermark.value, attributes: attributes)
        let size = value.size()
        let spacing = CGFloat(max(18, watermark.spacing))
        let stepX = max(size.width + spacing, 36)
        let stepY = max(fontSize * 2.4, spacing)
        let radians = CGFloat(watermark.angleDegrees * .pi / 180)

        context.saveGState()
        defer { context.restoreGState() }
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
                value.draw(at: CGPoint(x: -size.width / 2, y: -size.height / 2))
                context.restoreGState()
                x += stepX
            }
            row += 1
            y += stepY
        }
    }

    /// 最终导出会把背景扩展到选区外；Overlay 只以渐变边框提示当前样式，避免遮挡截图内容。
    private func drawBeautifyAnnotation(_ annotation: SelectionAnnotation, points: [CGPoint]) {
        guard let rect = annotationRect(points),
              let beautify = annotation.beautify,
              rect.width > 8,
              rect.height > 8 else { return }
        var colors = beautify.backgroundGradient.colors.map { color in
            NSColor(
                calibratedRed: min(1, max(0, color.red)),
                green: min(1, max(0, color.green)),
                blue: min(1, max(0, color.blue)),
                alpha: min(1, max(0, color.alpha))
            )
        }
        if colors.isEmpty {
            colors = [.systemPurple, .systemTeal]
        } else if colors.count == 1 {
            colors.append(colors[0])
        }
        guard let gradient = NSGradient(colors: colors) else { return }

        let radius = CGFloat(min(
            max(0, beautify.cornerRadius),
            Double(min(rect.width, rect.height) / 2)
        ))
        let outerRect = rect.insetBy(dx: 1.5, dy: 1.5)
        let innerRect = outerRect.insetBy(dx: 5, dy: 5)
        let border = NSBezierPath(
            roundedRect: outerRect,
            xRadius: radius,
            yRadius: radius
        )
        border.append(NSBezierPath(
            roundedRect: innerRect,
            xRadius: max(0, radius - 5),
            yRadius: max(0, radius - 5)
        ))
        border.windingRule = .evenOdd

        NSGraphicsContext.saveGraphicsState()
        border.addClip()
        gradient.draw(
            in: outerRect,
            angle: CGFloat(beautify.backgroundGradient.angleDegrees)
        )
        NSGraphicsContext.restoreGraphicsState()

        NSColor.black.withAlphaComponent(min(0.45, max(0.12, beautify.shadowOpacity))).setStroke()
        let outline = NSBezierPath(
            roundedRect: outerRect,
            xRadius: radius,
            yRadius: radius
        )
        outline.lineWidth = 1
        outline.stroke()
    }

    private func annotationRect(_ points: [CGPoint]) -> CGRect? {
        guard let first = points.first, let last = points.last else { return nil }
        return CGRect(
            x: min(first.x, last.x),
            y: min(first.y, last.y),
            width: abs(last.x - first.x),
            height: abs(last.y - first.y)
        )
    }

    private func appendArrow(
        from start: CGPoint,
        to end: CGPoint,
        lineWidth: CGFloat,
        to path: NSBezierPath
    ) {
        path.move(to: start)
        path.line(to: end)
        let dx = end.x - start.x
        let dy = end.y - start.y
        guard hypot(dx, dy) > 0.5 else { return }
        let angle = atan2(dy, dx)
        let size = max(8, lineWidth * 3.2)
        let spread = CGFloat.pi / 7
        let first = CGPoint(
            x: end.x - cos(angle - spread) * size,
            y: end.y - sin(angle - spread) * size
        )
        let second = CGPoint(
            x: end.x - cos(angle + spread) * size,
            y: end.y - sin(angle + spread) * size
        )
        path.move(to: first)
        path.line(to: end)
        path.line(to: second)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
        if !toolbar.isHidden {
            addCursorRect(toolbar.frame, cursor: .arrow)
        }
    }

    override func mouseEntered(with event: NSEvent) { notifyMouseMoved(event) }
    override func mouseMoved(with event: NSEvent) { notifyMouseMoved(event) }

    override func mouseDown(with event: NSEvent) {
        commitInlineTextEditing()
        window?.makeFirstResponder(self)
        controller?.mouseDown(on: display.id, at: desktopPoint(for: event))
    }

    override func mouseDragged(with event: NSEvent) {
        controller?.mouseDragged(on: display.id, to: desktopPoint(for: event))
    }

    override func mouseUp(with event: NSEvent) {
        controller?.mouseUp()
    }

    override func keyDown(with event: NSEvent) {
        controller?.keyDown(event)
    }

    override func keyUp(with event: NSEvent) {
        controller?.keyUp(event)
    }

    private func notifyMouseMoved(_ event: NSEvent) {
        controller?.mouseMoved(on: display.id, to: desktopPoint(for: event))
    }

    private var displayBounds: CGRect {
        CGRect(
            x: display.frame.x,
            y: display.frame.y,
            width: display.frame.width,
            height: display.frame.height
        )
    }

    private func desktopPoint(for event: NSEvent) -> CGPoint {
        let local = convert(event.locationInWindow, from: nil)
        return CGPoint(
            x: display.frame.x + local.x,
            y: display.frame.y + (bounds.height - local.y)
        )
    }

    private func localPoint(for desktop: CGPoint) -> CGPoint {
        CGPoint(
            x: desktop.x - display.frame.x,
            y: bounds.height - (desktop.y - display.frame.y)
        )
    }

    private func localRect(for desktop: CGRect) -> CGRect? {
        let clipped = desktop.intersection(displayBounds)
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return nil }
        return CGRect(
            x: clipped.minX - display.frame.x,
            y: bounds.height - (clipped.maxY - display.frame.y),
            width: clipped.width,
            height: clipped.height
        )
    }

    private func updateSizeLabel() {
        guard showsLabel, let selection, let localSelection = localRect(for: selection) else {
            sizeLabel.isHidden = true
            return
        }
        let pixels = SelectionGeometry.pixelSize(for: selection, scaleFactor: scaleFactor)
        let text = "\(Int(pixels.width)) × \(Int(pixels.height))"
        sizeLabel.stringValue = text
        sizeLabel.setAccessibilityLabel("选区尺寸 \(text) 像素")
        sizeLabel.setAccessibilityValue("\(text) 像素")
        let textSize = sizeLabel.intrinsicContentSize
        let labelSize = CGSize(width: max(92, textSize.width + 18), height: 28)
        let localPointer = localPoint(for: pointer)
        var preferred = CGPoint(x: localPointer.x, y: localPointer.y)
        if !bounds.contains(localPointer) {
            preferred = CGPoint(x: localSelection.maxX, y: localSelection.minY)
        }
        sizeLabel.frame = SelectionGeometry.labelFrame(
            pointer: preferred,
            labelSize: labelSize,
            in: bounds
        )
        sizeLabel.isHidden = false
    }

    private func updateToolbar(
        showsToolbar: Bool,
        selectedItem: SelectionToolbarItem?,
        windowShadowIncluded: Bool,
        showsWindowShadow: Bool,
        status: String
    ) {
        guard showsToolbar,
              let selection,
              let localSelection = localRect(for: selection) else {
            toolbar.isHidden = true
            window?.invalidateCursorRects(for: self)
            return
        }

        let pixels = SelectionGeometry.pixelSize(for: selection, scaleFactor: scaleFactor)
        toolbar.update(
            pixelSize: pixels,
            windowShadowIncluded: windowShadowIncluded,
            showsWindowShadow: showsWindowShadow,
            selectedItem: selectedItem
        )
        toolbar.showStatus(status)
        toolbar.frame = SelectionToolbarLayout.frame(
            selection: localSelection,
            toolbarSize: SelectionToolbarView.preferredSize,
            in: bounds
        )
        toolbar.isHidden = false
        window?.invalidateCursorRects(for: self)
    }
}


@MainActor
private final class SelectionInlineTextEditor: NSTextView {
    let kind: ScreenshotAnnotationKind
    var onFinish: ((String?) -> Void)?
    private var hasFinished = false

    init(kind: ScreenshotAnnotationKind) {
        self.kind = kind
        super.init(frame: .zero)
        isRichText = false
        isEditable = true
        isSelectable = true
        allowsUndo = true
        font = .systemFont(ofSize: kind == .note ? 14 : 18, weight: kind == .note ? .regular : .semibold)
        textColor = kind == .note ? NSColor(calibratedWhite: 0.12, alpha: 1) : .red
        backgroundColor = kind == .note
            ? NSColor(calibratedRed: 1, green: 0.91, blue: 0.35, alpha: 0.96)
            : NSColor.windowBackgroundColor.withAlphaComponent(0.92)
        drawsBackground = true
        textContainerInset = CGSize(width: 6, height: 5)
        insertionPointColor = textColor
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        setAccessibilityIdentifier("screenshot.selection.inline-text-editor")
        setAccessibilityLabel(kind == .note ? "输入备注，Command 回车完成" : "输入文本，回车完成")
    }

    required init?(coder: NSCoder) { nil }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            finish(commit: false)
            return
        }
        let isReturn = event.keyCode == 36 || event.keyCode == 52 || event.keyCode == 76
        if isReturn, kind == .text || (isReturn && event.modifierFlags.contains(.command)) {
            finish(commit: true)
            return
        }
        super.keyDown(with: event)
    }

    func finish(commit: Bool) {
        guard !hasFinished else { return }
        hasFinished = true
        let value = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let callback = onFinish
        onFinish = nil
        callback?(commit && !value.isEmpty ? value : nil)
    }
}
