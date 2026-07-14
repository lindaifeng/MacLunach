import AppKit
import FinderFeature
import ScreenshotFeature
import SuperRightFeature
import TouchCore
import TouchFeatureAPI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var launcherPanelController: LauncherPanelController?
    private var settingsWindowController: SettingsWindowController?
    let searchEnvironment = SearchEnvironment.makeForCurrentProcess()
    private(set) var screenshotEnvironment: ScreenshotEnvironment!
    private(set) var featureStore: FeatureAreaStore!
    private let globalHotKeyController = GlobalHotKeyController(identifier: 1)
    private let screenshotHotKeyController = GlobalHotKeyController(identifier: 2)
    private let allDisplaysScreenshotHotKeyController = GlobalHotKeyController(identifier: 3)
    private let colorPickerHotKeyController = GlobalHotKeyController(identifier: 4)
    private let isScreenshotSelectionFixture: Bool
    private let isScreenshotThumbnailFixture: Bool
    private let screenshotMeasurementOutputURL: URL?

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
                configurationProvider: measurementConfigurationProvider,
                registerShortcuts: { [weak self] in self?.registerScreenshotShortcuts() },
                unregisterShortcuts: { [weak self] in self?.unregisterScreenshotShortcuts() }
            )
        }
        screenshotEnvironment = environment
        featureStore = FeatureAreaStore(
            plugins: [
                FinderFeaturePlugin(),
                ScreenshotFeaturePlugin(router: environment.coordinator),
                SuperRightFeaturePlugin()
            ]
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if !isScreenshotSelectionFixture,
           !isScreenshotThumbnailFixture,
           screenshotMeasurementOutputURL == nil {
            Task { await searchEnvironment.prepare() }
        }
        let launcher = LauncherPanelController(
            searchEnvironment: searchEnvironment,
            featureStore: featureStore,
            screenshotEnvironment: screenshotEnvironment
        )
        launcherPanelController = launcher
        screenshotEnvironment.coordinator.attachLauncher(launcher)
        settingsWindowController = SettingsWindowController(
            searchEnvironment: searchEnvironment,
            featureStore: featureStore,
            screenshotEnvironment: screenshotEnvironment
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

        if isScreenshotSelectionFixture {
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
        } else if CommandLine.arguments.contains("--open-settings") {
            Task { @MainActor [weak self] in
                self?.showSettings()
            }
        } else {
            Task { @MainActor [weak self] in
                self?.launcherPanelController?.show()
            }
        }
        guard !isScreenshotSelectionFixture,
              !isScreenshotThumbnailFixture,
              screenshotMeasurementOutputURL == nil else { return }
        do {
            try globalHotKeyController.start(shortcut: .init(modifiers: [.option], key: "space")) { [weak self] in
                self?.launcherPanelController?.toggle()
            }
        } catch {
            NSLog("Unable to register Touch launcher shortcut: %@", error.localizedDescription)
        }
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
        Task { [screenshotEnvironment] in
            await screenshotEnvironment?.coordinator.deactivate()
        }
        NotificationCenter.default.removeObserver(self)
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        // 双击应用或通过 `open` 再次唤起时，启动器始终是首要界面。
        // 设置窗口可能仍在后台可见，不能让它拦截应用的再次唤起。
        settingsWindowController?.window?.orderOut(nil)
        launcherPanelController?.show()
        return false
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

    @objc private func handleRebuildSearchIndex() {
        Task { [searchEnvironment] in await searchEnvironment.rebuildIndex() }
    }

    @objc private func handleScreenshotShortcutsDidChange() {
        guard featureStore.isEnabled(FeatureConfigurationStore.screenshotID) else { return }
        registerScreenshotShortcuts()
    }

    private func registerScreenshotShortcuts() {
        unregisterScreenshotShortcuts()
        do {
            try screenshotHotKeyController.start(
                shortcut: featureStore.shortcut(for: FeatureConfigurationStore.screenshotID)
            ) { [weak self] in
                self?.performScreenshot(.captureDefaultMode)
            }
        } catch {
            NSLog("Unable to register screenshot shortcut: %@", error.localizedDescription)
        }

        if let shortcut = featureStore.configurations.screenshot.modeShortcuts[.allDisplays] {
            do {
                try allDisplaysScreenshotHotKeyController.start(shortcut: shortcut) { [weak self] in
                    self?.performScreenshot(.captureAllDisplays)
                }
            } catch {
                NSLog("Unable to register all-displays screenshot shortcut: %@", error.localizedDescription)
            }
        }

        if let shortcut = featureStore.configurations.screenshot.modeShortcuts[.colorPicker] {
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
                    showSettings(
                        destination: .init(
                            section: .featureArea,
                            featureID: FeatureConfigurationStore.screenshotID
                        )
                    )
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

    private func restoreLauncherAfterSettingsClose() {
        launcherPanelController?.show()
    }
}
