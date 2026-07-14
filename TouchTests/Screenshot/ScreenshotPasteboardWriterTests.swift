import AppKit
import ScreenshotFeature
import XCTest
@testable import 触达

@MainActor
final class ScreenshotPasteboardWriterTests: XCTestCase {
    func testWritesPNGAndTIFFAndFileURLAsOneItem() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let captureURL = root.appendingPathComponent("Captures/capture.png")
        try FileManager.default.createDirectory(
            at: captureURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try makePNGData().write(to: captureURL)
        let pasteboard = NSPasteboard(name: .init("touch.screenshot.pasteboard.\(UUID().uuidString)"))
        let writer = ScreenshotPasteboardWriter(
            pathsProvider: { ScreenshotFeaturePaths(rootURL: root) },
            pasteboard: pasteboard
        )

        try writer.write(makeArtifact(relativePath: "Captures/capture.png"))

        let item = try XCTUnwrap(pasteboard.pasteboardItems?.first)
        XCTAssertNotNil(item.data(forType: .png))
        XCTAssertNotNil(item.data(forType: .tiff))
        XCTAssertEqual(item.string(forType: .fileURL), captureURL.absoluteString)
        XCTAssertEqual(pasteboard.pasteboardItems?.count, 1)
    }

    func testUnreadableArtifactDoesNotClearExistingPasteboard() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let pasteboard = NSPasteboard(name: .init("touch.screenshot.pasteboard.\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("用户原有内容", forType: .string)
        let writer = ScreenshotPasteboardWriter(
            pathsProvider: { ScreenshotFeaturePaths(rootURL: root) },
            pasteboard: pasteboard
        )

        XCTAssertThrowsError(try writer.write(makeArtifact(relativePath: "missing.png")))
        XCTAssertEqual(pasteboard.string(forType: .string), "用户原有内容")
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("touch-pasteboard-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func makePNGData() throws -> Data {
        let image = NSImage(size: NSSize(width: 4, height: 3))
        image.lockFocus()
        NSColor.systemPurple.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 4, height: 3)).fill()
        image.unlockFocus()
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    private func makeArtifact(relativePath: String) -> ScreenshotArtifact {
        ScreenshotArtifact(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            captureMode: .region,
            relativePath: relativePath,
            thumbnailRelativePath: nil,
            pointSize: .init(width: 4, height: 3),
            pixelSize: .init(width: 4, height: 3),
            uniformTypeIdentifier: "public.png",
            sha256: "test-sha",
            displays: []
        )
    }
}
