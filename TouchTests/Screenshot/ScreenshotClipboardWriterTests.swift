import AppKit
import ScreenshotFeature
import XCTest
@testable import 触达

@MainActor
final class ScreenshotClipboardWriterTests: XCTestCase {
    func testWritesResolvedCaptureImage() throws {
        let root = temporaryRoot()
        let captureURL = root
            .appendingPathComponent("Captures", isDirectory: true)
            .appendingPathComponent("capture.png")
        try FileManager.default.createDirectory(
            at: captureURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try makePNGData().write(to: captureURL)

        var didWriteImage = false
        let writer = SystemScreenshotClipboardWriter(
            pathsProvider: { ScreenshotFeaturePaths(rootURL: root) },
            imageWriter: { image in
                didWriteImage = image.size.width > 0 && image.size.height > 0
                return true
            }
        )

        try writer.write(makeArtifact(relativePath: "Captures/capture.png"))

        XCTAssertTrue(didWriteImage)
    }

    func testRejectsTraversalBeforeReadingImage() {
        let root = temporaryRoot()
        let writer = SystemScreenshotClipboardWriter(
            pathsProvider: { ScreenshotFeaturePaths(rootURL: root) },
            imageWriter: { _ in
                XCTFail("越界路径不应进入剪贴板写入阶段")
                return true
            }
        )

        XCTAssertThrowsError(try writer.write(makeArtifact(relativePath: "../outside.png"))) { error in
            XCTAssertEqual(error as? ScreenshotFeaturePathError, .traversalNotAllowed)
        }
    }

    func testReportsPasteboardFailure() throws {
        let root = temporaryRoot()
        let captureURL = root.appendingPathComponent("capture.png")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try makePNGData().write(to: captureURL)
        let writer = SystemScreenshotClipboardWriter(
            pathsProvider: { ScreenshotFeaturePaths(rootURL: root) },
            imageWriter: { _ in false }
        )

        XCTAssertThrowsError(try writer.write(makeArtifact(relativePath: "capture.png"))) { error in
            XCTAssertEqual(error as? ScreenshotClipboardError, .pasteboardWriteFailed)
        }
    }

    private func temporaryRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("touch-clipboard-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func makePNGData() throws -> Data {
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 2, height: 2)).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw ScreenshotClipboardError.imageUnreadable(relativePath: "fixture")
        }
        return png
    }

    private func makeArtifact(relativePath: String) -> ScreenshotArtifact {
        ScreenshotArtifact(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            captureMode: .region,
            relativePath: relativePath,
            thumbnailRelativePath: nil,
            pointSize: .init(width: 2, height: 2),
            pixelSize: .init(width: 2, height: 2),
            uniformTypeIdentifier: "public.png",
            sha256: "test-sha",
            displays: []
        )
    }
}
