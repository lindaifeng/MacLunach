import AppKit
import ScreenshotFeature

@MainActor
protocol ScreenshotSelectionPresenting: AnyObject, Sendable {
    func select(from content: ScreenshotSelectionContent) async -> ScreenshotSelectionResult?
    func cancel()
}

enum ScreenshotSelectionCompletionAction: Equatable, Sendable {
    case copy
    case pin
    case recognizeText
    case scrollingCapture
    case gifRecording
}

struct ScreenshotSelectionResult: Equatable, Sendable {
    var target: ScreenshotCaptureTarget
    var completionAction: ScreenshotSelectionCompletionAction
    var windowShadow: ScreenshotWindowShadow
    var annotations: [ScreenshotAnnotation] = []
}

@MainActor
final class SelectionOverlayController: ScreenshotSelectionPresenting, SelectionToolbarViewDelegate {
    private enum DragSession {
        case create(anchor: CGPoint)
        case resize(handle: SelectionHandle)
        case move(lastPoint: CGPoint)
        case snapped(anchor: CGPoint, match: WindowSnapMatch)
    }

    private var panels: [SelectionOverlayPanel] = []
    private var views: [UInt32: SelectionOverlayView] = [:]
    private var continuation: CheckedContinuation<ScreenshotSelectionResult?, Never>?
    private var content = ScreenshotSelectionContent(displays: [], windows: [])
    private var resolver = WindowSnapResolver(windows: [])
    private var selection: CGRect?
    private var snappedWindow: WindowSnapMatch?
    private var activeDisplayID: UInt32?
    private var pointer = CGPoint.zero
    private var dragSession: DragSession?
    private var isSpacePressed = false
    private var isSelectionCommitted = false
    private var selectedToolbarItem: SelectionToolbarItem?
    private var windowShadowIncluded = true
    private var toolbarStatus = ""
    private var annotationHistory = SelectionAnnotationHistory()
    private var activeAnnotationID: UUID?
    private var selectedSticker = SelectionSticker.smile.rawValue
    private let startsWithCommittedSelection: Bool

    init(startsWithCommittedSelection: Bool = false) {
        self.startsWithCommittedSelection = startsWithCommittedSelection
    }

    func select(from content: ScreenshotSelectionContent) async -> ScreenshotSelectionResult? {
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
        if beginAnnotation(on: displayID, at: point) {
            updateViews()
            return
        }
        if isSelectionCommitted,
           selection?.contains(point) == true,
           selectedToolbarItem != nil {
            toolbarStatus = "该工具暂未完成，选区保持不变"
            updateViews()
            return
        }
        isSelectionCommitted = false
        toolbarStatus = ""
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
        if updateActiveAnnotation(to: point) {
            updateViews()
            return
        }
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
        if finishActiveAnnotation() {
            updateViews()
            return
        }
        dragSession = nil
        isSelectionCommitted = selection.map { $0.width > 0 && $0.height > 0 } ?? false
        updateViews()
    }

