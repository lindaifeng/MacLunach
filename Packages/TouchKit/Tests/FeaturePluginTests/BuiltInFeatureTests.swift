import Foundation
import Testing
import TouchFeatureAPI
@testable import ClipboardFeature
@testable import FinderFeature
@testable import DailyTaskFeature
@testable import HolidayCalendarFeature
@testable import MarkdownPreviewFeature
@testable import ParserToolsFeature
@testable import PomodoroFeature
@testable import OCRFeature
@testable import ScreenshotFeature
@testable import SuperRightFeature
@testable import TranslationFeature

private final class MemoryFeatureStorage: FeatureStorage, @unchecked Sendable {
    let pluginID = "me.touch.super-right"
    private var snapshot: FeatureConfigurationSnapshot?
    private var backups: [FeatureConfigurationBackup] = []

    func loadConfiguration() throws -> FeatureConfigurationSnapshot? { snapshot }
    func saveConfiguration(_ snapshot: FeatureConfigurationSnapshot) throws {
        self.snapshot = snapshot
    }
    func seedConfiguration(_ snapshot: FeatureConfigurationSnapshot) {
        self.snapshot = snapshot
    }
    func backupConfiguration(reason: String) throws {
        guard let snapshot else { return }
        backups.append(
            .init(
                createdAt: Date(timeIntervalSince1970: 1_234),
                reason: reason,
                snapshot: snapshot
            )
        )
        self.snapshot = nil
    }
    func configurationBackups() throws -> [FeatureConfigurationBackup] { backups }
    func resetConfiguration() throws { snapshot = nil }
}

@MainActor
private final class ScreenshotRouterStub: ScreenshotActionRouting {
    var state: FeatureState
    var result: FeatureActionResult
    private(set) var actions: [ScreenshotPluginAction] = []
    private(set) var activationCount = 0
    private(set) var deactivationCount = 0

    init(state: FeatureState = .available, result: FeatureActionResult = .completed) {
        self.state = state
        self.result = result
    }

    func featureState() -> FeatureState { state }

    func route(_ action: ScreenshotPluginAction) async throws -> FeatureActionResult {
        actions.append(action)
        return result
    }

    func activate() async { activationCount += 1 }
    func deactivate() async { deactivationCount += 1 }
}

@Test @MainActor func builtInFeatureManifestsAreUnique() {
    let superRightStorage = MemoryFeatureStorage()
    let plugins: [any FeaturePlugin] = [
        FinderFeaturePlugin(),
        ScreenshotFeaturePlugin(router: ScreenshotRouterStub()),
        SuperRightFeaturePlugin(storage: superRightStorage),
        PomodoroFeaturePlugin(),
        HolidayCalendarFeaturePlugin(),
        MarkdownPreviewFeaturePlugin(),
        ParserToolsFeaturePlugin()
    ]

    #expect(Set(plugins.map { $0.manifest.id }).count == 7)
    #expect(plugins.map { $0.manifest.name } == ["打开访达", "截取屏幕", "超级右键", "番茄闹钟", "节假日历", "Markdown", "解析工具"])
}

@Test @MainActor func builtInFeatureManifestsIncludeTextWorkspaces() {
    let plugins: [any FeaturePlugin] = [
        ClipboardFeaturePlugin(),
        TranslationFeaturePlugin(systemVersion: .init(majorVersion: 15, minorVersion: 0, patchVersion: 0)),
        OCRFeaturePlugin()
    ]

    #expect(Set(plugins.map(\.manifest.id)) == [
        "me.touch.clipboard", "me.touch.translation", "me.touch.ocr"
    ])
}

@Test func parserToolsRequestsItsHostOwnedPanel() async throws {
    #expect(
        try await ParserToolsFeaturePlugin().perform()
            == .presentPanel(featureID: ParserToolsFeaturePlugin.id)
    )
}

@Test func pomodoroRequestsItsHostOwnedPanel() async throws {
    let result = try await PomodoroFeaturePlugin().perform()
    #expect(result == .presentPanel(featureID: PomodoroFeaturePlugin.id))
}

@Test func holidayCalendarExposes2026OfficialHolidaysAndWorkdayAdjustments() async throws {
    let plugin = HolidayCalendarFeaturePlugin()
    #expect(try await plugin.perform() == .presentPanel(featureID: HolidayCalendarFeaturePlugin.id))

    let entries = HolidayCalendar.entries(for: 2026, calendar: Calendar(identifier: .gregorian))
    #expect(entries.contains { $0.name == "春节假期" && $0.kind == HolidayKind.chinaOfficial })
    #expect(entries.contains { $0.name == "调休上班" && $0.kind == HolidayKind.chinaWorkday })
    #expect(entries.contains { $0.name == "Christmas Day" && $0.kind == HolidayKind.international })
}

