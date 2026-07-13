import AppKit
import XCTest

@MainActor
final class ScreenshotSelectionTests: XCTestCase {
    func testDragKeyboardNudgeAndEnterCompletesSelection() throws {
        let outputURL = temporaryOutputURL()
        let app = launchSelectionFixture(outputURL: outputURL)
        let overlay = selectionOverlays(in: app).firstMatch
        XCTAssertTrue(overlay.waitForExistence(timeout: 3))

        let start = overlay.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.2))
        let end = overlay.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.55))
        start.press(forDuration: 0.1, thenDragTo: end)

        let label = app.staticTexts["screenshot.selection.size-label"]
        XCTAssertTrue(label.waitForExistence(timeout: 2))
        XCTAssertFalse(label.label.isEmpty)
        XCTAssertTrue(label.label.contains("像素"), label.label)
        app.typeKey(.rightArrow, modifierFlags: [])
        app.typeKey(.downArrow, modifierFlags: [.shift])
        app.typeKey(.enter, modifierFlags: [])

        XCTAssertTrue(waitForFile(at: outputURL, timeout: 3))
        let result = try String(contentsOf: outputURL, encoding: .utf8)
        XCTAssertTrue(result.contains("region"), result)
        XCTAssertFalse(overlay.exists)
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
        let overlay = selectionOverlays(in: app).firstMatch
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
        let overlay = selectionOverlays(in: app).firstMatch
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

    private func launchSelectionFixture(outputURL: URL) -> XCUIApplication {
        try? FileManager.default.removeItem(at: outputURL)
        let app = XCUIApplication()
        app.launchArguments = [
            "--screenshot-selection-fixture",
            "--screenshot-selection-output=\(outputURL.path)"
        ]
        app.launch()
        return app
    }

    private func selectionOverlays(in app: XCUIApplication) -> XCUIElementQuery {
        // NSPanel 在 macOS 辅助功能树中使用 Dialog 角色，不属于 app.windows。
        app.descendants(matching: .any).matching(identifier: "screenshot.selection.overlay")
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
