import Foundation
import OCRFeature
import SwiftUI
import TouchCore
import TouchFeatureAPI
import XCTest
@testable import 触达

private actor StoreTestPlugin: FeaturePlugin, FeatureLifecycleHandling {
    enum Action: Sendable {
        case complete
        case fail
        case requiresSetup
    }

    nonisolated let manifest: FeatureManifest
    private let state: FeatureState
    private let action: Action
    private var performCallCount = 0
    private var enableCallCount = 0
    private var disableCallCount = 0

    init(
        id: String,
        state: FeatureState = .available,
        action: Action = .complete,
        primaryAction: FeaturePrimaryAction = .perform,
        shortcutKey: String = "1"
    ) {
        manifest = FeatureManifest(
            id: id,
            name: id,
            summary: "测试功能",
            symbolName: "hammer",
            defaultOrder: 0,
            defaultShortcut: .init(modifiers: [.command], key: shortcutKey),
            primaryAction: primaryAction
        )
        self.state = state
        self.action = action
    }

    func initialState() async -> FeatureState { state }

    func perform() async throws -> FeatureActionResult {
        performCallCount += 1
        switch action {
        case .complete:
            return .completed
        case .fail:
            struct ExpectedFailure: Error {}
            throw ExpectedFailure()
        case .requiresSetup:
            return .requiresSetup(message: "需要设置")
        }
    }

    func callCount() -> Int { performCallCount }
    func lifecycleCounts() -> (enabled: Int, disabled: Int) {
        (enableCallCount, disableCallCount)
    }

    func featureDidEnable() async { enableCallCount += 1 }
    func featureDidDisable() async { disableCallCount += 1 }
}

private final class SettingsDestinationCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var destinations: [TouchSettingsDestination] = []

    func record(_ notification: Notification) {
        guard let destination = notification.object as? TouchSettingsDestination else { return }
        lock.withLock { destinations.append(destination) }
    }

    func featureIDs() -> [String] {
        lock.withLock {
            destinations.compactMap { destination in
                guard destination.section == .featureArea else { return nil }
                return destination.featureID
            }
        }
    }

    func sections() -> [TouchSettingsSection] {
        lock.withLock { destinations.map(\.section) }
    }
}

@MainActor
private final class SettingsProviderStub: FeatureSettingsProvider {
    private(set) var makeViewCallCount = 0

    func makeSettingsView(context: FeatureSettingsContext) -> AnyView {
        makeViewCallCount += 1
        return AnyView(EmptyView())
    }
}

private struct SettingsHostTestPlugin: FeaturePlugin, @unchecked Sendable {
    let manifest = FeatureManifest(
        id: "me.touch.test-provider",
        name: "测试设置提供器",
        summary: "验证通用设置宿主",
        symbolName: "gearshape",
        defaultOrder: 0,
        defaultShortcut: .init(modifiers: [], key: "")
    )
    let provider: SettingsProviderStub

    @MainActor
    var settingsProvider: (any FeatureSettingsProvider)? { provider }

    func initialState() async -> FeatureState { .available }
    func perform() async throws -> FeatureActionResult { .completed }
}

@MainActor
private final class WorkspaceTextCaptureStub: WorkspaceTextCapturing {
    private let result: Result<ScreenTextCaptureResult, Error>
    private(set) var captureCallCount = 0

    init(result: Result<ScreenTextCaptureResult, Error>) {
        self.result = result
    }

    func captureTextForWorkspace() async throws -> ScreenTextCaptureResult {
        captureCallCount += 1
        return try result.get()
    }

    func cancelWorkspaceTextCapture() {}
}

@MainActor
private final class OCRCopyRecorder {
    private(set) var texts: [String] = []
    var succeeds = true

    func write(_ text: String) -> Bool {
        texts.append(text)
        return succeeds
    }
}

@MainActor
final class FeatureAreaStoreTests: XCTestCase {
    func testAssigningAnOccupiedKeyboardKeySwapsFeatureAssignments() {
        let first = StoreTestPlugin(id: "me.touch.first", shortcutKey: "1")
        let second = StoreTestPlugin(id: "me.touch.second", shortcutKey: "2")
        let store = makeStore(plugins: [first, second])

        XCTAssertNil(store.assignKeyboardKey("2", to: first.manifest.id))

        XCTAssertEqual(store.shortcut(for: first.manifest.id).key, "2")
        XCTAssertEqual(store.shortcut(for: second.manifest.id).key, "1")
        XCTAssertTrue(store.shortcut(for: first.manifest.id).modifiers.isEmpty)
        XCTAssertTrue(store.shortcut(for: second.manifest.id).modifiers.isEmpty)
    }

