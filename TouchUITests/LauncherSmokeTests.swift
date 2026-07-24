import XCTest

@MainActor
final class LauncherSmokeTests: XCTestCase {
    private func terminateFixtureApplication(_ app: XCUIApplication) {
        if app.state != .notRunning {
            app.terminate()
            _ = app.wait(for: .notRunning, timeout: 3)
        }
    }

    private func launchFixtureApplication(
        _ app: XCUIApplication,
        arguments: [String]
    ) {
        // 同一个 UI 测试进程连续切换 fixture 时，LaunchServices 偶发复用
        // 上一轮的应用进程，导致新启动参数没有生效。启动前、结束后都显式
        // 终止应用，保证每个 fixture 都从独立进程开始。
        terminateFixtureApplication(app)
        app.launchArguments = arguments
        app.launch()
    }

    private func waitForHeight(
        of element: XCUIElement,
        greaterThan threshold: CGFloat,
        timeout: TimeInterval = 2
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if element.exists, element.frame.height > threshold {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        } while Date() < deadline
        return element.exists && element.frame.height > threshold
    }

    func testDailyTaskStartsPlannedPomodoroImmediately() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--show-daily-tasks", "--daily-task-fixture"]
        app.launch()

        let startTask = app.buttons["开始任务"]
        XCTAssertTrue(startTask.waitForExistence(timeout: 2))
        XCTAssertTrue(startTask.isEnabled)
        startTask.click()

