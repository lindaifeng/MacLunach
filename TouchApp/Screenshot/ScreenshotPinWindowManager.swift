import AppKit
import ImageIO
import ScreenshotFeature

@MainActor
protocol ScreenshotPinPresenting: AnyObject {
    func pin(_ artifact: ScreenshotArtifact, preferredFrame: CGRect?) throws
}

extension ScreenshotPinPresenting {
    func pin(_ artifact: ScreenshotArtifact) throws {
        try pin(artifact, preferredFrame: nil)
    }
}

enum ScreenshotPinError: Error, Equatable {
    case imageUnreadable(relativePath: String)
}

/// 钉图的纯布局计算。图片区域保持原始宽高比，缩放由滚轮实时驱动。
struct ScreenshotPinLayout: Equatable {
    static let controlBarHeight: CGFloat = 0
    static let minimumImageSize = CGSize(width: 184, height: 80)
    static let maximumImageSize = CGSize(width: 2_400, height: 2_400)

    let baseImageSize: CGSize

    static func scale(current: Double, wheelDelta: CGFloat, precise: Bool) -> Double {
        let sensitivity = precise ? 0.008 : 0.012
        return min(2.5, max(0.25, current * exp(Double(wheelDelta) * sensitivity)))
    }

    var aspectRatio: CGFloat {
        baseImageSize.width / max(1, baseImageSize.height)
    }

    func imageSize(scale requestedScale: Double) -> CGSize {
        let scale = CGFloat(min(2.5, max(0.25, requestedScale)))
        let proposed = CGSize(
            width: baseImageSize.width * scale,
            height: baseImageSize.height * scale
        )
        let fit = min(
            1,
            Self.maximumImageSize.width / max(1, proposed.width),
            Self.maximumImageSize.height / max(1, proposed.height)
        )
        return CGSize(
            width: max(Self.minimumImageSize.width, proposed.width * fit),
            height: max(Self.minimumImageSize.height, proposed.height * fit)
        )
    }

    func contentSize(scale: Double) -> CGSize {
        let image = imageSize(scale: scale)
        return CGSize(width: image.width, height: image.height + Self.controlBarHeight)
    }

    func contentSize(forRequestedWidth requestedWidth: CGFloat) -> CGSize {
        let width = min(Self.maximumImageSize.width, max(Self.minimumImageSize.width, requestedWidth))
        let imageHeight = min(
            Self.maximumImageSize.height,
            max(Self.minimumImageSize.height, width / max(0.01, aspectRatio))
        )
        return CGSize(width: width, height: imageHeight + Self.controlBarHeight)
    }
}

/// 管理独立的置顶截图窗口。每张钉图拥有自己的窗口状态，互不共享缩放和透明度。
@MainActor
final class ScreenshotPinWindowManager: NSObject, ScreenshotPinPresenting {
    typealias PathsProvider = () throws -> ScreenshotFeaturePaths

    private let pathsProvider: PathsProvider
    private var controllers: [UUID: ScreenshotPinWindowController] = [:]

    init(pathsProvider: @escaping PathsProvider = { try ScreenshotFeaturePaths.applicationSupport() }) {
        self.pathsProvider = pathsProvider
    }

    func pin(_ artifact: ScreenshotArtifact, preferredFrame: CGRect?) throws {
        let imageURL = try pathsProvider().resolve(relativePath: artifact.relativePath)
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(
                source,
                0,
                [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
              ) else {
            throw ScreenshotPinError.imageUnreadable(relativePath: artifact.relativePath)
        }

        let controller = ScreenshotPinWindowController(
            artifactID: artifact.id,
            image: image,
            pointSize: artifact.pointSize,
            pixelSize: artifact.pixelSize,
            preferredFrame: preferredFrame
        )
        controller.onClose = { [weak self] id in
            self?.controllers.removeValue(forKey: id)
        }
        controllers[artifact.id] = controller
        controller.showWindow(nil)
    }
}

@MainActor
private final class ScreenshotPinWindowController: NSWindowController, NSWindowDelegate {
    let artifactID: UUID
    var onClose: ((UUID) -> Void)?

    private var layout: ScreenshotPinLayout
    private weak var pinContentView: ScreenshotPinContentView?
    private var isApplyingSize = false

