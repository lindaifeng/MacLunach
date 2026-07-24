import AppKit
import XCTest

@MainActor
final class ScreenshotSelectionTests: XCTestCase {
    func testCommittedSelectionShowsQQToolbarAndCopyCompletesCapture() throws {
        let outputURL = temporaryOutputURL()
        let app = launchSelectionFixture(outputURL: outputURL, preselected: true)
        let toolbar = app.descendants(matching: .any)["screenshot.selection.toolbar"]

        XCTAssertTrue(toolbar.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["screenshot.selection.toolbar.rectangle"].exists)
        XCTAssertTrue(app.buttons["screenshot.selection.toolbar.recognizeText"].exists)
        XCTAssertTrue(app.buttons["screenshot.selection.toolbar.copy"].exists)
        XCTAssertFalse(app.staticTexts["screenshot.selection.size-label"].exists)

        app.buttons["screenshot.selection.toolbar.rectangle"].click()
        let status = app.staticTexts["screenshot.selection.toolbar.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 2))
        XCTAssertTrue(status.label.contains("矩形"), status.label)

        app.buttons["screenshot.selection.toolbar.copy"].click()
        XCTAssertTrue(waitForFile(at: outputURL, timeout: 3))
        let result = try String(contentsOf: outputURL, encoding: .utf8)
        XCTAssertTrue(result.contains("region"), result)
    }

    func testTextToolKeepsSelectionOpenAndArrowShowsContinuousSizeSlider() throws {
        let outputURL = temporaryOutputURL()
        let app = launchSelectionFixture(outputURL: outputURL, preselected: true)
        let overlay = activeSelectionOverlay(in: app)
        XCTAssertTrue(overlay.waitForExistence(timeout: 3))

        app.buttons["screenshot.selection.toolbar.arrow"].click()
        XCTAssertTrue(app.sliders["screenshot.selection.options.arrow-size"].waitForExistence(timeout: 2))

        app.buttons["screenshot.selection.toolbar.text"].click()
        overlay.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.4)).click()

