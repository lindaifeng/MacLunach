import AppKit
import TouchFeatureAPI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var launcherPanelController: LauncherPanelController?
    private let globalHotKeyController = GlobalHotKeyController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        launcherPanelController = LauncherPanelController()
        launcherPanelController?.show()
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
    }
}