    init(
        artifactID: UUID,
        image: CGImage,
        pointSize: ScreenshotSize,
        pixelSize: ScreenshotSize,
        preferredFrame: CGRect?
    ) {
        self.artifactID = artifactID
        let logicalSize = Self.logicalImageSize(
            pointSize: pointSize,
            pixelSize: pixelSize,
            image: image
        )
        // 从截图选区钉图时必须保持原来的 point 尺寸；原始 CGImage 仍作为高分辨率内容源。
        let initialImageSize = preferredFrame?.size ?? Self.initialSize(source: logicalSize)
        layout = ScreenshotPinLayout(baseImageSize: initialImageSize)
        let initialContentSize = CGSize(
            width: initialImageSize.width,
            height: initialImageSize.height + ScreenshotPinLayout.controlBarHeight
        )
        let panel = ScreenshotPinPanel(
            contentRect: CGRect(origin: .zero, size: initialContentSize),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        let contentView = ScreenshotPinContentView(image: image, logicalSize: logicalSize)
        panel.contentView = contentView
        panel.identifier = NSUserInterfaceItemIdentifier("screenshot.pin.\(artifactID.uuidString)")
        panel.title = "钉图"
        panel.setAccessibilityLabel("置顶截图")
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.minSize = CGSize(
            width: ScreenshotPinLayout.minimumImageSize.width,
            height: ScreenshotPinLayout.minimumImageSize.height + ScreenshotPinLayout.controlBarHeight
        )
        panel.maxSize = CGSize(
            width: ScreenshotPinLayout.maximumImageSize.width,
            height: ScreenshotPinLayout.maximumImageSize.height + ScreenshotPinLayout.controlBarHeight
        )

        super.init(window: panel)
        pinContentView = contentView
        panel.delegate = self
        contentView.onClose = { [weak panel] in panel?.close() }
        contentView.onScaleChanged = { [weak self] value, anchor in
            self?.applyScale(value, anchorInContent: anchor)
        }
        position(panel, preferredFrame: preferredFrame)
    }

    required init?(coder: NSCoder) { nil }

    func windowWillClose(_ notification: Notification) {
        onClose?(artifactID)
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard !isApplyingSize else { return frameSize }
        return layout.contentSize(forRequestedWidth: frameSize.width)
    }

    func windowDidChangeScreen(_ notification: Notification) {
        refreshForCurrentScreen()
    }

    func windowDidChangeBackingProperties(_ notification: Notification) {
        refreshForCurrentScreen()
    }

    private func applyScale(_ scale: Double, anchorInContent: CGPoint) {
        guard let panel = window else { return }
        let contentSize = layout.contentSize(scale: min(2.5, max(0.25, scale)))
        let oldSize = panel.frame.size
        let anchor = CGPoint(
            x: panel.frame.minX + anchorInContent.x,
            y: panel.frame.minY + anchorInContent.y
        )
        let normalizedX = min(1, max(0, anchorInContent.x / max(1, oldSize.width)))
        let normalizedY = min(1, max(0, anchorInContent.y / max(1, oldSize.height)))
        let newFrame = Self.pixelAlignedFrame(
            CGRect(
                x: anchor.x - contentSize.width * normalizedX,
                y: anchor.y - contentSize.height * normalizedY,
                width: contentSize.width,
                height: contentSize.height
            ),
            on: panel.screen
        )
        isApplyingSize = true
        panel.setFrame(newFrame, display: true, animate: false)
        isApplyingSize = false
    }

    private func refreshForCurrentScreen() {
        pinContentView?.updateContentsScale()
    }

    private func position(_ panel: NSPanel, preferredFrame: CGRect?) {
        if let preferredFrame,
           preferredFrame.width > 0,
           preferredFrame.height > 0 {
            // 图片区域与原截图完全重合，控制条仅向下延伸。
            panel.setFrame(Self.pixelAlignedFrame(
                CGRect(
                    x: preferredFrame.minX,
                    y: preferredFrame.minY - ScreenshotPinLayout.controlBarHeight,
                    width: preferredFrame.width,
                    height: preferredFrame.height + ScreenshotPinLayout.controlBarHeight
                ),
                on: NSScreen.screens.first(where: { $0.frame.intersects(preferredFrame) })
            ), display: true)
            return
        }
        guard let visibleFrame = NSScreen.main?.visibleFrame else {
            panel.center()
            return
        }
        let margin: CGFloat = 24
        panel.setFrameOrigin(CGPoint(
            x: visibleFrame.maxX - panel.frame.width - margin,
            y: visibleFrame.maxY - panel.frame.height - margin
        ))
    }

    private static func logicalImageSize(
        pointSize: ScreenshotSize,
        pixelSize: ScreenshotSize,
        image: CGImage
    ) -> CGSize {
        if pointSize.width.isFinite,
           pointSize.height.isFinite,
           pointSize.width > 0,
           pointSize.height > 0 {
            return CGSize(width: pointSize.width, height: pointSize.height)
        }
        let pixelWidth = pixelSize.width.isFinite && pixelSize.width > 0
            ? pixelSize.width
            : Double(image.width)
        let pixelHeight = pixelSize.height.isFinite && pixelSize.height > 0
            ? pixelSize.height
            : Double(image.height)
        let backingScale = NSScreen.main?.backingScaleFactor ?? 2
        return CGSize(width: pixelWidth / backingScale, height: pixelHeight / backingScale)
    }

    private static func pixelAlignedFrame(_ frame: CGRect, on screen: NSScreen?) -> CGRect {
        let scale = screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        func aligned(_ value: CGFloat) -> CGFloat {
            (value * scale).rounded() / scale
        }
        return CGRect(
            x: aligned(frame.minX),
            y: aligned(frame.minY),
            width: max(1 / scale, aligned(frame.width)),
            height: max(1 / scale, aligned(frame.height))
        )
    }

    private static func initialSize(source: CGSize) -> CGSize {
        guard source.width > 0, source.height > 0 else {
            return CGSize(width: 320, height: 200)
        }
        let maximum = CGSize(width: 720, height: 520)
        let scale = min(1, maximum.width / source.width, maximum.height / source.height)
        return CGSize(
            width: max(ScreenshotPinLayout.minimumImageSize.width, source.width * scale),
            height: max(ScreenshotPinLayout.minimumImageSize.height, source.height * scale)
        )
    }

}

private final class ScreenshotPinPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class ScreenshotPinContentView: NSView {
    var onScaleChanged: ((Double, CGPoint) -> Void)?
    var onClose: (() -> Void)?

