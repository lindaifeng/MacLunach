import AppKit
import ScreenshotFeature
import SwiftUI

/// 承载内建截图标注编辑器，并集中处理 AppKit 窗口生命周期和键盘命令。
@MainActor
final class AnnotationEditorController: NSWindowController, NSWindowDelegate {
    typealias ExportHandler = @MainActor (
        AnnotationDocument,
        URL,
        ScreenshotOutputOptions,
        Bool
    ) async throws -> Void
    typealias ExportSelection = (
        destination: URL,
        output: ScreenshotOutputOptions,
        allowsOverwrite: Bool
    )
    typealias ExportSelectionProvider = @MainActor (URL) -> ExportSelection?

    let artifact: ScreenshotArtifact
    let state: AnnotationEditorState

    private let sourceURL: URL
    private let exportHandler: ExportHandler
    private let exportSelectionProvider: ExportSelectionProvider?
    private let pasteboardWriter: ScreenshotPasteboardWriter
    private let onClose: (UUID) -> Void
    private var keyMonitor: Any?
    private var copyTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    private var isClosingAfterConfirmation = false
    private var isShowingCloseConfirmation = false

    convenience init(
        artifact: ScreenshotArtifact,
        sourceImage: NSImage,
        sourceURL: URL,
        document: AnnotationDocument? = nil,
        client: ScreenshotClient,
        themeStore: ThemeStore = ThemeStore(),
        pasteboardWriter: ScreenshotPasteboardWriter = ScreenshotPasteboardWriter(),
        onClose: @escaping (UUID) -> Void
    ) {
        self.init(
            artifact: artifact,
            sourceImage: sourceImage,
            sourceURL: sourceURL,
            document: document,
            themeStore: themeStore,
            saveProject: { document in
                _ = try await client.saveAnnotationProject(document)
            },
            exportDocument: { document, destination, output, allowsOverwrite in
                _ = try await client.exportAnnotationDocument(
                    document,
                    to: destination,
                    output: output,
                    allowsOverwrite: allowsOverwrite
                )
            },
            pasteboardWriter: pasteboardWriter,
            onClose: onClose
        )
    }

    init(
        artifact: ScreenshotArtifact,
        sourceImage: NSImage,
        sourceURL: URL,
        document: AnnotationDocument? = nil,
        themeStore: ThemeStore = ThemeStore(),
        saveProject: @escaping AnnotationEditorState.SaveHandler,
        exportDocument: @escaping ExportHandler,
        exportSelectionProvider: ExportSelectionProvider? = nil,
        pasteboardWriter: ScreenshotPasteboardWriter = ScreenshotPasteboardWriter(),
        onClose: @escaping (UUID) -> Void
    ) {
        self.artifact = artifact
        self.sourceURL = sourceURL
        self.exportHandler = exportDocument
        self.exportSelectionProvider = exportSelectionProvider
        self.pasteboardWriter = pasteboardWriter
        self.onClose = onClose
        state = AnnotationEditorState(
            artifact: artifact,
            document: document,
            save: saveProject
        )

        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1_080, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)

        window.title = "截图标注"
        window.identifier = NSUserInterfaceItemIdentifier(
            "screenshot.annotation.editor.\(artifact.id.uuidString)"
        )
        window.setAccessibilityLabel("截图标注编辑器")
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.minSize = NSSize(width: 820, height: 560)
        window.isMovableByWindowBackground = false
        window.contentViewController = NSHostingController(
            rootView: AnnotationEditorView(
                state: state,
                sourceImage: sourceImage,
                onCopy: { [weak self] in self?.copyRenderedImage() },
                onExport: { [weak self] in self?.presentExportPanel() }
            )
            .environmentObject(themeStore)
        )
        installWindowTopDragRegion(in: window)
        window.center()
        window.delegate = self
        installKeyMonitor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present() {
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if isClosingAfterConfirmation || state.closeRequirement == .closeImmediately {
            return true
        }
        guard !isShowingCloseConfirmation else { return false }
        guard !state.isSaving else {
            NSSound.beep()
            return false
        }
        presentUnsavedChangesAlert(in: sender)
        return false
    }

    func windowWillClose(_ notification: Notification) {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        copyTask?.cancel()
        copyTask = nil
        exportTask?.cancel()
        exportTask = nil
        onClose(artifact.id)
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            return self.handleKeyDown(event) ? nil : event
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let characters = event.charactersIgnoringModifiers?.lowercased()
        let firstResponder = window?.firstResponder
        let isEditingText = firstResponder is NSTextView
        let isEditingControl = responderConsumesPlainEditingKeys(firstResponder)

        if event.keyCode == 53, state.cancelPendingCrop() {
            return true
        }

        if flags.contains(.command), !flags.contains(.control), !flags.contains(.option) {
            if characters == "z" {
                guard !isEditingText else { return false }
                if flags.contains(.shift) {
                    _ = state.redo()
                } else {
                    _ = state.undo()
                }
                return true
            }
            if characters == "s", !flags.contains(.shift) {
                Task { await state.save() }
                return true
            }
            if characters == "s", flags.contains(.shift) {
                presentExportPanel()
                return true
            }
            if characters == "c", flags.contains(.shift) {
                guard !isEditingText else { return false }
                copyRenderedImage()
                return true
            }
        }

        if flags.contains(.option),
           !flags.contains(.command),
           !flags.contains(.control),
           !isEditingText {
            if characters == "[" {
                return state.selectPreviousLayer()
            }
            if characters == "]" {
                return state.selectNextLayer()
            }
        }

        guard !flags.contains(.command), !flags.contains(.control), !flags.contains(.option) else {
            return false
        }
        guard !isEditingControl else { return false }
        if !flags.contains(.shift),
           let characters,
           let tool = AnnotationEditorTool.allCases.first(where: {
               $0.keyboardShortcut == characters
           }) {
            state.selectedTool = tool
            return true
        }
        if event.keyCode == 51 || event.keyCode == 117 {
            do {
                return try state.deleteSelectedLayer()
            } catch {
                reportEditorError(error)
                return true
            }
        }

        let distance = flags.contains(.shift) ? 10.0 : 1.0
        let delta: (Double, Double)? = switch event.keyCode {
        case 123: (-distance, 0)
        case 124: (distance, 0)
        case 125: (0, distance)
        case 126: (0, -distance)
        default: nil
        }
        guard let delta else { return false }
        do {
            _ = try state.nudgeSelectedLayer(
                deltaX: delta.0,
                deltaY: delta.1,
                coalescingKey: "keyboard-nudge"
            )
        } catch {
            reportEditorError(error)
        }
        return true
    }

