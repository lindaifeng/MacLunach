import AppKit
import TouchFeatureAPI
import XCTest
@testable import 触达

@MainActor
final class LauncherPanelTests: XCTestCase {
    func testLauncherUses2160By1120RetinaDesignCanvas() {
        XCTAssertEqual(LauncherPanelController.contentSize, NSSize(width: 1_080, height: 560))
    }

    func testLauncherCentersAgainstCompleteScreenFrame() {
        let screenFrame = NSRect(x: -1_920, y: 120, width: 1_920, height: 1_080)

        let origin = LauncherPanelController.centeredOrigin(
            panelSize: NSSize(width: 1_080, height: 560),
            in: screenFrame
        )

        XCTAssertEqual(origin, NSPoint(x: -1_500, y: 380))
    }

    func testSettingsCenterAgainstCompleteScreenFrame() {
        let screenFrame = NSRect(x: -1_920, y: 120, width: 1_920, height: 1_080)

        let origin = SettingsWindowController.centeredOrigin(
            windowSize: NSSize(width: 800, height: 540),
            in: screenFrame
        )

        XCTAssertEqual(origin, NSPoint(x: -1_360, y: 390))
    }

    func testLauncherShortcutPreferencesRoundTripExactlyOneModifierAndSpace() {
        let suiteName = "LauncherShortcutPreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let shortcut = TouchFeatureAPI.KeyboardShortcut(modifiers: [.control], key: "space")

        LauncherShortcutPreferences.save(shortcut, defaults: defaults)

        XCTAssertEqual(LauncherShortcutPreferences.load(defaults: defaults), shortcut)
        XCTAssertEqual(shortcut.displayValue, "⌃Space")
    }

    func testSearchTextViewAppliesReadableAppearance() {
        let textView = SearchTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 32))
        let textColor = NSColor(calibratedWhite: 1, alpha: 1)
        let placeholderColor = NSColor(calibratedWhite: 1, alpha: 0.64)

        textView.applyAppearance(textColor: textColor, placeholderColor: placeholderColor)

        XCTAssertEqual(textView.textColor, textColor)
        XCTAssertEqual(textView.insertionPointColor, textColor)
        XCTAssertEqual(textView.placeholderColor, placeholderColor)
    }

    func testSearchTextViewSynchronizesFocusWhenItBecomesFirstResponder() {
        let panel = LauncherPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let textView = SearchTextView(frame: panel.contentView?.bounds ?? .zero)
        var focusChanges: [Bool] = []
        textView.onFocusChange = { focusChanges.append($0) }
        panel.contentView = textView

        XCTAssertTrue(panel.makeFirstResponder(textView))
        XCTAssertEqual(focusChanges.last, true)

        XCTAssertTrue(panel.makeFirstResponder(nil))
        XCTAssertEqual(focusChanges.last, false)
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

    func testSearchTextViewDoesNotRoutePrintableCharactersToLauncherShortcuts() throws {
        let panel = LauncherPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let textView = SearchTextView(frame: panel.contentView?.bounds ?? .zero)
        panel.contentView = textView
        XCTAssertTrue(panel.makeFirstResponder(textView))

        let character = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: panel.windowNumber,
                context: nil,
                characters: "d",
                charactersIgnoringModifiers: "d",
                isARepeat: false,
                keyCode: 2
            )
        )

        XCTAssertFalse(panel.shouldRouteToSearchKeyHandler(character))
    }

    func testMouseClickDistinguishesSearchFieldFromOutsideContent() throws {
        let panel = LauncherPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
        let textView = SearchTextView(frame: NSRect(x: 20, y: 40, width: 180, height: 32))
        contentView.addSubview(textView)
        let decorativeOverlay = NSView(frame: textView.frame)
        contentView.addSubview(decorativeOverlay)
        panel.contentView = contentView

        let insideEvent = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: NSPoint(x: 40, y: 50),
                modifierFlags: [],
                timestamp: 0,
                windowNumber: panel.windowNumber,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: 1
            )
        )
        let outsideEvent = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: NSPoint(x: 280, y: 50),
                modifierFlags: [],
                timestamp: 0,
                windowNumber: panel.windowNumber,
                context: nil,
                eventNumber: 2,
                clickCount: 1,
                pressure: 1
            )
        )

        XCTAssertTrue(panel.clickIsInsideSearchField(insideEvent))
        XCTAssertFalse(panel.clickIsInsideSearchField(outsideEvent))
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