    func testLauncherKeyFindsVisibleFeatureWithoutCommandModifier() {
        let visible = StoreTestPlugin(id: "me.touch.visible", shortcutKey: "7")
        let hidden = StoreTestPlugin(id: "me.touch.hidden", shortcutKey: "8")
        let store = makeStore(plugins: [visible, hidden])
        store.setHidden(true, for: hidden.manifest.id)

        XCTAssertEqual(store.featureID(forLauncherKey: "7"), visible.manifest.id)
        XCTAssertNil(store.featureID(forLauncherKey: "8"))
        XCTAssertTrue(store.shortcut(for: visible.manifest.id).modifiers.isEmpty)
    }

    func testCustomWebActionClaimsKeyAndRelocatesExistingFeature() {
        let first = StoreTestPlugin(id: "me.touch.first", shortcutKey: "1")
        let second = StoreTestPlugin(id: "me.touch.second", shortcutKey: "2")
        let store = makeStore(plugins: [first, second])
        let action = LauncherCustomAction(
            kind: .webPage,
            title: "OpenAI",
            target: "openai.com"
        )

        XCTAssertNil(store.assignCustomAction(action, to: "1"))

        XCTAssertEqual(store.customAction(forLauncherKey: "1"), action)
        XCTAssertNil(store.featureID(forLauncherKey: "1"))
        XCTAssertEqual(store.shortcut(for: first.manifest.id).key, "3")
        XCTAssertEqual(store.featureID(forLauncherKey: "3"), first.manifest.id)
        XCTAssertEqual(store.featureID(forLauncherKey: "2"), second.manifest.id)
    }

    func testAssigningBuiltInFeatureToCustomKeyRemovesCustomAction() {
        let plugin = StoreTestPlugin(id: "me.touch.first", shortcutKey: "1")
        let store = makeStore(plugins: [plugin])
        let action = LauncherCustomAction(
            kind: .shortcut,
            title: "开始专注",
            target: "开始专注"
        )
        XCTAssertNil(store.assignCustomAction(action, to: "q"))

        XCTAssertNil(store.assignKeyboardKey("q", to: plugin.manifest.id))

        XCTAssertNil(store.customAction(forLauncherKey: "q"))
        XCTAssertEqual(store.featureID(forLauncherKey: "q"), plugin.manifest.id)
    }

    func testRemovingCustomActionRestoresFeatureWithMatchingDefaultKey() {
        let plugin = StoreTestPlugin(id: "me.touch.first", shortcutKey: "1")
        let store = makeStore(plugins: [plugin])
        let action = LauncherCustomAction(kind: .webPage, title: "设计参考", target: "example.com")
        XCTAssertNil(store.assignCustomAction(action, to: "1"))
        XCTAssertEqual(store.shortcut(for: plugin.manifest.id).key, "2")

        store.removeCustomAction(for: "1")

        XCTAssertNil(store.customAction(forLauncherKey: "1"))
        XCTAssertEqual(store.shortcut(for: plugin.manifest.id).key, "1")
    }

    func testCustomKeyActionPersistsInUserDefaults() {
        let suiteName = "FeatureAreaStoreCustomActionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let action = LauncherCustomAction(kind: .shellScript, title: "刷新环境", target: "echo ready")
        let plugin = StoreTestPlugin(id: "me.touch.first", shortcutKey: "1")
        let firstStore = FeatureAreaStore(defaults: defaults, plugins: [plugin])
        XCTAssertNil(firstStore.assignCustomAction(action, to: "k"))

        let restoredStore = FeatureAreaStore(defaults: defaults, plugins: [plugin])

        XCTAssertEqual(restoredStore.customAction(forLauncherKey: "k"), action)
    }

    func testLauncherActionSearchDoesNotSubsequenceMatchHiddenURL() {
        let store = makeStore(plugins: [])
        XCTAssertNil(store.assignCustomAction(
            .init(kind: .webPage, title: "百度", target: "https://www.baidu.com/"),
            to: "="
        ))

        XCTAssertTrue(store.searchLauncherActions(query: "do").isEmpty)
        XCTAssertEqual(
            store.searchLauncherActions(query: "baidu").map(\.title),
            ["百度"]
        )
    }

    func testCardLayoutUsesKeyboardOrderForCustomActions() {
        let plugin = StoreTestPlugin(id: "me.touch.first", shortcutKey: "1")
        let store = makeStore(plugins: [plugin])

        XCTAssertNil(store.assignCustomAction(
            .init(kind: .webPage, title: "文档", target: "example.com"),
            to: "q"
        ))
        XCTAssertNil(store.assignCustomAction(
            .init(kind: .shellScript, title: "构建", target: "echo build"),
            to: "2"
        ))

        XCTAssertEqual(store.launcherCustomActionKeys, ["2", "q"])
    }