    /// SwiftUI 在 macOS 上会用不同的私有 NSControl 子类承载 Form 控件。除了公开
    /// 的 AppKit 类型外也检查类名，避免编辑器的全局方向键监听抢走 Slider、
    /// ColorPicker、Picker 等控件原本的键盘操作。
    private func responderConsumesPlainEditingKeys(_ responder: NSResponder?) -> Bool {
        guard let responder else { return false }
        if responder is NSTextView
            || responder is NSTextField
            || responder is NSSlider
            || responder is NSStepper
            || responder is NSPopUpButton
            || responder is NSColorWell {
            return true
        }

        let className = String(describing: type(of: responder)).lowercased()
        return ["textfield", "textview", "slider", "stepper", "popup", "colorwell", "picker"]
            .contains(where: className.contains)
    }

    private func presentUnsavedChangesAlert(in window: NSWindow) {
        isShowingCloseConfirmation = true
        let alert = NSAlert()
        alert.messageText = "要保存对此截图项目的修改吗？"
        alert.informativeText = "选择“不保存”会丢弃当前标注图层，但不会删除原始截图。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "不保存")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.isShowingCloseConfirmation = false
            switch response {
            case .alertFirstButtonReturn:
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if await self.state.resolveClose(choice: .save) == .close {
                        self.closeAfterConfirmation()
                    } else {
                        NSSound.beep()
                    }
                }
            case .alertSecondButtonReturn:
                self.closeAfterConfirmation()
            default:
                break
            }
        }
    }

    private func closeAfterConfirmation() {
        isClosingAfterConfirmation = true
        window?.performClose(nil)
    }

    private func presentExportPanel() {
        if let exportSelectionProvider {
            guard let selection = exportSelectionProvider(sourceURL) else { return }
            performExport(.init(
                document: state.document,
                destination: selection.destination,
                output: selection.output,
                allowsOverwrite: selection.allowsOverwrite
            ))
            return
        }

        let panel = NSSavePanel()
        let options = AnnotationExportOptions()
        panel.title = "导出标注截图"
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = options.suggestedFileName(for: sourceURL)
        panel.allowedContentTypes = [options.contentType]
        panel.accessoryView = NSHostingView(
            rootView: AnnotationExportAccessoryView(
                options: options,
                onFormatChange: { [weak panel, weak options] _ in
                    guard let panel, let options else { return }
                    panel.allowedContentTypes = [options.contentType]
                    panel.nameFieldStringValue = options.replacingExtension(
                        in: panel.nameFieldStringValue
                    )
                }
            )
        )
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        let output = options.outputOptions
        performExport(.init(
            document: state.document,
            destination: destination,
            output: output,
            allowsOverwrite: FileManager.default.fileExists(atPath: destination.path)
        ))
    }

    private func performExport(_ request: ExportRequest) {
        guard exportTask == nil else {
            NSSound.beep()
            return
        }
        exportTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { exportTask = nil }
            do {
                try await exportHandler(
                    request.document,
                    request.destination,
                    request.output,
                    request.allowsOverwrite
                )
                try Task.checkCancellation()
                NSSound(named: "Glass")?.play()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                presentExportError(error, request: request)
            }
        }
    }

    private func copyRenderedImage(document: AnnotationDocument? = nil) {
        guard copyTask == nil else {
            NSSound.beep()
            return
        }
        let document = document ?? state.document
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TouchAnnotationClipboard", isDirectory: true)
            .appendingPathComponent("\(artifact.id.uuidString)-\(UUID().uuidString).png")

        copyTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                try? FileManager.default.removeItem(at: temporaryURL)
                copyTask = nil
            }
            do {
                try await exportHandler(
                    document,
                    temporaryURL,
                    .init(format: .png, quality: 1),
                    false
                )
                try Task.checkCancellation()
                try pasteboardWriter.writeImage(at: temporaryURL)
                NSSound(named: "Glass")?.play()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                presentCopyError(error, document: document)
            }
        }
    }

    private func presentCopyError(_ error: Error, document: AnnotationDocument) {
        guard let window else {
            reportEditorError(error)
            return
        }
        let alert = NSAlert()
        alert.messageText = "复制标注截图失败"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .critical
        alert.addButton(withTitle: "重试")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.copyRenderedImage(document: document)
        }
    }

    private func presentExportError(_ error: Error, request: ExportRequest) {
        guard let window else {
            reportEditorError(error)
            return
        }
        let alert = NSAlert()
        alert.messageText = "导出标注截图失败"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .critical
        alert.addButton(withTitle: "重试")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.performExport(request)
        }
    }

    private func reportEditorError(_ error: Error) {
        NSSound.beep()
        NSLog("Annotation editor action failed: %@", error.localizedDescription)
    }

    private struct ExportRequest {
        let document: AnnotationDocument
        let destination: URL
        let output: ScreenshotOutputOptions
        let allowsOverwrite: Bool
    }
}
