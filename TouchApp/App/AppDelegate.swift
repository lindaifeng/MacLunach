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

struct FeaturePanelSessionState: Equatable {
    private(set) var openFeatureIDs: [String] = []

    var frontmostFeatureID: String? { openFeatureIDs.last }

    mutating func open(_ featureID: String) {
        openFeatureIDs.removeAll { $0 == featureID }
        openFeatureIDs.append(featureID)
    }

    mutating func promote(_ featureID: String) {
        guard openFeatureIDs.contains(featureID) else { return }
        open(featureID)
    }

    mutating func close(_ featureID: String) {
        openFeatureIDs.removeAll { $0 == featureID }
    }

}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var launcherPanelController: LauncherPanelController?
    private var settingsWindowController: SettingsWindowController?
    private var moveConflictWindowController: MoveConflictWindowController?
    private var pomodoroPanelController: PomodoroPanelController?
    private var holidayCalendarPanelController: HolidayCalendarPanelController?
    private var markdownPreviewPanelController: MarkdownPreviewPanelController?
    private var parserToolsPanelController: ParserToolsPanelController?
    private var dailyTaskPanelController: DailyTaskPanelController?
    private var clipboardPanelController: ClipboardPanelController?
    private var translationPanelController: TranslationPanelController?
    private var pendingTranslationRequest: TextTranslationRequest?
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
    private var moveConflictMonitorTimer: Timer?
    private let isScreenshotSelectionFixture: Bool
    private let isScreenshotThumbnailFixture: Bool
    private let isScreenshotAnnotationFixture: Bool
    private let usesOCRFixture: Bool
    private let screenshotMeasurementOutputURL: URL?
    private var dailyTaskRepository: DailyTaskRepository!
    private var ocrRepository: OCRConfigurationRepository!
    private var featurePanelSession = FeaturePanelSessionState()
    private var suppressLauncherForNextApplicationActivation = false
    private var priorExternalApplicationPID: Int32?
    private var windowCloseSettlementTask: Task<Void, Never>?
    private var pomodoroCardStatusTimer: Timer?

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

        let translationRequestHandler: ScreenshotCoordinator.TranslationRequestHandler = { [weak self] request in
            self?.presentTranslationRequest(request)
        }
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
                },
                translationRequestHandler: translationRequestHandler
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
                configurationProvider: { configuration },
                translationRequestHandler: translationRequestHandler
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
                translationRequestHandler: translationRequestHandler,
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
        let launchedForMoveConflict = (try? MoveConflictRequestStore().loadValid()) != nil
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
        pomodoroPanelController = PomodoroPanelController(
            themeStore: themeStore,
            onCompletion: { [weak self] in
                self?.presentPomodoroCompletion()
            },
            onClose: { [weak self] in
                self?.closeFeaturePanelSession(PomodoroFeaturePlugin.id)
            }
        )
        holidayCalendarPanelController = HolidayCalendarPanelController(themeStore: themeStore) { [weak self] in
            self?.closeFeaturePanelSession(HolidayCalendarFeaturePlugin.id)
        }
        markdownPreviewPanelController = MarkdownPreviewPanelController(themeStore: themeStore) { [weak self] in
            self?.closeFeaturePanelSession(MarkdownPreviewFeaturePlugin.id)
        }
        parserToolsPanelController = ParserToolsPanelController(themeStore: themeStore) { [weak self] in
            self?.closeFeaturePanelSession(ParserToolsFeaturePlugin.id)
        }
        clipboardPanelController = ClipboardPanelController(
            themeStore: themeStore,
            usesFixtureData: usesClipboardFixture
        ) { [weak self] in
            self?.closeFeaturePanelSession(ClipboardFeaturePlugin.id)
        }
        translationPanelController = TranslationPanelController(
            screenshotCoordinator: screenshotEnvironment.coordinator,
            themeStore: themeStore,
            onPresented: { [weak self] in
                self?.beginFeaturePanelPresentation(TranslationFeaturePlugin.id)
            },
            onClose: { [weak self] in
                self?.closeFeaturePanelSession(TranslationFeaturePlugin.id)
            }
        )
        if let pendingTranslationRequest {
            self.pendingTranslationRequest = nil
            presentTranslationRequest(pendingTranslationRequest)
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
                self?.presentTranslationRequest(request)
            },
            onPresented: { [weak self] in
                self?.beginFeaturePanelPresentation(OCRFeaturePlugin.id)
            },
            onClose: { [weak self] in
                self?.closeFeaturePanelSession(OCRFeaturePlugin.id)
            }
        )
        dailyTaskPanelController = DailyTaskPanelController(
            repository: dailyTaskRepository,
            themeStore: themeStore,
            onStartFocus: { [weak self] request in
                self?.presentPomodoro(request: request)
            }
        ) { [weak self] in
            self?.closeFeaturePanelSession(DailyTaskFeaturePlugin.id)
        }
        screenshotEnvironment.coordinator.attachLauncher(launcher)
        startPomodoroCardStatusUpdates()
        settingsWindowController = SettingsWindowController(
            searchEnvironment: searchEnvironment,
            featureStore: featureStore,
            screenshotEnvironment: screenshotEnvironment,
            themeStore: themeStore
        ) { [weak self] in
            self?.settleAfterTouchWindowClosed()
        }
        moveConflictWindowController = MoveConflictWindowController(
            themeStore: themeStore,
            onResolve: { [weak self] request, resolution in
                self?.resolveMoveConflict(request, resolution: resolution)
            },
            onCancel: { _ in
                try? MoveConflictResolutionService.cancel()
            }
        )
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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWindowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification,
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
                self?.beginFeaturePanelPresentation(ClipboardFeaturePlugin.id)
                self?.clipboardPanelController?.show()
            }
        } else if CommandLine.arguments.contains("--show-translation-fixture") {
            Task { @MainActor [weak self] in
                self?.beginFeaturePanelPresentation(TranslationFeaturePlugin.id)
                self?.translationPanelController?.showFixture(
                    sourceText: "原文内容",
                    translatedText: "Original content"
                )
            }
        } else if CommandLine.arguments.contains("--show-translation-language-pack-fixture") {
            Task { @MainActor [weak self] in
                self?.beginFeaturePanelPresentation(TranslationFeaturePlugin.id)
                self?.translationPanelController?.showLanguagePackFixture(
                    sourceText: "原文内容"
                )
            }
        } else if CommandLine.arguments.contains("--show-translation-long-fixture") {
            Task { @MainActor [weak self] in
                self?.beginFeaturePanelPresentation(TranslationFeaturePlugin.id)
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
                self?.beginFeaturePanelPresentation(TranslationFeaturePlugin.id)
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
                self?.beginFeaturePanelPresentation(OCRFeaturePlugin.id)
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
                self?.beginFeaturePanelPresentation(OCRFeaturePlugin.id)
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
                self?.beginFeaturePanelPresentation(OCRFeaturePlugin.id)
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
        } else if CommandLine.arguments.contains("--show-pomodoro-completed-fixture") {
            Task { @MainActor [weak self] in
                self?.beginFeaturePanelPresentation(PomodoroFeaturePlugin.id)
                self?.pomodoroPanelController?.showCompletedFixture()
            }
        } else if CommandLine.arguments.contains("--show-pomodoro-background-completion-fixture") {
            Task { @MainActor [weak self] in
                self?.beginFeaturePanelPresentation(PomodoroFeaturePlugin.id)
                self?.pomodoroPanelController?.showCompletionCountdownFixture()
            }
        } else if CommandLine.arguments.contains("--show-pomodoro-and-launcher") {
            Task { @MainActor [weak self] in
                self?.beginFeaturePanelPresentation(PomodoroFeaturePlugin.id)
                self?.pomodoroPanelController?.show()
                self?.launcherPanelController?.show()
            }
        } else if CommandLine.arguments.contains("--show-pomodoro-and-daily-tasks") {
            Task { @MainActor [weak self] in
                self?.beginFeaturePanelPresentation(DailyTaskFeaturePlugin.id)
                self?.dailyTaskPanelController?.show()
                self?.beginFeaturePanelPresentation(PomodoroFeaturePlugin.id)
                self?.pomodoroPanelController?.show()
            }
        } else if CommandLine.arguments.contains("--show-pomodoro") {
            Task { @MainActor [weak self] in
                self?.presentPomodoro()
            }
        } else if CommandLine.arguments.contains("--show-holiday-calendar") {
            Task { @MainActor [weak self] in
                self?.presentFeaturePanel(HolidayCalendarFeaturePlugin.id)
            }
        } else if CommandLine.arguments.contains("--show-markdown") {
            Task { @MainActor [weak self] in
                self?.presentFeaturePanel(MarkdownPreviewFeaturePlugin.id)
            }
        } else if CommandLine.arguments.contains("--show-daily-tasks") {
            Task { @MainActor [weak self] in
                self?.presentFeaturePanel(DailyTaskFeaturePlugin.id)
            }
        } else if launchedForMoveConflict {
            presentPendingMoveConflictIfNeeded()
        } else if launchedForFileActionRelay {
            // Finder 动作的后台唤起不抢焦点，也不弹出启动器。
            NSApp.hide(nil)
        } else {
            Task { @MainActor [weak self] in
                self?.showLauncherForExplicitUserRequest()
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
        moveConflictMonitorTimer?.invalidate()
        pomodoroCardStatusTimer?.invalidate()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if FileActionServiceRelay.hasPendingRequests {
            drainFileActionRelay()
            return false
        }
        settingsWindowController?.window?.orderOut(nil)
        showLauncherForExplicitUserRequest()
        return false
    }

    func applicationWillResignActive(_ notification: Notification) {
        recordPriorExternalApplicationIfNeeded()
        hideOpenFeaturePanelsForApplicationDeactivation()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        pomodoroPanelController?.synchronizeClock()
        if suppressLauncherForNextApplicationActivation {
            suppressLauncherForNextApplicationActivation = false
            return
        }
        guard launcherPanelController?.isVisible != true,
              settingsWindowController?.window?.isVisible != true,
              !hasVisibleFeaturePanel else { return }
        showLauncherForExplicitUserRequest()
    }

    private func startFileActionRelay() {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleFileActionRelayRequest),
            name: FileActionServiceRelay.notificationName,
            object: nil
        )
        moveConflictMonitorTimer = Timer.scheduledTimer(
            timeInterval: 0.75,
            target: self,
            selector: #selector(handleMoveConflictMonitorTick),
            userInfo: nil,
            repeats: true
        )
        drainFileActionRelay()
    }

    @objc private func handleFileActionRelayRequest() {
        drainFileActionRelay()
        presentPendingMoveConflictIfNeeded()
    }

    @objc private func handleMoveConflictMonitorTick() {
        presentPendingMoveConflictIfNeeded()
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

    private func presentPendingMoveConflictIfNeeded() {
        do {
            guard let request = try MoveConflictRequestStore().loadValid() else { return }
            guard moveConflictWindowController?.isPresentingConflict(id: request.id) != true else {
                return
            }
            moveConflictWindowController?.show(request)
        } catch {
            try? MoveConflictRequestStore().clear()
        }
    }

    private func resolveMoveConflict(
        _ request: MoveConflictRequest,
        resolution: MoveConflictResolution
    ) {
        Task { @MainActor [weak self] in
            do {
                _ = try await MoveConflictResolutionService.resolve(request, resolution: resolution)
                self?.moveConflictWindowController?.dismiss()
            } catch MoveConflictResolutionError.clipboardStateChanged {
                self?.moveConflictWindowController?.show(
                    request,
                    errorMessage: "剪切状态已变更，请回到 Finder 重新执行剪切。"
                )
            } catch {
                self?.moveConflictWindowController?.show(
                    request,
                    errorMessage: "暂时无法完成移动，请检查文件权限后重试。"
                )
            }
        }
    }

    func applicationShouldRestoreApplicationState(_ app: NSApplication) -> Bool {
        false
    }

    private func presentTranslationRequest(_ request: TextTranslationRequest) {
        guard let translationPanelController else {
            pendingTranslationRequest = request
            return
        }
        translationPanelController.show(request: request)
    }

    private func presentPomodoro(request: FocusSessionRequest? = nil) {
        beginFeaturePanelPresentation(PomodoroFeaturePlugin.id)
        pomodoroPanelController?.show(request: request)
    }

    private func presentPomodoroCompletion() {
        beginFeaturePanelPresentation(PomodoroFeaturePlugin.id)
        updateFeaturePanelStatus(for: PomodoroFeaturePlugin.id)
        NSApp.requestUserAttention(.criticalRequest)
        suppressLauncherForNextApplicationActivation = !NSApp.isActive
        _ = restoreFeaturePanel(
            PomodoroFeaturePlugin.id,
            restoresMiniaturizedWindow: true
        )
    }

    private func presentFeaturePanel(_ featureID: String) {
        if featureID == TranslationFeaturePlugin.id {
            guard let translationPanelController else { return }
            launcherPanelController?.hide()
            translationPanelController.show()
            return
        }
        if featureID == OCRFeaturePlugin.id {
            guard let ocrPanelController else { return }
            launcherPanelController?.hide()
            ocrPanelController.show()
            return
        }

        beginFeaturePanelPresentation(featureID)
        switch featureID {
        case DailyTaskFeaturePlugin.id:
            dailyTaskPanelController?.show()
        case PomodoroFeaturePlugin.id:
            pomodoroPanelController?.show()
        case HolidayCalendarFeaturePlugin.id:
            holidayCalendarPanelController?.show()
        case MarkdownPreviewFeaturePlugin.id:
            markdownPreviewPanelController?.show()
        case ParserToolsFeaturePlugin.id:
            parserToolsPanelController?.show()
        case ClipboardFeaturePlugin.id:
            clipboardPanelController?.show()
        default:
            featurePanelSession.close(featureID)
        }
    }

    private func beginFeaturePanelPresentation(_ featureID: String) {
        featurePanelSession.open(featureID)
        updateFeaturePanelStatus(for: featureID)
        launcherPanelController?.hide()
    }

    private func closeFeaturePanelSession(_ featureID: String) {
        featurePanelSession.close(featureID)
        featureStore.setPanelPresence(nil, for: featureID)
        featureStore.setPanelStatusText(nil, for: featureID)
        settleAfterTouchWindowClosed()
    }

    private func featurePanelController(
        for featureID: String
    ) -> (any FeaturePanelSessionController)? {
        switch featureID {
        case DailyTaskFeaturePlugin.id: dailyTaskPanelController
        case PomodoroFeaturePlugin.id: pomodoroPanelController
        case HolidayCalendarFeaturePlugin.id: holidayCalendarPanelController
        case MarkdownPreviewFeaturePlugin.id: markdownPreviewPanelController
        case ParserToolsFeaturePlugin.id: parserToolsPanelController
        case ClipboardFeaturePlugin.id: clipboardPanelController
        case TranslationFeaturePlugin.id: translationPanelController
        case OCRFeaturePlugin.id: ocrPanelController
        default: nil
        }
    }

    private func featureID(for window: NSWindow?) -> String? {
        guard let window else { return nil }
        return featurePanelSession.openFeatureIDs.first { featureID in
            featurePanelController(for: featureID)?.sessionWindow === window
        }
    }

    @discardableResult
    private func restoreFeaturePanel(
        _ featureID: String,
        activateApplication: Bool = true,
        restoresMiniaturizedWindow: Bool = false
    ) -> Bool {
        guard featurePanelSession.openFeatureIDs.contains(featureID),
              let controller = featurePanelController(for: featureID) else { return false }
        launcherPanelController?.hide()
        if restoresMiniaturizedWindow, controller.sessionWindow.isMiniaturized {
            controller.sessionWindow.deminiaturize(nil)
        }
        // 后台恢复时先提供一个真实可见窗口，再请求应用激活；否则 macOS
        // 可能保留 Running Background 状态，导致到时提醒无法弹到前台。
        controller.sessionWindow.orderFrontRegardless()
        if activateApplication, !NSApp.isActive {
            activateApplicationForFeaturePanel()
        }
        controller.sessionWindow.makeKeyAndOrderFront(nil)
        return true
    }

    private func hideOpenFeaturePanelsForApplicationDeactivation() {
        if let featureID = featureID(for: NSApp.keyWindow) {
            featurePanelSession.promote(featureID)
        }
        for featureID in featurePanelSession.openFeatureIDs {
            guard let controller = featurePanelController(for: featureID),
                  !controller.remainsVisibleWhenApplicationIsInactive else { continue }
            controller.sessionWindow.orderOut(nil)
        }
    }

    private var hasVisibleFeaturePanel: Bool {
        featurePanelSession.openFeatureIDs.contains { featureID in
            featurePanelController(for: featureID)?.sessionWindow.isVisible == true
        }
    }

    private func showLauncherForExplicitUserRequest() {
        recordPriorExternalApplicationIfNeeded()
        // 从后台返回一念时，普通窗口只保留状态，不应抢在启动器前面恢复。
        hideOpenFeaturePanelsForApplicationDeactivation()
        refreshFeaturePanelPresence()
        launcherPanelController?.show()
    }

    private func refreshFeaturePanelPresence() {
        for featureID in featurePanelSession.openFeatureIDs {
            updateFeaturePanelStatus(for: featureID)
        }
    }

    private func updateFeaturePanelStatus(for featureID: String) {
        let presence = panelPresence(for: featureID)
        featureStore.setPanelPresence(presence, for: featureID)
        guard featureID == PomodoroFeaturePlugin.id else {
            featureStore.setPanelStatusText(nil, for: featureID)
            return
        }
        switch presence {
        case .running:
            featureStore.setPanelStatusText(
                pomodoroPanelController?.launcherCardStatusText ?? "进行中",
                for: featureID
            )
        case .attentionRequired:
            featureStore.setPanelStatusText("时间到 · 待确认", for: featureID)
        case .retained:
            featureStore.setPanelStatusText("后台待命", for: featureID)
        }
    }

    private func startPomodoroCardStatusUpdates() {
        pomodoroCardStatusTimer?.invalidate()
        let timer = Timer(
            timeInterval: 1,
            target: self,
            selector: #selector(handlePomodoroCardStatusTick),
            userInfo: nil,
            repeats: true
        )
        pomodoroCardStatusTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func handlePomodoroCardStatusTick() {
        guard featurePanelSession.openFeatureIDs.contains(PomodoroFeaturePlugin.id) else { return }
        updateFeaturePanelStatus(for: PomodoroFeaturePlugin.id)
    }

    private func panelPresence(for featureID: String) -> FeaturePanelPresence {
        guard featureID == PomodoroFeaturePlugin.id else { return .retained }
        if pomodoroPanelController?.needsAttention == true { return .attentionRequired }
        if pomodoroPanelController?.isRunningSession == true { return .running }
        return .retained
    }

    private func recordPriorExternalApplicationIfNeeded() {
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        priorExternalApplicationPID = application.processIdentifier
    }

    private func settleAfterTouchWindowClosed() {
        windowCloseSettlementTask?.cancel()
        windowCloseSettlementTask = Task { @MainActor [weak self] in
            // windowWillClose 发生时正在关闭的窗口仍可能短暂可见；下一轮事件循环
            // 再判断，避免误以为还有可见功能窗口。
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            self.windowCloseSettlementTask = nil
            guard self.launcherPanelController?.isVisible != true,
                  self.settingsWindowController?.window?.isVisible != true,
                  !self.hasVisibleFeaturePanel else { return }
            if let keyWindow = NSApp.keyWindow, keyWindow.isVisible {
                return
            }
            self.hideTouchAndRestorePriorApplication()
        }
    }

    private func hideTouchAndRestorePriorApplication() {
        let priorApplication = priorExternalApplicationPID.flatMap(NSRunningApplication.init(processIdentifier:))
        priorExternalApplicationPID = nil
        if let priorApplication, !priorApplication.isTerminated {
            _ = priorApplication.activate(options: [])
        } else {
            NSApp.hide(nil)
        }
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
        presentFeaturePanel(featureID)
    }

    @objc private func handleWindowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let featureID = featureID(for: window) else { return }
        featurePanelSession.promote(featureID)
    }

    @objc private func handleStartFocusSession(_ notification: Notification) {
        guard let request = notification.object as? FocusSessionRequest else { return }
        presentPomodoro(request: request)
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
                    self?.performGlobalFeatureShortcut(featureID)
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

    /// Carbon 全局快捷键在应用处于后台时也会送达，但截图选区和功能面板需要
    /// 前台的事件循环才能立刻接收键鼠事件。先激活本应用，再统一派发功能，
    /// 不经过启动器面板，避免用户需要额外点击一次“一念”。
    private func performGlobalFeatureShortcut(_ featureID: String) {
        // 启动器拥有自己的单键交互；显示期间必须忽略所有功能全局快捷键，
        // 防止 Option + 键与卡片键位产生重复或意外执行。
        guard launcherPanelController?.isVisible != true else { return }
        recordPriorExternalApplicationIfNeeded()
        if featureID == FeatureConfigurationStore.screenshotID {
            performGlobalScreenshotShortcut(.captureDefaultMode)
            return
        }
        if !NSApp.isActive {
            suppressLauncherForNextApplicationActivation = true
            activateApplicationForFeaturePanel()
        }
        Task { @MainActor [weak self] in
            await self?.featureStore.perform(featureID)
        }
    }

    private func performGlobalScreenshotShortcut(_ action: ScreenshotPluginAction) {
        guard launcherPanelController?.isVisible != true else { return }
        recordPriorExternalApplicationIfNeeded()
        if !NSApp.isActive {
            suppressLauncherForNextApplicationActivation = true
            activateApplicationForFeaturePanel()
        }
        performScreenshot(action)
    }

    private func registerScreenshotShortcuts() {
        unregisterScreenshotShortcuts()
        if let shortcut = featureStore.configurations.screenshot.modeShortcuts[.allDisplays],
           !shortcut.modifiers.isEmpty {
            do {
                try allDisplaysScreenshotHotKeyController.start(shortcut: shortcut) { [weak self] in
                    self?.performGlobalScreenshotShortcut(.captureAllDisplays)
                }
            } catch {
                NSLog("Unable to register all-displays screenshot shortcut: %@", error.localizedDescription)
            }
        }

        if let shortcut = featureStore.configurations.screenshot.modeShortcuts[.colorPicker],
           !shortcut.modifiers.isEmpty {
            do {
                try colorPickerHotKeyController.start(shortcut: shortcut) { [weak self] in
                    self?.performGlobalScreenshotShortcut(.pickColor)
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
                } else {
                    settleAfterTouchWindowClosed()
                }
            } catch ScreenshotCoordinatorError.busy {
                NSSound.beep()
            } catch {
                NSLog("Screenshot shortcut action failed: %@", error.localizedDescription)
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "截图未完成"
                alert.informativeText = "\(error.localizedDescription)\n\n请检查屏幕录制权限或稍后重试。"
                alert.addButton(withTitle: "打开权限设置")
                alert.addButton(withTitle: "取消")
                if alert.runModal() == .alertFirstButtonReturn {
                    showSettings(section: .permissions)
                } else {
                    settleAfterTouchWindowClosed()
                }
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
        if launcherPanelController?.isVisible == true {
            launcherPanelController?.hide()
            settleAfterTouchWindowClosed()
        } else {
            settingsWindowController?.window?.orderOut(nil)
            showLauncherForExplicitUserRequest()
        }
    }
}
