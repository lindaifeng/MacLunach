import AppKit
import SwiftUI

extension Notification.Name {
    static let openTouchSettings = Notification.Name("me.touch.open-settings")
}

@MainActor
final class SettingsWindowController: NSWindowController {
    init() {
        let rootView = SettingsRootView().environmentObject(FeatureAreaStore.shared)
        let window = NSWindow(contentViewController: NSHostingController(rootView: rootView))
        window.title = "触达设置"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 820, height: 580))
        window.minSize = NSSize(width: 760, height: 540)
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        window?.center()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