@Test func markdownPreviewRequestsItsHostOwnedPanel() async throws {
    #expect(
        try await MarkdownPreviewFeaturePlugin().perform()
            == .presentPanel(featureID: MarkdownPreviewFeaturePlugin.id)
    )
}

@Test func dailyTaskRepositoryPersistsBoardMetadataAndFocusSelection() throws {
    let storage = MemoryFeatureStorage()
    let repository = DailyTaskRepository(storage: storage)
    let task = DailyTask(
        title: "整理发布说明",
        scheduledDate: Date(timeIntervalSince1970: 1_735_689_600),
        detail: "核对变更记录与升级说明",
        startMinute: 9 * 60 + 30,
        estimatedMinutes: 45,
        status: .inProgress,
        priority: .high,
        category: "工作",
        deadline: Date(timeIntervalSince1970: 1_735_725_600)
    )

    let configuration = DailyTaskConfiguration(tasks: [task], focusTaskID: task.id)
    try repository.save(configuration)

    #expect(try repository.load() == configuration)
}

@Test func dailyTaskRepositoryReadsLegacyCompletionState() throws {
    let storage = MemoryFeatureStorage()
    let repository = DailyTaskRepository(storage: storage)
    let taskID = UUID()
    let legacyData = try JSONSerialization.data(withJSONObject: [
        "tasks": [[
            "id": taskID.uuidString,
            "title": "旧任务",
            "scheduledDate": 0,
            "estimatedMinutes": 25,
            "isCompleted": true
        ]]
    ])
    storage.seedConfiguration(.init(schemaVersion: DailyTaskRepository.schemaVersion, data: legacyData))

    let task = try #require(repository.load().tasks.first)
    #expect(task.id == taskID)
    #expect(task.status == .completed)
    #expect(task.detail.isEmpty)
    #expect(task.priority == .medium)
    #expect(task.category == "工作")
}

@Test func dailyTaskBoardMovesFreelyBetweenColumnsAndClearsCompletedFocus() {
    let pending = DailyTask(title: "准备材料", scheduledDate: .now)
    let replacement = DailyTask(title: "复核内容", scheduledDate: .now, status: .inProgress)
    let completedExisting = DailyTask(title: "已有完成任务", scheduledDate: .now, status: .completed)
    var configuration = DailyTaskConfiguration()

    configuration.add(pending, asFocusTask: true)
    configuration.add(replacement, asFocusTask: true)
    configuration.add(completedExisting)
    #expect(configuration.focusTaskID == replacement.id)

    let movedBackward = configuration.moveTask(id: replacement.id, to: .pending)
    #expect(movedBackward)
    #expect(configuration.tasks.filter { $0.status == .pending }.map(\.id) == [replacement.id, pending.id])

    let skippedToCompleted = configuration.moveTask(id: pending.id, to: .completed)
    #expect(skippedToCompleted)
    #expect(configuration.tasks.filter { $0.status == .completed }.map(\.id) == [pending.id, completedExisting.id])

    let movedCompletedBack = configuration.moveTask(id: pending.id, to: .inProgress)
    let unchangedColumn = configuration.moveTask(id: pending.id, to: .inProgress)
    let completedReplacement = configuration.moveTask(id: replacement.id, to: .completed)

    #expect(movedCompletedBack)
    #expect(unchangedColumn == false)
    #expect(completedReplacement)
    #expect(configuration.tasks.filter { $0.status == .completed }.map(\.id) == [replacement.id, completedExisting.id])
    #expect(configuration.focusTaskID == nil)
}

@Test func disabledFinderExtensionRestrictsSuperRight() async {
    #expect(
        await SuperRightFeaturePlugin(
            storage: MemoryFeatureStorage(),
            isFinderExtensionEnabled: { false }
        ).initialState()
            == .restricted(message: "需要启用 Finder 扩展")
    )
}

@Test func enabledFinderExtensionMakesSuperRightAvailable() async {
    #expect(
        await SuperRightFeaturePlugin(
            storage: MemoryFeatureStorage(),
            isFinderExtensionEnabled: { true }
        ).initialState() == .available
    )
}

