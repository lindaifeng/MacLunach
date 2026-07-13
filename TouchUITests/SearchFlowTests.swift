import AppKit
import XCTest

@MainActor
final class SearchFlowTests: XCTestCase {
    func testTypingQueryReplacesCardsAndEscapeRestoresCards() throws {
        let app = launchFixture()
        let searchField = focusedSearchField(in: app)

        searchField.typeText("finder")
        XCTAssertTrue(app.staticTexts["Finder"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.buttons["feature.me.touch.finder"].exists)

        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.buttons["feature.me.touch.finder"].waitForExistence(timeout: 2))
    }

    func testTabPreservesQueryAndSearchesFiles() throws {
        let app = launchFixture()
        let searchField = focusedSearchField(in: app)
        paste("design", into: searchField)

        app.typeKey(.tab, modifierFlags: [])

        XCTAssertTrue(app.staticTexts["Design Brief.txt"].waitForExistence(timeout: 2))
        XCTAssertEqual(searchField.value as? String, "design")
    }

    func testSpaceCanBeTypedInMultiwordFileQueryBeforeArrowNavigation() throws {
        let app = launchFixture()
        let searchField = focusedSearchField(in: app)
        app.typeKey(.tab, modifierFlags: [])

        paste("design", into: searchField)
        app.typeKey(.space, modifierFlags: [])
        paste("brief", into: searchField)

        XCTAssertTrue(app.staticTexts["Design Brief.txt"].waitForExistence(timeout: 2))
        XCTAssertEqual(searchField.value as? String, "design brief")
    }

    func testFileKeyboardActionsInvokePreviewRevealAndOpen() throws {
        try assertFileAction(key: .space, modifiers: [], expectedPrefix: "preview|")
        try assertFileAction(key: .return, modifiers: [.command], expectedPrefix: "reveal|")
        try assertFileAction(key: .return, modifiers: [], expectedPrefix: "open|")
    }

    func testApplicationReturnLaunchesSelectedResultAndDismissesLauncher() throws {
        let logURL = actionLogURL()
        let app = launchFixture(actionLogURL: logURL)
        let searchField = focusedSearchField(in: app)
        paste("finder", into: searchField)
        XCTAssertTrue(app.staticTexts["Finder"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.descendants(matching: .any)["search.result.com.apple.finder"].exists)

        app.typeKey(.return, modifierFlags: [])

        XCTAssertTrue(waitForAction("launch|", in: logURL))
        let hidden = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hittable == false"),
            object: searchField
        )
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 2), .completed)
        try? FileManager.default.removeItem(at: logURL)
    }

    func testFailedFileOpenKeepsLauncherVisibleAndShowsRecoverableError() throws {
        let app = launchFixture(failingAction: "open")
        let searchField = focusedSearchField(in: app)
        app.typeKey(.tab, modifierFlags: [])
        paste("design", into: searchField)
        XCTAssertTrue(app.staticTexts["Design Brief.txt"].waitForExistence(timeout: 2))

        app.typeKey(.return, modifierFlags: [])

        XCTAssertTrue(app.staticTexts["操作未完成"].waitForExistence(timeout: 2))
        XCTAssertTrue(
            app.staticTexts
                .matching(NSPredicate(format: "value CONTAINS %@", "可能已移动或不可访问"))
                .firstMatch
                .waitForExistence(timeout: 2)
        )
        XCTAssertTrue(searchField.isHittable)
    }

    func testNoResultsOffersSwitchSettingsAndRebuildActions() throws {
        let app = launchFixture()
        let searchField = focusedSearchField(in: app)
        app.typeKey(.tab, modifierFlags: [])
        searchField.typeText("definitely-no-match")

        XCTAssertTrue(app.staticTexts["没有找到匹配结果"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["search.empty.switch-mode"].exists)
        XCTAssertTrue(app.buttons["search.empty.index-settings"].exists)
        XCTAssertTrue(app.buttons["search.empty.rebuild-index"].exists)
    }

    func testSecondEscapeDismissesLauncher() throws {
        let app = launchFixture()
        let searchField = focusedSearchField(in: app)
        searchField.typeText("finder")
        XCTAssertTrue(app.staticTexts["Finder"].waitForExistence(timeout: 2))

        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.buttons["feature.me.touch.finder"].waitForExistence(timeout: 2))
        app.typeKey(.escape, modifierFlags: [])

        let hidden = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hittable == false"),
            object: searchField
        )
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 2), .completed)
    }

    private func assertFileAction(
        key: XCUIKeyboardKey,
        modifiers: XCUIElement.KeyModifierFlags,
        expectedPrefix: String
    ) throws {
        let logURL = actionLogURL()
        let app = launchFixture(actionLogURL: logURL)
        let searchField = focusedSearchField(in: app)
        app.typeKey(.tab, modifierFlags: [])
        paste("design", into: searchField)
        XCTAssertTrue(app.staticTexts["Design Brief.txt"].waitForExistence(timeout: 2))

        app.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(key, modifierFlags: modifiers)

        XCTAssertTrue(waitForAction(expectedPrefix, in: logURL))
        if expectedPrefix == "preview|" {
            XCTAssertTrue(searchField.isHittable)
        } else {
            let hidden = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "hittable == false"),
                object: searchField
            )
            XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 2), .completed)
        }
        try? FileManager.default.removeItem(at: logURL)
        app.terminate()
    }

    private func launchFixture(actionLogURL: URL? = nil, failingAction: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--show-launcher", "--search-fixture"]
        if let actionLogURL {
            app.launchArguments.append("--search-action-log=\(actionLogURL.path)")
        }
        if let failingAction {
            app.launchArguments.append("--search-action-failure=\(failingAction)")
        }
        app.launch()
        return app
    }

    private func focusedSearchField(in app: XCUIApplication) -> XCUIElement {
        let searchField = app.textFields["search.query"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 2))
        searchField.click()
        return searchField
    }

    private func paste(_ text: String, into element: XCUIElement) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        element.typeKey(XCUIKeyboardKey("v"), modifierFlags: .command)
    }

    private func actionLogURL() -> URL {
        URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("TouchSearchAction-\(UUID().uuidString).log")
    }

    private func waitForAction(_ prefix: String, in logURL: URL) -> Bool {
        let actionWritten = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                guard let text = try? String(contentsOf: logURL, encoding: .utf8) else { return false }
                return text.split(separator: "\n").contains { $0.hasPrefix(prefix) }
            },
            object: nil
        )
        return XCTWaiter.wait(for: [actionWritten], timeout: 2) == .completed
    }
}
