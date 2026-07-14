import AppKit
import XCTest
@testable import 触达

@MainActor
final class LauncherPanelTests: XCTestCase {
    func testSearchTextViewAppliesReadableAppearance() {
        let textView = SearchTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 32))
        let textColor = NSColor(calibratedWhite: 1, alpha: 1)
        let placeholderColor = NSColor(calibratedWhite: 1, alpha: 0.64)

        textView.applyAppearance(textColor: textColor, placeholderColor: placeholderColor)

        XCTAssertEqual(textView.textColor, textColor)
        XCTAssertEqual(textView.insertionPointColor, textColor)
        XCTAssertEqual(textView.placeholderColor, placeholderColor)
    }

    func testMarkedTextKeepsNavigationKeysInInputMethod() throws {
        let panel = LauncherPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let textView = SearchTextView(frame: panel.contentView?.bounds ?? .zero)
        panel.contentView = textView
        XCTAssertTrue(panel.makeFirstResponder(textView))
        textView.setMarkedText("design", selectedRange: NSRange(location: 6, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let downArrow = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: panel.windowNumber,
                context: nil,
                characters: "\u{F701}",
                charactersIgnoringModifiers: "\u{F701}",
                isARepeat: false,
                keyCode: 125
            )
        )

        XCTAssertFalse(panel.shouldRouteToSearchKeyHandler(downArrow))
    }

    func testCommittedTextRoutesNavigationKeysToLauncher() throws {
        let panel = LauncherPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let textView = SearchTextView(frame: panel.contentView?.bounds ?? .zero)
        panel.contentView = textView
        XCTAssertTrue(panel.makeFirstResponder(textView))
        textView.string = "design"
        let downArrow = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: panel.windowNumber,
                context: nil,
                characters: "\u{F701}",
                charactersIgnoringModifiers: "\u{F701}",
                isARepeat: false,
                keyCode: 125
            )
        )

        XCTAssertTrue(panel.shouldRouteToSearchKeyHandler(downArrow))
    }

    func testCommandTabRemainsAvailableToSystemApplicationSwitcher() throws {
        let panel = LauncherPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let commandTab = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.command],
                timestamp: 0,
                windowNumber: panel.windowNumber,
                context: nil,
                characters: "\t",
                charactersIgnoringModifiers: "\t",
                isARepeat: false,
                keyCode: 48
            )
        )

        XCTAssertFalse(panel.shouldRouteToSearchKeyHandler(commandTab))
    }
}