    func testFeatureGlobalShortcutPersistsAndRejectsConflicts() {
        let suiteName = "FeatureGlobalShortcutTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let first = StoreTestPlugin(id: "me.touch.first", shortcutKey: "1")
        let second = StoreTestPlugin(id: "me.touch.second", shortcutKey: "2")
        let firstStore = FeatureAreaStore(defaults: defaults, plugins: [first, second])
        let shortcut = TouchFeatureAPI.KeyboardShortcut(modifiers: [.option, .shift], key: "f")

        XCTAssertNil(firstStore.updateGlobalShortcut(shortcut, for: first.manifest.id))
        XCTAssertEqual(
            firstStore.updateGlobalShortcut(shortcut, for: second.manifest.id),
            "与“me.touch.first”的快捷键冲突"
        )
        XCTAssertEqual(
            firstStore.updateGlobalShortcut(
                .init(modifiers: [.command, .option, .shift], key: "g"),
                for: second.manifest.id
            ),
            "快捷键需要一个主键和一至两个修饰键"
        )

        let restoredStore = FeatureAreaStore(defaults: defaults, plugins: [first, second])
        XCTAssertEqual(restoredStore.globalShortcut(for: first.manifest.id), shortcut)
        XCTAssertEqual(
            restoredStore.globalShortcut(for: second.manifest.id),
            .init(modifiers: [.option], key: "2")
        )
    }

    func testFeatureGlobalShortcutsDefaultToOptionAndLauncherKey() {
        let first = StoreTestPlugin(id: "me.touch.first", shortcutKey: "1")
        let second = StoreTestPlugin(id: "me.touch.second", shortcutKey: "q")
        let store = makeStore(plugins: [first, second])

        XCTAssertEqual(
            store.globalShortcut(for: first.manifest.id),
            .init(modifiers: [.option], key: "1")
        )
        XCTAssertEqual(
            store.globalShortcut(for: second.manifest.id),
            .init(modifiers: [.option], key: "q")
        )
    }

    func testFeatureGlobalShortcutDefaultFollowsCurrentLauncherKey() throws {
        let suiteName = "FeatureGlobalShortcutCurrentKeyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let plugin = StoreTestPlugin(id: "me.touch.first", shortcutKey: "1")
        try FeaturePreferencesStore(defaults: defaults).save(
            .init(shortcuts: [
                plugin.manifest.id: .init(modifiers: [], key: "q")
            ])
        )

        let store = FeatureAreaStore(defaults: defaults, plugins: [plugin])

        XCTAssertEqual(
            store.globalShortcut(for: plugin.manifest.id),
            .init(modifiers: [.option], key: "q")
        )
    }

    func testChangingLauncherKeyUpdatesItsDefaultGlobalShortcut() {
        let plugin = StoreTestPlugin(id: "me.touch.first", shortcutKey: "t")
        let store = makeStore(plugins: [plugin])

        XCTAssertNil(
            store.updateShortcut(
                .init(modifiers: [], key: "s"),
                for: plugin.manifest.id
            )
        )

        XCTAssertEqual(
            store.globalShortcut(for: plugin.manifest.id),
            .init(modifiers: [.option], key: "s")
        )
    }

    func testChangingLauncherKeyReplacesExistingGlobalShortcut() {
        let plugin = StoreTestPlugin(id: "me.touch.first", shortcutKey: "t")
        let store = makeStore(plugins: [plugin])
        let customizedShortcut = TouchFeatureAPI.KeyboardShortcut(modifiers: [.control], key: "t")
        XCTAssertNil(store.updateGlobalShortcut(customizedShortcut, for: plugin.manifest.id))

        XCTAssertNil(
            store.updateShortcut(
                .init(modifiers: [], key: "s"),
                for: plugin.manifest.id
            )
        )

        XCTAssertEqual(
            store.globalShortcut(for: plugin.manifest.id),
            .init(modifiers: [.option], key: "s")
        )
    }

    func testLegacyCommandDefaultIsMigratedEvenWhenCurrentSeedMarkerExists() throws {
        let suiteName = "FeatureGlobalShortcutLegacyMigrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let plugin = StoreTestPlugin(id: "me.touch.first", shortcutKey: "1")
        let legacyShortcut = TouchFeatureAPI.KeyboardShortcut(modifiers: [.command], key: "1")
        let data = try JSONEncoder().encode([plugin.manifest.id: legacyShortcut])

        defaults.set(data, forKey: "feature.global-shortcuts.v1")
        defaults.set(true, forKey: "feature.global-shortcuts.command-defaults-seeded-v1")
        defaults.set(true, forKey: "feature.global-shortcuts.option-defaults-seeded-v3")

        let store = FeatureAreaStore(defaults: defaults, plugins: [plugin])

        XCTAssertEqual(
            store.globalShortcut(for: plugin.manifest.id),
            .init(modifiers: [.option], key: "1")
        )
    }

