import Foundation
import ScreenshotFeature
import TouchFeatureAPI

public enum ScreenshotCoordinatorError: Error, Equatable, Sendable {
    case busy
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

    private let authorization: any ScreenRecordingAuthorizing
    private let captureService: any ScreenshotCapturing
    private let selectionFactory: SelectionFactory
    private let invalidateService: ServiceInvalidation
    private let registerShortcuts: ShortcutAction
    private let unregisterShortcuts: ShortcutAction

    private weak var launcher: (any ScreenshotLauncherPresenting)?
    private var captureTask: Task<Bool, any Error>?
    private var activeCaptureID: UUID?
    private var activeSelectionPresenter: (any ScreenshotSelectionPresenting)?
    private var isEnabled = true

    init(
        authorization: any ScreenRecordingAuthorizing,
        captureService: any ScreenshotCapturing,
        selectionFactory: @escaping SelectionFactory = { SelectionOverlayController() },
        invalidateService: @escaping ServiceInvalidation = {},
        registerShortcuts: @escaping ShortcutAction = {},
        unregisterShortcuts: @escaping ShortcutAction = {}
    ) {
        self.authorization = authorization
        self.captureService = captureService
        self.selectionFactory = selectionFactory
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
        captureTask?.cancel()
        unregisterShortcuts()
        await invalidateService()
    }

    private func captureDefaultMode() async throws -> FeatureActionResult {
        guard requestAuthorization() == .authorized else {
            return .requiresSetup(message: "请允许触达录制屏幕")
        }

        let shouldRestoreLauncher = launcher?.isLauncherVisible ?? false
        if shouldRestoreLauncher {
            launcher?.hideLauncher()
        }

        let captureID = UUID()
        let presenter = selectionFactory()
        activeSelectionPresenter = presenter
        let captureService = captureService
        let task = Task { @MainActor in
            let content = try await captureService.availableSelectionContent()
            guard let target = await presenter.select(from: content) else {
                return false
            }
            try Task.checkCancellation()
            let request = ScreenshotCaptureRequest(
                mode: Self.mode(for: target),
                target: target
            )
            try await captureService.capture(request)
            return true
        }
        activeCaptureID = captureID
        captureTask = task

        do {
            let didCapture = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
                Task { @MainActor in presenter.cancel() }
            }
            finishCapture(id: captureID)
            if !didCapture, shouldRestoreLauncher {
                launcher?.showLauncher()
            }
            return .completed
        } catch {
            finishCapture(id: captureID)
            if shouldRestoreLauncher {
                launcher?.showLauncher()
            }
            throw error
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
        activeCaptureID = nil
        captureTask = nil
    }
}
