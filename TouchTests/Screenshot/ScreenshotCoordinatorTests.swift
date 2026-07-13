import Foundation
import ScreenshotFeature
import TouchFeatureAPI
import XCTest
@testable import 触达

@MainActor
final class ScreenshotCoordinatorTests: XCTestCase {
    func testSuccessfulCaptureHidesLauncherBeforeFallbackAndDoesNotStealFocusAfterward() async throws {
        let events = EventRecorder()
        let launcher = LauncherStub(isVisible: true, events: events)
        let capture = CaptureStub {
            XCTAssertEqual(events.values(), ["hide"])
        }
        let coordinator = makeCoordinator(capture: capture)
        coordinator.attachLauncher(launcher)

        let result = try await coordinator.route(.captureDefaultMode)

        XCTAssertEqual(result, .completed)
        XCTAssertEqual(events.values(), ["hide"])
        XCTAssertFalse(launcher.isLauncherVisible)
    }

    func testFailureAndCancellationRestoreOnlyPreviouslyVisibleLauncher() async {
        struct ExpectedFailure: Error {}
        let failureEvents = EventRecorder()
        let failureLauncher = LauncherStub(isVisible: true, events: failureEvents)
        let failingCoordinator = makeCoordinator(capture: CaptureStub { throw ExpectedFailure() })
        failingCoordinator.attachLauncher(failureLauncher)

        do {
            _ = try await failingCoordinator.route(.captureDefaultMode)
            XCTFail("失败的捕获不应成功")
        } catch { }
        XCTAssertEqual(failureEvents.values(), ["hide", "show"])
        XCTAssertTrue(failureLauncher.isLauncherVisible)

        let hiddenEvents = EventRecorder()
        let hiddenLauncher = LauncherStub(isVisible: false, events: hiddenEvents)
        let hiddenCoordinator = makeCoordinator(capture: CaptureStub { throw ExpectedFailure() })
        hiddenCoordinator.attachLauncher(hiddenLauncher)
        _ = try? await hiddenCoordinator.route(.captureDefaultMode)
        XCTAssertEqual(hiddenEvents.values(), [])
        XCTAssertFalse(hiddenLauncher.isLauncherVisible)

        let gate = CaptureGate()
        let cancellationEvents = EventRecorder()
        let cancellationLauncher = LauncherStub(isVisible: true, events: cancellationEvents)
        let cancellationCoordinator = makeCoordinator(capture: CaptureStub { try await gate.wait() })
        cancellationCoordinator.attachLauncher(cancellationLauncher)
        let task = Task { try await cancellationCoordinator.route(.captureDefaultMode) }
        await gate.waitUntilStarted()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("取消的捕获不应成功")
        } catch { }
        XCTAssertEqual(cancellationEvents.values(), ["hide", "show"])
        XCTAssertTrue(cancellationLauncher.isLauncherVisible)
    }

    func testPermissionIsRequestedOnceFromUserActionAndRetryCanRecover() async throws {
        let authorization = AuthorizationStub(status: .notRequested, requestResult: .denied)
        let capture = CaptureStub {}
        let coordinator = makeCoordinator(authorization: authorization, capture: capture)

        XCTAssertEqual(coordinator.featureState(), .available)
        let firstPermissionResult = try await coordinator.route(.captureDefaultMode)
        XCTAssertEqual(firstPermissionResult, .requiresSetup(message: "请允许触达录制屏幕"))
        let secondPermissionResult = try await coordinator.route(.captureDefaultMode)
        XCTAssertEqual(secondPermissionResult, .requiresSetup(message: "请允许触达录制屏幕"))
        XCTAssertEqual(authorization.requestCount, 1)
        XCTAssertEqual(coordinator.featureState(), .restricted(message: "需要配置屏幕录制权限"))
        XCTAssertEqual(capture.captureCount, 0)

        authorization.status = .authorized
        XCTAssertEqual(coordinator.featureState(), .available)
        let recoveredResult = try await coordinator.route(.captureDefaultMode)
        XCTAssertEqual(recoveredResult, .completed)
        XCTAssertEqual(capture.captureCount, 1)
    }

    func testConcurrentCaptureReturnsBusyInsteadOfStackingFlows() async throws {
        let gate = CaptureGate()
        let coordinator = makeCoordinator(capture: CaptureStub { try await gate.wait() })
        let first = Task { try await coordinator.route(.captureDefaultMode) }
        await gate.waitUntilStarted()

        do {
            _ = try await coordinator.route(.captureDefaultMode)
            XCTFail("第二条并发截图流程不应启动")
        } catch let error as ScreenshotCoordinatorError {
            XCTAssertEqual(error, .busy)
        } catch {
            XCTFail("收到非预期错误：\(error)")
        }
        let startCount = await gate.startCount
        XCTAssertEqual(startCount, 1)

        await gate.release()
        let firstResult = try await first.value
        XCTAssertEqual(firstResult, .completed)
    }

    func testDeactivationCancelsFlowClosesServiceAndUnregistersShortcuts() async {
        let gate = CaptureGate()
        let service = LifecycleCounter()
        let shortcuts = ShortcutControllerStub()
        let coordinator = makeCoordinator(
            capture: CaptureStub { try await gate.wait() },
            invalidateService: { await service.increment() },
            registerShortcuts: { shortcuts.registerAll() },
            unregisterShortcuts: { shortcuts.unregisterAll() }
        )
        let task = Task { try await coordinator.route(.captureDefaultMode) }
        await gate.waitUntilStarted()

        await coordinator.deactivate()

        _ = try? await task.value
        let serviceCount = await service.count
        XCTAssertEqual(serviceCount, 1)
        XCTAssertEqual(shortcuts.unregisterCount, 1)
        XCTAssertEqual(coordinator.featureState(), .disabled)

        await coordinator.activate()
        XCTAssertEqual(shortcuts.registerCount, 1)
        XCTAssertEqual(coordinator.featureState(), .available)
        await gate.release()
        let recoveredResult = try? await coordinator.route(.captureDefaultMode)
        XCTAssertEqual(recoveredResult, .completed)
    }

    private func makeCoordinator(
        authorization: AuthorizationStub = AuthorizationStub(status: .authorized),
        capture: CaptureStub,
        invalidateService: @escaping @Sendable () async -> Void = {},
        registerShortcuts: @escaping @MainActor @Sendable () -> Void = {},
        unregisterShortcuts: @escaping @MainActor @Sendable () -> Void = {}
    ) -> ScreenshotCoordinator {
        ScreenshotCoordinator(
            authorization: authorization,
            captureService: capture,
            invalidateService: invalidateService,
            registerShortcuts: registerShortcuts,
            unregisterShortcuts: unregisterShortcuts
        )
    }
}

