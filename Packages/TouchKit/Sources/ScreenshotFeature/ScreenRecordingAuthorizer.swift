import AppKit
import CoreGraphics
import Foundation

public protocol ScreenshotCapturing: Sendable {
    func availableSelectionContent() async throws -> ScreenshotSelectionContent
    func capture(_ request: ScreenshotCaptureRequest) async throws
    func captureArtifact(_ request: ScreenshotCaptureRequest) async throws -> ScreenshotArtifact?
    func sampleColor(_ request: ScreenshotColorSampleRequest) async throws -> ScreenshotColorSample
    func recognize(_ request: ScreenshotRecognitionRequest) async throws -> ScreenshotRecognitionResult
    func capturePrimaryDisplay() async throws
}

public extension ScreenshotCapturing {
    func availableSelectionContent() async throws -> ScreenshotSelectionContent {
        throw ScreenshotFeatureError.targetUnavailable
    }

    func capture(_ request: ScreenshotCaptureRequest) async throws {
        try await capturePrimaryDisplay()
    }

    /// 捕获并返回可供主应用继续处理的产物。
    ///
    /// 默认实现保持旧的捕获服务与测试夹具兼容；真实 XPC 服务会覆盖此方法并返回产物。
    func captureArtifact(_ request: ScreenshotCaptureRequest) async throws -> ScreenshotArtifact? {
        try await capture(request)
        return nil
    }

    func sampleColor(_ request: ScreenshotColorSampleRequest) async throws -> ScreenshotColorSample {
        throw ScreenshotFeatureError.targetUnavailable
    }

    func recognize(_ request: ScreenshotRecognitionRequest) async throws -> ScreenshotRecognitionResult {
        throw ScreenshotFeatureError.targetUnavailable
    }
}

@MainActor
public protocol ScreenRecordingAuthorizing: AnyObject, Sendable {
    var status: ScreenshotPermissionState { get }
    func requestAccess() -> ScreenshotPermissionState
    func openSystemSettings()
}

@MainActor
public final class SystemScreenRecordingAuthorizer: ScreenRecordingAuthorizing {
    public static let requestRecordedKey = "me.touch.screenshot.screen-recording-requested.v1"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var status: ScreenshotPermissionState {
        if CGPreflightScreenCaptureAccess() {
            return .authorized
        }
        return defaults.bool(forKey: Self.requestRecordedKey) ? .denied : .notRequested
    }

    public func requestAccess() -> ScreenshotPermissionState {
        guard status == .notRequested else { return status }
        defaults.set(true, forKey: Self.requestRecordedKey)
        return CGRequestScreenCaptureAccess() ? .authorized : .denied
    }

    public func openSystemSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}
