import XCTest

@MainActor
final class ScreenshotThumbnailTests: XCTestCase {
    func testThumbnailExposesMenuAndKeyboardCopyDeleteActions() {
        let fixtureRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "touch-thumbnail-ui-\(UUID().uuidString)",
            isDirectory: true
        )
        let eventsURL = fixtureRoot.appendingPathComponent("events.txt")
        try? FileManager.default.removeItem(at: fixtureRoot)

        let app = XCUIApplication()
        app.launchArguments = [
            "--screenshot-thumbnail-fixture",
            "--screenshot-thumbnail-root=\(fixtureRoot.path)",
            "--screenshot-thumbnail-output=\(eventsURL.path)"
        ]
        app.launch()

        let thumbnail = app.descendants(matching: .any)["screenshot.floating-thumbnail.content"]
        XCTAssertTrue(thumbnail.waitForExistence(timeout: 4))
        XCTAssertGreaterThan(thumbnail.frame.width, 0)
        XCTAssertGreaterThan(thumbnail.frame.height, 0)

        thumbnail.rightClick()
        for title in ["保存", "另存为…", "文字识别", "钉住截图", "复制", "删除"] {
            XCTAssertTrue(app.menuItems[title].waitForExistence(timeout: 1), "缺少右键菜单项：\(title)")
        }
        app.typeKey(.escape, modifierFlags: [])

        thumbnail.click()
        app.typeKey(XCUIKeyboardKey("c"), modifierFlags: [.command])
        XCTAssertTrue(waitUntil(timeout: 2) { self.eventCount("copy", at: eventsURL) >= 2 })

        app.typeKey(.delete, modifierFlags: [])
        XCTAssertTrue(waitUntil(timeout: 2) { !thumbnail.exists })
        XCTAssertTrue(waitUntil(timeout: 2) { self.eventCount("delete", at: eventsURL) == 1 })
    }

    private func eventCount(_ event: String, at url: URL) -> Int {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return 0 }
        return contents.split(separator: "\n").filter { line in
            line == event || line.hasPrefix(event + " ")
        }.count
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
