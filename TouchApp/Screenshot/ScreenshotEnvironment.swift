import AppKit
import CoreGraphics
import CryptoKit
import ImageIO
import ScreenCaptureKit
import ScreenshotFeature
import SwiftUI
import TouchFeatureAPI
import UniformTypeIdentifiers

@MainActor
final class ScreenshotEnvironment: ObservableObject {
    @Published private(set) var permissionState: ScreenshotPermissionState

    let coordinator: ScreenshotCoordinator

    init(
        defaults: UserDefaults = .standard,
        themeStore: ThemeStore? = nil,
        authorization: (any ScreenRecordingAuthorizing)? = nil,
        captureService: (any ScreenshotCapturing)? = nil,
        clipboardWriter: (any ScreenshotClipboardWriting)? = nil,
        annotationPresenter: (any ScreenshotArtifactAnnotationPresenting)? = nil,
        floatingThumbnailPresenter: (any ScreenshotFloatingThumbnailPresenting)? = nil,
        configurationProvider: ScreenshotCoordinator.ConfigurationProvider? = nil,
        client: ScreenshotClient = ScreenshotClient(),
        selectionFactory: @escaping ScreenshotCoordinator.SelectionFactory = {
            SelectionOverlayController()
        },
        registerShortcuts: @escaping ScreenshotCoordinator.ShortcutAction = {},
        unregisterShortcuts: @escaping ScreenshotCoordinator.ShortcutAction = {}
    ) {
        let authorizer = authorization ?? SystemScreenRecordingAuthorizer(defaults: defaults)
        let captureService = captureService ?? XPCScreenCaptureService(client: client)
        let resolvedClipboardWriter = clipboardWriter ?? ScreenshotPasteboardWriter()
        let extensionPasteboardWriter = ScreenshotPasteboardWriter()
        permissionState = authorizer.status
        coordinator = ScreenshotCoordinator(
            authorization: authorizer,
            captureService: captureService,
            clipboardWriter: resolvedClipboardWriter,
            annotationPresenter: annotationPresenter
                ?? BuiltInScreenshotArtifactAnnotationPresenter(
                    client: client,
                    themeStore: themeStore ?? ThemeStore(defaults: defaults)
                ),
            floatingThumbnailPresenter: floatingThumbnailPresenter ?? FloatingThumbnailController(),
            extensionRouter: SystemScreenshotCaptureExtensionRouter(
                pasteboardWriter: extensionPasteboardWriter,
                client: client,
                historyConfigurationProvider: {
                    FeatureConfigurationStore(defaults: defaults).load().screenshot.history
                }
            ),
            selectionFactory: selectionFactory,
            configurationProvider: configurationProvider ?? {
                FeatureConfigurationStore(defaults: defaults).load().screenshot
            },
            invalidateService: { await client.shutdown() },
            registerShortcuts: registerShortcuts,
            unregisterShortcuts: unregisterShortcuts
        )
    }

    func refreshPermissionState() {
        permissionState = coordinator.permissionState
    }

    func openSystemSettings() {
        coordinator.openSystemSettings()
    }
}

// MARK: - 滚动截图与 GIF 录制

private final class CaptureExtensionFrameSampler: @unchecked Sendable {
    let pointFrame: CGRect
    let pixelScale: CGFloat
    let displays: [ScreenshotDisplayDescriptor]
    private let filter: SCContentFilter
    private let configuration: SCStreamConfiguration

    private init(
        pointFrame: CGRect,
        pixelScale: CGFloat,
        displays: [ScreenshotDisplayDescriptor],
        filter: SCContentFilter,
        configuration: SCStreamConfiguration
    ) {
        self.pointFrame = pointFrame
        self.pixelScale = pixelScale
        self.displays = displays
        self.filter = filter
        self.configuration = configuration
    }