    func testExistingCommandGlobalShortcutMigratesToOptionAfterPreviousMigrationCompleted() throws {
        let suiteName = "FeatureGlobalShortcutOptionResetTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let plugin = StoreTestPlugin(id: "me.touch.first", shortcutKey: "1")
        let commandShortcut = TouchFeatureAPI.KeyboardShortcut(modifiers: [.command], key: "q")

        defaults.set(
            try JSONEncoder().encode([plugin.manifest.id: commandShortcut]),
            forKey: "feature.global-shortcuts.v1"
        )
        defaults.set(true, forKey: "feature.global-shortcuts.option-defaults-seeded-v3")

        let store = FeatureAreaStore(defaults: defaults, plugins: [plugin])

        XCTAssertEqual(
            store.globalShortcut(for: plugin.manifest.id),
            .init(modifiers: [.option], key: "1")
        )
    }

    func testClearedDefaultGlobalShortcutStaysClearedAfterReload() {
        let suiteName = "FeatureGlobalShortcutClearTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let plugin = StoreTestPlugin(id: "me.touch.first", shortcutKey: "1")
        let firstStore = FeatureAreaStore(defaults: defaults, plugins: [plugin])
        XCTAssertNotNil(firstStore.globalShortcut(for: plugin.manifest.id))

        firstStore.removeGlobalShortcut(for: plugin.manifest.id)
        let restoredStore = FeatureAreaStore(defaults: defaults, plugins: [plugin])

        XCTAssertNil(restoredStore.globalShortcut(for: plugin.manifest.id))
    }

    func testFeatureGlobalShortcutRejectsLauncherShortcut() {
        let plugin = StoreTestPlugin(id: "me.touch.first", shortcutKey: "1")
        let store = makeStore(plugins: [plugin])

        XCTAssertEqual(
            store.updateGlobalShortcut(
                LauncherShortcutPreferences.defaultShortcut,
                for: plugin.manifest.id
            ),
            "与启动器呼出快捷键冲突"
        )
    }

    func testFeatureSettingsHostUsesRegisteredProviderWithoutInspectingPluginID() {
        let provider = SettingsProviderStub()
        let plugin = SettingsHostTestPlugin(provider: provider)

        _ = FeatureSettingsHost(
            plugin: plugin,
            context: FeatureSettingsContext(openPermissions: {})
        ).body

        XCTAssertEqual(provider.makeViewCallCount, 1)
    }

    func testPerformExecutesThroughRegistryAndRestoresAvailableState() async {
        let plugin = StoreTestPlugin(id: "me.touch.finder")
        let store = makeStore(plugins: [plugin])

        await store.perform(plugin.manifest.id)

        let callCount = await plugin.callCount()
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(store.states[plugin.manifest.id], .available)
    }

    func testRestrictedOpenSettingsFeatureRoutesToPermissionsCenter() async {
        let plugin = StoreTestPlugin(
            id: "me.touch.test-settings",
            state: .restricted(message: "需要启用扩展"),
            primaryAction: .openSettings
        )
        let center = NotificationCenter()
        let capture = SettingsDestinationCapture()
        let token = center.addObserver(forName: .openTouchSettings, object: nil, queue: nil) {
            capture.record($0)
        }
        defer { center.removeObserver(token) }
        let store = makeStore(plugins: [plugin], notificationCenter: center)
        await waitForState(of: plugin.manifest.id, in: store)

        await store.perform(plugin.manifest.id)

        XCTAssertEqual(capture.sections(), [.permissions])
        XCTAssertTrue(capture.featureIDs().isEmpty)
        let callCount = await plugin.callCount()
        XCTAssertEqual(callCount, 0)
    }

    func testRestrictedTranslationRoutesToItsFeatureSettingsInsteadOfPermissions() async {
        let plugin = StoreTestPlugin(
            id: "me.touch.translation",
            state: .restricted(message: "需要 macOS 15 才能使用系统离线翻译")
        )
        let center = NotificationCenter()
        let capture = SettingsDestinationCapture()
        let token = center.addObserver(forName: .openTouchSettings, object: nil, queue: nil) {
            capture.record($0)
        }
        defer { center.removeObserver(token) }
        let store = makeStore(plugins: [plugin], notificationCenter: center)
        await waitForState(of: plugin.manifest.id, in: store)

        await store.perform(plugin.manifest.id)

        XCTAssertEqual(capture.sections(), [.featureArea])
        XCTAssertEqual(capture.featureIDs(), [plugin.manifest.id])
        let callCount = await plugin.callCount()
        XCTAssertEqual(callCount, 0)
    }

    func testRestrictedPermissionFeatureStillRoutesToPermissionsCenter() async {
        let plugin = StoreTestPlugin(
            id: "me.touch.screenshot",
            state: .restricted(message: "需要屏幕录制权限")
        )
        let center = NotificationCenter()
        let capture = SettingsDestinationCapture()
        let token = center.addObserver(forName: .openTouchSettings, object: nil, queue: nil) {
            capture.record($0)
        }
        defer { center.removeObserver(token) }
        let store = makeStore(plugins: [plugin], notificationCenter: center)
        await waitForState(of: plugin.manifest.id, in: store)

        await store.perform(plugin.manifest.id)

        XCTAssertEqual(capture.sections(), [.permissions])
        XCTAssertTrue(capture.featureIDs().isEmpty)
        let callCount = await plugin.callCount()
        XCTAssertEqual(callCount, 0)
    }

