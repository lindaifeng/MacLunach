import AppKit
import ScreenshotFeature

@MainActor
protocol ScreenshotSelectionPresenting: AnyObject, Sendable {
    func select(from content: ScreenshotSelectionContent) async -> ScreenshotCaptureTarget?
    func cancel()
}

@MainActor
final class SelectionOverlayController: ScreenshotSelectionPresenting {
    private enum DragSession {
        case create(anchor: CGPoint)
        case resize(handle: SelectionHandle)
        case move(lastPoint: CGPoint)
        case snapped(anchor: CGPoint, match: WindowSnapMatch)
    }

    private var panels: [SelectionOverlayPanel] = []
    private var views: [UInt32: SelectionOverlayView] = [:]
    private var continuation: CheckedContinuation<ScreenshotCaptureTarget?, Never>?
    private var content = ScreenshotSelectionContent(displays: [], windows: [])
    private var resolver = WindowSnapResolver(windows: [])
    private var selection: CGRect?
    private var snappedWindow: WindowSnapMatch?
    private var activeDisplayID: UInt32?
    private var pointer = CGPoint.zero
    private var dragSession: DragSession?
    private var isSpacePressed = false

    func select(from content: ScreenshotSelectionContent) async -> ScreenshotCaptureTarget? {
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
        pointer = point
        guard dragSession == nil else {
            updateViews()
            return
        }
        // 已创建的区域仍归属于最初的显示器；仅仅把指针移到另一块屏幕
        // 不应改变 Enter 完成和方向键微调所使用的 displayID。
        guard selection == nil || snappedWindow != nil else {
            updateViews()
            return
        }
        activeDisplayID = displayID
        if let match = resolver.candidate(at: point) {
            selection = match.frame
            snappedWindow = match
        } else if snappedWindow != nil {
            selection = nil
            snappedWindow = nil
        }
        updateViews()
    }

    func mouseDown(on displayID: UInt32, at point: CGPoint) {
        pointer = point
        activeDisplayID = displayID
        if let match = snappedWindow {
            dragSession = .snapped(anchor: point, match: match)
            return
        }
        if isSpacePressed, selection != nil {
            dragSession = .move(lastPoint: point)
        } else if let selection,
           let handle = SelectionGeometry.handle(at: point, in: selection) {
            dragSession = .resize(handle: handle)
        } else {
            selection = SelectionGeometry.dragRect(
                from: point,
                to: point,
                in: bounds(for: displayID)
            )
            snappedWindow = nil
            dragSession = .create(anchor: point)
        }
        updateViews()
    }

    func mouseDragged(on displayID: UInt32, to point: CGPoint) {
        pointer = point
        guard let session = dragSession else { return }

        if isSpacePressed, selection != nil {
            switch session {
            case .move:
                break
            default:
                dragSession = .move(lastPoint: point)
                updateViews()
                return
            }
        }

        let displayBounds = bounds(for: activeDisplayID ?? displayID)
        switch session {
        case let .create(anchor):
            selection = SelectionGeometry.dragRect(from: anchor, to: point, in: displayBounds)
        case let .resize(handle):
            if let selection {
                self.selection = SelectionGeometry.resize(
                    selection,
                    handle: handle,
                    to: point,
                    in: displayBounds
                )
            }
        case let .move(lastPoint):
            if let selection {
                self.selection = SelectionGeometry.move(
                    selection,
                    by: CGVector(dx: point.x - lastPoint.x, dy: point.y - lastPoint.y),
                    in: displayBounds
                )
                dragSession = .move(lastPoint: point)
            }
        case let .snapped(anchor, match):
            if resolver.shouldReleaseSnap(from: anchor, to: point) {
                snappedWindow = nil
                selection = SelectionGeometry.dragRect(
                    from: anchor,
                    to: point,
                    in: displayBounds
                )
                dragSession = .create(anchor: anchor)
            } else {
                selection = match.frame
            }
        }
        updateViews()
    }

    func mouseUp() {
        dragSession = nil
        updateViews()
    }

