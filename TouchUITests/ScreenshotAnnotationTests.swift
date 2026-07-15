import AppKit
import XCTest

@MainActor
final class ScreenshotAnnotationTests: XCTestCase {
    func testEditorExposesThemeAndAccessibilityDisplayModes() {
        let fixtureRoot = makeFixtureRoot()
        let eventsURL = fixtureRoot.appendingPathComponent("events.txt")
        let app = launchFixture(
            eventsURL: eventsURL,
            additionalArguments: [
                "--appearance-theme=amber",
                "--reduce-transparency",
                "--increase-contrast",
                "--reduce-motion"
            ]
        )
        defer { app.terminate() }

        let editor = app.descendants(matching: .any)["screenshot.annotation.editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 2))
        XCTAssertTrue(editor.label.contains("暖色烟熏玻璃主题"))
        XCTAssertTrue(editor.label.contains("降低透明度"))
        XCTAssertTrue(editor.label.contains("增大对比度"))
    }

    func testToolsCanvasInspectorKeyboardSaveCopyAndCrop() throws {
        let fixtureRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "touch-annotation-ui-\(UUID().uuidString)",
            isDirectory: true
        )
        let eventsURL = fixtureRoot.appendingPathComponent("events.txt")
        try? FileManager.default.removeItem(at: fixtureRoot)

        let app = XCUIApplication()
        app.launchArguments = [
            "--screenshot-annotation-fixture",
            "--screenshot-annotation-output=\(eventsURL.path)"
        ]
        app.launch()

        let toolbar = app.descendants(matching: .any)["screenshot.annotation.toolbar"]
        XCTAssertTrue(toolbar.waitForExistence(timeout: 5))
        for tool in Self.toolIdentifiers {
            XCTAssertTrue(
                app.buttons["screenshot.annotation.tool.\(tool)"].exists,
                "标注工具未暴露给辅助功能：\(tool)"
            )
        }
        XCTAssertTrue(app.buttons["screenshot.annotation.undo"].exists)
        XCTAssertTrue(app.buttons["screenshot.annotation.redo"].exists)
        XCTAssertTrue(app.buttons["screenshot.annotation.layer.previous"].exists)
        XCTAssertTrue(app.buttons["screenshot.annotation.layer.next"].exists)
        XCTAssertTrue(app.buttons["screenshot.annotation.save"].exists)
        XCTAssertTrue(app.buttons["screenshot.annotation.copy"].exists)
        XCTAssertTrue(app.buttons["screenshot.annotation.export"].exists)

        let canvas = app.descendants(matching: .any)["screenshot.annotation.canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 2))
        app.buttons["screenshot.annotation.tool.rectangle"].click()
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.28, dy: 0.30)).press(
            forDuration: 0.05,
            thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.62, dy: 0.58))
        )

        let inspector = app.descendants(matching: .any)["screenshot.annotation.inspector"]
        XCTAssertTrue(inspector.waitForExistence(timeout: 2))
        XCTAssertTrue(
            app.descendants(matching: .any)["screenshot.annotation.inspector.line-width"].exists
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["screenshot.annotation.inspector.opacity"].exists
        )
        XCTAssertTrue(app.staticTexts["有未保存修改"].waitForExistence(timeout: 2))

        app.typeKey(XCUIKeyboardKey("s"), modifierFlags: [.command])
        XCTAssertTrue(waitUntil(timeout: 2) { self.events(at: eventsURL).contains("save 1") })
        XCTAssertTrue(app.staticTexts["已保存"].waitForExistence(timeout: 2))

        // 单键 T 选择文字工具；点击画布后应出现内容编辑器。
        app.typeKey(XCUIKeyboardKey("t"), modifierFlags: [])
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.48, dy: 0.42)).click()
        XCTAssertTrue(
            app.descendants(matching: .any)["screenshot.annotation.inspector.content"]
                .waitForExistence(timeout: 2)
        )

        let layerQuery = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "screenshot.annotation.canvas.layer.")
        )
        XCTAssertEqual(layerQuery.count, 2)
        let selectedTextLayer = selectedLayerIdentifier(in: layerQuery)

        // 文字内容输入框可能持有第一响应者；先明确切回选择工具，随后验证
        // Option+[ / Option+] 和 Delete 这组画布级键盘操作。
        app.buttons["screenshot.annotation.tool.select"].click()
        app.typeKey(XCUIKeyboardKey("["), modifierFlags: [.option])
        let selectedPreviousLayer = selectedLayerIdentifier(in: layerQuery)
        XCTAssertNotEqual(selectedPreviousLayer, selectedTextLayer)
        app.typeKey(XCUIKeyboardKey("]"), modifierFlags: [.option])
        XCTAssertEqual(selectedLayerIdentifier(in: layerQuery), selectedTextLayer)

        app.typeKey(.delete, modifierFlags: [])
        app.typeKey(XCUIKeyboardKey("z"), modifierFlags: [.command])
        XCTAssertTrue(
            app.descendants(matching: .any)["screenshot.annotation.inspector.content"]
                .waitForExistence(timeout: 2)
        )

        app.typeKey(XCUIKeyboardKey("c"), modifierFlags: [.command, .shift])
        XCTAssertTrue(waitUntil(timeout: 3) {
            self.events(at: eventsURL).contains("export png false")
        })

        // 单键 C 进入裁剪，Esc 可取消暂存裁剪而不修改文档。
        app.typeKey(XCUIKeyboardKey("c"), modifierFlags: [])
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.20, dy: 0.22)).press(
            forDuration: 0.05,
            thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.72))
        )
        XCTAssertTrue(
            app.buttons["screenshot.annotation.crop.confirm"].waitForExistence(timeout: 2)
        )
        XCTAssertTrue(app.buttons["screenshot.annotation.crop.cancel"].exists)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitUntil(timeout: 2) {
            !app.buttons["screenshot.annotation.crop.confirm"].exists
        })
    }

    func testCopyFailureCanRetryWithTheOriginalDocumentSnapshot() throws {
        let fixtureRoot = makeFixtureRoot()
        let eventsURL = fixtureRoot.appendingPathComponent("events.txt")
        let app = launchFixture(
            eventsURL: eventsURL,
            additionalArguments: ["--screenshot-annotation-fail-first-copy"]
        )
        defer { app.terminate() }

        drawRectangle(in: app)
        app.typeKey(XCUIKeyboardKey("c"), modifierFlags: [.command, .shift])

        // Touch Bar 可能镜像同名按钮，必须限定到当前窗口的 Sheet。
        let retryButton = app.sheets.buttons["重试"]
        XCTAssertTrue(retryButton.waitForExistence(timeout: 3))
        XCTAssertTrue(app.sheets.staticTexts["复制标注截图失败"].exists)
        retryButton.click()

        XCTAssertTrue(waitUntil(timeout: 3) {
            let events = self.events(at: eventsURL)
            return events.filter { $0 == "copy-attempt 1 png false" }.count == 2
                && events.contains("copy-failed 1")
                && events.contains("copy-success 1")
        })
    }

    func testExportFailureCanRetryWithTheOriginalDestinationAndDocument() throws {
        let fixtureRoot = makeFixtureRoot()
        let eventsURL = fixtureRoot.appendingPathComponent("events.txt")
        let exportURL = fixtureRoot.appendingPathComponent("retried-export.png")
        let app = launchFixture(
            eventsURL: eventsURL,
            additionalArguments: [
                "--screenshot-annotation-fail-first-export",
                "--screenshot-annotation-export-destination=\(exportURL.path)"
            ]
        )
        defer { app.terminate() }

        drawRectangle(in: app)
        app.buttons["screenshot.annotation.export"].click()

        // Touch Bar 可能镜像同名按钮，必须限定到当前窗口的 Sheet。
        let retryButton = app.sheets.buttons["重试"]
        XCTAssertTrue(retryButton.waitForExistence(timeout: 3))
        XCTAssertTrue(app.sheets.staticTexts["导出标注截图失败"].exists)
        retryButton.click()

        XCTAssertTrue(waitUntil(timeout: 3) {
            let events = self.events(at: eventsURL)
            return events.filter { $0 == "export-attempt 1 png false" }.count == 2
                && events.contains("export-failed 1")
                && events.contains("export-success 1")
                && FileManager.default.fileExists(atPath: exportURL.path)
        })
    }

    private static let toolIdentifiers = [
        "select", "rectangle", "ellipse", "line", "arrow", "freehand", "highlighter",
        "text", "numberedMarker", "note", "sticker", "mosaic", "blur", "magnifier",
        "crop", "watermark", "beautify"
    ]

    private func makeFixtureRoot() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "touch-annotation-ui-\(UUID().uuidString)",
            isDirectory: true
        )
        try? FileManager.default.removeItem(at: root)
        return root
    }

    private func launchFixture(
        eventsURL: URL,
        additionalArguments: [String] = []
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--screenshot-annotation-fixture",
            "--screenshot-annotation-output=\(eventsURL.path)"
        ] + additionalArguments
        app.launch()
        XCTAssertTrue(
            app.descendants(matching: .any)["screenshot.annotation.toolbar"]
                .waitForExistence(timeout: 5)
        )
        return app
    }

    private func drawRectangle(in app: XCUIApplication) {
        let canvas = app.descendants(matching: .any)["screenshot.annotation.canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 2))
        app.buttons["screenshot.annotation.tool.rectangle"].click()
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.28, dy: 0.30)).press(
            forDuration: 0.05,
            thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.62, dy: 0.58))
        )
    }

    private func selectedLayerIdentifier(in query: XCUIElementQuery) -> String? {
        query.allElementsBoundByIndex.first(where: \.isSelected)?.identifier
    }

    private func events(at url: URL) -> [String] {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return contents.split(separator: "\n").map(String.init)
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
