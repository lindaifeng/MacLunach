import ScreenshotFeature
import XCTest
@testable import 触达

@MainActor
final class AnnotationExportOptionsTests: XCTestCase {
    func testEveryFormatHasMatchingContentTypeExtensionAndOutput() {
        let cases: [(ScreenshotImageFormat, String, String)] = [
            (.png, "png", "public.png"),
            (.jpeg, "jpg", "public.jpeg"),
            (.heif, "heic", "public.heic")
        ]

        for (format, pathExtension, contentTypeIdentifier) in cases {
            let options = AnnotationExportOptions(format: format, quality: 0.73)

            XCTAssertEqual(options.preferredFilenameExtension, pathExtension)
            XCTAssertEqual(options.contentType.identifier, contentTypeIdentifier)
            XCTAssertEqual(options.outputOptions.format, format)
            XCTAssertEqual(options.outputOptions.quality, format == .png ? 1 : 0.73)
        }
    }

    func testSuggestedNameAndFormatChangesReplaceOnlyExtension() {
        let sourceURL = URL(fileURLWithPath: "/tmp/example.capture.png")
        let options = AnnotationExportOptions(format: .png)

        XCTAssertEqual(options.suggestedFileName(for: sourceURL), "example.capture-标注.png")

        options.format = .jpeg
        XCTAssertEqual(options.replacingExtension(in: "自定义.名称.png"), "自定义.名称.jpg")

        options.format = .heif
        XCTAssertEqual(options.replacingExtension(in: "没有扩展名"), "没有扩展名.heic")
    }

    func testQualityIsClampedAndPNGAlwaysUsesLosslessQuality() {
        let low = AnnotationExportOptions(format: .jpeg, quality: -1)
        XCTAssertEqual(low.outputOptions.quality, 0.1)
        XCTAssertEqual(low.qualityPercentage, 10)

        let high = AnnotationExportOptions(format: .heif, quality: 2)
        XCTAssertEqual(high.outputOptions.quality, 1)
        XCTAssertEqual(high.qualityPercentage, 100)

        let invalid = AnnotationExportOptions(format: .jpeg, quality: .nan)
        XCTAssertEqual(invalid.outputOptions.quality, 0.92)

        invalid.format = .png
        invalid.quality = 0.2
        XCTAssertEqual(invalid.outputOptions.quality, 1)
    }
}
