import AppKit
import ScreenshotFeature

struct ScreenshotPostCapturePolicy: Equatable {
    var copiesToClipboard: Bool
    var showsThumbnail: Bool
    var beginsAnnotation: Bool

    init(copiesToClipboard: Bool, showsThumbnail: Bool, beginsAnnotation: Bool) {
        self.copiesToClipboard = copiesToClipboard
        self.showsThumbnail = showsThumbnail
        self.beginsAnnotation = beginsAnnotation
    }

    init(configuration: ScreenshotFeatureConfiguration) {
        switch configuration.afterCaptureAction {
        case .copyAndShowThumbnail:
            copiesToClipboard = true
            showsThumbnail = configuration.showsFloatingThumbnail
            beginsAnnotation = false
        case .saveOnly:
            copiesToClipboard = false
            showsThumbnail = false
            beginsAnnotation = false
        case .copyAndSave:
            copiesToClipboard = true
            showsThumbnail = false
            beginsAnnotation = false
        case .annotate:
            copiesToClipboard = false
            showsThumbnail = false
            beginsAnnotation = true
        }
    }
}

extension ScreenshotThumbnailTimeout {
    var floatingThumbnailDelay: TimeInterval? {
        switch self {
        case let .seconds(value): TimeInterval(max(0, value))
        case .never: nil
        }
    }
}

enum FloatingThumbnailInteractionEffect: Equatable {
    case none
    case scheduleSingleClick
    case performDoubleClick
    case beginDrag
}

struct FloatingThumbnailInteractionState: Equatable {
    private(set) var isDragging = false
    private(set) var hasPendingSingleClick = false

    mutating func pointerDown() {
        isDragging = false
    }

    mutating func pointerMoved(distance: CGFloat, threshold: CGFloat = 4) -> FloatingThumbnailInteractionEffect {
        guard !isDragging, distance >= threshold else { return .none }
        isDragging = true
        hasPendingSingleClick = false
        return .beginDrag
    }

    mutating func pointerUp(clickCount: Int) -> FloatingThumbnailInteractionEffect {
        guard !isDragging else {
            isDragging = false
            return .none
        }
        if clickCount >= 2 {
            hasPendingSingleClick = false
            return .performDoubleClick
        }
        hasPendingSingleClick = true
        return .scheduleSingleClick
    }

    mutating func consumeSingleClick() -> Bool {
        guard hasPendingSingleClick else { return false }
        hasPendingSingleClick = false
        return true
    }

    mutating func cancelPendingSingleClick() {
        hasPendingSingleClick = false
    }
}

struct FloatingThumbnailLayout {
    static let margin: CGFloat = 18
    static let spacing: CGFloat = 12
    static let maximumContentSize = CGSize(width: 280, height: 180)
    static let minimumContentSize = CGSize(width: 120, height: 72)

    static func panelSize(for sourceSize: CGSize) -> CGSize {
        guard sourceSize.width.isFinite,
              sourceSize.height.isFinite,
              sourceSize.width > 0,
              sourceSize.height > 0 else {
            return CGSize(width: 240, height: 150)
        }
        let scale = min(
            maximumContentSize.width / sourceSize.width,
            maximumContentSize.height / sourceSize.height,
            1
        )
        let size = CGSize(
            width: min(maximumContentSize.width, max(minimumContentSize.width, sourceSize.width * scale)),
            height: min(maximumContentSize.height, max(minimumContentSize.height, sourceSize.height * scale))
        )
        return CGSize(width: round(size.width), height: round(size.height))
    }

    static func frame(
        contentSize: CGSize,
        visibleFrame: CGRect,
        verticalOffset: CGFloat
    ) -> CGRect {
        let size = panelSize(for: contentSize)
        let desiredY = visibleFrame.minY + margin
            + max(0, verticalOffset)
        let maximumY = max(visibleFrame.minY + margin, visibleFrame.maxY - size.height - margin)
        let origin = CGPoint(
            x: max(visibleFrame.minX + margin, visibleFrame.maxX - size.width - margin),
            y: min(desiredY, maximumY)
        )
        return CGRect(origin: origin, size: size)
    }
}

@MainActor
struct FloatingThumbnailActions {
    typealias AsyncAction = @MainActor (ScreenshotArtifact) async throws -> Void
    typealias ExportAction = @Sendable (ScreenshotArtifact, URL) async throws -> URL

    var annotate: ((ScreenshotArtifact) throws -> Void)?
    var pin: ((ScreenshotArtifact) throws -> Void)?
    var copy: ((ScreenshotArtifact) throws -> Void)?
    var recognize: ((ScreenshotArtifact) -> Void)?
    var save: AsyncAction?
    var export: ExportAction?
    var delete: AsyncAction?

    init(
        annotate: ((ScreenshotArtifact) throws -> Void)? = nil,
        pin: ((ScreenshotArtifact) throws -> Void)? = nil,
        copy: ((ScreenshotArtifact) throws -> Void)? = nil,
        recognize: ((ScreenshotArtifact) -> Void)? = nil,
        save: AsyncAction? = nil,
        export: ExportAction? = nil,
        delete: AsyncAction? = nil
    ) {
        self.annotate = annotate
        self.pin = pin
        self.copy = copy
        self.recognize = recognize
        self.save = save
        self.export = export
        self.delete = delete
    }
}

@MainActor
protocol ScreenshotFloatingThumbnailPresenting: AnyObject {
    func present(
        artifact: ScreenshotArtifact,
        timeout: ScreenshotThumbnailTimeout,
        actions: FloatingThumbnailActions
    )
    func dismissAll()
}

