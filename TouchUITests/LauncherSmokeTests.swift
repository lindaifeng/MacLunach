import XCTest

@MainActor
final class LauncherSmokeTests: XCTestCase {
    func testLauncherShowsThreeFeaturesAndSwitchesSearchMode() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--show-launcher"]
        app.launch()

        XCTAssertTrue(app.buttons["feature.me.touch.finder"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["feature.me.touch.screenshot"].exists)
        XCTAssertTrue(app.buttons["feature.me.touch.super-right"].exists)

        let searchField = app.textFields["search.query"]
        searchField.click()
        searchField.typeText("finder")
        app.typeKey(.tab, modifierFlags: [])

        XCTAssertTrue(app.buttons["search.mode.file"].isSelected)
        XCTAssertEqual(searchField.value as? String, "finder")
    }

    func testFeatureCardOffersShortcutEditingFromContextMenu() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--show-launcher"]
        app.launch()

        let finderCard = app.buttons["feature.me.touch.finder"]
        XCTAssertTrue(finderCard.waitForExistence(timeout: 2))
        finderCard.rightClick()

        XCTAssertTrue(app.menuItems["修改快捷键"].waitForExistence(timeout: 2))
    }
}