    func keyDown(_ event: NSEvent) {
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "z" {
            if event.modifierFlags.contains(.shift) {
                redoAnnotation()
            } else {
                undoAnnotation()
            }
            return
        }
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
            if let item = toolbarItem(for: event) {
                selectionToolbarItemChosen(item)
            }
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
        isSelectionCommitted = false
        selectedToolbarItem = nil
        windowShadowIncluded = true
        toolbarStatus = ""
        annotationHistory.reset()
        activeAnnotationID = nil

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
            if startsWithCommittedSelection {
                let displayBounds = bounds(for: preferredID)
                selection = CGRect(
                    x: displayBounds.minX + displayBounds.width * 0.18,
                    y: displayBounds.minY + displayBounds.height * 0.2,
                    width: displayBounds.width * 0.56,
                    height: displayBounds.height * 0.46
                )
                pointer = CGPoint(x: selection?.maxX ?? 0, y: selection?.maxY ?? 0)
                isSelectionCommitted = true
                updateViews()
            }
            panel.makeFirstResponder(view)
            panel.makeKey()
        }
    }

    private func completeSelection(action: ScreenshotSelectionCompletionAction = .copy) {
        commitInlineTextEditing()
        guard let selection, selection.width > 0, selection.height > 0 else { return }
        let target: ScreenshotCaptureTarget
        if let snappedWindow {
            target = .window(windowID: snappedWindow.windowID)
        } else {
            guard let displayID = activeDisplayID,
                  bounds(for: displayID).intersects(selection) else { return }
            let displayBounds = bounds(for: displayID)
            if SelectionGeometry.covers(selection, displayBounds) {
                target = .display(displayID: displayID)
            } else {
                target = .region(
                    displayID: displayID,
                    rect: ScreenshotRect(
                        x: selection.minX,
                        y: selection.minY,
                        width: selection.width,
                        height: selection.height
                    )
                )
            }
        }
        finish(with: ScreenshotSelectionResult(
            target: target,
            completionAction: action,
            windowShadow: windowShadowIncluded ? .included : .excluded,
            annotations: annotationHistory.annotations.map { $0.captureAnnotation(relativeTo: selection) }
        ))
    }

    private func nudge(_ direction: SelectionNudgeDirection, accelerated: Bool) {
        guard let selection, let displayID = activeDisplayID else { return }
        snappedWindow = nil
        isSelectionCommitted = true
        self.selection = SelectionGeometry.nudge(
            selection,
            direction: direction,
            accelerated: accelerated,
            in: bounds(for: displayID)
        )
        updateViews()
    }

    private func finish(with result: ScreenshotSelectionResult?) {
        guard let continuation else {
            closePanels()
            return
        }
        self.continuation = nil
        closePanels()
        continuation.resume(returning: result)
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
                showsLabel: isActive,
                showsToolbar: isActive && isSelectionCommitted && dragSession == nil,
                selectedToolbarItem: selectedToolbarItem,
                windowShadowIncluded: windowShadowIncluded,
                showsWindowShadow: snappedWindow != nil,
                toolbarStatus: toolbarStatus,
                annotations: annotationHistory.annotations
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

    func selectionToolbar(_ toolbar: SelectionToolbarView, didChoose item: SelectionToolbarItem) {
        selectionToolbarItemChosen(item)
    }

    func selectionToolbar(_ toolbar: SelectionToolbarView, didChooseSticker value: String) {
        guard isSelectionCommitted else { return }
        commitInlineTextEditing()
        selectedSticker = value
        selectedToolbarItem = .sticker
        toolbarStatus = "已选择贴纸 \(value)，请在选区内点击"
        updateViews()
    }

    func selectionToolbar(_ toolbar: SelectionToolbarView, didChooseWatermark value: String) {
        guard isSelectionCommitted, let selection else { return }
        commitInlineTextEditing()
        annotationHistory.add(.init(
            kind: .watermark,
            points: [selection.origin, CGPoint(x: selection.maxX, y: selection.maxY)],
            style: .init(color: .red, lineWidth: 1),
            watermark: .init(
                value: value,
                fontSize: 16,
                opacity: 0.22,
                angleDegrees: -24,
                spacing: 72
            )
        ))
        selectedToolbarItem = nil
        toolbarStatus = "已添加“\(value)”水印，可用 Command+Z 撤销"
        updateViews()
    }

    func selectionToolbar(
        _ toolbar: SelectionToolbarView,
        didChooseBeautify preset: SelectionBeautifyPreset
    ) {
        guard isSelectionCommitted, let selection else { return }
        commitInlineTextEditing()
        annotationHistory.add(.init(
            kind: .beautify,
            points: [selection.origin, CGPoint(x: selection.maxX, y: selection.maxY)],
            style: .init(color: .red, lineWidth: 1),
            beautify: preset.style
        ))
        selectedToolbarItem = nil
        toolbarStatus = "已应用“\(preset.title)”美化，可用 Command+Z 撤销"
        updateViews()
    }

    func selectionToolbar(
        _ toolbar: SelectionToolbarView,
        setWindowShadowIncluded included: Bool
    ) {
        windowShadowIncluded = included
        toolbarStatus = included ? "已保留窗口阴影" : "已去除窗口阴影"
        updateViews()
    }

    private func selectionToolbarItemChosen(_ item: SelectionToolbarItem) {
        guard isSelectionCommitted else { return }
        if item != .cancel { commitInlineTextEditing() }
        switch item {
        case .cancel:
            cancel()
        case .copy, .pin, .recognizeText, .scrollingCapture, .gifRecording:
            if let action = item.selectionCompletionAction {
                completeSelection(action: action)
            }
        default:
            if item.isImplementedAnnotationTool {
                selectedToolbarItem = selectedToolbarItem == item ? nil : item
                if selectedToolbarItem == nil {
                    toolbarStatus = "已退出“\(item.title)”"
                } else if item == .numberedMarker {
                    toolbarStatus = "已选择“数字点”，请在选区内点击"
                } else if item == .text || item == .note {
                    toolbarStatus = "已选择“\(item.title)”，请在选区内点击并输入"
                } else {
                    toolbarStatus = "已选择“\(item.title)”，请在选区内拖动"
                }
            } else {
                selectedToolbarItem = item
                toolbarStatus = "“\(item.title)”正在接入"
            }
            updateViews()
        }
    }

    private func beginAnnotation(on displayID: UInt32, at point: CGPoint) -> Bool {
        guard isSelectionCommitted,
              let selection,
              selection.contains(point),
              let item = selectedToolbarItem else { return false }

        if item == .numberedMarker {
            let number = annotationHistory.annotations.filter { $0.kind == .numberedMarker }.count + 1
            annotationHistory.add(.init(
                kind: .numberedMarker,
                points: [point],
                style: .init(color: .red, lineWidth: 2),
                text: .init(value: String(number), fontSize: 15)
            ))
            toolbarStatus = "已添加数字点 \(number)"
            return true
        }


        if item == .sticker {
            annotationHistory.add(.init(
                kind: .sticker,
                points: [point],
                style: .init(color: .red, lineWidth: 1),
                sticker: .init(value: selectedSticker, size: 36)
            ))
            toolbarStatus = "已添加贴纸 \(selectedSticker)"
            return true
        }

        if item == .text || item == .note {
            let kind: ScreenshotAnnotationKind = item == .note ? .note : .text
            guard views[displayID]?.beginTextEditing(
                at: point,
                kind: kind,
                completion: { [weak self] value, frame in
                    self?.finishTextAnnotation(kind: kind, value: value, frame: frame)
                }
            ) == true else { return false }
            toolbarStatus = kind == .note
                ? "正在输入备注，Command+Return 完成"
                : "正在输入文本，Return 完成"
            return true
        }

        guard let kind = item.drawableAnnotationKind else { return false }
        let style: ScreenshotAnnotationStyle
        switch kind {
        case .highlighter:
            style = .init(color: .yellow, lineWidth: 14)
        case .mosaic:
            style = .init(color: .red, lineWidth: 28)
        default:
            style = .init(color: .red, lineWidth: 3)
        }
        let id = UUID()
        let points = kind == .freehand || kind == .highlighter || kind == .mosaic
            ? [point]
            : [point, point]
        annotationHistory.add(.init(
            id: id,
            kind: kind,
            points: points,
            style: style,
            mosaic: kind == .mosaic ? .init(blockSize: 9) : nil
        ))
        activeAnnotationID = id
        toolbarStatus = "正在绘制“\(item.title)”"
        return true
    }

    private func finishTextAnnotation(
        kind: ScreenshotAnnotationKind,
        value: String,
        frame: CGRect
    ) {
        let points: [CGPoint] = kind == .note
            ? [frame.origin, CGPoint(x: frame.maxX, y: frame.maxY)]
            : [frame.origin]
        annotationHistory.add(.init(
            kind: kind,
            points: points,
            style: .init(color: .red, lineWidth: 2),
            text: .init(value: value, fontSize: kind == .note ? 14 : 18)
        ))
        toolbarStatus = kind == .note ? "已添加备注" : "已添加文本"
        updateViews()
    }

    private func commitInlineTextEditing() {
        for view in views.values { view.commitInlineTextEditing() }
    }

    private func updateActiveAnnotation(to point: CGPoint) -> Bool {
        guard let activeAnnotationID,
              let selection,
              annotationHistory.annotations.contains(where: { $0.id == activeAnnotationID }) else {
            return false
        }
        let clipped = CGPoint(
            x: min(max(point.x, selection.minX), selection.maxX),
            y: min(max(point.y, selection.minY), selection.maxY)
        )
        return annotationHistory.update(id: activeAnnotationID) { annotation in
            switch annotation.kind {
            case .freehand, .highlighter, .mosaic:
                if let last = annotation.points.last,
                   hypot(last.x - clipped.x, last.y - clipped.y) >= 0.75 {
                    annotation.points.append(clipped)
                }
            default:
                if annotation.points.count == 1 {
                    annotation.points.append(clipped)
                } else {
                    annotation.points[annotation.points.count - 1] = clipped
                }
            }
        }
    }

    private func finishActiveAnnotation() -> Bool {
        guard let activeAnnotationID,
              let annotation = annotationHistory.annotations.first(where: { $0.id == activeAnnotationID }) else {
            return false
        }
        let isVisible: Bool
        if let first = annotation.points.first, let last = annotation.points.last {
            isVisible = annotation.points.count >= 2 && hypot(first.x - last.x, first.y - last.y) >= 1
        } else {
            isVisible = false
        }
        if !isVisible { annotationHistory.remove(id: activeAnnotationID) }
        self.activeAnnotationID = nil
        isSelectionCommitted = true
        toolbarStatus = isVisible ? "已添加“\(selectedToolbarItem?.title ?? "标注")”" : "未创建标注"
        return true
    }

    private func undoAnnotation() {
        guard activeAnnotationID == nil, annotationHistory.undo() != nil else { return }
        toolbarStatus = "已撤销标注"
        updateViews()
    }

    private func redoAnnotation() {
        guard activeAnnotationID == nil, annotationHistory.redo() != nil else { return }
        toolbarStatus = "已重做标注"
        updateViews()
    }

    private func toolbarItem(for event: NSEvent) -> SelectionToolbarItem? {
        guard isSelectionCommitted,
              let key = event.charactersIgnoringModifiers?.lowercased() else { return nil }
        return switch key {
        case "r": .rectangle
        case "o": .ellipse
        case "l": .line
        case "t": .text
        case "1": .numberedMarker
        case "n": .note
        case "p": .pin
        default: nil
        }
    }
}

final class SelectionOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
