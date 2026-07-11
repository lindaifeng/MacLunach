import XCTest

@MainActor
final class SettingsNavigationTests: XCTestCase {
    func testFeatureAreaOwnsFeatureSpecificSettings() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--open-settings"]
        app.launch()

        app.buttons["settings.feature-area"].click()
        XCTAssertTrue(app.staticTexts["功能区总览"].waitForExistence(timeout: 2))

        app.buttons["settings.feature.me.touch.screenshot"].click()
        XCTAssertTrue(app.staticTexts["截取屏幕设置"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.buttons["settings.screenshot.top-level"].exists)
    }
}
