import AppKit

final class LauncherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 48 {
            NotificationCenter.default.post(name: .toggleTouchSearchMode, object: nil)
            return
        }
        super.sendEvent(event)
    }
}