    func keyDown(_ event: NSEvent) {
        switch event.keyCode {
        case 53:
            cancel()
        case 36, 52, 76:
            completeSelection()
        case 49:
            isSpacePressed = true
        case 123:
            nudge(.left, accelerated: event.modifierFlags.contains(.shift))
        case 124:
            nudge(.right, accelerated: event.modifierFlags.contains(.shift))
        case 125:
            nudge(.down, accelerated: event.modifierFlags.contains(.shift))
        case 126:
            nudge(.up, accelerated: event.modifierFlags.contains(.shift))
        default:
            break
        }
    }

    func keyUp(_ event: NSEvent) {
        if event.keyCode == 49 { isSpacePressed = false }
    }

    private func present(_ content: ScreenshotSelectionContent) {
        closePanels()
        self.content = content
        resolver = WindowSnapResolver(windows: content.windows)
        selection = nil
        snappedWindow = nil
        activeDisplayID = nil
        dragSession = nil
        isSpacePressed = false

        for display in content.displays {
            guard let screen = screen(for: display.id) else { continue }
            let panel = SelectionOverlayPanel(
                contentRect: screen.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false,
                screen: screen
            )
            let view = SelectionOverlayView(display: display, controller: self)
            panel.contentView = view
            panel.identifier = NSUserInterfaceItemIdentifier("screenshot.selection.overlay")
            panel.title = "screenshot.selection.overlay"
            panel.setAccessibilityIdentifier("screenshot.selection.overlay")
            panel.setAccessibilityLabel("截图区域选择")
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

        guard !panels.isEmpty else {
            finish(with: nil)
            return
        }

        let preferredID = content.displays.first(where: { $0.id == CGMainDisplayID() })?.id
            ?? content.displays.first?.id
        if let preferredID, let view = views[preferredID], let panel = view.window {
            activeDisplayID = preferredID
            panel.makeFirstResponder(view)
            panel.makeKey()
        }
    }

    private func completeSelection() {
        guard let selection, selection.width > 0, selection.height > 0 else { return }
        if let snappedWindow {
            finish(with: .window(windowID: snappedWindow.windowID))
            return
        }
        guard let displayID = activeDisplayID,
              bounds(for: displayID).intersects(selection) else { return }
        finish(with: .region(
            displayID: displayID,
            rect: ScreenshotRect(
                x: selection.minX,
                y: selection.minY,
                width: selection.width,
                height: selection.height
            )
        ))
    }

    private func nudge(_ direction: SelectionNudgeDirection, accelerated: Bool) {
        guard let selection, let displayID = activeDisplayID else { return }
        snappedWindow = nil
        self.selection = SelectionGeometry.nudge(
            selection,
            direction: direction,
            accelerated: accelerated,
            in: bounds(for: displayID)
        )
        updateViews()
    }

    private func finish(with target: ScreenshotCaptureTarget?) {
        guard let continuation else {
            closePanels()
            return
        }
        self.continuation = nil
        closePanels()
        continuation.resume(returning: target)
    }

    private func closePanels() {
        for panel in panels { panel.orderOut(nil) }
        panels.removeAll()
        views.removeAll()
    }

    private func updateViews() {
        for (displayID, view) in views {
            let isActive = displayID == activeDisplayID
            view.update(
                selection: selection,
                pointer: pointer,
                scaleFactor: scaleFactor(for: displayID),
                showsLabel: isActive
            )
            if isActive, view.window?.firstResponder !== view {
                view.window?.makeFirstResponder(view)
                view.window?.makeKey()
            }
        }
    }

    private func bounds(for displayID: UInt32) -> CGRect {
        guard let display = content.displays.first(where: { $0.id == displayID }) else { return .zero }
        return CGRect(
            x: display.frame.x,
            y: display.frame.y,
            width: display.frame.width,
            height: display.frame.height
        )
    }

    private func scaleFactor(for displayID: UInt32) -> CGFloat {
        CGFloat(content.displays.first(where: { $0.id == displayID })?.scaleFactor ?? 1)
    }

    private func screen(for displayID: UInt32) -> NSScreen? {
        NSScreen.screens.first { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                    as? NSNumber else { return false }
            return number.uint32Value == displayID
        }
    }
}

final class SelectionOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
