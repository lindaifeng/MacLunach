import XCTest

@MainActor
final class LauncherSmokeTests: XCTestCase {
    func testLauncherShowsThreeFeaturesAndSwitchesSearchMode() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--show-launcher", "--search-fixture"]
        app.launch()

        XCTAssertTrue(app.buttons["feature.me.touch.finder"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["feature.me.touch.screenshot"].exists)
        XCTAssertTrue(app.buttons["feature.me.touch.super-right"].exists)

        let searchField = app.textFields["search.query"]
        searchField.click()
        searchField.typeText("finder")
        app.typeKey(.tab, modifierFlags: [])

        let fileMode = app.buttons["search.mode.file"]
        let selected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "selected == true"),
            object: fileMode
        )
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 2), .completed)
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

    func testLauncherControlsExposeLabelsWithReducedTransparency() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--show-launcher", "--reduce-transparency"]
        app.launch()

        let finderCard = app.buttons["feature.me.touch.finder"]
        XCTAssertTrue(finderCard.waitForExistence(timeout: 2))

        let controls = [
            finderCard,
            app.buttons["feature.me.touch.screenshot"],
            app.buttons["feature.me.touch.super-right"],
            app.buttons["theme.switch"],
            app.buttons["launcher.settings"],
            app.buttons["search.mode.application"],
            app.buttons["search.mode.file"]
        ]

        for control in controls {
            XCTAssertTrue(control.exists)
            XCTAssertFalse(control.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        XCTAssertTrue(app.textFields["search.query"].isHittable)
    }

    func testCaptureThreeThemeSnapshots() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--show-launcher"]
        app.launch()

        let themeButton = app.buttons["theme.switch"]
        XCTAssertTrue(themeButton.waitForExistence(timeout: 2))

        for index in 1...3 {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "touch-theme-\(index)"
            attachment.lifetime = .keepAlways
            add(attachment)
            themeButton.click()
        }
    }
}
