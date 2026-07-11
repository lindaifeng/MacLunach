import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var launcherPanelController: LauncherPanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        launcherPanelController = LauncherPanelController()
        launcherPanelController?.show()
    }
}
