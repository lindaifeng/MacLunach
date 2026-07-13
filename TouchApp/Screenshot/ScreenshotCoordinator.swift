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

    private let authorization: any ScreenRecordingAuthorizing
    private let captureService: any ScreenshotCapturing
    private let invalidateService: ServiceInvalidation
    private let registerShortcuts: ShortcutAction
    private let unregisterShortcuts: ShortcutAction

    private weak var launcher: (any ScreenshotLauncherPresenting)?
    private var captureTask: Task<Void, any Error>?
    private var activeCaptureID: UUID?
    private var isEnabled = true

    init(
        authorization: any ScreenRecordingAuthorizing,
        captureService: any ScreenshotCapturing,
        invalidateService: @escaping ServiceInvalidation = {},
        registerShortcuts: @escaping ShortcutAction = {},
        unregisterShortcuts: @escaping ShortcutAction = {}
    ) {
        self.authorization = authorization
        self.captureService = captureService
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
        let task = Task { try await captureService.capturePrimaryDisplay() }
        activeCaptureID = captureID
        captureTask = task

        do {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            finishCapture(id: captureID)
            return .completed
        } catch {
            finishCapture(id: captureID)
            if shouldRestoreLauncher {
                launcher?.showLauncher()
            }
            throw error
        }
    }

    private func finishCapture(id: UUID) {
        guard activeCaptureID == id else { return }
        activeCaptureID = nil
        captureTask = nil
    }
}