@MainActor
final class FloatingThumbnailController: ScreenshotFloatingThumbnailPresenting {
    typealias PathsProvider = () throws -> ScreenshotFeaturePaths

    private let pathsProvider: PathsProvider
    private var windows: [UUID: FloatingThumbnailWindowController] = [:]
    private var dismissalTasks: [UUID: Task<Void, Never>] = [:]

    init(pathsProvider: @escaping PathsProvider = { try ScreenshotFeaturePaths.applicationSupport() }) {
        self.pathsProvider = pathsProvider
    }

    func present(
        artifact: ScreenshotArtifact,
        timeout: ScreenshotThumbnailTimeout,
        actions: FloatingThumbnailActions
    ) {
        do {
            let paths = try pathsProvider()
            let imageURL = try paths.resolve(
                relativePath: artifact.thumbnailRelativePath ?? artifact.relativePath
            )
            let sourceURL = try paths.resolve(relativePath: artifact.relativePath)
            guard let image = NSImage(contentsOf: imageURL) else {
                throw ScreenshotClipboardError.imageUnreadable(relativePath: imageURL.path)
            }

            dismissalTasks[artifact.id]?.cancel()
            if let existing = windows[artifact.id] {
                existing.update(image: image, sourceURL: sourceURL, actions: actions)
                existing.showWindow(nil)
                scheduleDismissal(of: artifact.id, timeout: timeout)
                return
            }

            let controller = FloatingThumbnailWindowController(
                artifact: artifact,
                image: image,
                sourceURL: sourceURL,
                actions: actions,
                onClose: { [weak self] id in self?.remove(id: id) }
            )
            windows[artifact.id] = controller
            repositionWindows()
            controller.showWindow(nil)
            controller.window?.orderFrontRegardless()
            scheduleDismissal(of: artifact.id, timeout: timeout)
        } catch {
            ScreenshotThumbnailPerformanceRecorder.shared.cancel()
            NSLog("Unable to show floating screenshot thumbnail: %@", error.localizedDescription)
        }
    }

    func dismissAll() {
        let current = Array(windows.values)
        dismissalTasks.values.forEach { $0.cancel() }
        dismissalTasks.removeAll()
        windows.removeAll()
        current.forEach { $0.close() }
    }

    private func scheduleDismissal(of id: UUID, timeout: ScreenshotThumbnailTimeout) {
        dismissalTasks[id]?.cancel()
        guard let delay = timeout.floatingThumbnailDelay else { return }
        if delay == 0 {
            windows[id]?.close()
            return
        }
        dismissalTasks[id] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.windows[id]?.close()
        }
    }

    private func remove(id: UUID) {
        dismissalTasks.removeValue(forKey: id)?.cancel()
        windows.removeValue(forKey: id)
        repositionWindows()
    }

    private func repositionWindows() {
        let ordered = windows.values.sorted { $0.artifact.createdAt < $1.artifact.createdAt }
        var verticalOffsetsByScreen: [ObjectIdentifier: CGFloat] = [:]
        for controller in ordered {
            let screen = screen(for: controller.artifact) ?? NSScreen.main ?? NSScreen.screens.first
            guard let screen else { continue }
            let key = ObjectIdentifier(screen)
            let verticalOffset = verticalOffsetsByScreen[key, default: 0]
            let panelSize = FloatingThumbnailLayout.panelSize(for: controller.artifactPointSize)
            let frame = FloatingThumbnailLayout.frame(
                contentSize: controller.artifactPointSize,
                visibleFrame: screen.visibleFrame,
                verticalOffset: verticalOffset
            )
            verticalOffsetsByScreen[key] = verticalOffset + panelSize.height + FloatingThumbnailLayout.spacing
            controller.window?.setFrame(frame, display: true, animate: windows.count > 1)
        }
    }

    private func screen(for artifact: ScreenshotArtifact) -> NSScreen? {
        let ids = Set(artifact.displays.map(\.id))
        return NSScreen.screens.first { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return false
            }
            return ids.contains(number.uint32Value)
        }
    }
}

@MainActor
private final class FloatingThumbnailWindowController: NSWindowController, NSWindowDelegate {
    let artifact: ScreenshotArtifact
    let artifactPointSize: CGSize
    private let thumbnailView: FloatingThumbnailView
    private let onClose: (UUID) -> Void

    init(
        artifact: ScreenshotArtifact,
        image: NSImage,
        sourceURL: URL,
        actions: FloatingThumbnailActions,
        onClose: @escaping (UUID) -> Void
    ) {
        self.artifact = artifact
        artifactPointSize = CGSize(width: artifact.pointSize.width, height: artifact.pointSize.height)
        self.onClose = onClose
        thumbnailView = FloatingThumbnailView(
            artifact: artifact,
            image: image,
            sourceURL: sourceURL,
            actions: actions
        )
        let panel = FloatingThumbnailPanel(
            contentRect: .init(origin: .zero, size: FloatingThumbnailLayout.panelSize(for: artifactPointSize)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = thumbnailView
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.setAccessibilityLabel("截图缩略图")
        panel.setAccessibilityIdentifier("screenshot.floating-thumbnail")
        super.init(window: panel)
        panel.delegate = self
        thumbnailView.onRequestClose = { [weak panel] in panel?.close() }
    }

    required init?(coder: NSCoder) { nil }

    func update(image: NSImage, sourceURL: URL, actions: FloatingThumbnailActions) {
        thumbnailView.update(image: image, sourceURL: sourceURL, actions: actions)
    }

    func windowWillClose(_ notification: Notification) {
        onClose(artifact.id)
    }
}

private final class FloatingThumbnailPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
