import XCTest

@MainActor
final class SearchSettingsTests: XCTestCase {
    func testSearchSettingsShowIndexStateAndRebuildAction() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--open-settings", "--search-fixture"]
        app.launch()

        let searchSection = app.buttons["settings.search"]
        XCTAssertTrue(searchSection.waitForExistence(timeout: 2))
        searchSection.click()

        XCTAssertTrue(app.staticTexts["索引状态"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["search.rebuild-index"].exists)
    }

    func testEmptyFileSearchOpensSearchSettingsDirectly() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--search-fixture"]
        app.launch()

        let query = app.textFields["search.query"]
        XCTAssertTrue(query.waitForExistence(timeout: 2))
        query.click()
        query.typeText("no-such-file")
        app.typeKey(.tab, modifierFlags: [])

        let indexSettings = app.buttons["search.empty.index-settings"]
        XCTAssertTrue(indexSettings.waitForExistence(timeout: 3))
        indexSettings.click()

        XCTAssertTrue(app.buttons["search.rebuild-index"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["索引范围"].exists)
    }
}
