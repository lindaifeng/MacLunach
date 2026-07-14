import Foundation
import ScreenshotFeature
import TouchFeatureAPI

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
final class ScreenshotCoordinator: ScreenshotActionRouting {
    typealias ServiceInvalidation = @Sendable () async -> Void
    typealias ShortcutAction = @MainActor @Sendable () -> Void
    typealias SelectionFactory = @MainActor () -> any ScreenshotSelectionPresenting
    typealias ColorPickerFactory = @MainActor () -> any ScreenshotColorPickerPresenting
    typealias ConfigurationProvider = @MainActor () -> ScreenshotFeatureConfiguration

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
    private let colorPickerFactory: ColorPickerFactory
    private let configurationProvider: ConfigurationProvider
    private let invalidateService: ServiceInvalidation
    private let registerShortcuts: ShortcutAction
    private let unregisterShortcuts: ShortcutAction

    private weak var launcher: (any ScreenshotLauncherPresenting)?
    private var captureTask: Task<CaptureFlowOutcome, any Error>?
    private var activeCaptureID: UUID?
    private var activeSelectionPresenter: (any ScreenshotSelectionPresenting)?
    private var activeColorPickerPresenter: (any ScreenshotColorPickerPresenting)?
    private var isEnabled = true

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
        colorPickerFactory: ColorPickerFactory? = nil,
        configurationProvider: @escaping ConfigurationProvider = { .init() },
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
        self.colorPickerFactory = colorPickerFactory ?? {
            ColorPickerController(captureService: captureService)
        }
        self.configurationProvider = configurationProvider
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
        guard captureTask == nil else {
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
        unregisterShortcuts()
        await invalidateService()
    }

    private func captureDefaultMode() async throws -> FeatureActionResult {
        guard requestAuthorization() == .authorized else {
            return .requiresSetup(message: "请允许触达录制屏幕")
        }

        let shouldRestoreLauncher = hideLauncherIfNeeded()
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
            try Task.checkCancellation()

            switch selection.completionAction {
            case .scrollingCapture:
                return .result(try await extensionRouter.start(.init(
                    kind: .scrollingCapture,
                    target: selection.target,
                    windowShadow: selection.windowShadow
                )))
            case .gifRecording:
                return .result(try await extensionRouter.start(.init(
                    kind: .gifRecording,
                    target: selection.target,
                    windowShadow: selection.windowShadow
                )))
            case .copy, .pin, .recognizeText:
                break
            }

            if configuration.defaultDelay != .none {
                try await countdownPresenter.wait(for: configuration.defaultDelay)
                try Task.checkCancellation()
            }
            let request = ScreenshotCaptureRequest(
                mode: selection.completionAction == .recognizeText
                    ? .ocrRegion
                    : Self.mode(for: selection.target),
                // 可见倒计时已在主进程完成。XPC 收到请求后必须立即捕获，
                // 否则会出现双重等待，且 HUD 关闭时间无法与最终帧严格对齐。
                delay: .none,
                target: selection.target,
                windowShadow: selection.windowShadow,
                output: configuration.output,
                annotations: selection.annotations,
                history: configuration.history
            )
            let artifact = try await captureService.captureArtifact(request)
            switch selection.completionAction {
            case .copy:
                if let artifact {
                    try performPostCaptureActions(for: artifact, configuration: configuration)
                }
            case .pin:
                if let artifact {
                    try pinPresenter.pin(artifact)
                }
            case .recognizeText:
                if let artifact {
                    try await recognizeAndPresent(artifact, configuration: configuration)
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
            return finish(outcome, restoringLauncher: shouldRestoreLauncher)
        } catch {
            finishCapture(id: captureID)
            restoreLauncher(if: shouldRestoreLauncher)
            throw error
        }
    }

    private func captureAllDisplays() async throws -> FeatureActionResult {
        guard requestAuthorization() == .authorized else {
            return .requiresSetup(message: "请允许触达录制屏幕")
        }

        let shouldRestoreLauncher = hideLauncherIfNeeded()
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
                try performPostCaptureActions(for: artifact, configuration: configuration)
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
            return finish(outcome, restoringLauncher: shouldRestoreLauncher)
        } catch {
            finishCapture(id: captureID)
            restoreLauncher(if: shouldRestoreLauncher)
            throw error
        }
    }

    private func performPostCaptureActions(
        for artifact: ScreenshotArtifact,
        configuration: ScreenshotFeatureConfiguration
    ) throws {
        let policy = ScreenshotPostCapturePolicy(configuration: configuration)
        if policy.showsThumbnail {
            ScreenshotThumbnailPerformanceRecorder.shared.begin()
        }
        do {
            if policy.copiesToClipboard {
                try clipboardWriter.write(artifact)
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
            // 捕获产物本身已由截图服务持久化到功能私有目录，无需重复复制。
            return
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

    private func pickColor() async throws -> FeatureActionResult {
        guard requestAuthorization() == .authorized else {
            return .requiresSetup(message: "请允许触达录制屏幕")
        }

        let shouldRestoreLauncher = hideLauncherIfNeeded()
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
            return finish(outcome, restoringLauncher: shouldRestoreLauncher)
        } catch {
            finishCapture(id: captureID)
            restoreLauncher(if: shouldRestoreLauncher)
            throw error
        }
    }

    private func hideLauncherIfNeeded() -> Bool {
        let shouldRestoreLauncher = launcher?.isLauncherVisible ?? false
        if shouldRestoreLauncher {
            launcher?.hideLauncher()
        }
        return shouldRestoreLauncher
    }

    private func finish(
        _ outcome: CaptureFlowOutcome,
        restoringLauncher shouldRestoreLauncher: Bool
    ) -> FeatureActionResult {
        switch outcome {
        case .cancelled:
            restoreLauncher(if: shouldRestoreLauncher)
            return .completed
        case .result(let result):
            if case .requiresSetup = result {
                restoreLauncher(if: shouldRestoreLauncher)
            }
            return result
        }
    }

    private func restoreLauncher(if shouldRestoreLauncher: Bool) {
        if shouldRestoreLauncher {
            launcher?.showLauncher()
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
    }
}
