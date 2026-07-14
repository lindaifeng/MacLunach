import AppKit
import ScreenshotFeature

@MainActor
final class FloatingThumbnailView: NSView, NSDraggingSource {
    var onRequestClose: (() -> Void)?

    private let artifact: ScreenshotArtifact
    private let imageView = NSImageView()
    private var sourceURL: URL
    private var actions: FloatingThumbnailActions
    private var interaction = FloatingThumbnailInteractionState()
    private var mouseDownPoint = CGPoint.zero
    private var singleClickTask: Task<Void, Never>?
    private var promiseDelegate: ScreenshotFilePromiseDelegate?

    init(
        artifact: ScreenshotArtifact,
        image: NSImage,
        sourceURL: URL,
        actions: FloatingThumbnailActions
    ) {
        self.artifact = artifact
        self.sourceURL = sourceURL
        self.actions = actions
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        layer?.borderColor = NSColor.white.withAlphaComponent(0.28).cgColor
        layer?.borderWidth = 1
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.82).cgColor

        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            imageView.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6)
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("截图缩略图，单击标注，双击钉住")
        setAccessibilityIdentifier("screenshot.floating-thumbnail.content")
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async {
            ScreenshotThumbnailPerformanceRecorder.shared.endAfterRenderedFrame()
        }
    }

    func update(image: NSImage, sourceURL: URL, actions: FloatingThumbnailActions) {
        imageView.image = image
        self.sourceURL = sourceURL
        self.actions = actions
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
        singleClickTask?.cancel()
        interaction.cancelPendingSingleClick()
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        interaction.pointerDown()
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let distance = hypot(point.x - mouseDownPoint.x, point.y - mouseDownPoint.y)
        guard interaction.pointerMoved(distance: distance) == .beginDrag else { return }
        singleClickTask?.cancel()
        beginFilePromiseDrag(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        switch interaction.pointerUp(clickCount: event.clickCount) {
        case .scheduleSingleClick:
            scheduleSingleClick()
        case .performDoubleClick:
            singleClickTask?.cancel()
            perform(actions.pin)
        case .none, .beginDrag:
            break
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        NSMenu.popUpContextMenu(contextMenu(), with: event, for: self)
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "c" {
            perform(actions.copy)
            return
        }
        switch event.keyCode {
        case 36, 49:
            perform(actions.annotate)
        case 51, 117:
            performAsync(actions.delete, closesAfterSuccess: true)
        case 53:
            onRequestClose?()
        default:
            super.keyDown(with: event)
        }
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    private func scheduleSingleClick() {
        singleClickTask?.cancel()
        singleClickTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(NSEvent.doubleClickInterval))
            guard !Task.isCancelled, var state = self?.interaction, state.consumeSingleClick() else { return }
            self?.interaction = state
            self?.perform(self?.actions.annotate)
        }
    }

    private func beginFilePromiseDrag(with event: NSEvent) {
        guard let export = actions.export else {
            NSSound.beep()
            return
        }
        let delegate = ScreenshotFilePromiseDelegate(
            artifact: artifact,
            fileName: sourceURL.lastPathComponent,
            export: export
        )
        promiseDelegate = delegate
        let provider = NSFilePromiseProvider(
            fileType: artifact.uniformTypeIdentifier,
            delegate: delegate
        )
        let draggingItem = NSDraggingItem(pasteboardWriter: provider)
        let previewSize = bounds.size
        draggingItem.setDraggingFrame(bounds, contents: imageView.image)
        let session = beginDraggingSession(with: [draggingItem], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .none
        if previewSize.width <= 0 || previewSize.height <= 0 {
            session.animatesToStartingPositionsOnCancelOrFail = false
        }
    }

    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        addItem(title: "保存", action: #selector(save), enabled: actions.save != nil, to: menu)
        addItem(title: "另存为…", action: #selector(saveAs), enabled: actions.export != nil, to: menu)
        menu.addItem(.separator())
        addItem(title: "文字识别", action: #selector(recognize), enabled: actions.recognize != nil, to: menu)
        addItem(title: "钉住截图", action: #selector(pin), enabled: actions.pin != nil, to: menu)
        addItem(title: "复制", action: #selector(copyImage), enabled: actions.copy != nil, to: menu)
        menu.addItem(.separator())
        addItem(title: "删除", action: #selector(deleteArtifact), enabled: actions.delete != nil, to: menu)
        return menu
    }

    private func addItem(title: String, action: Selector, enabled: Bool, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled
        menu.addItem(item)
    }

    @objc private func save() { performAsync(actions.save) }
    @objc private func saveAs() {
        guard let export = actions.export else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = sourceURL.lastPathComponent
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        performExport(export, destination: destination)
    }
    @objc private func recognize() { actions.recognize?(artifact) }
    @objc private func pin() { perform(actions.pin) }
    @objc private func copyImage() { perform(actions.copy) }
    @objc private func deleteArtifact() { performAsync(actions.delete, closesAfterSuccess: true) }

    private func perform(
        _ action: ((ScreenshotArtifact) throws -> Void)?,
        closesAfterSuccess: Bool = false
    ) {
        guard let action else { return }
        do {
            try action(artifact)
            if closesAfterSuccess { onRequestClose?() }
        } catch {
            NSSound.beep()
            NSLog("Floating thumbnail action failed: %@", error.localizedDescription)
        }
    }

    private func performAsync(
        _ action: FloatingThumbnailActions.AsyncAction?,
        closesAfterSuccess: Bool = false
    ) {
        guard let action else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await action(artifact)
                if closesAfterSuccess { onRequestClose?() }
            } catch {
                NSSound.beep()
                NSLog("Floating thumbnail action failed: %@", error.localizedDescription)
            }
        }
    }

    private func performExport(
        _ export: @escaping FloatingThumbnailActions.ExportAction,
        destination: URL
    ) {
        Task { [artifact] in
            do {
                _ = try await export(artifact, destination)
            } catch {
                await MainActor.run {
                    NSSound.beep()
                    NSLog("Floating thumbnail export failed: %@", error.localizedDescription)
                }
            }
        }
    }
}

private final class ScreenshotFilePromiseDelegate: NSObject, NSFilePromiseProviderDelegate, @unchecked Sendable {
    private final class CompletionBox: @unchecked Sendable {
        let completion: (Error?) -> Void

        init(_ completion: @escaping (Error?) -> Void) {
            self.completion = completion
        }
    }

    private let artifact: ScreenshotArtifact
    private let fileName: String
    private let export: FloatingThumbnailActions.ExportAction
    private let queue = OperationQueue()

    init(
        artifact: ScreenshotArtifact,
        fileName: String,
        export: @escaping FloatingThumbnailActions.ExportAction
    ) {
        self.artifact = artifact
        self.fileName = fileName
        self.export = export
        queue.maxConcurrentOperationCount = 1
        super.init()
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        fileName
    }

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        let artifact = artifact
        let destination = url.appendingPathComponent(fileName)
        let export = export
        let completion = CompletionBox(completionHandler)
        Task {
            do {
                _ = try await export(artifact, destination)
                completion.completion(nil)
            } catch {
                completion.completion(error)
            }
        }
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        queue
    }
}