    func testFailedPluginPublishesFailureAndRetryReloadsOnlyItsState() async {
        let failing = StoreTestPlugin(id: "me.touch.test-failing", action: .fail)
        let healthy = StoreTestPlugin(id: "me.touch.test-healthy")
        let store = makeStore(plugins: [failing, healthy])

        await store.perform(failing.manifest.id)

        XCTAssertEqual(store.states[failing.manifest.id], .failed(message: "功能执行失败，请重试。"))
        await store.retry(failing.manifest.id)
        XCTAssertEqual(store.states[failing.manifest.id], .available)

        await store.perform(healthy.manifest.id)
        let healthyCallCount = await healthy.callCount()
        XCTAssertEqual(healthyCallCount, 1)
        XCTAssertEqual(store.states[healthy.manifest.id], .available)
    }

    func testRequiresSetupResultOpensTheMatchingFeatureSettings() async {
        let plugin = StoreTestPlugin(id: "me.touch.test-setup", action: .requiresSetup)
        let center = NotificationCenter()
        let capture = SettingsDestinationCapture()
        let token = center.addObserver(forName: .openTouchSettings, object: nil, queue: nil) {
            capture.record($0)
        }
        defer { center.removeObserver(token) }
        let store = makeStore(plugins: [plugin], notificationCenter: center)

        await store.perform(plugin.manifest.id)

        XCTAssertEqual(capture.featureIDs(), [plugin.manifest.id])
        XCTAssertEqual(store.states[plugin.manifest.id], .available)
    }

    func testHidingCardDoesNotDisablePluginButDisableOnlyStopsRequestedFeature() async {
        let screenshot = StoreTestPlugin(id: "me.touch.screenshot")
        let finder = StoreTestPlugin(id: "me.touch.finder")
        let store = makeStore(plugins: [screenshot, finder])
        await waitForState(of: screenshot.manifest.id, in: store)

        store.setHidden(true, for: screenshot.manifest.id)
        XCTAssertFalse(store.visiblePlugins.contains { $0.manifest.id == screenshot.manifest.id })
        XCTAssertTrue(store.isEnabled(screenshot.manifest.id))
        let lifecycleCountsAfterHiding = await screenshot.lifecycleCounts()
        XCTAssertEqual(lifecycleCountsAfterHiding.disabled, 0)

        await store.setEnabled(false, for: screenshot.manifest.id)
        XCTAssertFalse(store.isEnabled(screenshot.manifest.id))
        XCTAssertEqual(store.states[screenshot.manifest.id], .disabled)
        let screenshotCountsAfterDisabling = await screenshot.lifecycleCounts()
        XCTAssertEqual(screenshotCountsAfterDisabling.disabled, 1)
        XCTAssertEqual(store.states[finder.manifest.id], .available)
        let finderCountsAfterDisablingScreenshot = await finder.lifecycleCounts()
        XCTAssertEqual(finderCountsAfterDisablingScreenshot.disabled, 0)

        await store.setEnabled(true, for: screenshot.manifest.id)
        XCTAssertTrue(store.isEnabled(screenshot.manifest.id))
        XCTAssertEqual(store.states[screenshot.manifest.id], .available)
        let screenshotCountsAfterReenabling = await screenshot.lifecycleCounts()
        let finderCountsAfterReenablingScreenshot = await finder.lifecycleCounts()
        XCTAssertEqual(screenshotCountsAfterReenabling.enabled, 2)
        XCTAssertEqual(finderCountsAfterReenablingScreenshot.enabled, 1)
    }

    func testFeaturePanelSessionTracksOpenOrderPromotionAndClose() {
        var session = FeaturePanelSessionState()

        session.open("pomodoro")
        session.open("daily-task")
        XCTAssertEqual(session.openFeatureIDs, ["pomodoro", "daily-task"])
        XCTAssertEqual(session.frontmostFeatureID, "daily-task")

        session.promote("pomodoro")
        XCTAssertEqual(session.openFeatureIDs, ["daily-task", "pomodoro"])
        XCTAssertEqual(session.frontmostFeatureID, "pomodoro")

        session.close("pomodoro")
        XCTAssertEqual(session.openFeatureIDs, ["daily-task"])
        XCTAssertEqual(session.frontmostFeatureID, "daily-task")
    }

    func testFeaturePanelSessionRetainsPanelsWithoutImplicitBulkRestoration() {
        var session = FeaturePanelSessionState()
        session.open("pomodoro")
        session.open("daily-task")

        // 窗口回到后台后仅保留会话记录；是否恢复由用户从启动器显式选择。
        XCTAssertEqual(session.openFeatureIDs, ["pomodoro", "daily-task"])
        XCTAssertEqual(session.frontmostFeatureID, "daily-task")
    }

