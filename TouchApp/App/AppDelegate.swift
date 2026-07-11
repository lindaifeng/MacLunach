import AppKit
import TouchFeatureAPI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var launcherPanelController: LauncherPanelController?
    private var settingsWindowController: SettingsWindowController?
    private let globalHotKeyController = GlobalHotKeyController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        launcherPanelController = LauncherPanelController()
        settingsWindowController = SettingsWindowController()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(showSettings),
            name: .openTouchSettings,
            object: nil
        )

        if CommandLine.arguments.contains("--open-settings") {
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
        launcherPanelController?.hide()
        settingsWindowController?.show()
    }
}