    private let imageView: ScreenshotPinImageView
    private let opacityControl = PinOpacityControl()
    private var currentScale = 1.0
    private var contextMenuPanel: NSPanel?
    private var contextMenuEventMonitor: Any?

    init(image: CGImage, logicalSize: CGSize) {
        imageView = ScreenshotPinImageView(image: image, logicalSize: logicalSize)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        configureImageView()
        configureOpacityControl()
        imageView.onDoubleClick = { [weak self] in self?.onClose?() }
    }

    required init?(coder: NSCoder) { nil }

    func updateContentsScale() {
        imageView.updateContentsScale()
    }

    private func configureImageView() {
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    private func configureOpacityControl() {
        opacityControl.translatesAutoresizingMaskIntoConstraints = false
        opacityControl.onValueChanged = { [weak self] value in
            self?.imageView.alphaValue = CGFloat(min(1, max(0.15, value)))
        }
        addSubview(opacityControl)
        NSLayoutConstraint.activate([
            opacityControl.centerXAnchor.constraint(equalTo: centerXAnchor),
            opacityControl.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            opacityControl.widthAnchor.constraint(equalToConstant: 104),
            opacityControl.heightAnchor.constraint(equalToConstant: 22)
        ])
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY * 8
        guard abs(delta) > 0.01 else {
            super.scrollWheel(with: event)
            return
        }
        currentScale = ScreenshotPinLayout.scale(
            current: currentScale,
            wheelDelta: delta,
            precise: event.hasPreciseScrollingDeltas
        )
        onScaleChanged?(currentScale, convert(event.locationInWindow, from: nil))
    }

    override func rightMouseDown(with event: NSEvent) {
        dismissContextMenu()
        guard let hostWindow = window else { return }

        let menuSize = CGSize(width: 154, height: 78)
        let clickOnScreen = hostWindow.convertPoint(toScreen: event.locationInWindow)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(clickOnScreen) }) ?? hostWindow.screen
        let visibleFrame = screen?.visibleFrame ?? hostWindow.frame
        let origin = CGPoint(
            x: min(max(clickOnScreen.x, visibleFrame.minX + 6), visibleFrame.maxX - menuSize.width - 6),
            y: min(max(clickOnScreen.y - menuSize.height, visibleFrame.minY + 6), visibleFrame.maxY - menuSize.height - 6)
        )
        let menuPanel = ScreenshotPinContextMenuPanel(
            contentRect: CGRect(origin: origin, size: menuSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        let menuView = ScreenshotPinContextMenuView(frame: CGRect(origin: .zero, size: menuSize))
        menuView.onCopy = { [weak self] in
            guard let self else { return }
            dismissContextMenu()
            if !imageView.copyToPasteboard() {
                NSSound.beep()
            }
        }
        menuView.onClose = { [weak self] in
            guard let self else { return }
            dismissContextMenu()
            onClose?()
        }
        menuView.onDismiss = { [weak self] in self?.dismissContextMenu() }

        menuPanel.contentView = menuView
        menuPanel.level = .popUpMenu
        menuPanel.backgroundColor = .clear
        menuPanel.isOpaque = false
        menuPanel.hasShadow = true
        menuPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        contextMenuPanel = menuPanel
        contextMenuEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .keyDown]
        ) { [weak self, weak menuPanel] monitoredEvent in
            guard let self, let menuPanel else { return monitoredEvent }
            if monitoredEvent.type == .keyDown, monitoredEvent.keyCode == 53 {
                dismissContextMenu()
                return nil
            }
            if let eventWindow = monitoredEvent.window, eventWindow !== menuPanel {
                dismissContextMenu()
            }
            return monitoredEvent
        }
        menuPanel.makeKeyAndOrderFront(nil)
        menuPanel.makeFirstResponder(menuView)
    }