@Test func superRightMonitorsTheFileSystemRoot() {
    #expect(
        SuperRightFeaturePlugin.monitoredDirectoryURLs
            == [URL(fileURLWithPath: "/", isDirectory: true)]
    )
}

@Test @MainActor func superRightDeclaresSettingsAsItsPrimaryAction() {
    let plugin = SuperRightFeaturePlugin(storage: MemoryFeatureStorage())

    #expect(plugin.manifest.pluginVersion == .init(major: 1, minor: 0, patch: 0))
    #expect(plugin.manifest.configurationSchemaVersion == 3)
    #expect(plugin.manifest.capabilities.required == [.finderMenu, .fileSystemRead])
    #expect(plugin.manifest.executionMode == .xpcService)
    #expect(plugin.manifest.primaryAction == .openSettings)
    #expect(plugin.manifest.settingsPresentation == .firstPartyProvider)
    #expect(plugin.settingsProvider != nil)
}

@Test func superRightMigratesLegacyBooleanConfigurationIntoOwnedV2Model() throws {
    struct LegacyConfiguration: Codable {
        let opensTerminal: Bool
        let copiesFilePath: Bool
        let cutsFiles: Bool
        let createsFiles: Bool
    }

    let storage = MemoryFeatureStorage()
    try storage.saveConfiguration(
        .init(
            schemaVersion: 1,
            data: try JSONEncoder().encode(
                LegacyConfiguration(
                    opensTerminal: false,
                    copiesFilePath: true,
                    cutsFiles: false,
                    createsFiles: true
                )
            )
        )
    )
    let repository = SuperRightConfigurationRepository(storage: storage)

    let configuration = try repository.load()

    #expect(configuration.actions.map(\.id) == [.newFile, .newFolder, .cut, .copyPath, .openTerminal])
    #expect(configuration.action(.openTerminal)?.isEnabled == false)
    #expect(configuration.action(.copyPath)?.isEnabled == true)
    #expect(configuration.action(.cut)?.isEnabled == false)
    #expect(configuration.action(.newFile)?.isEnabled == true)
    #expect(configuration.action(.newFolder)?.isEnabled == true)
    #expect(configuration.fileFormats.count == 10)
    #expect(try storage.loadConfiguration()?.schemaVersion == 3)
}

@Test func superRightBacksUpFailedLegacyMigrationBeforeUsingSafeDefaults() throws {
    let storage = MemoryFeatureStorage()
    try storage.saveConfiguration(
        .init(schemaVersion: 1, data: Data("not-json".utf8))
    )
    let repository = SuperRightConfigurationRepository(storage: storage)

    let configuration = try repository.load()

    #expect(configuration == SuperRightFeatureConfiguration())
    let backups = try storage.configurationBackups()
    #expect(backups.count == 1)
    #expect(backups.first?.reason == "migration-failed")
    #expect(backups.first?.snapshot.schemaVersion == 1)
    #expect(try storage.loadConfiguration()?.schemaVersion == 3)
}

@Test func superRightDefaultsToAppleTerminal() {
    #expect(SuperRightFeatureConfiguration().terminalBundleIdentifier == "com.apple.Terminal")
}

@Test func superRightMigratesV2ConfigurationAndAddsDefaultTerminal() throws {
    struct V2Configuration: Codable {
        let actions: [SuperRightActionConfiguration]
        let fileFormats: [NewFileFormatDefinition]
    }

    let storage = MemoryFeatureStorage()
    try storage.saveConfiguration(
        .init(
            schemaVersion: 2,
            data: try JSONEncoder().encode(
                V2Configuration(
                    actions: [
                        .init(id: .copyPath, isEnabled: false),
                        .init(id: .openTerminal, isEnabled: true)
                    ],
                    fileFormats: [.init(id: "text", displayName: "文本", fileExtension: "txt")]
                )
            )
        )
    )

    let configuration = try SuperRightConfigurationRepository(storage: storage).load()

    #expect(configuration.action(.copyPath)?.isEnabled == false)
    #expect(configuration.terminalBundleIdentifier == "com.apple.Terminal")
    #expect(try storage.loadConfiguration()?.schemaVersion == 3)
}

