import AppKit
import ImageIO
import ScreenshotFeature
import TouchFeatureAPI
import UniformTypeIdentifiers

public enum ScreenshotCoordinatorError: Error, Equatable, Sendable {
    case busy
    case noDisplaysAvailable
}

enum ScreenshotCaptureExtensionKind: Equatable, Sendable {
    case scrollingCapture
    case gifRecording
}

struct ScreenshotCaptureExtensionRequest: Equatable, Sendable {
    var kind: ScreenshotCaptureExtensionKind
    var target: ScreenshotCaptureTarget
    var windowShadow: ScreenshotWindowShadow
}

@MainActor
protocol ScreenshotCaptureExtensionRouting: AnyObject, Sendable {
    func start(_ request: ScreenshotCaptureExtensionRequest) async throws -> FeatureActionResult
    func cancel()
}

@MainActor
final class PendingScreenshotCaptureExtensionRouter: ScreenshotCaptureExtensionRouting {
    func start(_ request: ScreenshotCaptureExtensionRequest) async throws -> FeatureActionResult {
        switch request.kind {
        case .scrollingCapture:
            .requiresSetup(message: "滚动截图捕获链路尚未完成")
        case .gifRecording:
            .requiresSetup(message: "GIF 录制捕获链路尚未完成")
        }
    }

    func cancel() {}
}

@MainActor
protocol ScreenshotLauncherPresenting: AnyObject {
    var isLauncherVisible: Bool { get }
    func hideLauncher()
    func showLauncher()
}

@MainActor
protocol WorkspaceTextCapturing: AnyObject {
    func captureTextForWorkspace() async throws -> ScreenTextCaptureResult
    func cancelWorkspaceTextCapture()
}

@MainActor
protocol ScreenshotTranslationFeedbackPresenting: AnyObject {
    func present(message: String, retry: @escaping @MainActor @Sendable () -> Void)
}

@MainActor
final class ScreenshotTranslationFeedbackAlert: ScreenshotTranslationFeedbackPresenting {
    func present(message: String, retry: @escaping @MainActor @Sendable () -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "截图翻译"
        alert.informativeText = message
        alert.addButton(withTitle: "重新截图")
        alert.addButton(withTitle: "取消")

        let handleResponse: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            retry()
        }
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window, completionHandler: handleResponse)
        } else {
            handleResponse(alert.runModal())
        }
    }
}

@MainActor
final class ScreenshotCoordinator: ScreenshotActionRouting, WorkspaceTextCapturing {
    typealias ServiceInvalidation = @Sendable () async -> Void
    typealias ShortcutAction = @MainActor @Sendable () -> Void
    typealias SelectionFactory = @MainActor () -> any ScreenshotSelectionPresenting
    typealias WorkspaceSelectionFactory = @MainActor () -> any ScreenshotSelectionPresenting
    typealias WorkspacePreviewLoader = @Sendable (ScreenshotArtifact) async -> Data?
    typealias ColorPickerFactory = @MainActor () -> any ScreenshotColorPickerPresenting
    typealias ConfigurationProvider = @MainActor () -> ScreenshotFeatureConfiguration
    typealias TranslationRequestHandler = @MainActor @Sendable (TextTranslationRequest) -> Void

    private enum CaptureFlowOutcome {
        case result(FeatureActionResult)
        case cancelled
    }

    private let authorization: any ScreenRecordingAuthorizing
    private let captureService: any ScreenshotCapturing
    private let clipboardWriter: any ScreenshotClipboardWriting
    private let colorClipboardWriter: any ScreenshotColorClipboardWriting
    private let recognizedTextClipboardWriter: any ScreenshotRecognizedTextClipboardWriting
    private let recognitionPresenter: any ScreenshotRecognitionPresenting
    private let pinPresenter: any ScreenshotPinPresenting
    private let annotationPresenter: any ScreenshotArtifactAnnotationPresenting
    private let floatingThumbnailPresenter: any ScreenshotFloatingThumbnailPresenting
    private let countdownPresenter: any ScreenshotCaptureCountdownPresenting
    private let extensionRouter: any ScreenshotCaptureExtensionRouting
    private let selectionFactory: SelectionFactory
    private let workspaceSelectionFactory: WorkspaceSelectionFactory
    private let workspacePreviewLoader: WorkspacePreviewLoader
    private let colorPickerFactory: ColorPickerFactory
    private let configurationProvider: ConfigurationProvider
    private let translationRequestHandler: TranslationRequestHandler
    private let translationFeedbackPresenter: any ScreenshotTranslationFeedbackPresenting
    private let invalidateService: ServiceInvalidation
    private let registerShortcuts: ShortcutAction
    private let unregisterShortcuts: ShortcutAction

