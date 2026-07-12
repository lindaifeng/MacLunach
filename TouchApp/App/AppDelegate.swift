import AppKit
import TouchCore
import TouchFeatureAPI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var launcherPanelController: LauncherPanelController?
    private var settingsWindowController: SettingsWindowController?
    private var applicationCatalog: ApplicationCatalog?
    private var shouldRestoreLauncherAfterSettingsClose = false
    private let globalHotKeyController = GlobalHotKeyController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let applicationCatalog = ApplicationCatalog(
            discoverer: WorkspaceApplicationDiscoverer(),
            launcher: WorkspaceApplicationLauncher()
        )
        self.applicationCatalog = applicationCatalog
        Task {
            _ = await applicationCatalog.refresh()
        }
        launcherPanelController = LauncherPanelController()
        settingsWindowController = SettingsWindowController { [weak self] in
            self?.restoreLauncherAfterSettingsClose()
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(showSettings),
            name: .openTouchSettings,
            object: nil
        )

        if let measurementArgument = CommandLine.arguments.first(where: { $0.hasPrefix("--measure-launcher=") }),
           let outputPath = measurementArgument.split(separator: "=", maxSplits: 1).last {
            let outputURL = URL(fileURLWithPath: String(outputPath))
            Task { @MainActor [weak self] in
                await self?.launcherPanelController?.runPerformanceMeasurement(samples: 30, outputURL: outputURL)
            }
        } else if CommandLine.arguments.contains("--open-settings") {
            Task { @MainActor [weak self] in
                self?.showSettings()
            }
        } else {
            Task { @MainActor [weak self] in
                self?.launcherPanelController?.show()
            }
        }
        do {
            try globalHotKeyController.start(shortcut: .init(modifiers: [.option], key: "space")) { [weak self] in
                self?.launcherPanelController?.toggle()
            }
        } catch {
            NSLog("Unable to register Touch launcher shortcut: %@", error.localizedDescription)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        globalHotKeyController.stop()
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func showSettings() {
        shouldRestoreLauncherAfterSettingsClose = launcherPanelController?.isVisible ?? false
        if shouldRestoreLauncherAfterSettingsClose {
            launcherPanelController?.hide()
        }
        settingsWindowController?.show()
    }

    private func restoreLauncherAfterSettingsClose() {
        guard shouldRestoreLauncherAfterSettingsClose else { return }
        shouldRestoreLauncherAfterSettingsClose = false
        launcherPanelController?.show()
    }
}
