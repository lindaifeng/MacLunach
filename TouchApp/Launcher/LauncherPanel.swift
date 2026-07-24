import AppKit

final class LauncherPanel: NSPanel {
    var searchKeyHandler: ((NSEvent) -> Bool)?
    var outsideSearchClickHandler: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if shouldRouteToSearchKeyHandler(event), searchKeyHandler?(event) == true {
            return
        }
        let clickedOutsideSearch = event.type == .leftMouseDown && !clickIsInsideSearchField(event)
        super.sendEvent(event)
        if clickedOutsideSearch {
            outsideSearchClickHandler?()
        }
    }

    func clickIsInsideSearchField(_ event: NSEvent) -> Bool {
        guard let contentView else { return false }
        return contentView
            .descendantSearchTextViews
            .contains { textView in
                let location = textView.convert(event.locationInWindow, from: nil)
                return textView.bounds.contains(location)
            }
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
        if firstResponder is any NSTextInputClient {
            return Self.isLauncherControlKey(event)
        }
        return true
    }

    private static func isLauncherControlKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 36, 49, 48, 53, 76, 125, 126:
            return true
        default:
            return false
        }
    }

}

private extension NSView {
    var descendantSearchTextViews: [SearchTextView] {
        subviews.flatMap { view in
            (view as? SearchTextView).map { [$0] } ?? view.descendantSearchTextViews
        }
    }
}
