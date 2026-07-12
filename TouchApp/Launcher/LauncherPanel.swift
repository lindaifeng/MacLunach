import AppKit

final class LauncherPanel: NSPanel {
    var searchKeyHandler: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if shouldRouteToSearchKeyHandler(event), searchKeyHandler?(event) == true {
            return
        }
        super.sendEvent(event)
    }

    func shouldRouteToSearchKeyHandler(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        if event.keyCode == 48, event.modifierFlags.contains(.command) {
            return false
        }
        if let inputClient = firstResponder as? any NSTextInputClient,
           inputClient.hasMarkedText() {
            return false
        }
        return true
    }
}
