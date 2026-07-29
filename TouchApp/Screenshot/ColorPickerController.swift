import AppKit
import ScreenshotFeature

@MainActor
protocol ScreenshotColorPickerPresenting: AnyObject, Sendable {
    func pick(from content: ScreenshotSelectionContent) async -> ScreenshotColor?
    func cancel()
}

@MainActor
protocol ScreenshotColorClipboardWriting: AnyObject {
    func write(_ color: ScreenshotColor) throws
}

@MainActor
final class SystemScreenshotColorClipboardWriter: ScreenshotColorClipboardWriting {
    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    func write(_ color: ScreenshotColor) throws {
        pasteboard.clearContents()
        guard pasteboard.setString(Self.copyText(for: color), forType: .string) else {
            throw ScreenshotClipboardError.pasteboardWriteFailed
        }
    }

    static func copyText(for color: ScreenshotColor) -> String {
        color.rgbString
    }
}

@MainActor
final class ColorPickerController: ScreenshotColorPickerPresenting {
    private struct PendingSample {
        let displayID: UInt32
        let point: CGPoint
        let immediately: Bool
        let locksOnSuccess: Bool
    }

    typealias SampleAcceptedHandler = @MainActor (
        _ displayID: UInt32,
        _ point: CGPoint,
        _ sample: ScreenshotColorSample
    ) -> Void

    private let captureService: any ScreenshotCapturing
    private let minimumSampleInterval: Duration
    private let sampleAcceptedHandler: SampleAcceptedHandler?
    private var panels: [ColorPickerPanel] = []
    private var views: [UInt32: ColorPickerOverlayView] = [:]
    private var continuation: CheckedContinuation<ScreenshotColor?, Never>?
    private var sampleTask: Task<Void, Never>?
    private var pendingSample: PendingSample?
    private var latestSample: ScreenshotColorSample?
    private var latestSampleDisplayID: UInt32?
    private var latestPoint: CGPoint?
    private var lockedSample: ScreenshotColorSample?
    private var lastSampleStartedAt: ContinuousClock.Instant?
    private var didPushCursor = false

    init(
        captureService: any ScreenshotCapturing,
        minimumSampleInterval: Duration = .milliseconds(33),
        sampleAcceptedHandler: SampleAcceptedHandler? = nil
    ) {
        self.captureService = captureService
        self.minimumSampleInterval = minimumSampleInterval
        self.sampleAcceptedHandler = sampleAcceptedHandler
    }

    func pick(from content: ScreenshotSelectionContent) async -> ScreenshotColor? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                present(content)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    func cancel() {
        finish(with: nil)
    }

    func mouseMoved(on displayID: UInt32, to point: CGPoint) {
        guard lockedSample == nil else { return }
        latestPoint = point
        let sample = latestSampleDisplayID == displayID ? latestSample : nil
        views[displayID]?.update(pointer: point, sample: sample)
        requestSample(displayID: displayID, point: point, immediately: false)
    }

    func mouseDown(on displayID: UInt32, at point: CGPoint) {
        if let action = views[displayID]?.action(at: point) {
            switch action {
            case .confirm:
                _ = confirmLockedColor()
            }
            return
        }

        // 锁定后在其他位置单击即可重新采样，避免用户必须先取消再重进取色。
        lockedSample = nil
        requestSample(displayID: displayID, point: point, immediately: true, locksOnSuccess: true)
    }

    func keyDown(_ event: NSEvent) {
        switch event.keyCode {
        case 36 where lockedSample != nil,
             49 where lockedSample != nil:
            _ = confirmLockedColor()
        case 53:
            finish(with: nil)
        default:
            break
        }
    }

    @discardableResult
    func confirmLockedColor() -> ScreenshotColor? {
        guard let color = lockedSample?.color else { return nil }
        finish(with: color)
        return color
    }

    private func present(_ content: ScreenshotSelectionContent) {
        closePanels()
        latestSample = nil
        latestSampleDisplayID = nil
        latestPoint = nil
        lockedSample = nil
        lastSampleStartedAt = nil
        pendingSample = nil

        for display in content.displays {
            guard let screen = screen(for: display.id) else { continue }
            let panel = ColorPickerPanel(
                contentRect: screen.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false,
                screen: screen
            )
            let view = ColorPickerOverlayView(display: display, controller: self)
            panel.contentView = view
            panel.identifier = .init("screenshot.color-picker.overlay")
            panel.title = "screenshot.color-picker.overlay"
            panel.setAccessibilityIdentifier("screenshot.color-picker.overlay")
            panel.setAccessibilityLabel("屏幕取色")
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = false
            panel.acceptsMouseMovedEvents = true
            panels.append(panel)
            views[display.id] = view
            panel.orderFrontRegardless()
        }

        guard let first = panels.first, let view = first.contentView else {
            finish(with: nil)
            return
        }
        first.makeFirstResponder(view)
        first.makeKey()
        NSCursor.crosshair.push()
        didPushCursor = true
    }

