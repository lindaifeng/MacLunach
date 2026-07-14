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

    func testLauncherHidesWhenAnotherApplicationBecomesActive() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--show-launcher"]
        app.launch()

        let searchField = app.textFields["search.query"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 2))

        XCUIApplication(bundleIdentifier: "com.apple.finder").activate()

        let launcherHidden = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: searchField
        )
        XCTAssertEqual(XCTWaiter.wait(for: [launcherHidden], timeout: 2), .completed)
    }

    func testLauncherUsesBalancedCompactLayout() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--show-launcher"]
        app.launch()

        let applicationMode = app.buttons["search.mode.application"]
        let fileMode = app.buttons["search.mode.file"]
        let searchField = app.textFields["search.query"]
        let tabHint = app.staticTexts["search.hint.tab"]
        let featureCards = [
            app.buttons["feature.me.touch.finder"],
            app.buttons["feature.me.touch.screenshot"],
            app.buttons["feature.me.touch.super-right"]
        ]

        XCTAssertTrue(applicationMode.waitForExistence(timeout: 2))
        XCTAssertTrue(fileMode.exists)
        XCTAssertTrue(searchField.exists)
        XCTAssertTrue(tabHint.exists)
        XCTAssertTrue(featureCards.allSatisfy(\.exists))

        XCTAssertGreaterThanOrEqual(applicationMode.frame.width, 36)
        XCTAssertLessThanOrEqual(applicationMode.frame.width, 42)
        XCTAssertGreaterThanOrEqual(fileMode.frame.width, 36)
        XCTAssertLessThanOrEqual(fileMode.frame.width, 42)
        XCTAssertLessThanOrEqual(fileMode.frame.minX - applicationMode.frame.maxX, 8)
        XCTAssertLessThan(abs(applicationMode.frame.midY - searchField.frame.midY), 4)
        XCTAssertLessThan(abs(fileMode.frame.midY - searchField.frame.midY), 4)
        XCTAssertLessThan(tabHint.frame.maxX, searchField.frame.minX)

        for card in featureCards {
            XCTAssertLessThanOrEqual(card.frame.width, 232)
            XCTAssertLessThanOrEqual(card.frame.height, 76)
        }
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