@MainActor
private final class AuthorizationStub: ScreenRecordingAuthorizing {
    var status: ScreenshotPermissionState
    var requestResult: ScreenshotPermissionState
    private(set) var requestCount = 0
    private(set) var openSettingsCount = 0

    init(status: ScreenshotPermissionState, requestResult: ScreenshotPermissionState? = nil) {
        self.status = status
        self.requestResult = requestResult ?? status
    }

    func requestAccess() -> ScreenshotPermissionState {
        requestCount += 1
        status = requestResult
        return status
    }

    func openSystemSettings() {
        openSettingsCount += 1
    }
}

private final class CaptureStub: ScreenshotCapturing, @unchecked Sendable {
    private let lock = NSLock()
    private let handler: @Sendable () async throws -> Void
    private var storedCaptureCount = 0

    init(handler: @escaping @Sendable () async throws -> Void) {
        self.handler = handler
    }

    var captureCount: Int { lock.withLock { storedCaptureCount } }

    func capturePrimaryDisplay() async throws {
        lock.withLock { storedCaptureCount += 1 }
        try await handler()
    }
}

@MainActor
private final class LauncherStub: ScreenshotLauncherPresenting {
    private(set) var isLauncherVisible: Bool
    private let events: EventRecorder

    init(isVisible: Bool, events: EventRecorder) {
        self.isLauncherVisible = isVisible
        self.events = events
    }

    func hideLauncher() {
        isLauncherVisible = false
        events.append("hide")
    }

    func showLauncher() {
        isLauncherVisible = true
        events.append("show")
    }
}

private final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []

    func append(_ event: String) {
        lock.withLock { events.append(event) }
    }

    func values() -> [String] {
        lock.withLock { events }
    }
}

private actor CaptureGate {
    private(set) var startCount = 0
    private var isReleased = false

    func wait() async throws {
        startCount += 1
        while !isReleased {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func waitUntilStarted() async {
        while startCount == 0 {
            await Task.yield()
        }
    }

    func release() {
        isReleased = true
    }
}

private actor LifecycleCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

@MainActor
private final class ShortcutControllerStub {
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0

    func registerAll() { registerCount += 1 }
    func unregisterAll() { unregisterCount += 1 }
}
