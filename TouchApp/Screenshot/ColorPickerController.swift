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
        guard pasteboard.setString(color.hexString, forType: .string) else {
            throw ScreenshotClipboardError.pasteboardWriteFailed
        }
    }
}

@MainActor
final class ColorPickerController: ScreenshotColorPickerPresenting {
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
    private var latestRequestID: UUID?
    private var latestSample: ScreenshotColorSample?
    private var latestSampleDisplayID: UInt32?
    private var latestPoint: CGPoint?
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
        latestPoint = point
        for (id, view) in views {
            let sample = id == displayID && latestSampleDisplayID == displayID
                ? latestSample
                : nil
            view.update(pointer: point, sample: sample)
        }
        requestSample(displayID: displayID, point: point, immediately: false)
    }

    func mouseDown(on displayID: UInt32, at point: CGPoint) {
        requestSample(displayID: displayID, point: point, immediately: true, completesOnSuccess: true)
    }

    func keyDown(_ event: NSEvent) {
        if event.keyCode == 53 {
            finish(with: nil)
        }
    }

    private func present(_ content: ScreenshotSelectionContent) {
        closePanels()
        latestSample = nil
        latestSampleDisplayID = nil
        latestPoint = nil
        lastSampleStartedAt = nil

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
        completesOnSuccess: Bool = false
    ) {
        sampleTask?.cancel()
        let requestID = UUID()
        latestRequestID = requestID
        let captureService = captureService
        let delay: Duration
        if immediately {
            delay = .zero
        } else if let lastSampleStartedAt {
            let elapsed = lastSampleStartedAt.duration(to: ContinuousClock.now)
            delay = elapsed < minimumSampleInterval ? minimumSampleInterval - elapsed : .zero
        } else {
            delay = .zero
        }

        sampleTask = Task { @MainActor [weak self] in
            do {
                if delay > .zero { try await Task.sleep(for: delay) }
                guard let self, self.latestRequestID == requestID else { return }
                self.lastSampleStartedAt = ContinuousClock.now
                let sample = try await captureService.sampleColor(.init(
                    displayID: displayID,
                    desktopPoint: .init(x: point.x, y: point.y)
                ))
                try Task.checkCancellation()
                guard self.latestRequestID == requestID else { return }
                self.latestSample = sample
                self.latestSampleDisplayID = displayID
                self.latestPoint = point
                self.views[displayID]?.update(pointer: point, sample: sample)
                self.sampleAcceptedHandler?(displayID, point, sample)
                if completesOnSuccess { self.finish(with: sample.color) }
            } catch is CancellationError {
                return
            } catch let error as ScreenshotFeatureError where error == .cancelled {
                return
            } catch {
                guard let self, self.latestRequestID == requestID else { return }
                self.views[displayID]?.showError("无法读取屏幕颜色")
                NSSound.beep()
            }
        }
    }

    private func finish(with color: ScreenshotColor?) {
        sampleTask?.cancel()
        sampleTask = nil
        latestRequestID = nil
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
        errorMessage = nil
        needsDisplay = true
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