    private func dismissContextMenu() {
        if let contextMenuEventMonitor {
            NSEvent.removeMonitor(contextMenuEventMonitor)
            self.contextMenuEventMonitor = nil
        }
        contextMenuPanel?.orderOut(nil)
        contextMenuPanel = nil
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            dismissContextMenu()
        }
        super.viewWillMove(toWindow: newWindow)
    }
}

private final class ScreenshotPinContextMenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class ScreenshotPinContextMenuView: NSView {
    var onCopy: (() -> Void)?
    var onClose: (() -> Void)?
    var onDismiss: (() -> Void)?

    private enum Row: Int {
        case copy
        case close
    }

    private var hoveredRow: Row? {
        didSet {
            if oldValue != hoveredRow { needsDisplay = true }
        }
    }
    private var trackingAreaReference: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.075, alpha: 0.91).cgColor
        layer?.cornerRadius = 10
        layer?.borderWidth = 0.7
        layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        layer?.masksToBounds = true
        setAccessibilityLabel("钉图菜单")
    }

    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        if let trackingAreaReference { removeTrackingArea(trackingAreaReference) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaReference = area
        super.updateTrackingAreas()
    }

    override func mouseMoved(with event: NSEvent) {
        hoveredRow = row(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        hoveredRow = nil
    }

    override func mouseUp(with event: NSEvent) {
        switch row(at: convert(event.locationInWindow, from: nil)) {
        case .copy: onCopy?()
        case .close: onClose?()
        case nil: onDismiss?()
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onDismiss?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let rowHeight = bounds.height / 2
        if let hoveredRow {
            let highlight = CGRect(x: 5, y: CGFloat(hoveredRow.rawValue) * rowHeight + 4, width: bounds.width - 10, height: rowHeight - 8)
            NSColor.white.withAlphaComponent(0.11).setFill()
            NSBezierPath(roundedRect: highlight, xRadius: 6, yRadius: 6).fill()
        }
        NSColor.white.withAlphaComponent(0.10).setFill()
        NSRect(x: 12, y: rowHeight, width: bounds.width - 24, height: 0.7).fill()
        drawTitle("复制", row: .copy)
        drawTitle("关闭钉图", row: .close)
    }

    private func drawTitle(_ title: String, row: Row) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.92),
            .paragraphStyle: paragraph
        ]
        let rowHeight = bounds.height / 2
        let textRect = CGRect(
            x: 14,
            y: CGFloat(row.rawValue) * rowHeight + (rowHeight - 17) / 2,
            width: bounds.width - 28,
            height: 17
        )
        title.draw(in: textRect, withAttributes: attributes)
    }

    private func row(at point: CGPoint) -> Row? {
        guard bounds.contains(point) else { return nil }
        return point.y < bounds.height / 2 ? .copy : .close
    }
}