    func testPanelPresenceIsIndependentFromPluginLifecycleState() {
        let plugin = StoreTestPlugin(id: "me.touch.panel-presence")
        let store = makeStore(plugins: [plugin])

        store.setPanelPresence(.retained, for: plugin.manifest.id)
        XCTAssertEqual(store.panelPresence(for: plugin.manifest.id), .retained)

        store.setPanelPresence(.running, for: plugin.manifest.id)
        XCTAssertEqual(store.panelPresence(for: plugin.manifest.id), .running)

        store.setPanelStatusText("00:18:42 · 进行中", for: plugin.manifest.id)
        XCTAssertEqual(store.panelStatusText(for: plugin.manifest.id), "00:18:42 · 进行中")

        store.setPanelPresence(nil, for: plugin.manifest.id)
        store.setPanelStatusText(nil, for: plugin.manifest.id)
        XCTAssertNil(store.panelPresence(for: plugin.manifest.id))
        XCTAssertNil(store.panelStatusText(for: plugin.manifest.id))
    }

    func testPomodoroCompletionHoldsAtZeroUntilAcknowledged() {
        let model = PomodoroPanelModel()
        model.setTargetPomodoros(2)
        var completionCount = 0
        model.onCompletion = { completionCount += 1 }

        model.completeCurrentPhase(playSound: false)

        XCTAssertEqual(model.phase, .work)
        XCTAssertEqual(model.state, .completed)
        XCTAssertEqual(model.remainingSeconds, 0)
        XCTAssertEqual(model.completedPomodoros, 1)
        XCTAssertEqual(completionCount, 1)

        model.completeCurrentPhase(playSound: false)
        XCTAssertEqual(model.completedPomodoros, 1)
        XCTAssertEqual(completionCount, 1)

        model.stopCompletionAlertForUser()
        XCTAssertEqual(model.state, .completed)
        XCTAssertEqual(model.remainingSeconds, 0)

        model.acknowledgeCompletion()
        XCTAssertEqual(model.phase, .shortBreak)
        XCTAssertEqual(model.state, .ready)
        XCTAssertEqual(model.remainingSeconds, 5 * 60)

        model.completeCurrentPhase(playSound: false)
        XCTAssertEqual(model.phase, .shortBreak)
        XCTAssertEqual(model.state, .completed)
        XCTAssertEqual(model.remainingSeconds, 0)

        model.acknowledgeCompletion()
        XCTAssertEqual(model.phase, .work)
        XCTAssertEqual(model.state, .ready)
        XCTAssertEqual(model.remainingSeconds, 25 * 60)
    }

    func testPomodoroTargetCanBeAdjustedAndStopsAtTheGoal() {
        let model = PomodoroPanelModel()

        model.setTargetPomodoros(0)
        XCTAssertEqual(model.targetPomodoros, 1)
        model.completeCurrentPhase(playSound: false)

        XCTAssertEqual(model.completedPomodoros, 1)
        XCTAssertEqual(model.phase, .work)
        XCTAssertEqual(model.state, .completed)
        XCTAssertEqual(model.remainingSeconds, 0)

        model.acknowledgeCompletion()
        XCTAssertEqual(model.state, .ready)
        XCTAssertEqual(model.remainingSeconds, 25 * 60)

        model.setTargetPomodoros(99)
        XCTAssertEqual(model.targetPomodoros, 12)
    }

    func testPomodoroCustomizedTargetSurvivesDurationChangesForPlannedTask() {
        let model = PomodoroPanelModel()
        model.prepare(.init(title: "测试任务", plannedMinutes: 75))
        XCTAssertEqual(model.targetPomodoros, 3)

        model.setTargetPomodoros(5)
        model.configureWork(minutes: 45)

        XCTAssertEqual(model.targetPomodoros, 5)
    }

    func testPomodoroCompletionAlertDurationIsTenSeconds() {
        XCTAssertEqual(PomodoroPanelModel.completionAlertDuration, .seconds(10))
        XCTAssertEqual(PomodoroPanelModel.completionAlertRepeatInterval, .milliseconds(1_250))
        XCTAssertEqual(PomodoroPanelModel.completionAlertRepeatCount, 8)
    }

    func testPomodoroUsesWallClockAfterDelayedTimerDelivery() {
        var now = Date(timeIntervalSince1970: 1_000)
        let model = PomodoroPanelModel(nowProvider: { now })
        model.configureWork(minutes: 1)
        model.scrub(toElapsedProgress: 11.0 / 12.0)
        var completionCount = 0
        model.onCompletion = { completionCount += 1 }

        model.startOrResume()
        now.addTimeInterval(10)
        model.synchronizeRunningSession()

        XCTAssertEqual(model.state, .completed)
        XCTAssertEqual(model.remainingSeconds, 0)
        XCTAssertEqual(model.sessionFocusSeconds, 5)
        XCTAssertEqual(completionCount, 1)
    }

