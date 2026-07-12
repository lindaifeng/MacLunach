import Foundation
import TouchFeatureAPI
import XCTest
@testable import 触达

private actor StoreTestPlugin: FeaturePlugin {
    enum Action: Sendable {
        case complete
        case fail
        case requiresSetup
    }

    nonisolated let manifest: FeatureManifest
    private let state: FeatureState
    private let action: Action
    private var performCallCount = 0

    init(id: String, state: FeatureState = .available, action: Action = .complete) {
        manifest = FeatureManifest(
            id: id,
            name: id,
            summary: "测试功能",
            symbolName: "hammer",
            defaultOrder: 0,
            defaultShortcut: .init(modifiers: [.command], key: "1")
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
}

private final class SettingsDestinationCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var capturedFeatureIDs: [String] = []

    func record(_ notification: Notification) {
        guard let destination = notification.object as? TouchSettingsDestination,
              destination.section == .featureArea,
              let featureID = destination.featureID else { return }
        lock.withLock { capturedFeatureIDs.append(featureID) }
    }

    func featureIDs() -> [String] {
        lock.withLock { capturedFeatureIDs }
    }
}

@MainActor
final class FeatureAreaStoreTests: XCTestCase {
    func testPerformExecutesThroughRegistryAndRestoresAvailableState() async {
        let plugin = StoreTestPlugin(id: "me.touch.finder")
        let store = makeStore(plugins: [plugin])

        await store.perform(plugin.manifest.id)

        let callCount = await plugin.callCount()
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(store.states[plugin.manifest.id], .available)
    }

    func testRestrictedScreenshotAndSuperRightOpenTheirSpecificSettings() async {
        let screenshot = StoreTestPlugin(
            id: "me.touch.screenshot",
            state: .restricted(message: "需要屏幕录制权限")
        )
        let superRight = StoreTestPlugin(
            id: "me.touch.super-right",
            state: .restricted(message: "需要启用扩展")
        )
        let center = NotificationCenter()
        let capture = SettingsDestinationCapture()
        let token = center.addObserver(forName: .openTouchSettings, object: nil, queue: nil) {
            capture.record($0)
        }
        defer { center.removeObserver(token) }
        let store = makeStore(plugins: [screenshot, superRight], notificationCenter: center)

        await store.perform(screenshot.manifest.id)
        await store.perform(superRight.manifest.id)

        XCTAssertEqual(capture.featureIDs(), [screenshot.manifest.id, superRight.manifest.id])
        let screenshotCallCount = await screenshot.callCount()
        let superRightCallCount = await superRight.callCount()
        XCTAssertEqual(screenshotCallCount, 0)
        XCTAssertEqual(superRightCallCount, 0)
    }

    func testFailedPluginPublishesFailureAndRetryReloadsOnlyItsState() async {
        let failing = StoreTestPlugin(id: "failing", action: .fail)
        let healthy = StoreTestPlugin(id: "healthy")
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
        let plugin = StoreTestPlugin(id: "setup", action: .requiresSetup)
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