@MainActor
private final class PinOpacityControl: NSView {
    var onValueChanged: ((Double) -> Void)?

    private let slider = NSSlider(value: 1, minValue: 0.15, maxValue: 1, target: nil, action: nil)
    private let icon = NSImageView(image: NSImage(
        systemSymbolName: "circle.lefthalf.filled",
        accessibilityDescription: "不透明度"
    ) ?? NSImage())
    private var trackingAreaReference: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 11
        slider.target = self
        slider.action = #selector(changeOpacity(_:))
        slider.isContinuous = true
        slider.controlSize = .mini
        slider.identifier = NSUserInterfaceItemIdentifier("screenshot.pin.opacity")
        slider.setAccessibilityIdentifier("screenshot.pin.opacity")
        slider.setAccessibilityLabel("钉图不透明度")
        slider.toolTip = "不透明度"
        slider.translatesAutoresizingMaskIntoConstraints = false
        icon.contentTintColor = .white
        icon.symbolConfiguration = .init(pointSize: 10, weight: .medium)
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        addSubview(slider)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 12),
            icon.heightAnchor.constraint(equalToConstant: 12),
            slider.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            slider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            slider.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        updateHighlight(false)
    }

    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        if let trackingAreaReference { removeTrackingArea(trackingAreaReference) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaReference = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { updateHighlight(true) }
    override func mouseExited(with event: NSEvent) { updateHighlight(false) }

    @objc private func changeOpacity(_ sender: NSSlider) {
        sender.toolTip = "不透明度 \(Int((sender.doubleValue * 100).rounded()))%"
        onValueChanged?(sender.doubleValue)
    }

    private func updateHighlight(_ highlighted: Bool) {
        alphaValue = highlighted ? 1 : 0.38
        layer?.backgroundColor = NSColor.black.withAlphaComponent(highlighted ? 0.46 : 0.20).cgColor
        layer?.borderWidth = highlighted ? 0.8 : 0
        layer?.borderColor = NSColor.white.withAlphaComponent(0.24).cgColor
    }
}

/// 直接把原始 CGImage 交给 Core Animation，避免 NSImage 根据 DPI 重新选择低分辨率表征。
@MainActor
private final class ScreenshotPinImageView: NSView {
    private let image: CGImage
    private let logicalSize: CGSize

    init(image: CGImage, logicalSize: CGSize) {
        self.image = image
        self.logicalSize = logicalSize
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        layer?.contents = image
        // 容器本身已锁定图片宽高比，直接铺满可避免 resizeAspect 再做一次小数像素计算。
        layer?.contentsGravity = .resize
        // 图片与窗口都按物理像素对齐；缩放时只让 Core Animation 做一次高质量采样。
        layer?.magnificationFilter = .linear
        layer?.minificationFilter = .trilinear
        layer?.allowsEdgeAntialiasing = false
        layer?.backgroundColor = NSColor.clear.cgColor
        setAccessibilityLabel("钉住的高清截图")
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateContentsScale()
    }

    func updateContentsScale() {
        layer?.contentsScale = window?.screen?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2
    }

    @discardableResult
    func copyToPasteboard() -> Bool {
        let bitmap = NSBitmapImageRep(cgImage: image)
        bitmap.size = logicalSize
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            return false
        }
        let nsImage = NSImage(size: logicalSize)
        nsImage.addRepresentation(bitmap)
        guard let tiff = nsImage.tiffRepresentation else {
            return false
        }

        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        item.setData(tiff, forType: .tiff)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            onDoubleClick?()
            return
        }
        let localPoint = convert(event.locationInWindow, from: nil)
        guard topDragRegion.contains(localPoint) else { return }
        window?.performDrag(with: event)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(topDragRegion, cursor: .openHand)
    }

    private var topDragRegion: CGRect {
        CGRect(x: bounds.minX, y: max(bounds.minY, bounds.maxY - 28), width: bounds.width, height: min(28, bounds.height))
    }

    var onDoubleClick: (() -> Void)?
}