        XCTAssertTrue(app.buttons["暂停计时"].waitForExistence(timeout: 2))
        let planSummary = app.descendants(matching: .any)["pomodoro.plan-summary"]
        XCTAssertTrue(planSummary.waitForExistence(timeout: 2))
    }

    func testPomodoroPanelStateTransitionsAndKeepsSelectedDurationOnReset() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--show-pomodoro"]
        app.launch()

        XCTAssertTrue(app.buttons["置顶番茄闹钟"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["深度专注"].exists)
        let remainingTime = app.staticTexts["pomodoro.remaining-time"]
        XCTAssertTrue(remainingTime.waitForExistence(timeout: 1))
        XCTAssertEqual(remainingTime.value as? String, "25:00")

        let start = app.buttons["开始"]
        XCTAssertTrue(start.exists)
        XCTAssertFalse(app.buttons["重置计时"].isEnabled)

        app.buttons["专注时长，25 分钟"].click()
        app.buttons["45 分钟"].click()
        XCTAssertEqual(remainingTime.value as? String, "45:00")

        start.click()
        XCTAssertTrue(app.buttons["暂停计时"].waitForExistence(timeout: 1))
        XCTAssertTrue(app.buttons["重置计时"].isEnabled)

        app.buttons["暂停计时"].click()
        XCTAssertTrue(app.buttons["继续计时"].waitForExistence(timeout: 1))

        app.buttons["重置计时"].click()
        XCTAssertEqual(remainingTime.value as? String, "45:00")
        XCTAssertTrue(app.buttons["开始"].exists)
        XCTAssertFalse(app.buttons["重置计时"].isEnabled)

        app.buttons["专注时长，45 分钟"].click()
        let customMinutes = app.textFields["pomodoro.custom-minutes"]
        customMinutes.click()
        customMinutes.typeText("35")
        app.buttons["pomodoro.apply-custom-minutes"].click()
        XCTAssertEqual(remainingTime.value as? String, "35:00")

        app.buttons["置顶番茄闹钟"].click()
        XCTAssertTrue(app.buttons["取消置顶"].waitForExistence(timeout: 1))
    }

    func testPomodoroHeaderControlsAndFullscreenAreFunctional() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--show-pomodoro"]
        app.launch()

        let statisticsButton = app.buttons["pomodoro.statistics-summary"]
        XCTAssertTrue(statisticsButton.waitForExistence(timeout: 2))
        let soundButton = app.buttons["pomodoro.preview-sound"]
        XCTAssertTrue(soundButton.exists)
        XCTAssertGreaterThan(soundButton.frame.midX - statisticsButton.frame.midX, 300)
        let statisticsButtonFrame = statisticsButton.frame
        statisticsButton.click()
        let statisticsPopover = app.descendants(matching: .any)["pomodoro.statistics-popover"]
        XCTAssertTrue(statisticsPopover.waitForExistence(timeout: 1))
        XCTAssertEqual(statisticsButton.frame.origin.x, statisticsButtonFrame.origin.x, accuracy: 1)
        XCTAssertEqual(statisticsButton.frame.origin.y, statisticsButtonFrame.origin.y, accuracy: 1)
        statisticsButton.click()
        XCTAssertTrue(statisticsPopover.waitForNonExistence(timeout: 1))

        XCTAssertTrue(app.buttons["pomodoro.open-focus-settings"].exists)

        soundButton.click()
        XCTAssertTrue(app.buttons["停止试听"].waitForExistence(timeout: 1))
        app.buttons["停止试听"].click()
        XCTAssertTrue(app.buttons["试听轻铃声"].waitForExistence(timeout: 1))

        let statisticsCard = app.descendants(matching: .any)["pomodoro.session-statistics"]
        XCTAssertTrue(statisticsCard.exists)
        let initialFrame = statisticsCard.frame
        let initialDialFrame = app.descendants(matching: .any)["pomodoro.timer-dial"].frame
        let fullscreenButton = app.buttons["pomodoro.fullscreen"]
        XCTAssertTrue(fullscreenButton.exists)
        fullscreenButton.click()
        XCTAssertTrue(app.buttons["退出全屏"].waitForExistence(timeout: 4))
        let fullscreenDialFrame = app.descendants(matching: .any)["pomodoro.timer-dial"].frame
        XCTAssertEqual(statisticsCard.frame.width, initialFrame.width, accuracy: 80)
        XCTAssertEqual(fullscreenDialFrame.width, initialDialFrame.width, accuracy: 30)
        XCTAssertLessThan(fullscreenDialFrame.maxX, statisticsCard.frame.minX)

        app.buttons["退出全屏"].click()
        XCTAssertTrue(app.buttons["全屏专注"].waitForExistence(timeout: 4))
    }

    func testPomodoroTargetEditorAndProgressIndicatorUpdate() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--show-pomodoro"]
        app.launch()

        let targetButton = app.buttons["pomodoro.target-count"]
        XCTAssertTrue(targetButton.waitForExistence(timeout: 2))
        XCTAssertEqual(targetButton.value as? String, "已完成 0 个，目标 1 个")
        targetButton.click()

        let targetEditor = app.descendants(matching: .any)["pomodoro.target-editor"]
        XCTAssertTrue(targetEditor.waitForExistence(timeout: 1))
        XCTAssertTrue(app.buttons["pomodoro.target-increase"].isHittable)
        app.buttons["pomodoro.target-increase"].click()
        XCTAssertEqual(app.staticTexts["pomodoro.target-value"].value as? String, "2")
        app.buttons["pomodoro.target-decrease"].click()
        XCTAssertEqual(app.staticTexts["pomodoro.target-value"].value as? String, "1")

        app.buttons["pomodoro.target-editor-done"].click()
        XCTAssertTrue(targetEditor.waitForNonExistence(timeout: 1))
        XCTAssertTrue(targetButton.waitForExistence(timeout: 1))
        XCTAssertEqual(targetButton.value as? String, "已完成 0 个，目标 1 个")

        let progressIndicator = app.descendants(matching: .any)["pomodoro.progress-indicator"]
        XCTAssertTrue(progressIndicator.exists)
        XCTAssertEqual(progressIndicator.label, "倒计时进度点，已进行 0 秒")

        let timerDial = app.descendants(matching: .any)["pomodoro.timer-dial"]
        let dialRight = timerDial.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5))
        dialRight.click()
        XCTAssertNotEqual(app.staticTexts["pomodoro.remaining-time"].value as? String, "25:00")

        app.buttons["重置计时"].click()
        XCTAssertEqual(progressIndicator.label, "倒计时进度点，已进行 0 秒")
        app.buttons["开始"].click()
        let advanced = NSPredicate(format: "label != %@", "倒计时进度点，已进行 0 秒")
        expectation(for: advanced, evaluatedWith: progressIndicator)
        waitForExpectations(timeout: 3)
    }

    func testPomodoroStaysAboveLauncherWhenLauncherIsPresented() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--show-pomodoro-and-launcher"]
        app.launch()

        let targetButton = app.buttons["pomodoro.target-count"]
        XCTAssertTrue(targetButton.waitForExistence(timeout: 2))
        XCTAssertTrue(app.textFields["search.query"].waitForExistence(timeout: 2))
        targetButton.click()
        XCTAssertTrue(
            app.descendants(matching: .any)["pomodoro.target-editor"]
                .waitForExistence(timeout: 1)
        )

        targetButton
            .coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
            .withOffset(CGVector(dx: -180, dy: -300))
            .click()
        XCTAssertTrue(targetButton.waitForNonExistence(timeout: 1))
    }

    func testPomodoroHidesWhenAnotherApplicationBecomesActive() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--show-pomodoro"]
        app.launch()

        let targetButton = app.buttons["pomodoro.target-count"]
        XCTAssertTrue(targetButton.waitForExistence(timeout: 2))

        let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
        finder.activate()
        XCTAssertTrue(targetButton.waitForNonExistence(timeout: 2))
        app.activate()
    }

    func testPomodoroConfigurationRemainsInteractiveAndBreakCanReset() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--show-pomodoro"]
        app.launch()

        XCTAssertTrue(app.buttons["置顶番茄闹钟"].waitForExistence(timeout: 5))
        let breakPicker = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "休息方式")
        ).firstMatch
        XCTAssertTrue(breakPicker.waitForExistence(timeout: 2))
        breakPicker.click()
        let longBreak = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "长休息")
        ).firstMatch
        XCTAssertTrue(longBreak.waitForExistence(timeout: 1))
        longBreak.click()

        XCTAssertTrue(app.buttons["休息方式，长休 15 分钟"].waitForExistence(timeout: 1))
        XCTAssertTrue(app.buttons["重置计时"].isEnabled)
        app.buttons["重置计时"].click()
        XCTAssertTrue(app.buttons["休息方式，短休 5 分钟"].waitForExistence(timeout: 1))

        app.buttons["开始"].click()
        XCTAssertTrue(app.buttons["暂停计时"].waitForExistence(timeout: 1))
        let durationPicker = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "专注时长")
        ).firstMatch
        XCTAssertTrue(durationPicker.isEnabled)
        durationPicker.click()
        XCTAssertTrue(app.buttons["45 分钟"].waitForExistence(timeout: 1))
    }

    func testHolidayCalendarShowsLunarLabelsAndOpensDetailsOnSelection() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--show-holiday-calendar"]
        app.launch()

        let monthTitle = app.staticTexts["holiday-calendar.month-title"]
        XCTAssertTrue(monthTitle.waitForExistence(timeout: 2))
        XCTAssertFalse(app.staticTexts["当天详情"].exists)

        let today = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "农历")).firstMatch
        XCTAssertTrue(today.exists)
        today.click()

        XCTAssertTrue(app.staticTexts["当天详情"].waitForExistence(timeout: 1))
        XCTAssertTrue(app.buttons["关闭日期详情"].exists)
    }

    func testMarkdownPanelExposesEditingActions() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--show-markdown"]
        app.launch()

        let source = app.textViews["markdown.source"]
        XCTAssertTrue(source.waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["markdown.open-document"].exists)
        XCTAssertTrue(app.buttons["markdown.save-document"].exists)
        XCTAssertTrue(app.staticTexts["markdown.character-count"].exists)

        app.buttons["markdown.mode.reading"].click()
        XCTAssertTrue(app.scrollViews["markdown.rendered"].waitForExistence(timeout: 1))
        XCTAssertFalse(app.textViews["markdown.source"].exists)

        app.buttons["markdown.mode.editing"].click()
        XCTAssertTrue(app.textViews["markdown.source"].waitForExistence(timeout: 1))
        XCTAssertFalse(app.scrollViews["markdown.rendered"].exists)

        app.buttons["markdown.mode.split"].click()
        XCTAssertTrue(app.textViews["markdown.source"].waitForExistence(timeout: 1))
        XCTAssertTrue(app.scrollViews["markdown.rendered"].waitForExistence(timeout: 1))

        source.click()
        app.typeKey("a", modifierFlags: .command)
        source.typeText("\n\n# 实时预览")
        XCTAssertTrue((source.value as? String)?.contains("实时预览") == true)
        let rendered = app.scrollViews["markdown.rendered"]
        XCTAssertTrue(rendered.exists)
        XCTAssertTrue((rendered.value as? String)?.contains("实时预览") == true)

        app.typeKey("a", modifierFlags: .command)
        app.typeKey("c", modifierFlags: .command)
        app.buttons["新建"].click()
        let emptySource = app.textViews["markdown.source"]
        XCTAssertTrue(emptySource.waitForExistence(timeout: 1))
        emptySource.click()
        app.typeKey("v", modifierFlags: .command)
        XCTAssertTrue((emptySource.value as? String)?.contains("实时预览") == true)
    }

    func testMarkdownOpenPanelAppears() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--show-markdown"]
        app.launch()

        XCTAssertTrue(app.buttons["markdown.open-document"].waitForExistence(timeout: 2))
        app.buttons["markdown.open-document"].click()
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 1))
        app.buttons["CancelButton"].click()
    }

    func testMarkdownSplitDividerResizesPanesWithoutMovingWindow() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--show-markdown"]
        app.launch()

        let source = app.textViews["markdown.source"]
        let divider = app.otherElements["markdown.split-divider"]
        let closeButton = app.buttons["markdown.window.close"]
        XCTAssertTrue(source.waitForExistence(timeout: 2))
        XCTAssertTrue(divider.exists)
        XCTAssertTrue(closeButton.exists)

        let originalEditorWidth = source.frame.width
        let originalCloseButtonFrame = closeButton.frame
        let start = divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = start.withOffset(CGVector(dx: 140, dy: 0))
        start.press(forDuration: 0.1, thenDragTo: end)

        XCTAssertGreaterThan(source.frame.width, originalEditorWidth + 20)
        XCTAssertEqual(closeButton.frame.origin.x, originalCloseButtonFrame.origin.x, accuracy: 2)
        XCTAssertEqual(closeButton.frame.origin.y, originalCloseButtonFrame.origin.y, accuracy: 2)
    }

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
        let cardLayout = app.buttons["launcher.layout.cards"]
        XCTAssertTrue(cardLayout.waitForExistence(timeout: 2))
        cardLayout.click()
        XCTAssertTrue(finderCard.waitForExistence(timeout: 2))
        finderCard.rightClick()

        XCTAssertTrue(
            app.descendants(matching: .any)["launcher.shortcut-editor"]
                .waitForExistence(timeout: 2)
        )
        XCTAssertFalse(app.menuItems["设置功能"].exists)
        XCTAssertFalse(app.menuItems["修改快捷键"].exists)
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
        XCTAssertTrue(app.staticTexts["一念"].exists)
        XCTAssertTrue(app.staticTexts["所想即现"].exists)

        XCTAssertGreaterThanOrEqual(applicationMode.frame.width, 36)
        XCTAssertLessThanOrEqual(applicationMode.frame.width, 42)
        XCTAssertGreaterThanOrEqual(fileMode.frame.width, 36)
        XCTAssertLessThanOrEqual(fileMode.frame.width, 42)
        XCTAssertLessThanOrEqual(fileMode.frame.minX - applicationMode.frame.maxX, 8)
        XCTAssertLessThan(abs(applicationMode.frame.midY - searchField.frame.midY), 4)
        XCTAssertLessThan(abs(fileMode.frame.midY - searchField.frame.midY), 4)
        XCTAssertLessThan(searchField.frame.maxX, tabHint.frame.minX)

        for card in featureCards {
            XCTAssertLessThanOrEqual(card.frame.width, 232)
            XCTAssertLessThanOrEqual(card.frame.height, 76)
        }
    }

    func testLauncherSwitchesBetweenCardAndKeyboardFeatureLayouts() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--show-launcher"]
        app.launch()

        let searchField = app.textFields["search.query"]
        let cardLayout = app.buttons["launcher.layout.cards"]
        let keyboardLayout = app.buttons["launcher.layout.keyboard"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 2))
        XCTAssertTrue(cardLayout.exists)
        XCTAssertTrue(keyboardLayout.exists)

        cardLayout.click()
        let finderFeature = app.buttons["feature.me.touch.finder"]
        XCTAssertTrue(finderFeature.waitForExistence(timeout: 1))
        let originalFeatureFrame = finderFeature.frame
        let originalSearchFrame = searchField.frame

        keyboardLayout.click()
        XCTAssertTrue(finderFeature.waitForExistence(timeout: 1))
        XCTAssertLessThan(finderFeature.frame.width, originalFeatureFrame.width)
        XCTAssertGreaterThanOrEqual(finderFeature.frame.width, 64)
        XCTAssertGreaterThanOrEqual(finderFeature.frame.height, 64)
        XCTAssertLessThanOrEqual(finderFeature.frame.width, 72)
        XCTAssertLessThanOrEqual(finderFeature.frame.height, 72)
        XCTAssertTrue(finderFeature.label.contains("打开访达"))
        XCTAssertEqual(searchField.frame.origin.x, originalSearchFrame.origin.x, accuracy: 1)
        XCTAssertEqual(searchField.frame.origin.y, originalSearchFrame.origin.y, accuracy: 1)
        XCTAssertEqual(searchField.frame.width, originalSearchFrame.width, accuracy: 1)
        XCTAssertEqual(searchField.frame.height, originalSearchFrame.height, accuracy: 1)
        let keyboardFeatureFrame = finderFeature.frame

        finderFeature.rightClick()
        let keyEditor = app.descendants(matching: .any)["launcher.key-editor"]
        XCTAssertTrue(keyEditor.waitForExistence(timeout: 1))
        XCTAssertLessThanOrEqual(keyEditor.frame.width, 352)
        XCTAssertEqual(finderFeature.frame.origin.x, keyboardFeatureFrame.origin.x, accuracy: 1)
        XCTAssertEqual(finderFeature.frame.origin.y, keyboardFeatureFrame.origin.y, accuracy: 1)
        XCTAssertFalse(app.buttons["launcher.key-editor.shortcut"].exists)
        XCTAssertFalse(app.menuItems["设置功能"].exists)
        XCTAssertFalse(app.menuItems["修改快捷键"].exists)
    }

    func testLauncherLayoutSwitcherAcceptsClicksBesideIcons() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--show-launcher"]
        app.launch()

        let switcher = app.descendants(matching: .any)["launcher.layout.switcher"]
        let cardLayout = app.buttons["launcher.layout.cards"]
        let keyboardLayout = app.buttons["launcher.layout.keyboard"]
        XCTAssertTrue(switcher.waitForExistence(timeout: 2))
        XCTAssertTrue(cardLayout.exists)
        XCTAssertTrue(keyboardLayout.exists)

        switcher.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).click()
        XCTAssertTrue(keyboardLayout.isSelected)

        switcher.coordinate(withNormalizedOffset: CGVector(dx: 0.49, dy: 0.5)).click()
        XCTAssertTrue(cardLayout.isSelected)

        switcher.coordinate(withNormalizedOffset: CGVector(dx: 0.51, dy: 0.5)).click()
        XCTAssertTrue(keyboardLayout.isSelected)

        switcher.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5)).click()
        XCTAssertTrue(cardLayout.isSelected)
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

    func testLauncherExposesDedicatedTopDragHandle() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--show-launcher"]
        app.launch()

        XCTAssertTrue(app.otherElements["launcher.drag-handle"].waitForExistence(timeout: 2))
    }

    func testCaptureFourThemeSnapshots() throws {
        let app = XCUIApplication()
        for theme in ["default", "night", "graphite", "day"] {
            app.terminate()
            app.launchArguments = ["--show-launcher", "--appearance-theme=\(theme)"]
            app.launch()

            XCTAssertTrue(app.buttons["theme.switch"].waitForExistence(timeout: 2))
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "touch-theme-\(theme)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testTranslationFixtureShowsCompactVerticalWorkspace() throws {
        let app = XCUIApplication()
        defer { terminateFixtureApplication(app) }
        launchFixtureApplication(
            app,
            arguments: ["--show-translation-fixture", "--appearance-theme=graphite"]
        )

        // NSPanel 在 macOS 辅助功能树中以 Dialog 暴露，而不是 Window。
        let window = app.dialogs["translation.window"]
        XCTAssertTrue(window.waitForExistence(timeout: 2))
        // 参考图是 Retina 2× 截图：1120 × 464 像素对应 560 × 232 点。
        XCTAssertEqual(window.frame.width, 560, accuracy: 2)
        XCTAssertEqual(window.frame.height, 232, accuracy: 2)

        let sourceText = app.descendants(matching: .any)["translation.source-text"]
        let targetText = app.descendants(matching: .any)["translation.target-text"]
        let canvas = app.descendants(matching: .any)["translation.canvas"]
        let sourceLanguage = app.descendants(matching: .any)["translation.source-language"]
        let targetLanguage = app.descendants(matching: .any)["translation.target-language"]
        let swap = app.buttons["translation.swap"]
        let provider = app.descendants(matching: .any)["translation.provider"]

        XCTAssertTrue(sourceText.waitForExistence(timeout: 2))
        XCTAssertTrue(targetText.exists)
        XCTAssertTrue(canvas.exists)
        XCTAssertTrue(sourceLanguage.exists)
        XCTAssertTrue(targetLanguage.exists)
        XCTAssertTrue(provider.exists)
        XCTAssertGreaterThan(sourceLanguage.frame.width, 230)
        XCTAssertGreaterThan(targetLanguage.frame.width, 230)
        XCTAssertLessThanOrEqual(sourceText.frame.maxY, sourceLanguage.frame.minY)
        XCTAssertGreaterThanOrEqual(provider.frame.minY, sourceLanguage.frame.maxY)
        XCTAssertGreaterThanOrEqual(targetText.frame.minY, provider.frame.maxY)
        XCTAssertLessThan(sourceLanguage.frame.maxX, swap.frame.midX)
        XCTAssertGreaterThan(targetLanguage.frame.minX, swap.frame.midX)
        // TextEditor 为消除 AppKit 自带的 5pt 文本内缩会略微扩展自身的
        // accessibility frame；以视觉上稳定的语言栏验证工作区左右 16pt 边距，
        // 避免把系统编辑器内部实现误当成画布外边界。
        XCTAssertEqual(sourceLanguage.frame.minX - window.frame.minX, 16, accuracy: 2)
        XCTAssertEqual(window.frame.maxX - targetLanguage.frame.maxX, 16, accuracy: 2)
        XCTAssertEqual(sourceLanguage.frame.height, targetLanguage.frame.height, accuracy: 1)
        XCTAssertEqual(sourceLanguage.frame.midY, targetLanguage.frame.midY, accuracy: 1)
        XCTAssertEqual(swap.frame.midY, sourceLanguage.frame.midY, accuracy: 1)

        XCTAssertTrue(app.staticTexts["translation.title"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["translation.subtitle"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["translation.detected-language"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["translation.processing-location"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["translation.status.success"].exists)
        XCTAssertTrue(app.buttons["translation.capture"].exists)
        XCTAssertTrue(swap.exists)
        XCTAssertTrue(app.buttons["translation.translate"].exists)
        XCTAssertTrue(app.buttons["translation.copy-source"].isEnabled)
        XCTAssertTrue(app.buttons["translation.copy-target"].isEnabled)

        let sourceCopy = app.buttons["translation.copy-source"]
        let targetCopy = app.buttons["translation.copy-target"]
        XCTAssertEqual(sourceCopy.frame.midX, targetCopy.frame.midX, accuracy: 1)
        XCTAssertEqual(window.frame.maxX - sourceCopy.frame.maxX, 18, accuracy: 2)

        // 短文本不创建垂直滚动条，避免右侧出现没有滚动价值的空滑块。
        XCTAssertFalse(app.scrollBars["translation.source-text.scrollbar"].exists)
        XCTAssertFalse(app.scrollBars["translation.target-text.scrollbar"].exists)

        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = "touch-translation-reference-layout-graphite"
        attachment.lifetime = .keepAlways
        add(attachment)

        let pin = app.buttons["translation.pin"]
        XCTAssertTrue(pin.exists)
        pin.click()
        let updatedPin = app.buttons["translation.pin"]
        XCTAssertEqual(updatedPin.value as? String, "已置顶")

        sourceLanguage.click()
        let englishOption = app.buttons["English"]
        XCTAssertTrue(englishOption.waitForExistence(timeout: 2))

        let pickerAttachment = XCTAttachment(screenshot: app.screenshot())
        pickerAttachment.name = "touch-translation-language-picker-open-graphite"
        pickerAttachment.lifetime = .keepAlways
        add(pickerAttachment)

        englishOption.click()
        XCTAssertEqual(sourceLanguage.value as? String, "English")
    }

    func testTranslationLanguagePackFixtureShowsChineseDownloadPrompt() throws {
        let app = XCUIApplication()
        defer { terminateFixtureApplication(app) }
        launchFixtureApplication(
            app,
            arguments: [
                "--show-translation-language-pack-fixture",
                "--appearance-theme=graphite"
            ]
        )

        XCTAssertTrue(app.staticTexts["translation.language-pack-title"].waitForExistence(timeout: 2))
        let message = app.staticTexts["translation.language-pack-message"]
        XCTAssertTrue(message.waitForExistence(timeout: 2))
        let accessibleMessage = "\(message.label) \(String(describing: message.value))"
        XCTAssertTrue(
            accessibleMessage.contains("当前语言组合受支持"),
            accessibleMessage
        )
        XCTAssertFalse(app.descendants(matching: .any)["translation.target-empty-state"].exists)
        XCTAssertFalse(app.buttons["translation.copy-target"].isEnabled)
        XCTAssertTrue(app.buttons["translation.cancel-language-pack"].exists)
        let downloadButton = app.buttons["translation.download-language-pack"]
        XCTAssertTrue(downloadButton.exists)
        XCTAssertEqual(downloadButton.frame.height, 20, accuracy: 2)

        let window = app.dialogs["translation.window"]
        let prompt = app.descendants(matching: .any)["translation.language-pack-prompt"]
        XCTAssertTrue(window.exists)
        XCTAssertTrue(prompt.exists)
        XCTAssertTrue(waitForHeight(of: window, greaterThan: 234))
        XCTAssertEqual(window.frame.height, 240, accuracy: 3)
        XCTAssertGreaterThanOrEqual(prompt.frame.minX, window.frame.minX)
        XCTAssertLessThanOrEqual(prompt.frame.maxX, window.frame.maxX)
        XCTAssertGreaterThanOrEqual(prompt.frame.minY, window.frame.minY)
        XCTAssertLessThanOrEqual(prompt.frame.maxY, window.frame.maxY)
        XCTAssertEqual(prompt.frame.height, 32, accuracy: 2)
        XCTAssertGreaterThanOrEqual(downloadButton.frame.minY - prompt.frame.minY, 4)
        XCTAssertGreaterThanOrEqual(prompt.frame.maxY - downloadButton.frame.maxY, 4)
        XCTAssertGreaterThanOrEqual(window.frame.maxY - prompt.frame.maxY, 5)

        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = "touch-translation-language-pack-graphite"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testTranslationLongTextExpandsWindowBeforeScrolling() throws {
        let app = XCUIApplication()
        defer { terminateFixtureApplication(app) }
        launchFixtureApplication(
            app,
            arguments: ["--show-translation-long-fixture", "--appearance-theme=graphite"]
        )

        let window = app.dialogs["translation.window"]
        XCTAssertTrue(window.waitForExistence(timeout: 2))
        XCTAssertEqual(window.frame.width, 560, accuracy: 2)
        XCTAssertTrue(waitForHeight(of: window, greaterThan: 234))
        XCTAssertLessThanOrEqual(window.frame.height, 488)

        let sourceSection = app.descendants(matching: .any)["translation.source-section"]
        let targetSection = app.descendants(matching: .any)["translation.target-section"]
        XCTAssertTrue(sourceSection.waitForExistence(timeout: 2))
        XCTAssertTrue(targetSection.exists)
        XCTAssertGreaterThan(sourceSection.frame.height, 64)
        XCTAssertGreaterThan(targetSection.frame.height, 50)

        // 普通长文本先通过拉高上下内容区完整展示，不应过早出现滚动条。
        XCTAssertFalse(app.scrollBars["translation.source-text.scrollbar"].exists)
        XCTAssertFalse(app.scrollBars["translation.target-text.scrollbar"].exists)

        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = "touch-translation-long-text-expanded-graphite"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testTranslationExtraLongTextScrollsAfterAdaptiveHeightLimit() throws {
        let app = XCUIApplication()
        defer { terminateFixtureApplication(app) }
        launchFixtureApplication(
            app,
            arguments: ["--show-translation-overflow-fixture", "--appearance-theme=graphite"]
        )

        let window = app.dialogs["translation.window"]
        XCTAssertTrue(window.waitForExistence(timeout: 2))
        XCTAssertEqual(window.frame.width, 560, accuracy: 2)
        XCTAssertTrue(waitForHeight(of: window, greaterThan: 400))
        XCTAssertLessThanOrEqual(window.frame.height, 488)

        XCTAssertTrue(
            app.scrollBars["translation.source-text.scrollbar"].waitForExistence(timeout: 2)
        )
        XCTAssertTrue(
            app.scrollBars["translation.target-text.scrollbar"].waitForExistence(timeout: 2)
        )

        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = "touch-translation-extra-long-text-scrollbars-graphite"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testClipboardFixtureShowsSingleColumnCardsWithoutUsingSystemPasteboard() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--show-clipboard-fixture", "--appearance-theme=graphite"]
        app.launch()

        let textCard = app.buttons[
            "clipboard.item.10000000-0000-0000-0000-000000000001"
        ]
        let imageCard = app.buttons[
            "clipboard.item.10000000-0000-0000-0000-000000000002"
        ]
        XCTAssertTrue(textCard.waitForExistence(timeout: 2))
        XCTAssertTrue(imageCard.waitForExistence(timeout: 2))
        XCTAssertEqual(textCard.frame.midX, imageCard.frame.midX, accuracy: 2)
        XCTAssertGreaterThan(textCard.frame.width, 560)
        let accessibleImageCard = "\(imageCard.label) \(String(describing: imageCard.value))"
        XCTAssertTrue(accessibleImageCard.contains("剪贴板图片预览"), accessibleImageCard)
        let fixtureDate = app.staticTexts[
            "clipboard.date.10000000-0000-0000-0000-000000000001"
        ]
        XCTAssertTrue(fixtureDate.waitForExistence(timeout: 1))
        let accessibleDate = "\(fixtureDate.label) \(String(describing: fixtureDate.value))"
        XCTAssertTrue(accessibleDate.contains("2026年7月23日"), accessibleDate)
        XCTAssertFalse(accessibleDate.contains(":"), accessibleDate)

        let favoritesFilter = app.buttons["clipboard.favorites-filter"]
        let clearButton = app.buttons["clipboard.clear"]
        XCTAssertTrue(favoritesFilter.waitForExistence(timeout: 1))
        XCTAssertTrue(clearButton.waitForExistence(timeout: 1))
        XCTAssertEqual(favoritesFilter.frame.midY, clearButton.frame.midY, accuracy: 1)
        XCTAssertGreaterThanOrEqual(clearButton.frame.minX - favoritesFilter.frame.maxX, 6)
        XCTAssertLessThanOrEqual(clearButton.frame.minX - favoritesFilter.frame.maxX, 12)

        favoritesFilter.click()
        XCTAssertTrue(textCard.waitForNonExistence(timeout: 1))
        XCTAssertTrue(imageCard.exists)

        favoritesFilter.click()
        XCTAssertTrue(textCard.waitForExistence(timeout: 1))

        textCard.click()

        let toast = app.descendants(matching: .any)["clipboard.copy-toast"]
        XCTAssertTrue(toast.waitForExistence(timeout: 1))
        let accessibleToast = "\(toast.label) \(String(describing: toast.value))"
        XCTAssertTrue(accessibleToast.contains("未改动系统剪贴板"), accessibleToast)

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "clipboard-single-column-graphite"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testOCRFixtureMatchesCompactScreenshotAboveTextLayout() throws {
        let app = XCUIApplication()
        defer { terminateFixtureApplication(app) }
        launchFixtureApplication(
            app,
            arguments: ["--show-ocr-fixture", "--appearance-theme=graphite"]
        )

        let window = app.dialogs["ocr.window"]
        let title = app.staticTexts["ocr.title"]
        let preview = app.images["ocr.preview"]
        let textEditor = app.descendants(matching: .any)["ocr.text-editor"]
        let capture = app.buttons["ocr.capture"]
        let copy = app.buttons["ocr.copy"]
        let translate = app.buttons["ocr.translate"]
        let clear = app.buttons["ocr.clear"]

        XCTAssertTrue(window.waitForExistence(timeout: 2))
        // 自动复制提示只有 1.4 秒；UI 自动化建立会话时可能已经自然消失。
        // 在截图前主动执行一次复制，稳定验证相同的提示外观与可访问性。
        XCTAssertTrue(copy.waitForExistence(timeout: 1))
        XCTAssertTrue(copy.isEnabled)
        copy.click()
        let copyToast = app.descendants(matching: .any)["ocr.copy-toast"]
        XCTAssertTrue(copyToast.waitForExistence(timeout: 1))
        let accessibleToast = "\(copyToast.label) \(String(describing: copyToast.value))"
        XCTAssertTrue(accessibleToast.contains("拷贝成功"), accessibleToast)

        XCTAssertEqual(window.frame.width, 390, accuracy: 3)
        XCTAssertEqual(window.frame.height, 252, accuracy: 3)
        XCTAssertTrue(title.exists)
        let accessibleTitle = "\(title.label) \(String(describing: title.value))"
        XCTAssertTrue(accessibleTitle.contains("文字识别"), accessibleTitle)
        XCTAssertTrue(preview.waitForExistence(timeout: 2))
        XCTAssertTrue(textEditor.exists)
        XCTAssertEqual(preview.frame.width, 247, accuracy: 3)
        XCTAssertEqual(preview.frame.height, 105, accuracy: 3)
        XCTAssertLessThanOrEqual(preview.frame.maxY, textEditor.frame.minY + 2)

        XCTAssertTrue(capture.exists)
        XCTAssertTrue(copy.isEnabled)
        XCTAssertTrue(translate.isEnabled)
        XCTAssertTrue(clear.isEnabled)
        for button in [copy, translate, clear] {
            XCTAssertEqual(button.frame.height, capture.frame.height, accuracy: 1)
            XCTAssertEqual(button.frame.midY, capture.frame.midY, accuracy: 1)
        }
        XCTAssertFalse(app.descendants(matching: .any)["ocr.subtitle"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["ocr.status"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["ocr.character-count"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["ocr.editor-surface"].exists)
        XCTAssertFalse(app.scrollBars["ocr.text-editor.scrollbar"].exists)

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "touch-text-recognition-reference-layout-graphite"
        attachment.lifetime = .keepAlways
        add(attachment)

        clear.click()

        XCTAssertTrue(app.descendants(matching: .any)["ocr.empty-state"].waitForExistence(timeout: 1))
        XCTAssertTrue(app.images["ocr.preview"].exists)
        XCTAssertFalse(app.buttons["ocr.copy"].isEnabled)
        XCTAssertFalse(app.buttons["ocr.translate"].isEnabled)
        XCTAssertFalse(app.buttons["ocr.clear"].isEnabled)
    }

    func testOCRLongTextExpandsWindowBeforeScrolling() throws {
        let app = XCUIApplication()
        defer { terminateFixtureApplication(app) }
        launchFixtureApplication(
            app,
            arguments: ["--show-ocr-long-fixture", "--appearance-theme=graphite"]
        )

        let window = app.dialogs["ocr.window"]
        XCTAssertTrue(window.waitForExistence(timeout: 2))
        XCTAssertEqual(window.frame.width, 390, accuracy: 3)
        XCTAssertTrue(waitForHeight(of: window, greaterThan: 254))
        XCTAssertLessThan(window.frame.height, 486)

        let textSection = app.descendants(matching: .any)["ocr.text-section"]
        XCTAssertTrue(textSection.waitForExistence(timeout: 2))
        XCTAssertGreaterThan(textSection.frame.height, 49)
        XCTAssertFalse(app.scrollBars["ocr.text-editor.scrollbar"].exists)

        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = "touch-text-recognition-long-text-expanded-graphite"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testOCRExtraLongTextScrollsAfterAdaptiveHeightLimit() throws {
        let app = XCUIApplication()
        defer { terminateFixtureApplication(app) }
        launchFixtureApplication(
            app,
            arguments: ["--show-ocr-overflow-fixture", "--appearance-theme=graphite"]
        )

        let window = app.dialogs["ocr.window"]
        XCTAssertTrue(window.waitForExistence(timeout: 2))
        XCTAssertEqual(window.frame.width, 390, accuracy: 3)
        XCTAssertTrue(waitForHeight(of: window, greaterThan: 400))
        XCTAssertEqual(window.frame.height, 486, accuracy: 3)

        let textSection = app.descendants(matching: .any)["ocr.text-section"]
        XCTAssertTrue(textSection.waitForExistence(timeout: 2))
        XCTAssertGreaterThan(textSection.frame.height, 250)
        XCTAssertTrue(
            app.scrollBars["ocr.text-editor.scrollbar"].waitForExistence(timeout: 2)
        )

        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = "touch-text-recognition-extra-long-scrollbar-graphite"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