    static func make(
        target: ScreenshotCaptureTarget,
        windowShadow: ScreenshotWindowShadow
    ) async throws -> CaptureExtensionFrameSampler {
        guard CGPreflightScreenCaptureAccess() else {
            throw ScreenshotFeatureError.permissionDenied
        }
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        let displayFrames = content.displays.map(\.frame)
        let virtualMinX = displayFrames.map(\.minX).min() ?? 0
        let virtualMaxY = displayFrames.map(\.maxY).max() ?? 0
        let ownApplications = content.applications.filter {
            $0.bundleIdentifier == Bundle.main.bundleIdentifier
        }
        let configuration = SCStreamConfiguration()
        configuration.showsCursor = false
        configuration.capturesAudio = false

        switch target {
        case let .region(displayID, rect):
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw ScreenshotFeatureError.targetUnavailable
            }
            let normalizedDisplay = normalizedFrame(
                display.frame,
                virtualMinX: virtualMinX,
                virtualMaxY: virtualMaxY
            )
            let local = CGRect(
                x: rect.x - normalizedDisplay.minX,
                y: rect.y - normalizedDisplay.minY,
                width: rect.width,
                height: rect.height
            ).intersection(CGRect(origin: .zero, size: display.frame.size))
            guard local.width >= 2, local.height >= 2 else {
                throw ScreenshotFeatureError.targetUnavailable
            }
            let filter = SCContentFilter(
                display: display,
                excludingApplications: ownApplications,
                exceptingWindows: []
            )
            configuration.sourceRect = local
            let scale = max(1, CGFloat(CGDisplayPixelsWide(displayID)) / max(1, display.frame.width))
            configuration.width = max(1, Int(ceil(local.width * scale)))
            configuration.height = max(1, Int(ceil(local.height * scale)))
            configuration.ignoreShadowsDisplay = true
            return .init(
                pointFrame: appKitFrame(local: local, displayID: displayID),
                pixelScale: scale,
                displays: [displayDescriptor(
                    display,
                    virtualMinX: virtualMinX,
                    virtualMaxY: virtualMaxY,
                    scale: scale
                )],
                filter: filter,
                configuration: configuration
            )

        case let .display(displayID):
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw ScreenshotFeatureError.targetUnavailable
            }
            let filter = SCContentFilter(
                display: display,
                excludingApplications: ownApplications,
                exceptingWindows: []
            )
            configuration.sourceRect = CGRect(origin: .zero, size: display.frame.size)
            configuration.width = max(1, Int(CGDisplayPixelsWide(displayID)))
            configuration.height = max(1, Int(CGDisplayPixelsHigh(displayID)))
            configuration.ignoreShadowsDisplay = true
            return .init(
                pointFrame: appKitFrame(
                    local: CGRect(origin: .zero, size: display.frame.size),
                    displayID: displayID
                ),
                pixelScale: max(1, CGFloat(CGDisplayPixelsWide(displayID)) / max(1, display.frame.width)),
                displays: [displayDescriptor(
                    display,
                    virtualMinX: virtualMinX,
                    virtualMaxY: virtualMaxY,
                    scale: max(1, CGFloat(CGDisplayPixelsWide(displayID)) / max(1, display.frame.width))
                )],
                filter: filter,
                configuration: configuration
            )

        case let .window(windowID):
            guard let window = content.windows.first(where: { $0.windowID == windowID && $0.isOnScreen }) else {
                throw ScreenshotFeatureError.targetUnavailable
            }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            configuration.ignoreShadowsSingleWindow = windowShadow == .excluded
            configuration.width = max(1, Int(ceil(filter.contentRect.width * CGFloat(filter.pointPixelScale))))
            configuration.height = max(1, Int(ceil(filter.contentRect.height * CGFloat(filter.pointPixelScale))))
            let normalizedWindow = normalizedFrame(
                window.frame,
                virtualMinX: virtualMinX,
                virtualMaxY: virtualMaxY
            )
            let display = content.displays.first { $0.frame.intersects(window.frame) }
            let pointFrame: CGRect
            if let display {
                let normalizedDisplay = normalizedFrame(
                    display.frame,
                    virtualMinX: virtualMinX,
                    virtualMaxY: virtualMaxY
                )
                let local = CGRect(
                    x: normalizedWindow.minX - normalizedDisplay.minX,
                    y: normalizedWindow.minY - normalizedDisplay.minY,
                    width: normalizedWindow.width,
                    height: normalizedWindow.height
                )
                pointFrame = appKitFrame(local: local, displayID: display.displayID)
            } else {
                pointFrame = NSScreen.main?.visibleFrame ?? .zero
            }
            let scale = max(1, CGFloat(filter.pointPixelScale))
            let displays = display.map {
                [displayDescriptor(
                    $0,
                    virtualMinX: virtualMinX,
                    virtualMaxY: virtualMaxY,
                    scale: max(1, CGFloat(CGDisplayPixelsWide($0.displayID)) / max(1, $0.frame.width))
                )]
            } ?? []
            return .init(
                pointFrame: pointFrame,
                pixelScale: scale,
                displays: displays,
                filter: filter,
                configuration: configuration
            )