        XCTAssertTrue(app.textViews["screenshot.selection.inline-text-editor"].waitForExistence(timeout: 2))
        XCTAssertTrue(overlay.exists)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
        app.textViews["screenshot.selection.inline-text-editor"].click()
        app.textViews["screenshot.selection.inline-text-editor"].typeText("text-input-ok")
        XCTAssertTrue(
            String(describing: app.textViews["screenshot.selection.inline-text-editor"].value)
                .contains("text-input-ok")
        )
        app.buttons["screenshot.selection.toolbar.copy"].click()
        XCTAssertTrue(waitForFile(at: outputURL, timeout: 3))
        let result = try String(contentsOf: outputURL, encoding: .utf8)
        XCTAssertTrue(result.contains("text-input-ok"), result)
        XCTAssertTrue(result.contains("text"), result)
    }

    func testToolbarHoverShowsChineseFunctionName() {
        let outputURL = temporaryOutputURL()
        let app = launchSelectionFixture(outputURL: outputURL, preselected: true)
        let arrow = app.buttons["screenshot.selection.toolbar.arrow"]
        XCTAssertTrue(arrow.waitForExistence(timeout: 3))

        arrow.hover()

        let label = app.staticTexts["screenshot.selection.toolbar.hover-label"]
        XCTAssertTrue(label.waitForExistence(timeout: 2))
        XCTAssertEqual(label.label, "箭头")
        app.typeKey(.escape, modifierFlags: [])
    }

    func testDragKeyboardNudgeAndEnterCompletesSelection() throws {
        let outputURL = temporaryOutputURL()
        let app = launchSelectionFixture(outputURL: outputURL)
        let overlay = activeSelectionOverlay(in: app)
        XCTAssertTrue(overlay.waitForExistence(timeout: 3))

        let start = overlay.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.2))
        let end = overlay.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.55))
        start.press(forDuration: 0.1, thenDragTo: end)

        let toolbar = app.descendants(matching: .any)["screenshot.selection.toolbar"]
        XCTAssertTrue(toolbar.waitForExistence(timeout: 2))
        XCTAssertFalse(app.staticTexts["screenshot.selection.size-label"].exists)
        app.typeKey(.rightArrow, modifierFlags: [])
        app.typeKey(.downArrow, modifierFlags: [.shift])
        app.typeKey(.enter, modifierFlags: [])

        XCTAssertTrue(waitForFile(at: outputURL, timeout: 3))
        let result = try String(contentsOf: outputURL, encoding: .utf8)
        XCTAssertTrue(result.contains("region"), result)
        XCTAssertFalse(overlay.exists)
    }

    func testWorkspaceSelectionCompletesImmediatelyWhenDragEnds() throws {
        let outputURL = temporaryOutputURL()
        let app = launchSelectionFixture(outputURL: outputURL, autoComplete: true)
        let overlay = activeSelectionOverlay(in: app)
        XCTAssertTrue(overlay.waitForExistence(timeout: 3))

        let start = overlay.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.2))
        let end = overlay.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.55))
        start.press(forDuration: 0.1, thenDragTo: end)

        XCTAssertTrue(waitForFile(at: outputURL, timeout: 3))
        let result = try String(contentsOf: outputURL, encoding: .utf8)
        XCTAssertTrue(result.contains("region"), result)
        XCTAssertFalse(overlay.exists)
        XCTAssertFalse(app.descendants(matching: .any)["screenshot.selection.toolbar"].exists)
    }

    func testEnterWithoutSelectionDoesNothingAndEscapeCancelsAllOverlays() {
        let outputURL = temporaryOutputURL()
        let app = launchSelectionFixture(outputURL: outputURL)
        let overlays = selectionOverlays(in: app)
        XCTAssertEqual(overlays.count, NSScreen.screens.count)

        app.typeKey(.enter, modifierFlags: [])
        XCTAssertTrue(overlays.firstMatch.exists)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))

        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitUntil(timeout: 2) { !overlays.firstMatch.exists })
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
    }

    func testPointerSnapsToWindowAndEnterCapturesWindow() throws {
        let outputURL = temporaryOutputURL()
        let app = launchSelectionFixture(outputURL: outputURL)
        let overlay = activeSelectionOverlay(in: app)
        XCTAssertTrue(overlay.waitForExistence(timeout: 3))

        overlay.coordinate(withNormalizedOffset: CGVector(dx: 0.72, dy: 0.25)).hover()
        XCTAssertTrue(app.staticTexts["screenshot.selection.size-label"].waitForExistence(timeout: 2))
        app.typeKey(.enter, modifierFlags: [])

        XCTAssertTrue(waitForFile(at: outputURL, timeout: 3))
        let result = try String(contentsOf: outputURL, encoding: .utf8)
        XCTAssertTrue(result.contains("window"), result)
        XCTAssertTrue(result.contains("990001"), result)
    }

    func testDraggingPastSnapThresholdReleasesToRegionSelection() throws {
        let outputURL = temporaryOutputURL()
        let app = launchSelectionFixture(outputURL: outputURL)
        let overlay = activeSelectionOverlay(in: app)
        XCTAssertTrue(overlay.waitForExistence(timeout: 3))

        let snappedPoint = overlay.coordinate(
            withNormalizedOffset: CGVector(dx: 0.72, dy: 0.25)
        )
        snappedPoint.hover()
        snappedPoint.press(
            forDuration: 0.1,
            thenDragTo: overlay.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.52))
        )
        app.typeKey(.enter, modifierFlags: [])

        XCTAssertTrue(waitForFile(at: outputURL, timeout: 3))
        let result = try String(contentsOf: outputURL, encoding: .utf8)
        XCTAssertTrue(result.contains("region"), result)
        XCTAssertFalse(result.contains("990001"), result)
    }

    private func launchSelectionFixture(
        outputURL: URL,
        preselected: Bool = false,
        autoComplete: Bool = false
    ) -> XCUIApplication {
        try? FileManager.default.removeItem(at: outputURL)
        let app = XCUIApplication()
        app.launchArguments = [
            "--screenshot-selection-fixture",
            "--screenshot-selection-output=\(outputURL.path)"
        ]
        if preselected {
            app.launchArguments.append("--screenshot-selection-preselected")
        }
        if autoComplete {
            app.launchArguments.append("--screenshot-selection-auto-complete")
        }
        app.launch()
        return app
    }

    private func selectionOverlays(in app: XCUIApplication) -> XCUIElementQuery {
        // NSPanel 在 macOS 辅助功能树中使用 Dialog 角色，不属于 app.windows。
        app.descendants(matching: .any).matching(identifier: "screenshot.selection.overlay")
    }

    private func activeSelectionOverlay(in app: XCUIApplication) -> XCUIElement {
        let overlays = selectionOverlays(in: app)
        _ = waitUntil(timeout: 3) { overlays.count == NSScreen.screens.count }

        let mainDisplayBounds = CGDisplayBounds(CGMainDisplayID())
        return overlays.allElementsBoundByIndex.max { lhs, rhs in
            overlapArea(lhs.frame, mainDisplayBounds) < overlapArea(rhs.frame, mainDisplayBounds)
        } ?? overlays.firstMatch
    }

    private func overlapArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull, !intersection.isEmpty else { return 0 }
        return intersection.width * intersection.height
    }

    private func temporaryOutputURL() -> URL {
        URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("touch-selection-ui-\(UUID().uuidString).txt")
    }

    private func waitForFile(at url: URL, timeout: TimeInterval) -> Bool {
        waitUntil(timeout: timeout) { FileManager.default.fileExists(atPath: url.path) }
    }

    private func waitUntil(timeout: TimeInterval, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }
}