    private weak var launcher: (any ScreenshotLauncherPresenting)?
    private var captureTask: Task<CaptureFlowOutcome, any Error>?
    private var workspaceTextCaptureTask: Task<ScreenTextCaptureResult, any Error>?
    private var activeCaptureID: UUID?
    private var activeSelectionPresenter: (any ScreenshotSelectionPresenting)?
    private var activeColorPickerPresenter: (any ScreenshotColorPickerPresenting)?
    private var isEnabled = true
    private var pendingTranslationRetry = false

    init(
        authorization: any ScreenRecordingAuthorizing,
        captureService: any ScreenshotCapturing,
        clipboardWriter: any ScreenshotClipboardWriting = ScreenshotPasteboardWriter(),
        colorClipboardWriter: any ScreenshotColorClipboardWriting = SystemScreenshotColorClipboardWriter(),
        recognizedTextClipboardWriter: any ScreenshotRecognizedTextClipboardWriting = SystemScreenshotRecognizedTextClipboardWriter(),
        recognitionPresenter: any ScreenshotRecognitionPresenting = ScreenshotRecognitionResultPanel(),
        pinPresenter: any ScreenshotPinPresenting = ScreenshotPinWindowManager(),
        annotationPresenter: any ScreenshotArtifactAnnotationPresenting = SystemScreenshotArtifactAnnotationPresenter(),
        floatingThumbnailPresenter: any ScreenshotFloatingThumbnailPresenting = FloatingThumbnailController(),
        countdownPresenter: any ScreenshotCaptureCountdownPresenting = CaptureCountdownPanel(),
        extensionRouter: any ScreenshotCaptureExtensionRouting = PendingScreenshotCaptureExtensionRouter(),
        selectionFactory: @escaping SelectionFactory = { SelectionOverlayController() },
        workspaceSelectionFactory: @escaping WorkspaceSelectionFactory = {
            SelectionOverlayController(
                completionActionOverride: .recognizeText,
                automaticallyCompletesOnMouseUp: true
            )
        },
        workspacePreviewLoader: @escaping WorkspacePreviewLoader = {
            await ScreenshotWorkspacePreviewDataLoader.load($0)
        },
        colorPickerFactory: ColorPickerFactory? = nil,
        configurationProvider: @escaping ConfigurationProvider = { .init() },
        translationRequestHandler: @escaping TranslationRequestHandler = { _ in },
        translationFeedbackPresenter: any ScreenshotTranslationFeedbackPresenting = ScreenshotTranslationFeedbackAlert(),
        invalidateService: @escaping ServiceInvalidation = {},
        registerShortcuts: @escaping ShortcutAction = {},
        unregisterShortcuts: @escaping ShortcutAction = {}
    ) {
        self.authorization = authorization
        self.captureService = captureService
        self.clipboardWriter = clipboardWriter
        self.colorClipboardWriter = colorClipboardWriter
        self.recognizedTextClipboardWriter = recognizedTextClipboardWriter
        self.recognitionPresenter = recognitionPresenter
        self.pinPresenter = pinPresenter
        self.annotationPresenter = annotationPresenter
        self.floatingThumbnailPresenter = floatingThumbnailPresenter
        self.countdownPresenter = countdownPresenter
        self.extensionRouter = extensionRouter
        self.selectionFactory = selectionFactory
        self.workspaceSelectionFactory = workspaceSelectionFactory
        self.workspacePreviewLoader = workspacePreviewLoader
        self.colorPickerFactory = colorPickerFactory ?? {
            ColorPickerController(captureService: captureService)
        }
        self.configurationProvider = configurationProvider
        self.translationRequestHandler = translationRequestHandler
        self.translationFeedbackPresenter = translationFeedbackPresenter
        self.invalidateService = invalidateService
        self.registerShortcuts = registerShortcuts
        self.unregisterShortcuts = unregisterShortcuts
    }