    private func requestSample(
        displayID: UInt32,
        point: CGPoint,
        immediately: Bool,
        locksOnSuccess: Bool = false
    ) {
        pendingSample = PendingSample(
            displayID: displayID,
            point: point,
            immediately: immediately,
            locksOnSuccess: locksOnSuccess
        )
        startSampleWorkerIfNeeded()
    }

    private func startSampleWorkerIfNeeded() {
        guard sampleTask == nil else { return }
        let captureService = captureService
        sampleTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.sampleTask = nil }
            while !Task.isCancelled, let request = self.pendingSample {
                self.pendingSample = nil
                do {
                    if !request.immediately, let lastSampleStartedAt = self.lastSampleStartedAt {
                        let elapsed = lastSampleStartedAt.duration(to: ContinuousClock.now)
                        if elapsed < self.minimumSampleInterval {
                            try await Task.sleep(for: self.minimumSampleInterval - elapsed)
                        }
                    }
                    try Task.checkCancellation()
                    self.lastSampleStartedAt = ContinuousClock.now
                    let sample = try await captureService.sampleColor(.init(
                        displayID: request.displayID,
                        desktopPoint: .init(x: request.point.x, y: request.point.y)
                    ))
                    try Task.checkCancellation()
                    // 采集中发生的新移动只保留最后一个位置；旧结果不再刷新界面。
                    if self.pendingSample != nil { continue }
                    self.latestSample = sample
                    self.latestSampleDisplayID = request.displayID
                    self.latestPoint = request.point
                    if request.locksOnSuccess {
                        self.lockedSample = sample
                        self.views[request.displayID]?.lock(pointer: request.point, sample: sample)
                    } else {
                        self.views[request.displayID]?.update(pointer: request.point, sample: sample)
                    }
                    self.sampleAcceptedHandler?(request.displayID, request.point, sample)
                } catch is CancellationError {
                    return
                } catch let error as ScreenshotFeatureError where error == .cancelled {
                    return
                } catch {
                    guard self.pendingSample == nil else { continue }
                    self.views[request.displayID]?.showError("无法读取屏幕颜色")
                    NSSound.beep()
                }
            }
        }
    }

    private func finish(with color: ScreenshotColor?) {
        sampleTask?.cancel()
        sampleTask = nil
        pendingSample = nil
        guard let continuation else {
            closePanels()
            return
        }
        self.continuation = nil
        closePanels()
        if didPushCursor {
            NSCursor.pop()
            didPushCursor = false
        }
        continuation.resume(returning: color)
    }

    private func closePanels() {
        for panel in panels { panel.orderOut(nil) }
        panels.removeAll()
        views.removeAll()
    }

    private func screen(for displayID: UInt32) -> NSScreen? {
        NSScreen.screens.first { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                as? NSNumber else { return false }
            return number.uint32Value == displayID
        }
    }
}

private final class ColorPickerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class ColorPickerOverlayView: NSView {
    private let display: ScreenshotDisplayDescriptor
    private weak var controller: ColorPickerController?
    private var pointer: CGPoint?
    private var sample: ScreenshotColorSample?
    private var isLocked = false
    private var errorMessage: String?
    private var tracking: NSTrackingArea?

    init(display: ScreenshotDisplayDescriptor, controller: ColorPickerController) {
        self.display = display
        self.controller = controller
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let tracking = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(tracking)
        self.tracking = tracking
    }

    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }

    override func mouseMoved(with event: NSEvent) {
        controller?.mouseMoved(on: display.id, to: desktopPoint(for: event))
    }

    override func mouseDown(with event: NSEvent) {
        controller?.mouseDown(on: display.id, at: desktopPoint(for: event))
    }

    override func keyDown(with event: NSEvent) {
        controller?.keyDown(event)
    }

    func update(pointer: CGPoint, sample: ScreenshotColorSample?) {
        self.pointer = pointer
        self.sample = sample
        isLocked = false
        errorMessage = nil
        needsDisplay = true
    }

    func lock(pointer: CGPoint, sample: ScreenshotColorSample) {
        self.pointer = pointer
        self.sample = sample
        isLocked = true
        errorMessage = nil
        needsDisplay = true
    }

    func action(at desktopPoint: CGPoint) -> ColorPickerLoupeAction? {
        guard let pointer, isLocked else { return nil }
        return ColorPickerLoupeView.action(
            at: localPoint(for: desktopPoint),
            near: localPoint(for: pointer),
            in: bounds
        )
    }

    func showError(_ message: String) {
        errorMessage = message
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let pointer else { return }
        ColorPickerLoupeView.draw(
            sample: sample,
            errorMessage: errorMessage,
            isLocked: isLocked,
            at: localPoint(for: pointer),
            in: bounds
        )
    }

    private func desktopPoint(for event: NSEvent) -> CGPoint {
        let local = convert(event.locationInWindow, from: nil)
        return CGPoint(
            x: display.frame.x + local.x,
            y: display.frame.y + (bounds.height - local.y)
        )
    }

    private func localPoint(for desktopPoint: CGPoint) -> CGPoint {
        CGPoint(
            x: desktopPoint.x - display.frame.x,
            y: bounds.height - (desktopPoint.y - display.frame.y)
        )
    }
}