        case .interactive, .allDisplays:
            throw ScreenshotFeatureError.targetUnavailable
        }
    }

    func capture() async throws -> CGImage {
        try Task.checkCancellation()
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
        try Task.checkCancellation()
        return image
    }

    private static func normalizedFrame(
        _ frame: CGRect,
        virtualMinX: CGFloat,
        virtualMaxY: CGFloat
    ) -> CGRect {
        CGRect(
            x: frame.minX - virtualMinX,
            y: virtualMaxY - frame.maxY,
            width: frame.width,
            height: frame.height
        )
    }

    private static func appKitFrame(local: CGRect, displayID: CGDirectDisplayID) -> CGRect {
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
                == displayID
        }) else { return local }
        return CGRect(
            x: screen.frame.minX + local.minX,
            y: screen.frame.maxY - local.minY - local.height,
            width: local.width,
            height: local.height
        )
    }

    private static func displayDescriptor(
        _ display: SCDisplay,
        virtualMinX: CGFloat,
        virtualMaxY: CGFloat,
        scale: CGFloat
    ) -> ScreenshotDisplayDescriptor {
        ScreenshotDisplayDescriptor(
            id: display.displayID,
            frame: .init(
                x: display.frame.minX - virtualMinX,
                y: virtualMaxY - display.frame.maxY,
                width: display.frame.width,
                height: display.frame.height
            ),
            pixelSize: .init(
                width: Double(display.frame.width * scale),
                height: Double(display.frame.height * scale)
            ),
            scaleFactor: Double(scale)
        )
    }
}

private actor ScrollingCaptureProcessor {
    struct Update: @unchecked Sendable {
        var result: ScrollingAppendResult
        var preview: CGImage?
    }

    private var stitcher: ScrollingImageStitcher

    init(firstFrame: CGImage) throws {
        stitcher = try ScrollingImageStitcher(firstFrame: firstFrame)
    }

    func append(_ frame: CGImage) throws -> Update {
        let result = try stitcher.append(frame)
        let preview: CGImage?
        if case .extended = result {
            preview = try stitcher.makePreview(maximumWidth: 264, maximumHeight: 368)
        } else {
            preview = nil
        }
        return Update(result: result, preview: preview)
    }

    func initialPreview() throws -> CGImage {
        try stitcher.makePreview(maximumWidth: 264, maximumHeight: 368)
    }

    func finalImage() throws -> CGImage {
        try stitcher.makeImage()
    }
}

private final class CaptureExtensionHUDPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
private final class CaptureExtensionHUDController: NSObject {
    enum Kind {
        case scrolling
        case gif
    }

    var onFinish: (() -> Void)?
    var onCancel: (() -> Void)?

    private let borderPanel: NSPanel
    private let controlsPanel: CaptureExtensionHUDPanel
    private let previewView = NSImageView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")

    init(frame: CGRect, kind: Kind) {
        borderPanel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        controlsPanel = CaptureExtensionHUDPanel(
            contentRect: CGRect(x: 0, y: 0, width: kind == .scrolling ? 184 : 210, height: kind == .scrolling ? 326 : 360),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        super.init()
        configureBorder(frame: frame)
        configureControls(frame: frame, kind: kind)
    }

    func show() {
        borderPanel.orderFrontRegardless()
        controlsPanel.makeKeyAndOrderFront(nil)
    }

    func update(preview: CGImage?, status: String, detail: String) {
        if let preview {
            previewView.image = NSImage(
                cgImage: preview,
                size: NSSize(width: preview.width, height: preview.height)
            )
        }
        statusLabel.stringValue = status
        detailLabel.stringValue = detail
    }

    func dismiss() {
        borderPanel.orderOut(nil)
        controlsPanel.orderOut(nil)
    }

    private func configureBorder(frame: CGRect) {
        let border = NSView(frame: CGRect(origin: .zero, size: frame.size))
        border.wantsLayer = true
        border.layer?.borderWidth = 2
        border.layer?.borderColor = NSColor.systemCyan.cgColor
        border.layer?.backgroundColor = NSColor.clear.cgColor
        borderPanel.contentView = border
        borderPanel.level = .screenSaver
        borderPanel.isOpaque = false
        borderPanel.backgroundColor = .clear
        borderPanel.hasShadow = false
        borderPanel.ignoresMouseEvents = true
        borderPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    }

    private func configureControls(frame: CGRect, kind: Kind) {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(calibratedWhite: 0.055, alpha: 0.84).cgColor
        container.layer?.cornerRadius = 11
        container.layer?.borderWidth = 0.7
        container.layer?.borderColor = NSColor.white.withAlphaComponent(0.13).cgColor
        container.layer?.masksToBounds = true

        let title = NSTextField(labelWithString: kind == .scrolling ? "滚动截图" : "GIF 录制")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = NSColor.white.withAlphaComponent(0.94)
        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.textColor = NSColor.white.withAlphaComponent(0.72)
        statusLabel.stringValue = kind == .scrolling ? "请在选区内单向滚动" : "正在录制选区"
        detailLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        detailLabel.textColor = NSColor.white.withAlphaComponent(0.48)
        detailLabel.stringValue = kind == .scrolling ? "正在建立首帧…" : "00:00 / 00:30"
        detailLabel.alignment = .center

        previewView.imageScaling = .scaleProportionallyDown
        previewView.wantsLayer = true
        previewView.layer?.backgroundColor = NSColor.clear.cgColor

        let finish = NSButton(title: "完成", target: self, action: #selector(finishPressed))
        finish.bezelStyle = .rounded
        finish.keyEquivalent = "\r"
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelPressed))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [cancel, finish])
        buttons.orientation = .horizontal
        buttons.distribution = .fillEqually
        buttons.spacing = 8