    var permissionState: ScreenshotPermissionState {
        authorization.status
    }

    func attachLauncher(_ launcher: any ScreenshotLauncherPresenting) {
        self.launcher = launcher
    }

    func featureState() -> FeatureState {
        guard isEnabled else { return .disabled }
        switch authorization.status {
        case .notRequested, .authorized:
            return .available
        case .denied, .restricted:
            return .restricted(message: "需要配置屏幕录制权限")
        }
    }

    func route(_ action: ScreenshotPluginAction) async throws -> FeatureActionResult {
        guard isEnabled else {
            return .requiresSetup(message: "截取屏幕功能已停用")
        }
        guard captureTask == nil, workspaceTextCaptureTask == nil else {
            throw ScreenshotCoordinatorError.busy
        }

        switch action {
        case .captureDefaultMode:
            return try await captureDefaultMode()
        case .captureAllDisplays:
            return try await captureAllDisplays()
        case .pickColor:
            return try await pickColor()
        }
    }

    @discardableResult
    func requestAuthorization() -> ScreenshotPermissionState {
        if authorization.status == .notRequested {
            return authorization.requestAccess()
        }
        return authorization.status
    }

    func openSystemSettings() {
        authorization.openSystemSettings()
    }

    /// 供翻译和 OCR 工作台使用的专用选区识别流程。
    /// 截图产物只作为临时识别输入，完成（或失败）后在返回前请求服务删除，
    /// 工作台只保留一份内存预览，不进入截图历史。
    func captureTextForWorkspace() async throws -> ScreenTextCaptureResult {
        guard isEnabled else {
            throw ScreenTextCaptureError.unavailable("截取屏幕功能已停用")
        }
        guard authorization.status == .authorized else {
            throw ScreenTextCaptureError.permissionRequired
        }
        guard captureTask == nil, workspaceTextCaptureTask == nil else {
            throw ScreenTextCaptureError.busy
        }

        let captureService = captureService
        let workspacePreviewLoader = workspacePreviewLoader
        let configuration = configurationProvider()
        let task = Task { @MainActor [weak self] () throws -> ScreenTextCaptureResult in
            guard let self else { throw CancellationError() }
            let content = try await captureService.availableSelectionContent()
            let presenter = self.workspaceSelectionFactory()
            self.activeSelectionPresenter = presenter
            defer { self.activeSelectionPresenter = nil }

            guard let selection = await presenter.select(from: content) else {
                throw ScreenTextCaptureError.cancelled
            }
            try Task.checkCancellation()

            let request = ScreenshotCaptureRequest(
                mode: .ocrRegion,
                delay: .none,
                target: selection.target,
                windowShadow: selection.windowShadow,
                output: configuration.output,
                history: .init(isEnabled: false, keepsFilesWhenDisabled: false)
            )
            guard let artifact = try await captureService.captureArtifact(request) else {
                throw ScreenTextCaptureError.noText
            }

            do {
                let previewImageData = await workspacePreviewLoader(artifact)
                try Task.checkCancellation()
                let result = try await captureService.recognize(.init(
                    artifact: artifact,
                    configuration: configuration.ocr
                ))
                let text = result.fullText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { throw ScreenTextCaptureError.noText }
                let captureResult = ScreenTextCaptureResult(
                    text: text,
                    previewImageData: previewImageData
                )
                await deleteTemporaryArtifact(artifact, using: captureService)
                return captureResult
            } catch {
                await deleteTemporaryArtifact(artifact, using: captureService)
                throw error
            }
        }
        workspaceTextCaptureTask = task
        defer { workspaceTextCaptureTask = nil }

        do {
            return try await task.value
        } catch is CancellationError {
            throw ScreenTextCaptureError.cancelled
        } catch let error as ScreenTextCaptureError {
            throw error
        } catch let error as ScreenshotFeatureError {
            switch error {
            case .permissionDenied: throw ScreenTextCaptureError.permissionRequired
            case .cancelled: throw ScreenTextCaptureError.cancelled
            case .serviceTimedOut: throw ScreenTextCaptureError.timedOut
            case let .recognitionFailed(message):
                throw ScreenTextCaptureError.unavailable(message)
            default: throw ScreenTextCaptureError.unavailable(error.localizedDescription)
            }
        } catch {
            throw ScreenTextCaptureError.unavailable(error.localizedDescription)
        }
    }

