import AppKit
import SwiftUI

extension Notification.Name {
    static let openTouchSettings = Notification.Name("me.touch.open-settings")
}

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let onClose: () -> Void
    private let navigation = SettingsNavigationModel()

    init(
        searchEnvironment: SearchEnvironment,
        featureStore: FeatureAreaStore,
        screenshotEnvironment: ScreenshotEnvironment,
        themeStore: ThemeStore,
        onClose: @escaping () -> Void
    ) {
        self.onClose = onClose
        let rootView = SettingsRootView(searchEnvironment: searchEnvironment, navigation: navigation)
            .environmentObject(featureStore)
            .environmentObject(screenshotEnvironment)
            .environmentObject(themeStore)
        let window = NSWindow(contentViewController: NSHostingController(rootView: rootView))
        window.title = "一念设置"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.setContentSize(NSSize(width: 800, height: 540))
        window.minSize = NSSize(width: 740, height: 500)
        if let screen = NSScreen.main {
            window.setFrameOrigin(Self.centeredOrigin(windowSize: window.frame.size, in: screen.frame))
        }
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.standardWindowButton(.closeButton)?.identifier = NSUserInterfaceItemIdentifier("settings.close")
        installWindowTopDragRegion(in: window)
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(section: TouchSettingsSection = .general) {
        show(destination: TouchSettingsDestination(section: section))
    }

    func show(destination: TouchSettingsDestination) {
        navigation.navigate(to: destination)
        if let window {
            let mouseLocation = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { $0.frame.contains(mouseLocation) }
                ?? window.screen
                ?? NSScreen.main
            if let screen {
                window.setFrameOrigin(
                    Self.centeredOrigin(windowSize: window.frame.size, in: screen.frame)
                )
            }
        }
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    static func centeredOrigin(windowSize: NSSize, in screenFrame: NSRect) -> NSPoint {
        NSPoint(
            x: screenFrame.midX - windowSize.width / 2,
            y: screenFrame.midY - windowSize.height / 2
        )
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}
