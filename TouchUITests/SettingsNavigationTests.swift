import XCTest

@MainActor
final class SettingsNavigationTests: XCTestCase {
    func testEverySidebarItemRespondsToOneClick() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--open-settings"]
        app.launch()

        let identifiers = [
            "settings.general",
            "settings.search",
            "settings.feature-area",
            "settings.appearance",
            "settings.permissions",
            "settings.update",
            "settings.privacy",
            "settings.about"
        ]

        for identifier in identifiers {
            let item = app.buttons[identifier]
            XCTAssertTrue(item.waitForExistence(timeout: 2), "缺少侧栏入口：\(identifier)")
            item.click()
            let selected = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "selected == true"),
                object: item
            )
            XCTAssertEqual(
                XCTWaiter.wait(for: [selected], timeout: 1),
                .completed,
                "侧栏入口未响应单击：\(identifier)"
            )
        }
    }

    func testFeatureAreaOwnsFeatureSpecificSettings() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--open-settings"]
        app.launch()

        app.buttons["settings.feature-area"].click()
        XCTAssertTrue(app.staticTexts["功能区"].waitForExistence(timeout: 2))

        app.buttons["settings.feature.me.touch.screenshot"].click()
        XCTAssertTrue(app.staticTexts["截取屏幕设置"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.buttons["settings.screenshot.top-level"].exists)
    }

    func testSuperRightSettingsOpenAtTopAndExposeConfigurationControls() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--open-settings"]
        app.launch()

        app.buttons["settings.feature-area"].click()
        let superRight = app.buttons["settings.feature.me.touch.super-right"]
        XCTAssertTrue(superRight.waitForExistence(timeout: 2))
        let detailScrollView = app.scrollViews.firstMatch
        for _ in 0..<6 where !superRight.isHittable {
            detailScrollView.swipeUp()
        }
        XCTAssertTrue(superRight.isHittable)
        superRight.click()

        let pageTitle = app.staticTexts["超级右键设置"]
        XCTAssertTrue(pageTitle.waitForExistence(timeout: 2))
        XCTAssertTrue(
            detailScrollView.frame.intersects(pageTitle.frame),
            "进入超级右键设置时，页面标题应位于可视区域"
        )
        XCTAssertFalse(app.buttons["settings.super-right.open-permissions"].exists)
        XCTAssertFalse(app.otherElements["settings.super-right.extension-section"].exists)
        XCTAssertTrue(app.popUpButtons["settings.super-right.terminal"].exists)
        XCTAssertTrue(app.checkBoxes["settings.super-right.action.newFile"].exists)

        let textFormat = app.checkBoxes["settings.super-right.format.txt"]
        for _ in 0..<6 where !textFormat.exists {
            detailScrollView.swipeUp()
        }
        XCTAssertTrue(textFormat.exists)
    }

    func testPermissionsOwnsFinderExtensionManagement() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--open-settings"]
        app.launch()

        let permissions = app.buttons["settings.permissions"]
        XCTAssertTrue(permissions.waitForExistence(timeout: 2))
        permissions.click()
        let selected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "selected == true"),
            object: permissions
        )
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 1), .completed)
        XCTAssertTrue(app.otherElements["settings.permissions.finder-extension"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["settings.permissions.finder-extension.manage"].exists)
    }

    func testClosingSettingsRestoresLauncher() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--show-launcher"]
        app.launch()

        XCTAssertTrue(app.buttons["launcher.settings"].waitForExistence(timeout: 2))
        app.buttons["launcher.settings"].click()
        XCTAssertTrue(app.buttons["settings.close"].waitForExistence(timeout: 2))

        app.buttons["settings.close"].click()

        XCTAssertTrue(app.buttons["feature.me.touch.finder"].waitForExistence(timeout: 2))
    }

    func testAppearanceUsesCustomThemeChoices() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--open-settings"]
        app.launch()

        app.buttons["settings.appearance"].click()
        XCTAssertTrue(app.buttons["settings.theme.default"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["settings.theme.night"].exists)
        XCTAssertTrue(app.buttons["settings.theme.graphite"].exists)
        XCTAssertTrue(app.buttons["settings.theme.day"].exists)
        XCTAssertTrue(app.sliders["settings.theme.opacity"].exists)
        XCTAssertTrue(app.staticTexts["settings.theme.opacity.value"].exists)
    }
}
