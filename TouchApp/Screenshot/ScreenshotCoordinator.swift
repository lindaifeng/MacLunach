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
    private let pinPresenter: any ScreenshotPinPresenting
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
        clipboardWriter: any ScreenshotClipboardWriting = SystemScreenshotClipboardWriter(),
        colorClipboardWriter: any ScreenshotColorClipboardWriting = SystemScreenshotColorClipboardWriter(),
        pinPresenter: any ScreenshotPinPresenting = ScreenshotPinWindowManager(),
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
        self.pinPresenter = pinPresenter
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
            case .copy, .pin:
                break
            }

            if configuration.defaultDelay != .none {
                try await countdownPresenter.wait(for: configuration.defaultDelay)
                try Task.checkCancellation()
            }
            let request = ScreenshotCaptureRequest(
                mode: Self.mode(for: selection.target),
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
                    try clipboardWriter.write(artifact)
                }
            case .pin:
                if let artifact {
                    try pinPresenter.pin(artifact)
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
                try clipboardWriter.write(artifact)
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
