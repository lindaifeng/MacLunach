import AppKit
import SwiftUI

extension Notification.Name {
    static let openTouchSettings = Notification.Name("me.touch.open-settings")
}

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let onClose: () -> Void
    private let navigation = SettingsNavigationModel()

    init(searchEnvironment: SearchEnvironment, onClose: @escaping () -> Void) {
        self.onClose = onClose
        let rootView = SettingsRootView(searchEnvironment: searchEnvironment, navigation: navigation)
            .environmentObject(FeatureAreaStore.shared)
        let window = NSWindow(contentViewController: NSHostingController(rootView: rootView))
        window.title = "触达设置"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 820, height: 580))
        window.minSize = NSSize(width: 760, height: 540)
        window.center()
        window.isReleasedWhenClosed = false
        window.standardWindowButton(.closeButton)?.identifier = NSUserInterfaceItemIdentifier("settings.close")
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(section: TouchSettingsSection = .general) {
        navigation.section = section
        window?.center()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}
