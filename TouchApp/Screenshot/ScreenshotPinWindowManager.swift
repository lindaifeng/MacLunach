import AppKit
import ScreenshotFeature

@MainActor
protocol ScreenshotPinPresenting: AnyObject {
    func pin(_ artifact: ScreenshotArtifact) throws
}

enum ScreenshotPinError: Error, Equatable {
    case imageUnreadable(relativePath: String)
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

    func pin(_ artifact: ScreenshotArtifact) throws {
        let imageURL = try pathsProvider().resolve(relativePath: artifact.relativePath)
        guard let image = NSImage(contentsOf: imageURL) else {
            throw ScreenshotPinError.imageUnreadable(relativePath: artifact.relativePath)
        }

        let controller = ScreenshotPinWindowController(
            artifactID: artifact.id,
            image: image,
            pointSize: artifact.pointSize
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

    init(artifactID: UUID, image: NSImage, pointSize: ScreenshotSize) {
        self.artifactID = artifactID

        let size = Self.initialSize(pointSize: pointSize, fallback: image.size)
        let panel = ScreenshotPinPanel(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        let contentView = ScreenshotPinImageView(image: image)
        panel.contentView = contentView
        panel.identifier = NSUserInterfaceItemIdentifier("screenshot.pin.\(artifactID.uuidString)")
        panel.title = "钉图"
        panel.setAccessibilityLabel("置顶截图")
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.minSize = CGSize(width: 80, height: 60)
        panel.maxSize = CGSize(width: 2_400, height: 2_400)
        panel.contentAspectRatio = size

        super.init(window: panel)
        panel.delegate = self
        contentView.onClose = { [weak panel] in panel?.close() }
        contentView.onCopy = { [weak contentView] in
            guard let image = contentView?.image else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            _ = pasteboard.writeObjects([image])
        }
        position(panel)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func windowWillClose(_ notification: Notification) {
        onClose?(artifactID)
    }

    private func position(_ panel: NSPanel) {
        guard let visibleFrame = NSScreen.main?.visibleFrame else {
            panel.center()
            return
        }
        let margin: CGFloat = 24
        let origin = CGPoint(
            x: visibleFrame.maxX - panel.frame.width - margin,
            y: visibleFrame.maxY - panel.frame.height - margin
        )
        panel.setFrameOrigin(origin)
    }

    private static func initialSize(pointSize: ScreenshotSize, fallback: CGSize) -> CGSize {
        let sourceWidth = CGFloat(pointSize.width.isFinite && pointSize.width > 0
            ? pointSize.width
            : Double(fallback.width))
        let sourceHeight = CGFloat(pointSize.height.isFinite && pointSize.height > 0
            ? pointSize.height
            : Double(fallback.height))
        guard sourceWidth > 0, sourceHeight > 0 else {
            return CGSize(width: 320, height: 200)
        }
        let maximum = CGSize(width: 640, height: 480)
        let scale = min(1, maximum.width / sourceWidth, maximum.height / sourceHeight)
        return CGSize(
            width: max(80, sourceWidth * scale),
            height: max(60, sourceHeight * scale)
        )
    }
}

private final class ScreenshotPinPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class ScreenshotPinImageView: NSImageView {
    var onCopy: (() -> Void)?
    var onClose: (() -> Void)?

    init(image: NSImage) {
        super.init(frame: .zero)
        self.image = image
        imageScaling = .scaleProportionallyUpOrDown
        imageAlignment = .alignCenter
        setAccessibilityLabel("钉住的截图")
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        let copy = NSMenuItem(title: "复制", action: #selector(copyImage), keyEquivalent: "")
        copy.target = self
        menu.addItem(copy)
        menu.addItem(.separator())
        let close = NSMenuItem(title: "关闭钉图", action: #selector(closePin), keyEquivalent: "")
        close.target = self
        menu.addItem(close)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func copyImage() {
        onCopy?()
    }

    @objc private func closePin() {
        onClose?()
    }
}