@Test func superRightMenuUsesConfiguredOrderAndEnabledFileFormats() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let configuration = SuperRightFeatureConfiguration(
        actions: [
            .init(id: .copyPath),
            .init(id: .newFile),
            .init(id: .openTerminal, isEnabled: false)
        ],
        fileFormats: [
            .init(id: "txt", displayName: "纯文本", fileExtension: "txt"),
            .init(id: "md", displayName: "Markdown", fileExtension: "md", isEnabled: false),
            .init(id: "json", displayName: "JSON", fileExtension: "json", initialContent: "{}\n")
        ]
    )

    let menu = FinderMenuBuilder(configuration: configuration).build(
        for: .init(targetedURL: root, selectedURLs: [])
    )

    #expect(menu.map(\.title) == ["复制路径", "新建文件"])
    #expect(menu.last?.children.map(\.title) == ["纯文本", "JSON"])
}

@Test func superRightMenuAdaptsToBlankFileFolderAndMultipleSelection() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let folder = root.appendingPathComponent("资料", isDirectory: true)
    let file = root.appendingPathComponent("说明.md")
    let anotherFile = root.appendingPathComponent("数据.json")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data().write(to: file)
    try Data().write(to: anotherFile)
    defer { try? FileManager.default.removeItem(at: root) }

    let builder = FinderMenuBuilder(configuration: .init())
    let blankMenu = builder.build(for: .init(targetedURL: root, selectedURLs: []))
    let fileMenu = builder.build(for: .init(targetedURL: root, selectedURLs: [file]))
    let folderMenu = builder.build(for: .init(targetedURL: root, selectedURLs: [folder]))
    let multiMenu = builder.build(for: .init(targetedURL: root, selectedURLs: [file, anotherFile]))

    #expect(blankMenu.map(\.title) == ["新建文件", "新建文件夹", "复制路径", "在终端中打开"])
    #expect(fileMenu.map(\.title) == ["复制路径", "在终端中打开"])
    #expect(folderMenu.map(\.title) == ["新建文件", "新建文件夹", "复制路径", "在终端中打开"])
    #expect(multiMenu.map(\.title) == ["复制路径", "在终端中打开"])
}

@Test func superRightConfigurationSnapshotRoundTripsAtomically() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let url = root.appendingPathComponent("config.json")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SuperRightConfigurationSnapshotStore(url: url)
    let configuration = SuperRightFeatureConfiguration(terminalBundleIdentifier: "com.googlecode.iterm2")

    try store.save(configuration)

    #expect(try store.load() == configuration)
    #expect(FileManager.default.fileExists(atPath: url.path))
}

@Test func missingPreferredTerminalFallsBackToAppleTerminal() {
    let resolved = TerminalApplicationCatalog.resolveBundleIdentifier(
        preferred: "dev.warp.Warp-Stable",
        isInstalled: { $0 == "com.apple.Terminal" }
    )

    #expect(resolved == "com.apple.Terminal")
}

@Test func superRightCreatesPredictablyNamedFilesAndFolders() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let creator = SuperRightFileCreator()
    let format = NewFileFormatDefinition(
        id: "json",
        displayName: "JSON",
        fileExtension: "json",
        initialContent: "{}\n"
    )

    let firstFile = try creator.createFile(in: root, format: format)
    let secondFile = try creator.createFile(in: root, format: format)
    let firstFolder = try creator.createFolder(in: root)
    let secondFolder = try creator.createFolder(in: root)

    #expect(firstFile.lastPathComponent == "未命名.json")
    #expect(secondFile.lastPathComponent == "未命名 2.json")
    #expect(try String(contentsOf: firstFile, encoding: .utf8) == "{}\n")
    #expect(firstFolder.lastPathComponent == "未命名文件夹")
    #expect(secondFolder.lastPathComponent == "未命名文件夹 2")
}

@Test @MainActor func screenshotPluginOnlyRoutesDefaultModeAction() async throws {
    let router = ScreenshotRouterStub()
    let plugin = ScreenshotFeaturePlugin(router: router)

    #expect(await plugin.initialState() == .available)
    #expect(try await plugin.perform() == .completed)
    #expect(router.actions == [.captureDefaultMode])
}

@Test @MainActor func screenshotPluginForwardsLifecycleWithoutPerformingAnAction() async {
    let router = ScreenshotRouterStub(state: .restricted(message: "需要配置屏幕录制权限"))
    let plugin = ScreenshotFeaturePlugin(router: router)

    #expect(await plugin.initialState() == .restricted(message: "需要配置屏幕录制权限"))
    await plugin.featureDidEnable()
    await plugin.featureDidDisable()

    #expect(router.activationCount == 1)
    #expect(router.deactivationCount == 1)
    #expect(router.actions.isEmpty)
}
