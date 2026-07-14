import Foundation
import Testing
@testable import ScreenshotFeature

@Test func screenshotRequestRoundTripsEveryModeAndDelay() throws {
    for mode in ScreenshotCaptureMode.allCases {
        for delay in ScreenshotCaptureDelay.allCases {
            let request = ScreenshotCaptureRequest(
                id: UUID(uuidString: "A1B2C3D4-E5F6-4789-ABCD-0123456789AB")!,
                mode: mode,
                delay: delay,
                target: .region(
                    displayID: 42,
                    rect: ScreenshotRect(x: -320, y: 120, width: 1440, height: 900)
                ),
                windowShadow: .included,
                output: ScreenshotOutputOptions(format: .png, quality: 0.92),
                history: .init(
                    isEnabled: false,
                    retentionDays: 14,
                    maximumItemCount: 120,
                    trashRetentionHours: 12,
                    keepsFilesWhenDisabled: false
                )
            )

            let data = try JSONEncoder().encode(request)
            #expect(try JSONDecoder().decode(ScreenshotCaptureRequest.self, from: data) == request)
        }
    }
}

@Test func legacyScreenshotRequestDefaultsMissingHistoryConfiguration() throws {
    let request = ScreenshotCaptureRequest(
        mode: .region,
        target: .region(
            displayID: 42,
            rect: ScreenshotRect(x: 10, y: 20, width: 300, height: 200)
        )
    )
    let encoded = try JSONEncoder().encode(request)
    var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object.removeValue(forKey: "history")
    let legacyData = try JSONSerialization.data(withJSONObject: object)

    let decoded = try JSONDecoder().decode(ScreenshotCaptureRequest.self, from: legacyData)

    #expect(decoded.history == ScreenshotHistoryConfiguration())
}

@Test func screenshotArtifactPreservesDisplayAndPixelMetadata() throws {
    let artifact = ScreenshotArtifact(
        id: UUID(uuidString: "0D8137C8-5319-4A10-BD74-D548367B6216")!,
        createdAt: Date(timeIntervalSince1970: 1_789_000_000),
        captureMode: .allDisplays,
        relativePath: "Captures/2026/07/capture.png",
        thumbnailRelativePath: "Thumbnails/2026/07/capture.png",
        pointSize: ScreenshotSize(width: 2880, height: 1800),
        pixelSize: ScreenshotSize(width: 5760, height: 3600),
        uniformTypeIdentifier: "public.png",
        sha256: String(repeating: "a", count: 64),
        displays: [
            ScreenshotDisplayDescriptor(
                id: 1,
                frame: ScreenshotRect(x: 0, y: 0, width: 1440, height: 900),
                pixelSize: ScreenshotSize(width: 2880, height: 1800),
                scaleFactor: 2
            )
        ]
    )

    let data = try JSONEncoder().encode(artifact)
    #expect(try JSONDecoder().decode(ScreenshotArtifact.self, from: data) == artifact)
}

@Test func screenshotErrorsRemainStructuredAcrossSerialization() throws {
    let errors: [ScreenshotFeatureError] = [
        .permissionDenied,
        .cancelled,
        .noDisplayAvailable,
        .targetUnavailable,
        .serviceTimedOut,
        .serviceInterrupted,
        .encodingFailed,
        .storageFailed(message: "disk full"),
        .migrationFailed(message: "schema 2"),
        .incompatibleProtocol(expected: 2, received: 3),
        .responseMismatch(
            expected: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            received: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        ),
        .unsupportedAction(action: "capture"),
        .serviceFailed(message: "unavailable"),
        .serviceIsolated
    ]

    for error in errors {
        let data = try JSONEncoder().encode(error)
        #expect(try JSONDecoder().decode(ScreenshotFeatureError.self, from: data) == error)
    }
}

@Test func screenshotFeaturePathsRejectTraversalAndSymlinkEscape() throws {
    let fileManager = FileManager.default
    let temporary = fileManager.temporaryDirectory
        .appendingPathComponent("ScreenshotFeaturePathsTests-\(UUID().uuidString)", isDirectory: true)
    let root = temporary.appendingPathComponent("Screenshot", isDirectory: true)
    let outside = temporary.appendingPathComponent("Outside", isDirectory: true)
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: temporary) }

    let paths = ScreenshotFeaturePaths(rootURL: root)
    let valid = try paths.resolve(relativePath: "Captures/2026/capture.png")
    #expect(valid.path.hasPrefix(root.path + "/"))
    #expect(throws: ScreenshotFeaturePathError.self) {
        try paths.resolve(relativePath: "../me.touch.finder/private.sqlite")
    }
    #expect(throws: ScreenshotFeaturePathError.self) {
        try paths.resolve(relativePath: outside.path)
    }
    #expect(throws: ScreenshotFeaturePathError.self) {
        try paths.resolve(relativePath: ".")
    }

    let link = root.appendingPathComponent("link", isDirectory: true)
    try fileManager.createSymbolicLink(at: link, withDestinationURL: outside)
    #expect(throws: ScreenshotFeaturePathError.self) {
        try paths.resolve(relativePath: "link/escaped.png")
    }
    #expect(throws: ScreenshotFeaturePathError.self) {
        try paths.relativePath(for: link.appendingPathComponent("escaped.png"))
    }
}
