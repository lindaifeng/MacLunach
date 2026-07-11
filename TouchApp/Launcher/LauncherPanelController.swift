import AppKit
import SwiftUI

@MainActor
final class LauncherPanelController {
    private let panel: LauncherPanel
    private let themeStore = ThemeStore()

    init() {
        panel = LauncherPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 620),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(
            rootView: LauncherView()
                .environmentObject(themeStore)
                .environmentObject(FeatureAreaStore.shared)
        )
    }

    func show() {
        panel.center()
        NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    func toggle() {
        panel.isVisible ? hide() : show()
    }
}
