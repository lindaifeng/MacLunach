import CoreGraphics
import Foundation

public actor XPCScreenCaptureService: ScreenshotCapturing {
    private let client: ScreenshotClient

    public init(client: ScreenshotClient) {
        self.client = client
    }

    public func capturePrimaryDisplay() async throws {
        let request = ScreenshotCaptureRequest(
            mode: .fullScreen,
            target: .display(displayID: CGMainDisplayID())
        )
        _ = try await client.capture(request)
    }
}
