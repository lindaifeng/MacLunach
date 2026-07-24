import AppKit
import ClipboardFeature
import DailyTaskFeature
import FinderFeature
import HolidayCalendarFeature
import MarkdownPreviewFeature
import OCRFeature
import ParserToolsFeature
import PomodoroFeature
import ScreenshotFeature
import SuperRightFeature
import TouchCore
import TouchFeatureAPI
import TranslationFeature

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var launcherPanelController: LauncherPanelController?
    private var settingsWindowController: SettingsWindowController?
    private var pomodoroPanelController: PomodoroPanelController?
    private var holidayCalendarPanelController: HolidayCalendarPanelController?
    private var markdownPreviewPanelController: MarkdownPreviewPanelController?
    private var parserToolsPanelController: ParserToolsPanelController?
    private var dailyTaskPanelController: DailyTaskPanelController?
    private var clipboardPanelController: ClipboardPanelController?
    private var translationPanelController: TranslationPanelController?
    private var ocrPanelController: OCRPanelController?
    private var screenshotAnnotationFixtureController: AnnotationEditorController?
    private let themeStore = ThemeStore()
    let searchEnvironment = SearchEnvironment.makeForCurrentProcess()
    private(set) var screenshotEnvironment: ScreenshotEnvironment!
    private(set) var featureStore: FeatureAreaStore!
    private let globalHotKeyController = GlobalHotKeyController(identifier: 1)
    private let screenshotHotKeyController = GlobalHotKeyController(identifier: 2)
    private let allDisplaysScreenshotHotKeyController = GlobalHotKeyController(identifier: 3)
    private let colorPickerHotKeyController = GlobalHotKeyController(identifier: 4)
    private var featureHotKeyControllers: [String: GlobalHotKeyController] = [:]
    private let fileActionRelayHost = FileActionServiceRelayHost()
    private var statusItem: NSStatusItem?
    private var fileActionRelayDrainTask: Task<Void, Never>?
    private let isScreenshotSelectionFixture: Bool
    private let isScreenshotThumbnailFixture: Bool
    private let isScreenshotAnnotationFixture: Bool
    private let usesOCRFixture: Bool
    private let screenshotMeasurementOutputURL: URL?
    private var dailyTaskRepository: DailyTaskRepository!
    private var ocrRepository: OCRConfigurationRepository!

    override init() {
        let selectionOutputArgument = CommandLine.arguments.first {
            $0.hasPrefix("--screenshot-selection-output=")
        }
        isScreenshotSelectionFixture = CommandLine.arguments.contains(
            "--screenshot-selection-fixture"
        )
        isScreenshotThumbnailFixture = CommandLine.arguments.contains(
            "--screenshot-thumbnail-fixture"
        )
        isScreenshotAnnotationFixture = CommandLine.arguments.contains(
            "--screenshot-annotation-fixture"
        )
        usesOCRFixture = CommandLine.arguments.contains { argument in
            [
                "--show-ocr-fixture",
                "--show-ocr-long-fixture",
                "--show-ocr-overflow-fixture"
            ].contains(argument)
        }
        screenshotMeasurementOutputURL = Self.argumentURL(prefix: "--measure-screenshot=")
        super.init()

        let environment: ScreenshotEnvironment
        if isScreenshotSelectionFixture,
           let selectionOutputArgument,
           let outputPath = selectionOutputArgument.split(separator: "=", maxSplits: 1).last {
            environment = ScreenshotEnvironment(
                authorization: ScreenshotSelectionFixtureAuthorizer(),
                captureService: ScreenshotSelectionFixtureCaptureService(
                    content: ScreenshotSelectionFixtureContent.make(),
                    outputURL: URL(fileURLWithPath: String(outputPath))
                ),
                selectionFactory: {
                    SelectionOverlayController(
                        startsWithCommittedSelection: CommandLine.arguments.contains(
                            "--screenshot-selection-preselected"
                        ),
                        automaticallyCompletesOnMouseUp: CommandLine.arguments.contains(
                            "--screenshot-selection-auto-complete"
                        )
                    )
                }
            )
        } else if isScreenshotThumbnailFixture {
            let rootURL = Self.argumentURL(prefix: "--screenshot-thumbnail-root=")
                ?? FileManager.default.temporaryDirectory.appendingPathComponent(
                    "touch-thumbnail-fixture-\(ProcessInfo.processInfo.processIdentifier)",
                    isDirectory: true
                )
            let outputURL = Self.argumentURL(prefix: "--screenshot-thumbnail-output=")
                ?? rootURL.appendingPathComponent("events.txt")
            let paths = ScreenshotFeaturePaths(rootURL: rootURL)
            let recorder = ScreenshotThumbnailFixtureEventRecorder(outputURL: outputURL)
            var configuration = ScreenshotFeatureConfiguration()
            configuration.thumbnailTimeout = .never
            environment = ScreenshotEnvironment(
                authorization: ScreenshotSelectionFixtureAuthorizer(),
                captureService: ScreenshotThumbnailFixtureCaptureService(
                    content: ScreenshotSelectionFixtureContent.make(),
                    paths: paths,
                    recorder: recorder
                ),
                clipboardWriter: ScreenshotThumbnailFixtureClipboardWriter(
                    paths: paths,
                    recorder: recorder
                ),
                annotationPresenter: ScreenshotThumbnailFixtureAnnotationPresenter(
                    recorder: recorder
                ),
                floatingThumbnailPresenter: FloatingThumbnailController(pathsProvider: { paths }),
                configurationProvider: { configuration }
            )
        } else {
            let measurementConfigurationProvider: ScreenshotCoordinator.ConfigurationProvider?
            if screenshotMeasurementOutputURL != nil {
                var configuration = FeatureConfigurationStore().load().screenshot
                configuration.afterCaptureAction = .copyAndShowThumbnail
                configuration.showsFloatingThumbnail = true
                configuration.thumbnailTimeout = .never
                measurementConfigurationProvider = { configuration }
            } else {
                measurementConfigurationProvider = nil
            }
            environment = ScreenshotEnvironment(
                themeStore: themeStore,
                configurationProvider: measurementConfigurationProvider,
                registerShortcuts: { [weak self] in self?.registerScreenshotShortcuts() },
                unregisterShortcuts: { [weak self] in self?.unregisterScreenshotShortcuts() }
            )
        }
        screenshotEnvironment = environment
        let superRightStorage = FeatureStorageFactory()
            .makeStorage(pluginID: SuperRightFeaturePlugin.id)
        let usesDailyTaskFixture = CommandLine.arguments.contains("--daily-task-fixture")
        let dailyTaskDefaults: UserDefaults
        if usesDailyTaskFixture {
            let suiteName = "me.touch.daily-task-fixture.\(ProcessInfo.processInfo.processIdentifier)"
            dailyTaskDefaults = UserDefaults(suiteName: suiteName) ?? .standard
            dailyTaskDefaults.removePersistentDomain(forName: suiteName)
        } else {
            dailyTaskDefaults = .standard
        }
        let dailyTaskStorage = FeatureStorageFactory(defaults: dailyTaskDefaults)
            .makeStorage(pluginID: DailyTaskFeaturePlugin.id)
        dailyTaskRepository = DailyTaskRepository(storage: dailyTaskStorage)
        if usesDailyTaskFixture {
            try? dailyTaskRepository.save(Self.makeDailyTaskFixture())
        }
        let ocrDefaults: UserDefaults
        if usesOCRFixture {
            let suiteName = "me.touch.ocr-fixture.\(ProcessInfo.processInfo.processIdentifier)"
            ocrDefaults = UserDefaults(suiteName: suiteName) ?? .standard
            ocrDefaults.removePersistentDomain(forName: suiteName)
        } else {
            ocrDefaults = .standard
        }
        let ocrStorage = FeatureStorageFactory(defaults: ocrDefaults)
            .makeStorage(pluginID: OCRFeaturePlugin.id)
        ocrRepository = OCRConfigurationRepository(storage: ocrStorage)
        if usesOCRFixture {
            try? ocrRepository.save(.init(automaticallyCopiesRecognizedText: true))
        }
        try? FeatureConfigurationStore().handoffLegacyConfiguration(to: superRightStorage)
        featureStore = FeatureAreaStore(
            plugins: [
                FinderFeaturePlugin(),
                ScreenshotFeaturePlugin(router: environment.coordinator),
                SuperRightFeaturePlugin(storage: superRightStorage),
                DailyTaskFeaturePlugin(storage: dailyTaskStorage),
                PomodoroFeaturePlugin(),
                HolidayCalendarFeaturePlugin(),
                MarkdownPreviewFeaturePlugin(),
                ParserToolsFeaturePlugin(),
                ClipboardFeaturePlugin(),
                TranslationFeaturePlugin(),
                OCRFeaturePlugin(storage: ocrStorage)
            ]
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let launchedForFileActionRelay = FileActionServiceRelay.hasPendingRequests
        let usesClipboardFixture = CommandLine.arguments.contains("--show-clipboard-fixture")
        NSApp.setActivationPolicy(.regular)
        installTextEditingMenu()
        installStatusItem()
        startFileActionRelay()
        if !isScreenshotSelectionFixture,
           !isScreenshotThumbnailFixture,
           !isScreenshotAnnotationFixture,
           screenshotMeasurementOutputURL == nil {
            Task { await searchEnvironment.prepareApplications() }
        }
        let launcher = LauncherPanelController(
            searchEnvironment: searchEnvironment,
            featureStore: featureStore,
            screenshotEnvironment: screenshotEnvironment,
            themeStore: themeStore
        )
        launcherPanelController = launcher
        pomodoroPanelController = PomodoroPanelController(themeStore: themeStore) { [weak self] in
            self?.launcherPanelController?.show()
        }
        holidayCalendarPanelController = HolidayCalendarPanelController(themeStore: themeStore) { [weak self] in
            self?.launcherPanelController?.show()
        }
        markdownPreviewPanelController = MarkdownPreviewPanelController(themeStore: themeStore) { [weak self] in
            self?.launcherPanelController?.show()
        }
        parserToolsPanelController = ParserToolsPanelController(themeStore: themeStore) { [weak self] in
            self?.launcherPanelController?.show()
        }
        clipboardPanelController = ClipboardPanelController(
            themeStore: themeStore,
            usesFixtureData: usesClipboardFixture
        ) { [weak self] in
            self?.launcherPanelController?.show()
        }
        translationPanelController = TranslationPanelController(
            screenshotCoordinator: screenshotEnvironment.coordinator,
            themeStore: themeStore
        ) { [weak self] in
            self?.launcherPanelController?.show()
        }
        ocrPanelController = OCRPanelController(
            screenshotCoordinator: screenshotEnvironment.coordinator,
            themeStore: themeStore,
            configurationProvider: { [ocrRepository] in
                (try? ocrRepository?.load()) ?? .init()
            },
            copyWriter: { [usesOCRFixture] text in
                if usesOCRFixture { return true }
                return OCRPanelController.writeToSystemPasteboard(text)
            },
            onTranslate: { [weak self] request in
                self?.translationPanelController?.show(request: request)
            }
        ) { [weak self] in
            self?.launcherPanelController?.show()
        }
        dailyTaskPanelController = DailyTaskPanelController(
            repository: dailyTaskRepository,
            themeStore: themeStore,
            onStartFocus: { [weak self] request in
                self?.pomodoroPanelController?.show(request: request)
            }
        ) { [weak self] in
            self?.launcherPanelController?.show()
        }
        screenshotEnvironment.coordinator.attachLauncher(launcher)
        settingsWindowController = SettingsWindowController(
            searchEnvironment: searchEnvironment,
            featureStore: featureStore,
            screenshotEnvironment: screenshotEnvironment,
            themeStore: themeStore
        ) { [weak self] in
            self?.restoreLauncherAfterSettingsClose()
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleOpenSettings(_:)),
            name: .openTouchSettings,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePresentFeaturePanel(_:)),
            name: .presentTouchFeaturePanel,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleStartFocusSession(_:)),
            name: .startTouchFocusSession,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRebuildSearchIndex),
            name: .rebuildTouchSearchIndex,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenshotShortcutsDidChange),
            name: .screenshotShortcutsDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleLauncherShortcutDidChange),
            name: .launcherShortcutDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleFeatureGlobalShortcutsDidChange),
            name: .featureGlobalShortcutsDidChange,
            object: nil
        )

        if isScreenshotAnnotationFixture {
            let outputURL = Self.argumentURL(prefix: "--screenshot-annotation-output=")
                ?? FileManager.default.temporaryDirectory.appendingPathComponent(
                    "touch-annotation-fixture-\(ProcessInfo.processInfo.processIdentifier).txt"
                )
            let exportDestination = Self.argumentURL(
                prefix: "--screenshot-annotation-export-destination="
            )
            let controller = ScreenshotAnnotationFixture.makeController(
                outputURL: outputURL,
                exportDestination: exportDestination,
                themeStore: themeStore,
                failFirstExport: CommandLine.arguments.contains(
                    "--screenshot-annotation-fail-first-export"
                ),
                failFirstCopy: CommandLine.arguments.contains(
                    "--screenshot-annotation-fail-first-copy"
                )
            )
            screenshotAnnotationFixtureController = controller
            controller.present()
        } else if isScreenshotSelectionFixture {
            Task { @MainActor [weak self] in
                do {
                    _ = try await self?.screenshotEnvironment.coordinator.route(.captureDefaultMode)
                } catch {
                    NSLog("Screenshot selection UI fixture failed: %@", error.localizedDescription)
                }
            }
        } else if isScreenshotThumbnailFixture || screenshotMeasurementOutputURL != nil {
            if let outputURL = screenshotMeasurementOutputURL {
                ScreenshotThumbnailPerformanceRecorder.shared.prepareNextSample { milliseconds in
                    Self.appendScreenshotMeasurement(milliseconds, to: outputURL)
                    NSApp.terminate(nil)
                }
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let result = try await self.screenshotEnvironment.coordinator.route(.captureAllDisplays)
                    if case let .requiresSetup(message) = result,
                       self.screenshotMeasurementOutputURL != nil {
                        NSLog("Screenshot measurement requires setup: %@", message)
                        NSApp.terminate(nil)
                    }
                } catch {
                    NSLog("Screenshot thumbnail fixture failed: %@", error.localizedDescription)
                    if self.screenshotMeasurementOutputURL != nil {
                        NSApp.terminate(nil)
                    }
                }
            }
        } else if let measurementArgument = CommandLine.arguments.first(where: { $0.hasPrefix("--measure-launcher=") }),
           let outputPath = measurementArgument.split(separator: "=", maxSplits: 1).last {
            let outputURL = URL(fileURLWithPath: String(outputPath))
            Task { @MainActor [weak self] in
                await self?.launcherPanelController?.runPerformanceMeasurement(samples: 30, outputURL: outputURL)
            }
        } else if usesClipboardFixture {
            Task { @MainActor [weak self] in
                self?.clipboardPanelController?.show()
            }
        } else if CommandLine.arguments.contains("--show-translation-fixture") {
            Task { @MainActor [weak self] in
                self?.translationPanelController?.showFixture(
                    sourceText: "原文内容",
                    translatedText: "Original content"
                )
            }
        } else if CommandLine.arguments.contains("--show-translation-language-pack-fixture") {
            Task { @MainActor [weak self] in
                self?.translationPanelController?.showLanguagePackFixture(
                    sourceText: "原文内容"
                )
            }
        } else if CommandLine.arguments.contains("--show-translation-long-fixture") {
            Task { @MainActor [weak self] in
                self?.translationPanelController?.showFixture(
                    sourceText: "这是一段用于验证长文本自适应布局的截图识别内容。原文和译文会先随内容自然增高，只有窗口达到合理高度上限且文字真正超出显示区域时，右侧才出现滚动条；短文本保持紧凑干净，不显示空滑块。",
                    translatedText: "This long translation fixture verifies adaptive content sizing. The source and translation areas expand with their text first, and scrollbars appear only after the window reaches its height limit."
                )
            }
        } else if CommandLine.arguments.contains("--show-translation-overflow-fixture") {
            Task { @MainActor [weak self] in
                let sourceText = Array(
                    repeating: "超长原文用于验证窗口达到自适应高度上限后，原文区域继续通过滚动查看。",
                    count: 18
                ).joined(separator: "\n")
                let translatedText = Array(
                    repeating: "Extra-long translated content remains scrollable after the adaptive window reaches its height limit.",
                    count: 18
                ).joined(separator: "\n")
                self?.translationPanelController?.showFixture(
                    sourceText: sourceText,
                    translatedText: translatedText
                )
            }
        } else if CommandLine.arguments.contains("--show-ocr-long-fixture") {
            Task { @MainActor [weak self] in
                let text = [
                    "文字识别会完整保留截图中的段落结构。",
                    "普通长文本会先随内容自动增高。",
                    "在窗口达到高度上限之前不会显示滚动条。",
                    "你仍然可以直接编辑、复制或翻译识别结果。",
                    "重新截图后，窗口会根据新内容重新调整高度。"
                ].joined(separator: "\n")
                self?.ocrPanelController?.show(
                    result: .init(
                        text: text,
                        recognizedLanguageCode: "zh-Hans",
                        previewImageData: OCRFixturePreview.makeImageData()
                    )
                )
            }
        } else if CommandLine.arguments.contains("--show-ocr-overflow-fixture") {
            Task { @MainActor [weak self] in
                let text = Array(
                    repeating: "超长识别内容用于验证窗口达到 486pt 上限后继续滚动查看。",
                    count: 24
                ).joined(separator: "\n")
                self?.ocrPanelController?.show(
                    result: .init(
                        text: text,
                        recognizedLanguageCode: "zh-Hans",
                        previewImageData: OCRFixturePreview.makeImageData()
                    )
                )
            }
        } else if CommandLine.arguments.contains("--show-ocr-fixture") {
            Task { @MainActor [weak self] in
                self?.ocrPanelController?.show(
                    result: .init(
                        text: "pple Root CA\nier=8YLX494879",
                        recognizedLanguageCode: "en",
                        previewImageData: OCRFixturePreview.makeImageData()
                    )
                )
            }
        } else if CommandLine.arguments.contains("--open-settings") {
            Task { @MainActor [weak self] in
                self?.showSettings()
            }
        } else if CommandLine.arguments.contains("--show-pomodoro-and-launcher") {
            Task { @MainActor [weak self] in
                self?.pomodoroPanelController?.show()
                self?.launcherPanelController?.show()
            }
        } else if CommandLine.arguments.contains("--show-pomodoro") {
            Task { @MainActor [weak self] in
                self?.pomodoroPanelController?.show()
            }
        } else if CommandLine.arguments.contains("--show-holiday-calendar") {
            Task { @MainActor [weak self] in
                self?.holidayCalendarPanelController?.show()
            }
        } else if CommandLine.arguments.contains("--show-markdown") {
            Task { @MainActor [weak self] in
                self?.markdownPreviewPanelController?.show()
            }
        } else if CommandLine.arguments.contains("--show-daily-tasks") {
            Task { @MainActor [weak self] in
                self?.dailyTaskPanelController?.show()
            }
        } else if launchedForFileActionRelay {
            // Finder 动作的后台唤起不抢焦点，也不弹出启动器。
            NSApp.hide(nil)
        } else {
            Task { @MainActor [weak self] in
                self?.launcherPanelController?.show()
            }
        }
        guard !isScreenshotSelectionFixture,
              !isScreenshotThumbnailFixture,
              !isScreenshotAnnotationFixture,
              screenshotMeasurementOutputURL == nil else { return }
        registerLauncherShortcut()
        registerFeatureGlobalShortcuts()
    }

    /// 为 SwiftUI、AppKit 以及自定义文本编辑器提供统一的原生编辑命令。
    /// target 保持为 nil，让 AppKit 将动作沿 responder chain 发送给当前输入控件。
    private func installTextEditingMenu() {
        let mainMenu = NSApp.mainMenu ?? NSMenu()
        if NSApp.mainMenu == nil {
            NSApp.mainMenu = mainMenu
        }
        guard mainMenu.items.contains(where: { $0.submenu?.identifier?.rawValue == "touch.edit-menu" }) == false else {
            return
        }

        let editMenu = NSMenu(title: "编辑")
        editMenu.identifier = NSUserInterfaceItemIdentifier("touch.edit-menu")
        editMenu.autoenablesItems = true
        editMenu.addItem(commandItem(title: "撤销", action: Selector(("undo:")), key: "z"))
        let redoItem = commandItem(title: "重做", action: Selector(("redo:")), key: "z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redoItem)
        editMenu.addItem(.separator())
        editMenu.addItem(commandItem(title: "剪切", action: #selector(NSText.cut(_:)), key: "x"))
        editMenu.addItem(commandItem(title: "复制", action: #selector(NSText.copy(_:)), key: "c"))
        editMenu.addItem(commandItem(title: "粘贴", action: #selector(NSText.paste(_:)), key: "v"))
        editMenu.addItem(commandItem(title: "全选", action: #selector(NSText.selectAll(_:)), key: "a"))

        let editMenuItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)
    }

    private func installStatusItem() {
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = item.button else { return }

        let image = NSImage(named: NSImage.Name("StatusBarLogo"))
        image?.size = NSSize(width: 18, height: 18)
        image?.isTemplate = false
        button.image = image
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(handleStatusItemClick(_:))
        button.toolTip = "一念"
        button.setAccessibilityLabel("一念")
        statusItem = item
    }

    private static func makeDailyTaskFixture() -> DailyTaskConfiguration {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        func deadline(on day: Date, hour: Int) -> Date? {
            calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day)
        }

        let focusTask = DailyTask(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            title: "撰写产品需求文档",
            scheduledDate: today,
            detail: "明确核心需求与功能范围，优先完成需求文档初稿。",
            estimatedMinutes: 60,
            priority: .urgent,
            category: "工作",
            deadline: deadline(on: today, hour: 20)
        )
        let tasks = [
            focusTask,
            DailyTask(title: "复习操作系统知识点", scheduledDate: today, estimatedMinutes: 45, category: "学习", deadline: deadline(on: tomorrow, hour: 10)),
            DailyTask(title: "整理读书笔记", scheduledDate: today, estimatedMinutes: 30, priority: .high, category: "个人成长", deadline: deadline(on: tomorrow, hour: 18)),
            DailyTask(title: "准备本周工作计划", scheduledDate: today, estimatedMinutes: 25, category: "工作"),
            DailyTask(title: "完成设计稿评审", scheduledDate: today, estimatedMinutes: 45, status: .inProgress, priority: .high, category: "工作", deadline: deadline(on: today, hour: 18)),
            DailyTask(title: "准备周会汇报材料", scheduledDate: today, estimatedMinutes: 90, status: .inProgress, category: "工作", deadline: deadline(on: tomorrow, hour: 9)),
            DailyTask(title: "晨间冥想 10 分钟", scheduledDate: today, estimatedMinutes: 10, status: .completed, category: "健康"),
            DailyTask(title: "回复邮件", scheduledDate: today, estimatedMinutes: 15, status: .completed, category: "工作"),
            DailyTask(title: "完成 30 分钟运动", scheduledDate: today, estimatedMinutes: 30, status: .completed, category: "健康"),
            DailyTask(title: "背单词 20 个", scheduledDate: today, estimatedMinutes: 20, status: .completed, category: "学习")
        ]
        return DailyTaskConfiguration(tasks: tasks, focusTaskID: focusTask.id)
    }

    private func commandItem(title: String, action: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = [.command]
        return item
    }

    private static func argumentURL(prefix: String) -> URL? {
        guard let argument = CommandLine.arguments.first(where: { $0.hasPrefix(prefix) }),
              let path = argument.split(separator: "=", maxSplits: 1).last,
              !path.isEmpty else { return nil }
        return URL(fileURLWithPath: String(path))
    }

    private static func appendScreenshotMeasurement(_ milliseconds: Double, to outputURL: URL) {
        let line = String(format: "%.3f\n", milliseconds)
        let directory = outputURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: outputURL.path) {
            try? line.write(to: outputURL, atomically: true, encoding: .utf8)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: outputURL) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
        } catch {
            NSLog("Unable to append screenshot performance sample: %@", error.localizedDescription)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        globalHotKeyController.stop()
        unregisterScreenshotShortcuts()
        featureHotKeyControllers.values.forEach { $0.stop() }
        featureHotKeyControllers.removeAll()
        clipboardPanelController?.stopMonitoring()
        Task { [screenshotEnvironment] in
            await screenshotEnvironment?.coordinator.deactivate()
        }
        NotificationCenter.default.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
        fileActionRelayDrainTask?.cancel()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if FileActionServiceRelay.hasPendingRequests {
            drainFileActionRelay()
            return false
        }
        // 双击应用或通过 `open` 再次唤起时，启动器始终是首要界面。
        // 设置窗口可能仍在后台可见，不能让它拦截应用的再次唤起。
        settingsWindowController?.window?.orderOut(nil)
        launcherPanelController?.show()
        return false
    }

    private func startFileActionRelay() {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleFileActionRelayRequest),
            name: FileActionServiceRelay.notificationName,
            object: nil
        )
        drainFileActionRelay()
    }

    @objc private func handleFileActionRelayRequest() {
        drainFileActionRelay()
    }

    private func drainFileActionRelay() {
        guard fileActionRelayDrainTask == nil else { return }
        fileActionRelayDrainTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await fileActionRelayHost.drainPendingRequests()
            fileActionRelayDrainTask = nil
            if FileActionServiceRelay.hasPendingRequests {
                drainFileActionRelay()
            }
        }
    }

    func applicationShouldRestoreApplicationState(_ app: NSApplication) -> Bool {
        false
    }

    func applicationShouldSaveApplicationState(_ app: NSApplication) -> Bool {
        false
    }

    @objc private func handleOpenSettings(_ notification: Notification) {
        if let destination = notification.object as? TouchSettingsDestination {
            showSettings(destination: destination)
        } else {
            showSettings(section: notification.object as? TouchSettingsSection ?? .general)
        }
    }

    @objc private func handleStatusItemClick(_ sender: Any?) {
        handleLauncherHotKey()
    }

    @objc private func handlePresentFeaturePanel(_ notification: Notification) {
        guard let featureID = notification.object as? String else { return }
        switch featureID {
        case DailyTaskFeaturePlugin.id:
            launcherPanelController?.hide()
            dailyTaskPanelController?.show()
        case PomodoroFeaturePlugin.id:
            launcherPanelController?.hide()
            pomodoroPanelController?.show()
        case HolidayCalendarFeaturePlugin.id:
            launcherPanelController?.hide()
            holidayCalendarPanelController?.show()
        case MarkdownPreviewFeaturePlugin.id:
            launcherPanelController?.hide()
            markdownPreviewPanelController?.show()
        case ParserToolsFeaturePlugin.id:
            launcherPanelController?.hide()
            parserToolsPanelController?.show()
        case ClipboardFeaturePlugin.id:
            launcherPanelController?.hide()
            clipboardPanelController?.show()
        case TranslationFeaturePlugin.id:
            launcherPanelController?.hide()
            translationPanelController?.show()
        case OCRFeaturePlugin.id:
            launcherPanelController?.hide()
            ocrPanelController?.show()
        default:
            break
        }
    }

    @objc private func handleStartFocusSession(_ notification: Notification) {
        guard let request = notification.object as? FocusSessionRequest else { return }
        pomodoroPanelController?.show(request: request)
    }

    @objc private func handleRebuildSearchIndex() {
        Task { [searchEnvironment] in await searchEnvironment.rebuildIndex() }
    }

    @objc private func handleScreenshotShortcutsDidChange() {
        guard featureStore.isEnabled(FeatureConfigurationStore.screenshotID) else { return }
        registerScreenshotShortcuts()
    }

    @objc private func handleLauncherShortcutDidChange() {
        registerLauncherShortcut()
    }

    @objc private func handleFeatureGlobalShortcutsDidChange() {
        registerFeatureGlobalShortcuts()
    }

    private func registerLauncherShortcut() {
        do {
            try globalHotKeyController.start(shortcut: LauncherShortcutPreferences.load()) { [weak self] in
                self?.handleLauncherHotKey()
            }
        } catch {
            NSLog("Unable to register Touch launcher shortcut: %@", error.localizedDescription)
        }
    }

    private func registerFeatureGlobalShortcuts() {
        featureHotKeyControllers.values.forEach { $0.stop() }
        featureHotKeyControllers.removeAll()

        for (offset, plugin) in featureStore.plugins.enumerated() {
            let featureID = plugin.manifest.id
            featureStore.setGlobalShortcutRegistrationError(nil, for: featureID)
            guard featureStore.isEnabled(featureID),
                  let shortcut = featureStore.globalShortcut(for: featureID) else {
                continue
            }

            let controller = GlobalHotKeyController(identifier: UInt32(100 + offset))
            do {
                try controller.start(shortcut: shortcut) { [weak self] in
                    guard let self else { return }
                    Task { @MainActor in
                        await self.featureStore.perform(featureID)
                    }
                }
                featureHotKeyControllers[featureID] = controller
            } catch {
                featureStore.setGlobalShortcutRegistrationError(
                    "该组合键已被系统或其他应用占用，请换一个快捷键",
                    for: featureID
                )
                NSLog(
                    "Unable to register global shortcut for %@: %@",
                    featureID,
                    error.localizedDescription
                )
            }
        }
    }

    private func registerScreenshotShortcuts() {
        unregisterScreenshotShortcuts()
        if let shortcut = featureStore.configurations.screenshot.modeShortcuts[.allDisplays],
           !shortcut.modifiers.isEmpty {
            do {
                try allDisplaysScreenshotHotKeyController.start(shortcut: shortcut) { [weak self] in
                    self?.performScreenshot(.captureAllDisplays)
                }
            } catch {
                NSLog("Unable to register all-displays screenshot shortcut: %@", error.localizedDescription)
            }
        }

        if let shortcut = featureStore.configurations.screenshot.modeShortcuts[.colorPicker],
           !shortcut.modifiers.isEmpty {
            do {
                try colorPickerHotKeyController.start(shortcut: shortcut) { [weak self] in
                    self?.performScreenshot(.pickColor)
                }
            } catch {
                NSLog("Unable to register color-picker shortcut: %@", error.localizedDescription)
            }
        }
    }

    private func unregisterScreenshotShortcuts() {
        screenshotHotKeyController.stop()
        allDisplaysScreenshotHotKeyController.stop()
        colorPickerHotKeyController.stop()
    }

    private func performScreenshot(_ action: ScreenshotPluginAction) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await screenshotEnvironment.coordinator.route(action)
                if case .requiresSetup = result {
                    showSettings(section: .permissions)
                }
            } catch ScreenshotCoordinatorError.busy {
                NSSound.beep()
            } catch {
                NSLog("Screenshot shortcut action failed: %@", error.localizedDescription)
            }
        }
    }

    private func showSettings(section: TouchSettingsSection = .general) {
        showSettings(destination: TouchSettingsDestination(section: section))
    }

    private func showSettings(destination: TouchSettingsDestination) {
        launcherPanelController?.hide()
        settingsWindowController?.show(destination: destination)
    }

    private func handleLauncherHotKey() {
        let settingsWasVisible = settingsWindowController?.window?.isVisible == true
        if settingsWasVisible {
            settingsWindowController?.window?.orderOut(nil)
        }

        if settingsWasVisible {
            launcherPanelController?.show()
        } else {
            launcherPanelController?.toggle()
        }
    }

    private func restoreLauncherAfterSettingsClose() {
        launcherPanelController?.show()
    }
}
