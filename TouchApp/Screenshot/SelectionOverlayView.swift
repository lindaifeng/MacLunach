import AppKit
import ScreenshotFeature

@MainActor
final class SelectionOverlayView: NSView {
    private let display: ScreenshotDisplayDescriptor
    private weak var controller: SelectionOverlayController?
    private let sizeLabel = NSTextField(labelWithString: "")
    private var selection: CGRect?
    private var pointer = CGPoint.zero
    private var scaleFactor: CGFloat = 1
    private var showsLabel = false
    private var trackingAreaReference: NSTrackingArea?

    init(display: ScreenshotDisplayDescriptor, controller: SelectionOverlayController) {
        self.display = display
        self.controller = controller
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
        showsLabel: Bool
    ) {
        self.selection = selection
        self.pointer = pointer
        self.scaleFactor = scaleFactor
        self.showsLabel = showsLabel
        updateSizeLabel()
        needsDisplay = true
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

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseEntered(with event: NSEvent) { notifyMouseMoved(event) }
    override func mouseMoved(with event: NSEvent) { notifyMouseMoved(event) }

    override func mouseDown(with event: NSEvent) {
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
}