        let stack = NSStackView(views: [title, statusLabel, previewView, detailLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = kind == .scrolling ? 7 : 9
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        controlsPanel.contentView = container
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            previewView.widthAnchor.constraint(equalToConstant: kind == .scrolling ? 132 : 174),
            previewView.heightAnchor.constraint(equalToConstant: kind == .scrolling ? 184 : 210),
            buttons.widthAnchor.constraint(equalToConstant: kind == .scrolling ? 148 : 174)
        ])

        controlsPanel.level = .screenSaver
        controlsPanel.isOpaque = false
        controlsPanel.backgroundColor = .clear
        controlsPanel.hasShadow = false
        controlsPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        controlsPanel.setFrameOrigin(panelOrigin(for: frame, size: controlsPanel.frame.size))
    }

    private func panelOrigin(for target: CGRect, size: CGSize) -> CGPoint {
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(target) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? target.insetBy(dx: -300, dy: -300)
        let rightX = target.maxX + 12
        let x = rightX + size.width <= visible.maxX
            ? rightX
            : max(visible.minX, target.minX - size.width - 12)
        let y = min(max(target.midY - size.height / 2, visible.minY), visible.maxY - size.height)
        return CGPoint(x: x, y: y)
    }

    @objc private func finishPressed() { onFinish?() }
    @objc private func cancelPressed() { onCancel?() }
}

@MainActor
final class SystemScreenshotCaptureExtensionRouter: ScreenshotCaptureExtensionRouting {
    private let pasteboardWriter: ScreenshotPasteboardWriter
    private let client: ScreenshotClient
    private let historyConfigurationProvider: @MainActor () -> ScreenshotHistoryConfiguration
    private var hud: CaptureExtensionHUDController?
    private var activeTask: Task<Void, Never>?
    private var continuation: CheckedContinuation<FeatureActionResult, any Error>?
    private var scrollingProcessor: ScrollingCaptureProcessor?
    private var gifEncoder: GIFRecordingEncoder?
    private var currentSampler: CaptureExtensionFrameSampler?
    private var outputURL: URL?
    private var completionTask: Task<Void, Never>?
    private var sessionID: UUID?
    private var isCompleting = false

    init(
        pasteboardWriter: ScreenshotPasteboardWriter = ScreenshotPasteboardWriter(),
        client: ScreenshotClient = ScreenshotClient(),
        historyConfigurationProvider: @escaping @MainActor () -> ScreenshotHistoryConfiguration = { .init() }
    ) {
        self.pasteboardWriter = pasteboardWriter
        self.client = client
        self.historyConfigurationProvider = historyConfigurationProvider
    }