    func testPomodoroPauseAccountsForActualElapsedTime() {
        var now = Date(timeIntervalSince1970: 2_000)
        let model = PomodoroPanelModel(nowProvider: { now })
        model.configureWork(minutes: 1)

        model.startOrResume()
        now.addTimeInterval(17)
        model.pause()

        XCTAssertEqual(model.state, .paused)
        XCTAssertEqual(model.remainingSeconds, 43)
        XCTAssertEqual(model.sessionFocusSeconds, 17)
    }

    func testClipboardHistoryMonitoringSurvivesWorkspaceWindowClose() {
        let controller = ClipboardPanelController(themeStore: ThemeStore(), onClose: {})

        XCTAssertTrue(controller.isMonitoring)

        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))

        XCTAssertTrue(controller.isMonitoring)
    }

    func testClipboardHistoryStorageMigratesLegacyDatabaseIntoFeatureNamespace() throws {
        let applicationSupportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipboardHistoryStorageTests-\(UUID().uuidString)", isDirectory: true)
        let legacyDirectory = applicationSupportURL
            .appendingPathComponent("一念", isDirectory: true)
            .appendingPathComponent("Clipboard", isDirectory: true)
        let legacyDatabaseURL = legacyDirectory.appendingPathComponent("history.sqlite", isDirectory: false)
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        try Data("legacy-history".utf8).write(to: legacyDatabaseURL)
        defer { try? FileManager.default.removeItem(at: applicationSupportURL) }

        let databaseURL = try ClipboardHistoryStorage.prepareDatabaseURL(
            applicationSupportURL: applicationSupportURL
        )

        XCTAssertEqual(
            databaseURL,
            applicationSupportURL
                .appendingPathComponent("Touch", isDirectory: true)
                .appendingPathComponent("Features", isDirectory: true)
                .appendingPathComponent("me.touch.clipboard", isDirectory: true)
                .appendingPathComponent("history.sqlite", isDirectory: false)
        )
        XCTAssertEqual(try Data(contentsOf: databaseURL), Data("legacy-history".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyDirectory.path))
    }

    func testTranslationWorkspaceCapturesTextBeforeShowingItsResultWindow() async {
        let capture = WorkspaceTextCaptureStub(
            result: .success(.init(text: "Hello", recognizedLanguageCode: "en"))
        )
        var presentationCount = 0
        let controller = TranslationPanelController(
            screenshotCoordinator: capture,
            themeStore: ThemeStore(),
            onPresented: { presentationCount += 1 },
            onClose: {}
        )

        controller.show()

        XCTAssertFalse(controller.isPanelVisible)
        XCTAssertEqual(presentationCount, 0)
        await waitForPanelToAppear(controller.isPanelVisible)
        XCTAssertEqual(capture.captureCallCount, 1)
        XCTAssertTrue(controller.isPanelVisible)
        XCTAssertEqual(presentationCount, 1)
    }

    func testTranslationLanguagePackRequirementPersistsAcrossRepeatedRequests() {
        let model = TranslationWorkspaceModel()
        let request = TextTranslationRequest(
            text: "Hello",
            source: .screenCapture,
            recognizedLanguageCode: "en"
        )

        model.accept(request)
        model.beginTranslation()
        let firstSessionRequest = try? XCTUnwrap(model.sessionRequest)
        XCTAssertNotNil(firstSessionRequest)

        if let firstSessionRequest {
            model.showLanguagePackPrompt(
                for: firstSessionRequest,
                title: "系统语言包未安装",
                message: "当前语言组合受支持，但本机尚未下载对应的离线语言包。"
            )
        }

        model.accept(request)
        model.beginTranslation()

        XCTAssertNil(model.sessionRequest)
        XCTAssertNotNil(model.languagePackPrompt)
        XCTAssertFalse(model.isTranslating)
    }

    func testOCRWorkspaceCapturesTextBeforeShowingItsResultWindow() async {
        let capture = WorkspaceTextCaptureStub(
            result: .success(.init(text: "识别结果", recognizedLanguageCode: "zh-Hans"))
        )
        var presentationCount = 0
        let controller = OCRPanelController(
            screenshotCoordinator: capture,
            themeStore: ThemeStore(),
            onTranslate: { _ in },
            onPresented: { presentationCount += 1 },
            onClose: {}
        )

        controller.show()

        XCTAssertFalse(controller.isPanelVisible)
        XCTAssertEqual(presentationCount, 0)
        await waitForPanelToAppear(controller.isPanelVisible)
        XCTAssertEqual(capture.captureCallCount, 1)
        XCTAssertTrue(controller.isPanelVisible)
        XCTAssertEqual(presentationCount, 1)
    }

    func testOCRWorkspaceAutomaticallyCopiesRecognizedTextAndKeepsPreview() {
        let preview = Data([0x01, 0x02, 0x03])
        let recorder = OCRCopyRecorder()
        let controller = OCRPanelController(
            screenshotCoordinator: WorkspaceTextCaptureStub(
                result: .success(.init(text: "未使用"))
            ),
            themeStore: ThemeStore(),
            configurationProvider: {
                .init(automaticallyCopiesRecognizedText: true)
            },
            copyWriter: recorder.write,
            onTranslate: { _ in },
            onClose: {}
        )

        controller.applyResultForTesting(.init(
            text: "识别结果",
            recognizedLanguageCode: "zh-Hans",
            previewImageData: preview
        ))

        XCTAssertEqual(recorder.texts, ["识别结果"])
        XCTAssertEqual(controller.recognizedTextForTesting, "识别结果")
        XCTAssertEqual(controller.previewImageDataForTesting, preview)
        XCTAssertEqual(controller.copyConfirmationForTesting, "拷贝成功")
        XCTAssertEqual(controller.windowSizeForTesting.width, 390, accuracy: 0.5)
        XCTAssertEqual(controller.windowSizeForTesting.height, 252, accuracy: 0.5)
    }

    func testOCRWorkspaceDoesNotAutomaticallyCopyWhenSettingIsDisabled() {
        let recorder = OCRCopyRecorder()
        let controller = OCRPanelController(
            screenshotCoordinator: WorkspaceTextCaptureStub(
                result: .success(.init(text: "未使用"))
            ),
            themeStore: ThemeStore(),
            configurationProvider: {
                .init(automaticallyCopiesRecognizedText: false)
            },
            copyWriter: recorder.write,
            onTranslate: { _ in },
            onClose: {}
        )

        controller.applyResultForTesting(.init(text: "不自动复制"))

        XCTAssertTrue(recorder.texts.isEmpty)
        XCTAssertNil(controller.copyConfirmationForTesting)
    }

    func testOCRWorkspaceManualCopyStillWorksWhenAutomaticCopyIsDisabled() {
        let recorder = OCRCopyRecorder()
        let controller = OCRPanelController(
            screenshotCoordinator: WorkspaceTextCaptureStub(
                result: .success(.init(text: "未使用"))
            ),
            themeStore: ThemeStore(),
            configurationProvider: {
                .init(automaticallyCopiesRecognizedText: false)
            },
            copyWriter: recorder.write,
            onTranslate: { _ in },
            onClose: {}
        )
        controller.applyResultForTesting(.init(text: "手动复制内容"))

        controller.copyRecognizedTextForTesting()

        XCTAssertEqual(recorder.texts, ["手动复制内容"])
        XCTAssertEqual(controller.copyConfirmationForTesting, "拷贝成功")
    }

    func testPomodoroDialScrubsRemainingTimeClockwise() {
        let model = PomodoroPanelModel()
        model.configureWork(minutes: 20)

        model.scrub(toElapsedProgress: 0.25)
        XCTAssertEqual(model.remainingSeconds, 15 * 60)

        model.scrub(toElapsedProgress: 0.75)
        XCTAssertEqual(model.remainingSeconds, 5 * 60)
    }

    func testPlannedPomodoroStopsAfterTheRequestedCountAndResetsSessionStatistics() {
        let model = PomodoroPanelModel()
        model.prepare(.init(title: "测试任务", plannedMinutes: 25))

        model.completeCurrentPhase(playSound: false)

        XCTAssertEqual(model.phase, .work)
        XCTAssertEqual(model.state, .completed)
        XCTAssertEqual(model.remainingSeconds, 0)
        XCTAssertEqual(model.completedPomodoros, 1)
        XCTAssertEqual(model.taskCompletedPomodoros, 1)

        model.prepare(.init(title: "下一任务", plannedMinutes: 50))

        XCTAssertEqual(model.completedPomodoros, 0)
        XCTAssertEqual(model.taskCompletedPomodoros, 0)
        XCTAssertEqual(model.sessionFocusSeconds, 0)
    }

    private func waitForState(of featureID: String, in store: FeatureAreaStore) async {
        for _ in 0..<100 where store.states[featureID] == nil {
            await Task.yield()
        }
    }

    private func waitForPanelToAppear(_ isVisible: @autoclosure @escaping () -> Bool) async {
        for _ in 0..<100 where !isVisible() {
            await Task.yield()
        }
    }

    private func makeStore(
        plugins: [any FeaturePlugin],
        notificationCenter: NotificationCenter = NotificationCenter()
    ) -> FeatureAreaStore {
        let suiteName = "FeatureAreaStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return FeatureAreaStore(
            defaults: defaults,
            plugins: plugins,
            notificationCenter: notificationCenter
        )
    }
}
