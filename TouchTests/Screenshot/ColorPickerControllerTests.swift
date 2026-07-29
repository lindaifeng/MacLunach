import CoreGraphics
import Foundation
import ScreenshotFeature
import XCTest
@testable import 触达

@MainActor
final class ColorPickerControllerTests: XCTestCase {
    func testRapidMovementCoalescesToLatestPointWithoutConcurrentCaptures() async throws {
        let capture = ColorSampleCaptureProbe { request in
            request.desktopPoint.x == 3 ? .milliseconds(5) : .milliseconds(40)
        }
        var acceptedPoints: [CGPoint] = []
        let controller = ColorPickerController(
            captureService: capture,
            minimumSampleInterval: .zero,
            sampleAcceptedHandler: { _, point, _ in acceptedPoints.append(point) }
        )

        controller.mouseMoved(on: 1, to: .init(x: 1, y: 10))
        try await waitUntil { await capture.requestCount >= 1 }
        controller.mouseMoved(on: 1, to: .init(x: 2, y: 10))
        controller.mouseMoved(on: 1, to: .init(x: 3, y: 10))

        try await waitUntil { acceptedPoints.count == 1 }

        XCTAssertEqual(acceptedPoints, [.init(x: 3, y: 10)])
        let requests = await capture.requests
        let maximumConcurrentRequestCount = await capture.maximumConcurrentRequestCount
        let cancellationCount = await capture.cancellationCount
        XCTAssertEqual(requests.map(\.desktopPoint.x), [1, 3])
        XCTAssertEqual(maximumConcurrentRequestCount, 1)
        XCTAssertEqual(cancellationCount, 0)
    }

    func testMouseMovementSamplingIsThrottled() async throws {
        let capture = ColorSampleCaptureProbe { _ in .zero }
        var acceptedPoints: [CGPoint] = []
        let controller = ColorPickerController(
            captureService: capture,
            minimumSampleInterval: .milliseconds(120),
            sampleAcceptedHandler: { _, point, _ in acceptedPoints.append(point) }
        )

        controller.mouseMoved(on: 1, to: .init(x: 1, y: 10))
        try await waitUntil { acceptedPoints.count == 1 }
        controller.mouseMoved(on: 1, to: .init(x: 2, y: 10))

        try await Task.sleep(for: .milliseconds(35))
        let requestCountDuringThrottle = await capture.requestCount
        XCTAssertEqual(requestCountDuringThrottle, 1)

        try await waitUntil(timeout: .seconds(1)) { await capture.requestCount == 2 }
        try await waitUntil { acceptedPoints.count == 2 }
        XCTAssertEqual(acceptedPoints.last, .init(x: 2, y: 10))
    }

    func testMouseDownBypassesMovementThrottleAndLocksFreshSampleUntilConfirmation() async throws {
        let capture = ColorSampleCaptureProbe { _ in .zero }
        var acceptedPoints: [CGPoint] = []
        let controller = ColorPickerController(
            captureService: capture,
            minimumSampleInterval: .seconds(5),
            sampleAcceptedHandler: { _, point, _ in acceptedPoints.append(point) }
        )

        controller.mouseMoved(on: 1, to: .init(x: 1, y: 10))
        try await waitUntil { acceptedPoints.count == 1 }
        controller.mouseDown(on: 1, at: .init(x: 2, y: 10))

        try await waitUntil(timeout: .milliseconds(250)) { await capture.requestCount == 2 }
        try await waitUntil { acceptedPoints.count == 2 }
        XCTAssertEqual(acceptedPoints.last, .init(x: 2, y: 10))
        XCTAssertEqual(controller.confirmLockedColor(), .init(red: 2, green: 0, blue: 0))
    }

    func testLockedColorIgnoresPointerMovementAndCopiesRGBText() async throws {
        let capture = ColorSampleCaptureProbe { _ in .zero }
        let controller = ColorPickerController(
            captureService: capture,
            minimumSampleInterval: .zero
        )

        controller.mouseDown(on: 1, at: .init(x: 18, y: 10))
        try await waitUntil { await capture.requestCount == 1 }
        try await Task.sleep(for: .milliseconds(20))
        controller.mouseMoved(on: 1, to: .init(x: 42, y: 10))
        try await Task.sleep(for: .milliseconds(20))

        let requestCount = await capture.requestCount
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(
            SystemScreenshotColorClipboardWriter.copyText(for: .init(red: 18, green: 0, blue: 0)),
            "RGB(18, 0, 0)"
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @MainActor () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !(await condition()) {
            if ContinuousClock.now >= deadline {
                XCTFail("等待异步条件超时")
                throw ColorPickerControllerTestError.timeout
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private enum ColorPickerControllerTestError: Error {
    case timeout
}

private actor ColorSampleCaptureProbe: ScreenshotCapturing {
    typealias DelayProvider = @Sendable (ScreenshotColorSampleRequest) -> Duration

    private let delayProvider: DelayProvider
    private(set) var requests: [ScreenshotColorSampleRequest] = []
    private(set) var cancellationCount = 0
    private(set) var maximumConcurrentRequestCount = 0
    private var activeRequestCount = 0

    init(delayProvider: @escaping DelayProvider) {
        self.delayProvider = delayProvider
    }

    var requestCount: Int { requests.count }

    func availableSelectionContent() async throws -> ScreenshotSelectionContent {
        .init(displays: [], windows: [])
    }

    func capture(_ request: ScreenshotCaptureRequest) async throws {}

    func capturePrimaryDisplay() async throws {}

    func sampleColor(
        _ request: ScreenshotColorSampleRequest
    ) async throws -> ScreenshotColorSample {
        requests.append(request)
        activeRequestCount += 1
        maximumConcurrentRequestCount = max(maximumConcurrentRequestCount, activeRequestCount)
        defer { activeRequestCount -= 1 }
        do {
            let delay = delayProvider(request)
            if delay > .zero {
                try await Task.sleep(for: delay)
            }
            let component = UInt8(clamping: Int(request.desktopPoint.x))
            return .init(
                color: .init(red: component, green: 0, blue: 0),
                loupeRGBA: Data([component, 0, 0, 255]),
                loupePixelSize: .init(width: 1, height: 1),
                centerPixel: .init(x: 0, y: 0)
            )
        } catch is CancellationError {
            cancellationCount += 1
            throw CancellationError()
        }
    }
}
