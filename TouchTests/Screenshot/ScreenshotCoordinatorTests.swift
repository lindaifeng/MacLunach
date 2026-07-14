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
        let selection = SelectionStub {
            XCTAssertEqual(events.values(), ["hide"])
        }
        let capture = CaptureStub {
            XCTAssertEqual(events.values(), ["hide"])
        }
        let coordinator = makeCoordinator(capture: capture, selection: selection)
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

    func testWindowShadowChoiceFromSelectionIsForwardedToCaptureRequest() async throws {
        let capture = CaptureStub {}
        let selection = SelectionStub(
            target: .window(windowID: 42),
            windowShadow: .excluded
        )
        let coordinator = makeCoordinator(capture: capture, selection: selection)

        _ = try await coordinator.route(.captureDefaultMode)

        XCTAssertEqual(capture.lastRequest?.mode, .window)
        XCTAssertEqual(capture.lastRequest?.target, .window(windowID: 42))
        XCTAssertEqual(capture.lastRequest?.windowShadow, .excluded)
    }

    func testAllDisplaysShortcutCapturesEveryAdvertisedDisplayAndCopiesArtifact() async throws {
        let capture = CaptureStub(
            content: ScreenshotSelectionContent(
                displays: [
                    .init(
                        id: 1,
                        frame: .init(x: 0, y: 0, width: 1440, height: 900),
                        pixelSize: .init(width: 2880, height: 1800),
                        scaleFactor: 2
                    ),
                    .init(
                        id: 2,
                        frame: .init(x: 1440, y: 0, width: 1920, height: 1080),
                        pixelSize: .init(width: 1920, height: 1080),
                        scaleFactor: 1
                    )
                ],
                windows: []
            ),
            artifact: makeArtifact(relativePath: "Captures/all.png"),
            handler: {}
        )
        let clipboard = ClipboardWriterStub()
        let configuration = ScreenshotFeatureConfiguration(
            history: .init(isEnabled: true, retentionDays: 7, maximumItemCount: 50)
        )
        let coordinator = makeCoordinator(
            capture: capture,
            clipboardWriter: clipboard,
            configuration: configuration
        )

        let result = try await coordinator.route(.captureAllDisplays)
        XCTAssertEqual(result, .completed)
        XCTAssertEqual(
            capture.lastRequest?.target,
            .allDisplays(displayIDs: [1, 2])
        )
        XCTAssertEqual(capture.lastRequest?.mode, .allDisplays)
        XCTAssertEqual(capture.lastRequest?.history, configuration.history)
        XCTAssertEqual(clipboard.artifacts.count, 1)
    }

    func testToolbarExtensionActionsAreRoutedWithoutCapturingAStillImage() async throws {
        let router = CaptureExtensionRouterStub()
        let scrollingCapture = CaptureStub {}
        let scrollingCoordinator = makeCoordinator(
            capture: scrollingCapture,
            extensionRouter: router,
            selection: SelectionStub(completionAction: .scrollingCapture)
        )

        let scrollingResult = try await scrollingCoordinator.route(.captureDefaultMode)
        XCTAssertEqual(scrollingResult, .completed)
        XCTAssertEqual(router.requests.map(\.kind), [.scrollingCapture])
        XCTAssertEqual(scrollingCapture.captureCount, 0)

        let gifRouter = CaptureExtensionRouterStub()
        let gifCapture = CaptureStub {}
        let gifCoordinator = makeCoordinator(
            capture: gifCapture,
            extensionRouter: gifRouter,
            selection: SelectionStub(completionAction: .gifRecording)
        )
        let gifResult = try await gifCoordinator.route(.captureDefaultMode)
        XCTAssertEqual(gifResult, .completed)
        XCTAssertEqual(gifRouter.requests.map(\.kind), [.gifRecording])
        XCTAssertEqual(gifCapture.captureCount, 0)
    }

    func testSelectionAnnotationsAreForwardedToCaptureRequest() async throws {
        let annotation = ScreenshotAnnotation(
            kind: .arrow,
            points: [.init(x: 5, y: 8), .init(x: 80, y: 60)],
            style: .init(color: .red, lineWidth: 3)
        )
        let capture = CaptureStub {}
        let selection = SelectionStub(annotations: [annotation])
        let coordinator = makeCoordinator(capture: capture, selection: selection)

        _ = try await coordinator.route(.captureDefaultMode)

        XCTAssertEqual(capture.lastRequest?.annotations, [annotation])
    }

    func testConfiguredDelayUsesVisibleCountdownThenCapturesImmediatelyWithConfiguredOutput() async throws {
        let capture = CaptureStub {}
        let countdown = CountdownPresenterStub()
        let configuration = ScreenshotFeatureConfiguration(
            defaultDelay: .fiveSeconds,
            output: .init(format: .jpeg, quality: 0.73),
            history: .init(
                isEnabled: true,
                retentionDays: 14,
                maximumItemCount: 120,
                trashRetentionHours: 12
            )
        )
        let coordinator = makeCoordinator(
            capture: capture,
            countdownPresenter: countdown,
            configuration: configuration
        )

        _ = try await coordinator.route(.captureDefaultMode)

        XCTAssertEqual(countdown.requestedDelays, [.fiveSeconds])
        XCTAssertEqual(capture.lastRequest?.delay, ScreenshotCaptureDelay.none)
        XCTAssertEqual(capture.lastRequest?.output, configuration.output)
        XCTAssertEqual(capture.lastRequest?.history, configuration.history)
    }

    func testNoDelaySkipsCountdown() async throws {
        let capture = CaptureStub {}
        let countdown = CountdownPresenterStub()
        let coordinator = makeCoordinator(
            capture: capture,
            countdownPresenter: countdown,
            configuration: .init(defaultDelay: .none)
        )

        _ = try await coordinator.route(.captureDefaultMode)

        XCTAssertTrue(countdown.requestedDelays.isEmpty)
        XCTAssertEqual(capture.captureCount, 1)
    }

    func testDeactivationCancelsVisibleCountdownBeforeAnyCaptureStarts() async {
        let capture = CaptureStub {}
        let countdown = BlockingCountdownPresenterStub()
        let coordinator = makeCoordinator(
            capture: capture,
            countdownPresenter: countdown,
            configuration: .init(defaultDelay: .tenSeconds)
        )
        let routeTask = Task { try await coordinator.route(.captureDefaultMode) }
        while !countdown.didStart {
            await Task.yield()
        }

        await coordinator.deactivate()
        _ = try? await routeTask.value

        XCTAssertGreaterThanOrEqual(countdown.cancelCount, 1)
        XCTAssertEqual(capture.captureCount, 0)
        XCTAssertEqual(coordinator.featureState(), .disabled)
    }

    func testCopyCompletionWritesReturnedCaptureArtifactToClipboard() async throws {
        let artifact = makeArtifact(relativePath: "Captures/copied.png")
        let capture = CaptureStub(artifact: artifact) {}
        let clipboard = ClipboardWriterStub()
        let coordinator = makeCoordinator(capture: capture, clipboardWriter: clipboard)

        _ = try await coordinator.route(.captureDefaultMode)

        XCTAssertEqual(clipboard.artifacts, [artifact])
    }

    func testPinCompletionPresentsArtifactWithoutOverwritingClipboard() async throws {
        let artifact = makeArtifact(relativePath: "Captures/pin.png")
        let capture = CaptureStub(artifact: artifact) {}
        let clipboard = ClipboardWriterStub()
        let pinPresenter = PinPresenterStub()
        let selection = SelectionStub(completionAction: .pin)
        let coordinator = makeCoordinator(
            capture: capture,
            clipboardWriter: clipboard,
            pinPresenter: pinPresenter,
            selection: selection
        )

        _ = try await coordinator.route(.captureDefaultMode)

        XCTAssertTrue(clipboard.artifacts.isEmpty)
        XCTAssertEqual(pinPresenter.artifacts, [artifact])
    }

    func testCaptureServiceWithoutArtifactRemainsCompatibleAndDoesNotWriteClipboard() async throws {
        let capture = CaptureStub {}
        let clipboard = ClipboardWriterStub()
        let coordinator = makeCoordinator(capture: capture, clipboardWriter: clipboard)

        _ = try await coordinator.route(.captureDefaultMode)

        XCTAssertEqual(capture.captureCount, 1)
        XCTAssertTrue(clipboard.artifacts.isEmpty)
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

    func testColorPickerUsesScreenRecordingAuthorization() async throws {
        let authorization = AuthorizationStub(status: .notRequested, requestResult: .denied)
        let picker = ColorPickerStub(color: .init(red: 12, green: 34, blue: 56))
        let coordinator = makeCoordinator(
            authorization: authorization,
            capture: CaptureStub(),
            colorPicker: picker
        )

        let result = try await coordinator.route(.pickColor)

        XCTAssertEqual(result, .requiresSetup(message: "请允许触达录制屏幕"))
        XCTAssertEqual(authorization.requestCount, 1)
        XCTAssertEqual(picker.pickCount, 0)
    }

    func testColorPickerCopiesSelectedColorAndLeavesLauncherHiddenAfterSuccess() async throws {
        let color = ScreenshotColor(red: 255, green: 128, blue: 0)
        let picker = ColorPickerStub(color: color)
        let clipboard = ColorClipboardWriterStub()
        let events = EventRecorder()
        let launcher = LauncherStub(isVisible: true, events: events)
        let coordinator = makeCoordinator(
            capture: CaptureStub(),
            colorClipboardWriter: clipboard,
            colorPicker: picker
        )
        coordinator.attachLauncher(launcher)

        let result = try await coordinator.route(.pickColor)

        XCTAssertEqual(result, .completed)
        XCTAssertEqual(picker.pickCount, 1)
        XCTAssertEqual(clipboard.colors, [color])
        XCTAssertEqual(events.values(), ["hide"])
        XCTAssertFalse(launcher.isLauncherVisible)
    }

    func testColorPickerCancellationDoesNotWriteClipboardAndRestoresLauncher() async throws {
        let picker = ColorPickerStub(color: nil)
        let clipboard = ColorClipboardWriterStub()
        let events = EventRecorder()
        let launcher = LauncherStub(isVisible: true, events: events)
        let coordinator = makeCoordinator(
            capture: CaptureStub(),
            colorClipboardWriter: clipboard,
            colorPicker: picker
        )
        coordinator.attachLauncher(launcher)

        let result = try await coordinator.route(.pickColor)

        XCTAssertEqual(result, .completed)
        XCTAssertTrue(clipboard.colors.isEmpty)
        XCTAssertEqual(events.values(), ["hide", "show"])
        XCTAssertTrue(launcher.isLauncherVisible)
    }

    func testDeactivationCancelsActiveColorPicker() async {
        let picker = BlockingColorPickerStub()
        let coordinator = makeCoordinator(capture: CaptureStub(), colorPicker: picker)
        let routeTask = Task { try await coordinator.route(.pickColor) }
        while !picker.didStart {
            await Task.yield()
        }

        await coordinator.deactivate()
        _ = try? await routeTask.value

        XCTAssertGreaterThanOrEqual(picker.cancelCount, 1)
        XCTAssertEqual(coordinator.featureState(), .disabled)
    }

    func testActiveColorPickerMakesOtherScreenshotActionsBusy() async {
        let picker = BlockingColorPickerStub()
        let coordinator = makeCoordinator(capture: CaptureStub(), colorPicker: picker)
        let routeTask = Task { try await coordinator.route(.pickColor) }
        while !picker.didStart {
            await Task.yield()
        }

        do {
            _ = try await coordinator.route(.captureDefaultMode)
            XCTFail("取色期间不应启动第二条截图流程")
        } catch let error as ScreenshotCoordinatorError {
            XCTAssertEqual(error, .busy)
        } catch {
            XCTFail("收到非预期错误：\(error)")
        }

        picker.cancel()
        _ = try? await routeTask.value
    }

    func testCancelledSelectionDoesNotCaptureAndRestoresLauncher() async throws {
        let events = EventRecorder()
        let launcher = LauncherStub(isVisible: true, events: events)
        let capture = CaptureStub {}
        let coordinator = makeCoordinator(
            capture: capture,
            selection: SelectionStub(target: nil)
        )
        coordinator.attachLauncher(launcher)

        let result = try await coordinator.route(.captureDefaultMode)

        XCTAssertEqual(result, .completed)
        XCTAssertEqual(capture.captureCount, 0)
        XCTAssertEqual(events.values(), ["hide", "show"])
        XCTAssertTrue(launcher.isLauncherVisible)
    }

    func testConcurrentCaptureIsBusyDuringSelectionAndDeactivationCancelsPresenter() async {
        let selection = BlockingSelectionStub()
        let capture = CaptureStub {}
        let coordinator = makeCoordinator(capture: capture, selection: selection)
        let routeTask = Task { try await coordinator.route(.captureDefaultMode) }
        while !selection.didStart {
            await Task.yield()
        }

        do {
            _ = try await coordinator.route(.captureDefaultMode)
            XCTFail("选择期间不应启动第二条截图流程")
        } catch let error as ScreenshotCoordinatorError {
            XCTAssertEqual(error, .busy)
        } catch {
            XCTFail("收到非预期错误：\(error)")
        }

        await coordinator.deactivate()
        _ = try? await routeTask.value

        XCTAssertGreaterThanOrEqual(selection.cancelCount, 1)
        XCTAssertEqual(capture.captureCount, 0)
        XCTAssertEqual(coordinator.featureState(), .disabled)
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

    func testRecognizeTextCapturesOCRRegionAndCopiesRecognizedText() async throws {
        let artifact = makeArtifact(relativePath: "Captures/ocr-region.png")
        let recognition = ScreenshotRecognitionResult(
            artifactID: artifact.id,
            fullText: "你好 Touch",
            textBlocks: [.init(
                text: "你好 Touch",
                confidence: 0.96,
                normalizedBounds: .init(x: 0.1, y: 0.2, width: 0.8, height: 0.2)
            )],
            barcodes: []
        )
        let capture = CaptureStub(artifact: artifact, recognitionResult: recognition)
        let textWriter = RecognizedTextClipboardWriterStub()
        let recognitionPresenter = RecognitionPresenterStub()
        let selection = SelectionStub(completionAction: .recognizeText)
        let configuration = ScreenshotFeatureConfiguration(
            ocr: .init(
                recognitionLanguages: ["zh-Hans", "en-US"],
                copiesRecognizedText: true,
                minimumTextConfidence: 0.45
            )
        )
        let coordinator = makeCoordinator(
            capture: capture,
            recognizedTextClipboardWriter: textWriter,
            recognitionPresenter: recognitionPresenter,
            selection: selection,
            configuration: configuration
        )

        let result = try await coordinator.route(.captureDefaultMode)

        XCTAssertEqual(result, .completed)
        XCTAssertEqual(capture.lastRequest?.mode, .ocrRegion)
        XCTAssertEqual(capture.lastRecognitionRequest?.artifact.id, artifact.id)
        XCTAssertEqual(capture.lastRecognitionRequest?.configuration, configuration.ocr)
        XCTAssertEqual(textWriter.texts, ["你好 Touch"])
        XCTAssertEqual(recognitionPresenter.artifacts, [artifact])
        XCTAssertEqual(recognitionPresenter.presentations, [.result(recognition)])
    }

    func testRecognitionFailureKeepsArtifactAndPresentsRetryableFailure() async throws {
        let artifact = makeArtifact(relativePath: "Captures/ocr-failed.png")
        let capture = CaptureStub(
            artifact: artifact,
            recognitionError: .recognitionFailed(message: "Vision 暂时不可用")
        )
        let recognitionPresenter = RecognitionPresenterStub()
        let coordinator = makeCoordinator(
            capture: capture,
            recognitionPresenter: recognitionPresenter,
            selection: SelectionStub(completionAction: .recognizeText)
        )

        let result = try await coordinator.route(.captureDefaultMode)

        XCTAssertEqual(result, .completed)
        XCTAssertEqual(capture.captureCount, 1)
        XCTAssertEqual(recognitionPresenter.artifacts, [artifact])
        guard case let .failure(message)? = recognitionPresenter.presentations.first else {
            return XCTFail("识别失败后应显示可重试结果面板")
        }
        XCTAssertTrue(message.contains("Vision 暂时不可用"))
        do {
            _ = try await recognitionPresenter.retry()
            XCTFail("失败后的重试应继续抛出识别错误")
        } catch {
            XCTAssertEqual(error as? ScreenshotFeatureError, .recognitionFailed(message: "Vision 暂时不可用"))
        }
    }

    func testRecognitionPanelRetryUsesOriginalArtifactAndCopiesNewResult() async throws {
        let artifact = makeArtifact(relativePath: "Captures/ocr-retry.png")
        let recognition = ScreenshotRecognitionResult(
            artifactID: artifact.id,
            fullText: "重试结果",
            textBlocks: [],
            barcodes: []
        )
        let capture = CaptureStub(artifact: artifact, recognitionResult: recognition)
        let textWriter = RecognizedTextClipboardWriterStub()
        let recognitionPresenter = RecognitionPresenterStub()
        let coordinator = makeCoordinator(
            capture: capture,
            recognizedTextClipboardWriter: textWriter,
            recognitionPresenter: recognitionPresenter,
            selection: SelectionStub(completionAction: .recognizeText)
        )

        _ = try await coordinator.route(.captureDefaultMode)
        let retried = try await recognitionPresenter.retry()

        XCTAssertEqual(retried, recognition)
        XCTAssertEqual(capture.recognitionCount, 2)
        XCTAssertEqual(capture.lastRecognitionRequest?.artifact, artifact)
        XCTAssertEqual(textWriter.texts, ["重试结果", "重试结果"])
    }

    private func makeCoordinator(
        authorization: AuthorizationStub = AuthorizationStub(status: .authorized),
        capture: CaptureStub,
        clipboardWriter: any ScreenshotClipboardWriting = ClipboardWriterStub(),
        colorClipboardWriter: any ScreenshotColorClipboardWriting = ColorClipboardWriterStub(),
        recognizedTextClipboardWriter: any ScreenshotRecognizedTextClipboardWriting = RecognizedTextClipboardWriterStub(),
        recognitionPresenter: any ScreenshotRecognitionPresenting = RecognitionPresenterStub(),
        pinPresenter: any ScreenshotPinPresenting = PinPresenterStub(),
        countdownPresenter: any ScreenshotCaptureCountdownPresenting = CountdownPresenterStub(),
        extensionRouter: any ScreenshotCaptureExtensionRouting = PendingScreenshotCaptureExtensionRouter(),
        selection: any ScreenshotSelectionPresenting = SelectionStub(),
        colorPicker: any ScreenshotColorPickerPresenting = ColorPickerStub(color: nil),
        configuration: ScreenshotFeatureConfiguration = .init(),
        invalidateService: @escaping @Sendable () async -> Void = {},
        registerShortcuts: @escaping @MainActor @Sendable () -> Void = {},
        unregisterShortcuts: @escaping @MainActor @Sendable () -> Void = {}
    ) -> ScreenshotCoordinator {
        ScreenshotCoordinator(
            authorization: authorization,
            captureService: capture,
            clipboardWriter: clipboardWriter,
            colorClipboardWriter: colorClipboardWriter,
            recognizedTextClipboardWriter: recognizedTextClipboardWriter,
            recognitionPresenter: recognitionPresenter,
            pinPresenter: pinPresenter,
            countdownPresenter: countdownPresenter,
            extensionRouter: extensionRouter,
            selectionFactory: { selection },
            colorPickerFactory: { colorPicker },
            configurationProvider: { configuration },
            invalidateService: invalidateService,
            registerShortcuts: registerShortcuts,
            unregisterShortcuts: unregisterShortcuts
        )
    }


    private func makeArtifact(relativePath: String) -> ScreenshotArtifact {
        ScreenshotArtifact(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            captureMode: .region,
            relativePath: relativePath,
            thumbnailRelativePath: nil,
            pointSize: .init(width: 300, height: 200),
            pixelSize: .init(width: 600, height: 400),
            uniformTypeIdentifier: "public.png",
            sha256: "test-sha",
            displays: []
        )
    }
}

@MainActor
private final class CountdownPresenterStub: ScreenshotCaptureCountdownPresenting {
    private(set) var requestedDelays: [ScreenshotCaptureDelay] = []
    private(set) var cancelCount = 0

    func wait(for delay: ScreenshotCaptureDelay) async throws {
        requestedDelays.append(delay)
    }

    func cancel() {
        cancelCount += 1
    }
}

@MainActor
private final class BlockingCountdownPresenterStub: ScreenshotCaptureCountdownPresenting {
    private var continuation: CheckedContinuation<Void, any Error>?
    private(set) var didStart = false
    private(set) var cancelCount = 0

    func wait(for delay: ScreenshotCaptureDelay) async throws {
        didStart = true
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func cancel() {
        cancelCount += 1
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(throwing: CancellationError())
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
    private let artifact: ScreenshotArtifact?
    private let recognitionResult: ScreenshotRecognitionResult?
    private let recognitionError: ScreenshotFeatureError?
    private let content: ScreenshotSelectionContent
    private var storedCaptureCount = 0
    private var storedLastRequest: ScreenshotCaptureRequest?
    private var storedLastRecognitionRequest: ScreenshotRecognitionRequest?
    private var storedRecognitionCount = 0

    init(
        content: ScreenshotSelectionContent? = nil,
        artifact: ScreenshotArtifact? = nil,
        recognitionResult: ScreenshotRecognitionResult? = nil,
        recognitionError: ScreenshotFeatureError? = nil,
        handler: @escaping @Sendable () async throws -> Void = {}
    ) {
        self.content = content ?? ScreenshotSelectionContent(
            displays: [
                .init(
                    id: 1,
                    frame: .init(x: 0, y: 0, width: 1440, height: 900),
                    pixelSize: .init(width: 2880, height: 1800),
                    scaleFactor: 2
                )
            ],
            windows: []
        )
        self.artifact = artifact
        self.recognitionResult = recognitionResult
        self.recognitionError = recognitionError
        self.handler = handler
    }

    var captureCount: Int { lock.withLock { storedCaptureCount } }
    var lastRequest: ScreenshotCaptureRequest? { lock.withLock { storedLastRequest } }
    var lastRecognitionRequest: ScreenshotRecognitionRequest? {
        lock.withLock { storedLastRecognitionRequest }
    }
    var recognitionCount: Int { lock.withLock { storedRecognitionCount } }

    func availableSelectionContent() async throws -> ScreenshotSelectionContent {
        content
    }

    func capture(_ request: ScreenshotCaptureRequest) async throws {
        lock.withLock {
            storedCaptureCount += 1
            storedLastRequest = request
        }
        try await handler()
    }

    func captureArtifact(_ request: ScreenshotCaptureRequest) async throws -> ScreenshotArtifact? {
        try await capture(request)
        return artifact
    }

    func recognize(_ request: ScreenshotRecognitionRequest) async throws -> ScreenshotRecognitionResult {
        lock.withLock {
            storedLastRecognitionRequest = request
            storedRecognitionCount += 1
        }
        if let recognitionError { throw recognitionError }
        guard let recognitionResult else { throw ScreenshotFeatureError.targetUnavailable }
        return recognitionResult
    }

    func capturePrimaryDisplay() async throws {
        try await capture(.init(mode: .fullScreen, target: .display(displayID: 1)))
    }
}

@MainActor
private final class CaptureExtensionRouterStub: ScreenshotCaptureExtensionRouting {
    private(set) var requests: [ScreenshotCaptureExtensionRequest] = []

    func start(_ request: ScreenshotCaptureExtensionRequest) async throws -> FeatureActionResult {
        requests.append(request)
        return .completed
    }

    func cancel() {}
}

@MainActor
private final class ClipboardWriterStub: ScreenshotClipboardWriting {
    private(set) var artifacts: [ScreenshotArtifact] = []

    func write(_ artifact: ScreenshotArtifact) throws {
        artifacts.append(artifact)
    }
}

@MainActor
private final class ColorClipboardWriterStub: ScreenshotColorClipboardWriting {
    private(set) var colors: [ScreenshotColor] = []

    func write(_ color: ScreenshotColor) throws {
        colors.append(color)
    }
}

@MainActor
private final class RecognizedTextClipboardWriterStub: ScreenshotRecognizedTextClipboardWriting {
    private(set) var texts: [String] = []

    func writeRecognizedText(_ text: String) throws {
        texts.append(text)
    }
}

@MainActor
private final class RecognitionPresenterStub: ScreenshotRecognitionPresenting {
    private(set) var artifacts: [ScreenshotArtifact] = []
    private(set) var presentations: [ScreenshotRecognitionPresentation] = []
    private(set) var dismissCount = 0
    private var retryAction: RetryAction?

    func present(
        artifact: ScreenshotArtifact,
        presentation: ScreenshotRecognitionPresentation,
        retry: @escaping RetryAction
    ) {
        artifacts.append(artifact)
        presentations.append(presentation)
        retryAction = retry
    }

    func dismiss() {
        dismissCount += 1
    }

    func retry() async throws -> ScreenshotRecognitionResult {
        guard let retryAction else { throw ScreenshotFeatureError.targetUnavailable }
        return try await retryAction()
    }
}

@MainActor
private final class ColorPickerStub: ScreenshotColorPickerPresenting {
    var color: ScreenshotColor?
    private(set) var pickCount = 0
    private(set) var cancelCount = 0

    init(color: ScreenshotColor?) {
        self.color = color
    }

    func pick(from content: ScreenshotSelectionContent) async -> ScreenshotColor? {
        pickCount += 1
        return color
    }

    func cancel() {
        cancelCount += 1
    }
}

@MainActor
private final class BlockingColorPickerStub: ScreenshotColorPickerPresenting {
    private var continuation: CheckedContinuation<ScreenshotColor?, Never>?
    private(set) var didStart = false
    private(set) var cancelCount = 0

    func pick(from content: ScreenshotSelectionContent) async -> ScreenshotColor? {
        didStart = true
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func cancel() {
        cancelCount += 1
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(returning: nil)
    }
}

@MainActor
private final class PinPresenterStub: ScreenshotPinPresenting {
    private(set) var artifacts: [ScreenshotArtifact] = []

    func pin(_ artifact: ScreenshotArtifact) throws {
        artifacts.append(artifact)
    }
}

@MainActor
private final class SelectionStub: ScreenshotSelectionPresenting {
    var result: ScreenshotSelectionResult?
    private(set) var cancelCount = 0
    private let onSelect: @MainActor () -> Void

    init(target: ScreenshotCaptureTarget? = .region(
        displayID: 1,
        rect: .init(x: 10, y: 20, width: 300, height: 200)
    ), windowShadow: ScreenshotWindowShadow = .included,
         completionAction: ScreenshotSelectionCompletionAction = .copy,
         annotations: [ScreenshotAnnotation] = [],
         onSelect: @escaping @MainActor () -> Void = {}) {
        result = target.map {
            ScreenshotSelectionResult(
                target: $0,
                completionAction: completionAction,
                windowShadow: windowShadow,
                annotations: annotations
            )
        }
        self.onSelect = onSelect
    }

    func select(from content: ScreenshotSelectionContent) async -> ScreenshotSelectionResult? {
        onSelect()
        return result
    }

    func cancel() {
        cancelCount += 1
    }
}

@MainActor
private final class BlockingSelectionStub: ScreenshotSelectionPresenting {
    private var continuation: CheckedContinuation<ScreenshotSelectionResult?, Never>?
    private(set) var didStart = false
    private(set) var cancelCount = 0

    func select(from content: ScreenshotSelectionContent) async -> ScreenshotSelectionResult? {
        didStart = true
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func cancel() {
        cancelCount += 1
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(returning: nil)
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
