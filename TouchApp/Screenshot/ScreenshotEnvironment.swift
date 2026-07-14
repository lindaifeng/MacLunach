import ScreenshotFeature
import SwiftUI

@MainActor
final class ScreenshotEnvironment: ObservableObject {
    @Published private(set) var permissionState: ScreenshotPermissionState

    let coordinator: ScreenshotCoordinator

    init(
        defaults: UserDefaults = .standard,
        authorization: (any ScreenRecordingAuthorizing)? = nil,
        captureService: (any ScreenshotCapturing)? = nil,
        clipboardWriter: (any ScreenshotClipboardWriting)? = nil,
        client: ScreenshotClient = ScreenshotClient(),
        selectionFactory: @escaping ScreenshotCoordinator.SelectionFactory = {
            SelectionOverlayController()
        },
        registerShortcuts: @escaping ScreenshotCoordinator.ShortcutAction = {},
        unregisterShortcuts: @escaping ScreenshotCoordinator.ShortcutAction = {}
    ) {
        let authorizer = authorization ?? SystemScreenRecordingAuthorizer(defaults: defaults)
        let captureService = captureService ?? XPCScreenCaptureService(client: client)
        permissionState = authorizer.status
        coordinator = ScreenshotCoordinator(
            authorization: authorizer,
            captureService: captureService,
            clipboardWriter: clipboardWriter ?? SystemScreenshotClipboardWriter(),
            selectionFactory: selectionFactory,
            configurationProvider: {
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

    func requestPermission() {
        permissionState = coordinator.requestAuthorization()
    }

    func openSystemSettings() {
        coordinator.openSystemSettings()
    }
}
