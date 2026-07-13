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
        _ = try await client.capture(request)
    }

    public func capturePrimaryDisplay() async throws {
        let request = ScreenshotCaptureRequest(
            mode: .fullScreen,
            target: .display(displayID: CGMainDisplayID())
        )
        try await capture(request)
    }
}