    func start(_ request: ScreenshotCaptureExtensionRequest) async throws -> FeatureActionResult {
        guard continuation == nil, activeTask == nil, completionTask == nil else {
            throw ScreenshotCoordinatorError.busy
        }
        let sampler = try await CaptureExtensionFrameSampler.make(
            target: request.target,
            windowShadow: request.windowShadow
        )
        let sessionID = UUID()
        self.sessionID = sessionID
        currentSampler = sampler
        let kind: CaptureExtensionHUDController.Kind = request.kind == .scrollingCapture ? .scrolling : .gif
        let hud = CaptureExtensionHUDController(frame: sampler.pointFrame, kind: kind)
        hud.onFinish = { [weak self] in self?.complete(sessionID: sessionID) }
        hud.onCancel = { [weak self] in self?.cancel(sessionID: sessionID) }
        self.hud = hud
        hud.show()

        do {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    self.continuation = continuation
                    switch request.kind {
                    case .scrollingCapture:
                        beginScrolling(using: sampler, sessionID: sessionID)
                    case .gifRecording:
                        beginGIF(using: sampler, sessionID: sessionID)
                    }
                }
            } onCancel: {
                Task { @MainActor [weak self] in self?.cancel(sessionID: sessionID) }
            }
        } catch {
            tearDownUI()
            throw error
        }
    }

    func cancel() {
        guard let sessionID else { return }
        cancel(sessionID: sessionID)
    }

    private func cancel(sessionID: UUID) {
        guard self.sessionID == sessionID else { return }
        activeTask?.cancel()
        activeTask = nil
        completionTask?.cancel()
        completionTask = nil
        if let encoder = gifEncoder {
            Task { await encoder.cancel() }
        }
        if let outputURL { try? FileManager.default.removeItem(at: outputURL) }
        tearDownUI()
        continuation?.resume(throwing: CancellationError())
        continuation = nil
        resetState()
    }

    private func beginScrolling(using sampler: CaptureExtensionFrameSampler, sessionID: UUID) {
        activeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let first = try await sampler.capture()
                let processor = try ScrollingCaptureProcessor(firstFrame: first)
                scrollingProcessor = processor
                let initial = try await processor.initialPreview()
                hud?.update(
                    preview: initial,
                    status: "请在选区内单向滚动",
                    detail: "已捕获 \(first.height) px"
                )
                while !Task.isCancelled {
                    try await Task.sleep(for: .milliseconds(70))
                    let frame = try await sampler.capture()
                    let update = try await processor.append(frame)
                    if !applyScrolling(update) { return }
                }
            } catch is CancellationError {
                return
            } catch {
                fail(error, sessionID: sessionID)
            }
        }
    }

    @discardableResult
    private func applyScrolling(_ update: ScrollingCaptureProcessor.Update) -> Bool {
        switch update.result {
        case .duplicate:
            hud?.update(preview: nil, status: "请继续滚动", detail: "等待新内容")
        case let .extended(newRows, totalHeight):
            hud?.update(
                preview: update.preview,
                status: "正在拼接",
                detail: "+\(newRows) px · 共 \(totalHeight) px"
            )
        case .reverseIgnored:
            hud?.update(preview: nil, status: "等待画面稳定", detail: "当前画面未加入长截图")
        case .needsSlowerScrolling:
            hud?.update(preview: nil, status: "请稍慢滚动", detail: "正在校验上下画面")
        case let .reachedLengthLimit(totalHeight):
            hud?.update(preview: update.preview, status: "已达到安全长度", detail: "当前约 \(totalHeight) px，请点击完成")
            return false
        }
        return true
    }

    private func beginGIF(using sampler: CaptureExtensionFrameSampler, sessionID: UUID) {
        do {
            let url = try makeOutputURL(extension: "gif", prefix: "GIF")
            outputURL = url
            let encoder = try GIFRecordingEncoder(
                outputURL: url,
                framesPerSecond: 15,
                maximumDuration: 30
            )
            gifEncoder = encoder
            activeTask = Task { [weak self] in
                guard let self else { return }
                let startedAt = ProcessInfo.processInfo.systemUptime
                do {
                    while !Task.isCancelled {
                        let frame = try await sampler.capture()
                        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
                        let decision = try await encoder.append(frame, at: elapsed)
                        switch decision {
                        case .skipped:
                            break
                        case let .appended(frameCount):
                            let seconds = min(30, Int(elapsed))
                            hud?.update(
                                preview: frame,
                                status: "正在录制 · \(frameCount) 帧",
                                detail: String(format: "00:%02d / 00:30", seconds)
                            )
                        case .reachedDurationLimit:
                            complete(sessionID: sessionID)
                            return
                        }
                        try await Task.sleep(for: .milliseconds(25))
                    }
                } catch is CancellationError {
                    return
                } catch {
                    fail(error, sessionID: sessionID)
                }
            }
        } catch {
            fail(error, sessionID: sessionID)
        }
    }

    private func complete(sessionID: UUID) {
        guard self.sessionID == sessionID, !isCompleting else { return }
        isCompleting = true
        activeTask?.cancel()
        activeTask = nil
        hud?.update(preview: nil, status: "正在生成…", detail: "请稍候")

        let processor = scrollingProcessor
        let encoder = gifEncoder
        let sampler = currentSampler
        let completionTask = Task { [weak self] in
            guard let self else { return }
            var generatedURL: URL?
            do {
                if let processor {
                    let image = try await processor.finalImage()
                    let url = try makeOutputURL(extension: "png", prefix: "Scrolling")
                    generatedURL = url
                    outputURL = url
                    try await Task.detached {
                        try Self.writePNG(image, to: url)
                    }.value
                    try Task.checkCancellation()
                    try pasteboardWriter.writeImage(at: url)
                    if let sampler {
                        let artifact = try await Task.detached {
                            try Self.makeArtifact(image: image, url: url, sampler: sampler)
                        }.value
                        let history = historyConfigurationProvider()
                        do {
                            try await client.registerArtifact(artifact, history: history)
                        } catch {
                            // 截图已经成功生成并复制；历史故障不应让用户丢失结果。
                            NSLog("Scrolling screenshot history registration failed: %@", String(describing: error))
                        }
                    }
                } else if let encoder {
                    let result = try await encoder.finish()
                    try pasteboardWriter.writeGIF(at: result.outputURL)
                } else {
                    throw ScreenshotFeatureError.encodingFailed
                }
                guard self.sessionID == sessionID else { return }
                finishSuccessfully(sessionID: sessionID)
            } catch is CancellationError {
                if let generatedURL { try? FileManager.default.removeItem(at: generatedURL) }
                cancel(sessionID: sessionID)
            } catch {
                if let generatedURL { try? FileManager.default.removeItem(at: generatedURL) }
                fail(error, sessionID: sessionID)
            }
        }
        self.completionTask = completionTask
    }

    private func finishSuccessfully(sessionID: UUID) {
        guard self.sessionID == sessionID else { return }
        tearDownUI()
        continuation?.resume(returning: .completed)
        continuation = nil
        resetState()
    }

    private func fail(_ error: any Error, sessionID: UUID) {
        guard self.sessionID == sessionID else { return }
        activeTask?.cancel()
        activeTask = nil
        completionTask?.cancel()
        completionTask = nil
        tearDownUI()
        continuation?.resume(throwing: error)
        continuation = nil
        resetState()
    }

    private func tearDownUI() {
        hud?.dismiss()
        hud = nil
    }

    private func resetState() {
        activeTask = nil
        scrollingProcessor = nil
        gifEncoder = nil
        currentSampler = nil
        outputURL = nil
        completionTask = nil
        sessionID = nil
        isCompleting = false
    }

    private func makeOutputURL(extension fileExtension: String, prefix: String) throws -> URL {
        let paths = try ScreenshotFeaturePaths.applicationSupport()
        try FileManager.default.createDirectory(
            at: paths.capturesURL,
            withIntermediateDirectories: true
        )
        return paths.capturesURL
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
            .appendingPathExtension(fileExtension)
    }

    nonisolated private static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw ScreenshotFeatureError.encodingFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: url)
            throw ScreenshotFeatureError.encodingFailed
        }
    }

    nonisolated private static func makeArtifact(
        image: CGImage,
        url: URL,
        sampler: CaptureExtensionFrameSampler
    ) throws -> ScreenshotArtifact {
        let paths = try ScreenshotFeaturePaths.applicationSupport()
        let relativePath = try paths.relativePath(for: url)
        let digest = try sha256(of: url)
        let scale = max(1, sampler.pixelScale)
        return ScreenshotArtifact(
            id: UUID(),
            createdAt: Date(),
            captureMode: .region,
            relativePath: relativePath,
            thumbnailRelativePath: nil,
            pointSize: .init(
                width: Double(image.width) / Double(scale),
                height: Double(image.height) / Double(scale)
            ),
            pixelSize: .init(width: Double(image.width), height: Double(image.height)),
            uniformTypeIdentifier: UTType.png.identifier,
            sha256: digest,
            displays: sampler.displays
        )
    }

    /// 分块计算摘要，避免把超长 PNG 再完整读入一份 `Data` 造成峰值内存翻倍。
    nonisolated private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            guard let data = try handle.read(upToCount: 1_048_576), !data.isEmpty else { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