    func cancelWorkspaceTextCapture() {
        guard workspaceTextCaptureTask != nil else { return }
        activeSelectionPresenter?.cancel()
        workspaceTextCaptureTask?.cancel()
        pendingTranslationRetry = false
    }

    func activate() async {
        isEnabled = true
        registerShortcuts()
    }

    func deactivate() async {
        guard isEnabled else { return }
        isEnabled = false
        activeSelectionPresenter?.cancel()
        activeColorPickerPresenter?.cancel()
        recognitionPresenter.dismiss()
        floatingThumbnailPresenter.dismissAll()
        countdownPresenter.cancel()
        extensionRouter.cancel()
        captureTask?.cancel()
        workspaceTextCaptureTask?.cancel()
        unregisterShortcuts()
        await invalidateService()
    }

    private func captureDefaultMode() async throws -> FeatureActionResult {
        guard requestAuthorization() == .authorized else {
            return .requiresSetup(message: "请允许一念录制屏幕")
        }

        hideLauncherIfNeeded()
        let captureID = UUID()
        let presenter = selectionFactory()
        activeSelectionPresenter = presenter
        let captureService = captureService
        let countdownPresenter = countdownPresenter
        let extensionRouter = extensionRouter
        let configuration = configurationProvider()
        let task = Task { @MainActor in
            let content = try await captureService.availableSelectionContent()
            guard let selection = await presenter.select(from: content) else {
                return CaptureFlowOutcome.cancelled
            }
            let preferredPinFrame = Self.pinFrame(for: selection.target, content: content)
            try Task.checkCancellation()

            switch selection.completionAction {
            case .scrollingCapture:
                let result = try await extensionRouter.start(.init(
                    kind: .scrollingCapture,
                    target: selection.target,
                    windowShadow: selection.windowShadow
                ))
                return .result(result)
            case .gifRecording:
                let result = try await extensionRouter.start(.init(
                    kind: .gifRecording,
                    target: selection.target,
                    windowShadow: selection.windowShadow
                ))
                return .result(result)
            case .copy, .save, .pin, .recognizeText, .translate:
                break
            }

            if configuration.defaultDelay != .none {
                try await countdownPresenter.wait(for: configuration.defaultDelay)
                try Task.checkCancellation()
            }
            let request = ScreenshotCaptureRequest(
                mode: selection.completionAction == .recognizeText || selection.completionAction == .translate
                    ? .ocrRegion
                    : Self.mode(for: selection.target),
                // 可见倒计时已在主进程完成。XPC 收到请求后必须立即捕获，
                // 否则会出现双重等待，且 HUD 关闭时间无法与最终帧严格对齐。
                delay: .none,
                target: selection.target,
                windowShadow: selection.windowShadow,
                // 钉图是持续显示、反复缩放的视觉产物，不能继承 JPEG/HEIF 的有损导出设置。
                // 始终保留无损原始像素；用户的格式偏好仍只影响复制、保存和历史导出。
                output: selection.completionAction == .pin
                    ? .init(format: .png, quality: 1)
                    : configuration.output,
                annotations: selection.annotations,
                history: selection.completionAction == .translate
                    ? .init(isEnabled: false, keepsFilesWhenDisabled: false)
                    : configuration.history
            )
            let artifact = try await captureService.captureArtifact(request)
            switch selection.completionAction {
            case .copy:
                if let artifact {
                    try await performPostCaptureActions(for: artifact, configuration: configuration)
                }
            case .save:
                if let artifact {
                    try await save(artifact, configuration: configuration)
                }
            case .pin:
                if let artifact {
                    try pinPresenter.pin(artifact, preferredFrame: preferredPinFrame)
                }
            case .recognizeText:
                if let artifact {
                    try await recognizeAndPresent(artifact, configuration: configuration)
                }
            case .translate:
                if let artifact {
                    try await recognizeAndTranslate(artifact, configuration: configuration)
                }
            case .scrollingCapture, .gifRecording:
                break
            }
            return .result(.completed)
        }
        activeCaptureID = captureID
        captureTask = task

        do {
            let outcome = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
                Task { @MainActor in
                    presenter.cancel()
                    countdownPresenter.cancel()
                    extensionRouter.cancel()
                }
            }
            finishCapture(id: captureID)
            return finish(outcome)
        } catch is CancellationError {
            finishCapture(id: captureID)
            return .completed
        } catch let error as ScreenshotFeatureError where error == .cancelled {
            finishCapture(id: captureID)
            return .completed
        } catch {
            finishCapture(id: captureID)
            throw error
        }
    }

    private func captureAllDisplays() async throws -> FeatureActionResult {
        guard requestAuthorization() == .authorized else {
            return .requiresSetup(message: "请允许一念录制屏幕")
        }

        hideLauncherIfNeeded()
        let captureID = UUID()
        let captureService = captureService
        let countdownPresenter = countdownPresenter
        let configuration = configurationProvider()
        let task = Task { @MainActor in
            let content = try await captureService.availableSelectionContent()
            let displayIDs = content.displays.map(\.id)
            guard !displayIDs.isEmpty else {
                throw ScreenshotCoordinatorError.noDisplaysAvailable
            }
            if configuration.defaultDelay != .none {
                try await countdownPresenter.wait(for: configuration.defaultDelay)
                try Task.checkCancellation()
            }
            let request = ScreenshotCaptureRequest(
                mode: .allDisplays,
                delay: .none,
                target: .allDisplays(displayIDs: displayIDs),
                windowShadow: configuration.windowShadow,
                output: configuration.output,
                history: configuration.history
            )
            if let artifact = try await captureService.captureArtifact(request) {
                try await performPostCaptureActions(for: artifact, configuration: configuration)
            }
            return CaptureFlowOutcome.result(.completed)
        }
        activeCaptureID = captureID
        captureTask = task

        do {
            let outcome = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
                Task { @MainActor in countdownPresenter.cancel() }
            }
            finishCapture(id: captureID)
            return finish(outcome)
        } catch is CancellationError {
            finishCapture(id: captureID)
            return .completed
        } catch let error as ScreenshotFeatureError where error == .cancelled {
            finishCapture(id: captureID)
            return .completed
        } catch {
            finishCapture(id: captureID)
            throw error
        }
    }

    private func performPostCaptureActions(
        for artifact: ScreenshotArtifact,
        configuration: ScreenshotFeatureConfiguration
    ) async throws {
        let policy = ScreenshotPostCapturePolicy(configuration: configuration)
        if policy.showsThumbnail {
            ScreenshotThumbnailPerformanceRecorder.shared.begin()
        }
        do {
            if policy.copiesToClipboard {
                try clipboardWriter.write(artifact)
            }
            if policy.savesToConfiguredLocation {
                try await save(artifact, configuration: configuration)
            }
            if policy.beginsAnnotation {
                try annotationPresenter.presentForAnnotation(artifact)
            }
            if policy.showsThumbnail {
                floatingThumbnailPresenter.present(
                    artifact: artifact,
                    timeout: configuration.thumbnailTimeout,
                    actions: floatingThumbnailActions(configuration: configuration)
                )
            }
        } catch {
            ScreenshotThumbnailPerformanceRecorder.shared.cancel()
            throw error
        }
    }

    private func floatingThumbnailActions(
        configuration: ScreenshotFeatureConfiguration
    ) -> FloatingThumbnailActions {
        let captureService = captureService
        return FloatingThumbnailActions(
            annotate: { [annotationPresenter] artifact in
                try annotationPresenter.presentForAnnotation(artifact)
            },
            pin: { [pinPresenter] artifact in
                try pinPresenter.pin(artifact)
            },
            copy: { [clipboardWriter] artifact in
                try clipboardWriter.write(artifact)
            },
            recognize: { [weak self] artifact in
                Task { @MainActor [weak self] in
                    try? await self?.recognizeAndPresent(artifact, configuration: configuration)
                }
            },
            save: { [weak self] artifact in
                guard let self else { throw ScreenshotFeatureError.cancelled }
                try await self.save(artifact, configuration: configuration)
            },
            export: { artifact, destinationURL in
                try await captureService.exportArtifact(artifact, to: destinationURL)
            },
            delete: { artifact in
                try await captureService.deleteArtifact(artifact)
            }
        )
    }

    private func save(
        _ artifact: ScreenshotArtifact,
        configuration: ScreenshotFeatureConfiguration
    ) async throws {
        let directory: URL
        var securityScopedDirectory: URL?

        switch configuration.saveLocation {
        case .pluginDirectory:
            // 兼容旧配置；旧的插件目录语义回退到下载目录。
            directory = try FileManager.default.url(
                for: .downloadsDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        case .downloads:
            directory = try FileManager.default.url(
                for: .downloadsDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        case .desktop:
            directory = try FileManager.default.url(
                for: .desktopDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        case let .customBookmark(bookmark):
            var isStale = false
            do {
                directory = try URL(
                    resolvingBookmarkData: bookmark,
                    options: [.withSecurityScope],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
            } catch {
                throw ScreenshotFeatureError.storageFailed(message: "截图保存目录不可用：\(error)")
            }
            if directory.startAccessingSecurityScopedResource() {
                securityScopedDirectory = directory
            }
        }

        defer { securityScopedDirectory?.stopAccessingSecurityScopedResource() }
        let fileName = URL(fileURLWithPath: artifact.relativePath).lastPathComponent
        guard !fileName.isEmpty else {
            throw ScreenshotFeatureError.storageFailed(message: "截图文件名无效")
        }
        let destination = nextAvailableURL(
            in: directory.standardizedFileURL,
            fileName: fileName
        )
        _ = try await captureService.exportArtifact(artifact, to: destination)
    }

    static func pinFrame(
        for target: ScreenshotCaptureTarget,
        content: ScreenshotSelectionContent,
        screens: [NSScreen] = NSScreen.screens
    ) -> CGRect? {
        let targetRect: ScreenshotRect
        let displayID: UInt32
        switch target {
        case let .region(id, rect):
            displayID = id
            targetRect = rect
        case let .window(windowID):
            guard let window = content.windows.first(where: { $0.id == windowID }),
                  let display = content.displays.first(where: {
                      CGRect(x: $0.frame.x, y: $0.frame.y, width: $0.frame.width, height: $0.frame.height)
                          .intersects(CGRect(x: window.frame.x, y: window.frame.y, width: window.frame.width, height: window.frame.height))
                  }) else { return nil }
            displayID = display.id
            targetRect = window.frame
        case let .display(id):
            guard let display = content.displays.first(where: { $0.id == id }) else { return nil }
            displayID = id
            targetRect = display.frame
        case .interactive, .allDisplays:
            return nil
        }

        guard let descriptor = content.displays.first(where: { $0.id == displayID }),
              let screen = screens.first(where: { screen in
                  (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
              }) else { return nil }
        let positionedRect: ScreenshotRect
        if case .region = target {
            let localRect = CGRect(
                x: CGFloat(targetRect.x - descriptor.frame.x),
                y: CGFloat(targetRect.y - descriptor.frame.y),
                width: CGFloat(targetRect.width),
                height: CGFloat(targetRect.height)
            )
            guard let alignedLocalRect = ScreenshotPixelGeometry.alignedLocalRect(
                localRect,
                displayPointSize: CGSize(
                    width: CGFloat(descriptor.frame.width),
                    height: CGFloat(descriptor.frame.height)
                ),
                displayPixelSize: CGSize(
                    width: CGFloat(descriptor.pixelSize.width),
                    height: CGFloat(descriptor.pixelSize.height)
                ),
                scaleFactor: CGFloat(descriptor.scaleFactor)
            ) else { return nil }
            positionedRect = .init(
                x: descriptor.frame.x + Double(alignedLocalRect.minX),
                y: descriptor.frame.y + Double(alignedLocalRect.minY),
                width: Double(alignedLocalRect.width),
                height: Double(alignedLocalRect.height)
            )
        } else {
            positionedRect = targetRect
        }

        let xOffset = CGFloat(positionedRect.x - descriptor.frame.x)
        let yOffsetFromTop = CGFloat(positionedRect.y - descriptor.frame.y)
        return CGRect(
            x: screen.frame.minX + xOffset,
            y: screen.frame.maxY - yOffsetFromTop - CGFloat(positionedRect.height),
            width: CGFloat(positionedRect.width),
            height: CGFloat(positionedRect.height)
        )
    }

    private func nextAvailableURL(in directory: URL, fileName: String) -> URL {
        let initial = directory.appendingPathComponent(fileName, isDirectory: false)
        guard FileManager.default.fileExists(atPath: initial.path) else { return initial }

        let source = URL(fileURLWithPath: fileName)
        let extensionName = source.pathExtension
        let baseName = source.deletingPathExtension().lastPathComponent
        for suffix in 1...999 {
            let candidateName = extensionName.isEmpty
                ? "\(baseName) (\(suffix))"
                : "\(baseName) (\(suffix)).\(extensionName)"
            let candidate = directory.appendingPathComponent(candidateName, isDirectory: false)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return directory.appendingPathComponent("\(UUID().uuidString)-\(fileName)")
    }

    private func recognizeAndPresent(
        _ artifact: ScreenshotArtifact,
        configuration: ScreenshotFeatureConfiguration
    ) async throws {
        let captureService = captureService
        let recognizedTextClipboardWriter = recognizedTextClipboardWriter
        let recognize: ScreenshotRecognitionPresenting.RetryAction = {
            let result = try await captureService.recognize(.init(
                artifact: artifact,
                configuration: configuration.ocr
            ))
            if configuration.ocr.copiesRecognizedText, !result.fullText.isEmpty {
                try recognizedTextClipboardWriter.writeRecognizedText(result.fullText)
            }
            return result
        }
        do {
            let result = try await recognize()
            recognitionPresenter.present(
                artifact: artifact,
                presentation: .result(result),
                retry: recognize
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ScreenshotFeatureError where error == .cancelled {
            throw error
        } catch {
            recognitionPresenter.present(
                artifact: artifact,
                presentation: .failure(message: ScreenshotRecognitionErrorMessage.text(for: error)),
                retry: recognize
            )
        }
    }

    private func recognizeAndTranslate(
        _ artifact: ScreenshotArtifact,
        configuration: ScreenshotFeatureConfiguration
    ) async throws {
        do {
            let result = try await captureService.recognize(.init(
                artifact: artifact,
                configuration: configuration.ocr
            ))
            try Task.checkCancellation()
            let text = result.fullText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                presentTranslationFeedback("未识别到可翻译的文字，请重新选择区域。")
                await deleteTemporaryArtifact(artifact, using: captureService)
                return
            }
            translationRequestHandler(.init(
                text: text,
                source: .screenCapture,
                recognizedLanguageCode: nil
            ))
        } catch is CancellationError {
            presentTranslationFeedback("识别已取消，请重新选择区域。")
        } catch let error as ScreenshotFeatureError where error == .cancelled {
            presentTranslationFeedback("识别已取消，请重新选择区域。")
        } catch {
            presentTranslationFeedback(
                "\(ScreenshotRecognitionErrorMessage.text(for: error))，请重新选择区域。"
            )
        }
        await deleteTemporaryArtifact(artifact, using: captureService)
    }

    private func presentTranslationFeedback(_ message: String) {
        translationFeedbackPresenter.present(message: message) { [weak self] in
            self?.retryTranslationCapture()
        }
    }

    private func retryTranslationCapture() {
        guard captureTask == nil else {
            pendingTranslationRetry = true
            return
        }
        Task { @MainActor [weak self] in
            _ = try? await self?.route(.captureDefaultMode)
        }
    }

    private func pickColor() async throws -> FeatureActionResult {
        guard requestAuthorization() == .authorized else {
            return .requiresSetup(message: "请允许一念录制屏幕")
        }

        hideLauncherIfNeeded()
        let captureID = UUID()
        let presenter = colorPickerFactory()
        activeColorPickerPresenter = presenter
        let captureService = captureService
        let colorClipboardWriter = colorClipboardWriter
        let task = Task { @MainActor in
            let content = try await captureService.availableSelectionContent()
            guard let color = await presenter.pick(from: content) else {
                return CaptureFlowOutcome.cancelled
            }
            try Task.checkCancellation()
            try colorClipboardWriter.write(color)
            return .result(.completed)
        }
        activeCaptureID = captureID
        captureTask = task

        do {
            let outcome = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
                Task { @MainActor in presenter.cancel() }
            }
            finishCapture(id: captureID)
            return finish(outcome)
        } catch is CancellationError {
            finishCapture(id: captureID)
            return .completed
        } catch let error as ScreenshotFeatureError where error == .cancelled {
            finishCapture(id: captureID)
            return .completed
        } catch {
            finishCapture(id: captureID)
            throw error
        }
    }

    private func hideLauncherIfNeeded() {
        if launcher?.isLauncherVisible == true {
            launcher?.hideLauncher()
        }
    }

    private func finish(_ outcome: CaptureFlowOutcome) -> FeatureActionResult {
        switch outcome {
        case .cancelled:
            // 用户主动按 Escape 或点击取消时，截图流程应安静结束，不能把启动器
            // 强行带回前台打断用户正在使用的应用。
            return .completed
        case .result(let result):
            return result
        }
    }

    private static func mode(for target: ScreenshotCaptureTarget) -> ScreenshotCaptureMode {
        switch target {
        case .region:
            .region
        case .window:
            .window
        case .display:
            .fullScreen
        case .allDisplays:
            .allDisplays
        case .interactive:
            .region
        }
    }

    private func finishCapture(id: UUID) {
        guard activeCaptureID == id else { return }
        activeSelectionPresenter = nil
        activeColorPickerPresenter = nil
        activeCaptureID = nil
        captureTask = nil
        if pendingTranslationRetry {
            pendingTranslationRetry = false
            retryTranslationCapture()
        }
    }
}

private func deleteTemporaryArtifact(
    _ artifact: ScreenshotArtifact,
    using captureService: any ScreenshotCapturing
) async {
    // 清理任务不能继承工作台任务的取消状态。等待其完成后再返回，保证临时截图
    // 不会在 OCR 窗口已经出现后继续残留在截图服务目录中。
    let cleanupTask = Task.detached(priority: .utility) {
        try? await captureService.deleteArtifact(artifact)
    }
    await cleanupTask.value
}

private enum ScreenshotWorkspacePreviewDataLoader {
    static func load(_ artifact: ScreenshotArtifact) async -> Data? {
        await Task.detached(priority: .utility) {
            loadSynchronously(artifact)
        }.value
    }

    private static func loadSynchronously(_ artifact: ScreenshotArtifact) -> Data? {
        guard let paths = try? ScreenshotFeaturePaths.applicationSupport() else { return nil }

        if let thumbnailRelativePath = artifact.thumbnailRelativePath,
           let thumbnailURL = try? paths.resolve(relativePath: thumbnailRelativePath),
           let thumbnailData = try? Data(contentsOf: thumbnailURL),
           !thumbnailData.isEmpty {
            return thumbnailData
        }

        guard let sourceURL = try? paths.resolve(relativePath: artifact.relativePath) else {
            return nil
        }
        return downsampledPNGData(from: sourceURL, maximumPixelSize: 720)
    }

    private static func downsampledPNGData(
        from sourceURL: URL,
        maximumPixelSize: Int
    ) -> Data? {
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
