import AppKit
import ScreenshotFeature

@MainActor
protocol ScreenshotSelectionPresenting: AnyObject, Sendable {
    func select(from content: ScreenshotSelectionContent) async -> ScreenshotSelectionResult?
    func cancel()
}

enum ScreenshotSelectionCompletionAction: Equatable, Sendable {
    case copy
    case save
    case pin
    case recognizeText
    case translate
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
        case annotationEndpoint(id: UUID, pointIndex: Int)
        case calloutBoxMove(id: UUID, lastPoint: CGPoint)
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
    private var pendingCalloutID: UUID?
    private var selectedAnnotationID: UUID?
    private var selectedSticker = SelectionSticker.smile.rawValue
    private var annotationOptions = SelectionAnnotationOptions()
    private let startsWithCommittedSelection: Bool
    private let completionActionOverride: ScreenshotSelectionCompletionAction?
    private let automaticallyCompletesOnMouseUp: Bool

    init(
        startsWithCommittedSelection: Bool = false,
        completionActionOverride: ScreenshotSelectionCompletionAction? = nil,
        automaticallyCompletesOnMouseUp: Bool = false
    ) {
        self.startsWithCommittedSelection = startsWithCommittedSelection
        self.completionActionOverride = completionActionOverride
        self.automaticallyCompletesOnMouseUp = automaticallyCompletesOnMouseUp
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
        if updatePendingCalloutEndpoint(to: point) {
            updateViews()
            return
        }
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
        if let selectedAnnotationID,
           let annotation = annotationHistory.annotations.first(where: { $0.id == selectedAnnotationID }),
           let pointIndex = annotation.editablePointIndex(at: point) {
            dragSession = .annotationEndpoint(id: selectedAnnotationID, pointIndex: pointIndex)
            toolbarStatus = annotation.kind == .callout ? "正在调整批注框大小" : "正在调整标注大小"
            updateViews()
            return
        }
        if let selectedAnnotationID,
           let annotation = annotationHistory.annotations.first(where: { $0.id == selectedAnnotationID }),
           annotation.containsCalloutBorder(point) {
            dragSession = .calloutBoxMove(id: selectedAnnotationID, lastPoint: point)
            toolbarStatus = "正在移动批注框"
            updateViews()
            return
        }
        if beginEditingSelectedCallout(on: displayID, at: point) {
            updateViews()
            return
        }
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
        case let .annotationEndpoint(id, pointIndex):
            if let selection {
                let clipped = CGPoint(
                    x: min(max(point.x, selection.minX), selection.maxX),
                    y: min(max(point.y, selection.minY), selection.maxY)
                )
                _ = annotationHistory.update(id: id) { annotation in
                    guard annotation.points.indices.contains(pointIndex) else { return }
                    annotation.points[pointIndex] = clipped
                    if annotation.kind == .sticker, let center = annotation.points.first {
                        let halfExtent = max(abs(clipped.x - center.x), abs(clipped.y - center.y))
                        annotation.sticker?.size = Double(min(160, max(14, halfExtent * 2)))
                    }
                }
            }
        case let .calloutBoxMove(id, lastPoint):
            if let selection {
                _ = annotationHistory.update(id: id) { annotation in
                    guard annotation.points.count >= 4 else { return }
                    let box = CGRect(
                        x: min(annotation.points[2].x, annotation.points[3].x),
                        y: min(annotation.points[2].y, annotation.points[3].y),
                        width: abs(annotation.points[3].x - annotation.points[2].x),
                        height: abs(annotation.points[3].y - annotation.points[2].y)
                    )
                    let requested = CGVector(dx: point.x - lastPoint.x, dy: point.y - lastPoint.y)
                    let dx = min(max(requested.dx, selection.minX - box.minX), selection.maxX - box.maxX)
                    let dy = min(max(requested.dy, selection.minY - box.minY), selection.maxY - box.maxY)
                    for index in 1...3 {
                        annotation.points[index].x += dx
                        annotation.points[index].y += dy
                    }
                }
                dragSession = .calloutBoxMove(id: id, lastPoint: point)
            }
        }
        updateViews()
    }

    func mouseUp() {
        if finishActiveAnnotation() {
            updateViews()
            return
        }
        if case .annotationEndpoint = dragSession {
            dragSession = nil
            isSelectionCommitted = true
            toolbarStatus = "标注大小与位置已更新"
            updateViews()
            return
        }
        if case .calloutBoxMove = dragSession {
            dragSession = nil
            isSelectionCommitted = true
            toolbarStatus = "批注框位置已更新"
            updateViews()
            return
        }
        let completedSelectionDrag = dragSession.map { session in
            switch session {
            case .create, .resize, .move, .snapped:
                true
            case .annotationEndpoint, .calloutBoxMove:
                false
            }
        } ?? false
        dragSession = nil
        isSelectionCommitted = selection.map { $0.width > 0 && $0.height > 0 } ?? false
        if automaticallyCompletesOnMouseUp, completedSelectionDrag, isSelectionCommitted {
            completeSelection()
            return
        }
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
        pendingCalloutID = nil
        selectedAnnotationID = nil

        for display in content.displays {
            guard let screen = screen(for: display.id) else { continue }
            let panel = SelectionOverlayPanel(
                contentRect: screen.frame,
                styleMask: [.borderless],
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
        discardPendingCallout()
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
            completionAction: completionActionOverride ?? action,
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
                annotationOptions: annotationOptions,
                annotations: annotationHistory.annotations,
                selectedAnnotationID: selectedAnnotationID
            )
            if isActive, !view.containsCurrentFirstResponder {
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
        annotationHistory.removeAll(where: { $0.kind == .watermark })
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

    func selectionToolbar(
        _ toolbar: SelectionToolbarView,
        didChange options: SelectionAnnotationOptions
    ) {
        annotationOptions = options
        for view in views.values {
            view.updateInlineTextStyle(fontSize: options.fontSize, color: options.color)
        }
        let editableIDs = Set([selectedAnnotationID, activeAnnotationID].compactMap { $0 })
        for editableID in editableIDs {
            _ = annotationHistory.update(id: editableID) { annotation in
                annotation.style.color = options.color
                switch annotation.kind {
                case .text, .note:
                    annotation.text?.fontSize = options.fontSize
                case .numberedMarker:
                    annotation.text?.fontSize = 14
                case .sticker:
                    annotation.sticker?.size = options.fontSize
                    if annotation.points.count >= 2, let center = annotation.points.first {
                        let half = CGFloat(options.fontSize) / 2
                        annotation.points[1] = CGPoint(x: center.x + half, y: center.y + half)
                    }
                case .callout:
                    annotation.style.color = .red
                    annotation.text?.fontSize = options.fontSize
                case .highlighter:
                    annotation.style.lineWidth = max(9, options.lineWidth)
                case .mosaic:
                    annotation.style.lineWidth = options.lineWidth * 3
                    annotation.mosaic?.blockSize = max(4, options.lineWidth * 2)
                default:
                    annotation.style.lineWidth = options.lineWidth
                }
                if annotation.kind == .callout,
                   let selection,
                   let rect = annotation.calloutBoxRect,
                   let text = annotation.text {
                    let size = SelectionCalloutLayout.size(
                        text: text.value,
                        fontSize: text.fontSize,
                        maximumSize: selection.size
                    )
                    let origin = CGPoint(
                        x: min(max(selection.minX, rect.minX), selection.maxX - size.width),
                        y: min(max(selection.minY, rect.minY), selection.maxY - size.height)
                    )
                    annotation.points[2] = origin
                    annotation.points[3] = CGPoint(x: origin.x + size.width, y: origin.y + size.height)
                }
            }
        }
        toolbarStatus = "标注样式已更新"
        updateViews()
    }

    private func selectionToolbarItemChosen(_ item: SelectionToolbarItem) {
        guard isSelectionCommitted else { return }
        if item != .cancel { commitInlineTextEditing() }
        if item != .callout { discardPendingCallout() }
        switch item {
        case .cancel:
            cancel()
        case .copy, .save, .pin, .recognizeText, .translate, .scrollingCapture, .gifRecording:
            if let action = item.selectionCompletionAction {
                completeSelection(action: action)
            }
        default:
            if item.isImplementedAnnotationTool {
                selectedToolbarItem = item
                if item == .numberedMarker {
                    toolbarStatus = "已选择“数字点”，请在选区内点击"
                } else if item == .callout {
                    toolbarStatus = "已选择“批注”，请点击定位点"
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

        if item == .callout {
            if let pendingCalloutID {
                _ = annotationHistory.update(id: pendingCalloutID) { annotation in
                    guard annotation.points.count >= 2 else { return }
                    annotation.points[1] = point
                }
                self.pendingCalloutID = nil
                selectedAnnotationID = pendingCalloutID
                guard views[displayID]?.beginTextEditing(
                    at: point,
                    kind: .callout,
                    fontSize: annotationOptions.fontSize,
                    color: .red,
                    completion: { [weak self] value, frame in
                        self?.finishCalloutAnnotation(
                            id: pendingCalloutID,
                            value: value,
                            frame: frame
                        )
                    }
                ) == true else {
                    annotationHistory.remove(id: pendingCalloutID)
                    selectedAnnotationID = nil
                    return false
                }
                toolbarStatus = "正在输入批注，Command+Return 完成"
                return true
            }

            let id = UUID()
            annotationHistory.add(.init(
                id: id,
                kind: .callout,
                points: [point, point],
                style: .init(color: .red, lineWidth: annotationOptions.lineWidth),
                text: .init(value: "", fontSize: annotationOptions.fontSize)
            ))
            pendingCalloutID = id
            selectedAnnotationID = id
            toolbarStatus = "已放置定位点，移动鼠标后再次点击放置批注框"
            return true
        }

        if item == .numberedMarker {
            let id = UUID()
            let number = annotationHistory.annotations.filter { $0.kind == .numberedMarker }.count + 1
            annotationHistory.add(.init(
                id: id,
                kind: .numberedMarker,
                points: [point],
                style: .init(color: annotationOptions.color, lineWidth: annotationOptions.lineWidth),
                text: .init(value: String(number), fontSize: 14)
            ))
            selectedAnnotationID = id
            toolbarStatus = "已添加数字点 \(number)"
            return true
        }


        if item == .sticker {
            annotationHistory.add(.init(
                kind: .sticker,
                points: [
                    point,
                    CGPoint(
                        x: point.x + CGFloat(max(14, annotationOptions.fontSize)) / 2,
                        y: point.y + CGFloat(max(14, annotationOptions.fontSize)) / 2
                    )
                ],
                style: .init(color: .red, lineWidth: 1),
                sticker: .init(value: selectedSticker, size: max(14, annotationOptions.fontSize))
            ))
            toolbarStatus = "已添加贴纸 \(selectedSticker)"
            return true
        }

        if item == .text || item == .note {
            let kind: ScreenshotAnnotationKind = item == .note ? .note : .text
            guard views[displayID]?.beginTextEditing(
                at: point,
                kind: kind,
                fontSize: annotationOptions.fontSize,
                color: annotationOptions.color,
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
            style = .init(color: annotationOptions.color, lineWidth: max(9, annotationOptions.lineWidth))
        case .mosaic:
            style = .init(color: annotationOptions.color, lineWidth: annotationOptions.lineWidth * 3)
        default:
            style = .init(color: annotationOptions.color, lineWidth: annotationOptions.lineWidth)
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
        selectedAnnotationID = nil
        toolbarStatus = "正在绘制“\(item.title)”"
        return true
    }

    private func beginEditingSelectedCallout(on displayID: UInt32, at point: CGPoint) -> Bool {
        guard let selectedAnnotationID,
              let annotation = annotationHistory.annotations.first(where: {
                  $0.id == selectedAnnotationID
              }),
              annotation.containsCalloutContent(point),
              let frame = annotation.calloutBoxRect,
              let text = annotation.text else { return false }
        guard views[displayID]?.beginTextEditing(
            at: point,
            kind: .callout,
            fontSize: text.fontSize,
            color: .red,
            initialValue: text.value,
            initialFrame: frame,
            completion: { [weak self] value, updatedFrame in
                self?.finishCalloutAnnotation(
                    id: selectedAnnotationID,
                    value: value,
                    frame: updatedFrame
                )
            }
        ) == true else { return false }
        toolbarStatus = "正在编辑批注，Command+Return 完成"
        return true
    }

    private func finishTextAnnotation(
        kind: ScreenshotAnnotationKind,
        value: String?,
        frame: CGRect
    ) {
        guard let value else {
            toolbarStatus = "已取消输入"
            updateViews()
            return
        }
        let points: [CGPoint] = kind == .note
            ? [frame.origin, CGPoint(x: frame.maxX, y: frame.maxY)]
            : [frame.origin]
        let id = UUID()
        annotationHistory.add(.init(
            id: id,
            kind: kind,
            points: points,
            style: .init(color: annotationOptions.color, lineWidth: annotationOptions.lineWidth),
            text: .init(value: value, fontSize: kind == .note ? 14 : annotationOptions.fontSize)
        ))
        selectedAnnotationID = id
        toolbarStatus = kind == .note ? "已添加备注" : "已添加文本"
        updateViews()
    }

    private func finishCalloutAnnotation(id: UUID, value: String?, frame: CGRect) {
        guard let value else {
            annotationHistory.remove(id: id)
            selectedAnnotationID = nil
            toolbarStatus = "已取消批注"
            updateViews()
            return
        }
        _ = annotationHistory.update(id: id) { annotation in
            let anchor = annotation.points.first ?? frame.origin
            let connector = annotation.points.dropFirst().first ?? frame.origin
            let fontSize = annotation.text?.fontSize ?? annotationOptions.fontSize
            annotation.points = [
                anchor,
                connector,
                frame.origin,
                CGPoint(x: frame.maxX, y: frame.maxY)
            ]
            annotation.text = .init(value: value, fontSize: fontSize)
            annotation.style.color = .red
        }
        selectedAnnotationID = id
        toolbarStatus = "已添加批注"
        updateViews()
    }

    private func commitInlineTextEditing() {
        for view in views.values { view.commitInlineTextEditing() }
    }

    private func updatePendingCalloutEndpoint(to point: CGPoint) -> Bool {
        guard let pendingCalloutID, let selection else { return false }
        let clipped = CGPoint(
            x: min(max(point.x, selection.minX), selection.maxX),
            y: min(max(point.y, selection.minY), selection.maxY)
        )
        return annotationHistory.update(id: pendingCalloutID) { annotation in
            guard annotation.points.count >= 2 else { return }
            annotation.points[1] = clipped
        }
    }

    private func discardPendingCallout() {
        guard let pendingCalloutID else { return }
        annotationHistory.remove(id: pendingCalloutID)
        if selectedAnnotationID == pendingCalloutID { selectedAnnotationID = nil }
        self.pendingCalloutID = nil
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
        if !isVisible {
            annotationHistory.remove(id: activeAnnotationID)
            selectedAnnotationID = nil
        } else {
            selectedAnnotationID = activeAnnotationID
        }
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
        case "c": .callout
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
