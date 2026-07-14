import CoreGraphics
import Foundation

public actor XPCScreenCaptureService: ScreenshotCapturing {
    private let client: ScreenshotClient

    public init(client: ScreenshotClient) {
        self.client = client
    }

    public func availableSelectionContent() async throws -> ScreenshotSelectionContent {
        try await client.availableSelectionContent()
    }

    public func capture(_ request: ScreenshotCaptureRequest) async throws {
        _ = try await captureArtifact(request)
    }

    public func captureArtifact(_ request: ScreenshotCaptureRequest) async throws -> ScreenshotArtifact? {
        try await client.capture(request)
    }

    public func sampleColor(_ request: ScreenshotColorSampleRequest) async throws -> ScreenshotColorSample {
        try await client.sampleColor(request)
    }

    public func recognize(_ request: ScreenshotRecognitionRequest) async throws -> ScreenshotRecognitionResult {
        try await client.recognize(request)
    }

    public func capturePrimaryDisplay() async throws {
        let request = ScreenshotCaptureRequest(
            mode: .fullScreen,
            target: .display(displayID: CGMainDisplayID())
        )
        try await capture(request)
    }
}
