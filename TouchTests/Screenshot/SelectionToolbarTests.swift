import AppKit
import CoreGraphics
import ScreenshotFeature
import XCTest
@testable import 触达

final class SelectionToolbarTests: XCTestCase {
    @MainActor
    func testPinnedImageUsesOriginalPixelsAndOnlyOverlaysOpacitySlider() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "touch-pin-test-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let captureDirectory = root.appendingPathComponent("Captures", isDirectory: true)
        try FileManager.default.createDirectory(
            at: captureDirectory,
            withIntermediateDirectories: true
        )
        let imageURL = captureDirectory.appendingPathComponent("pin.png")
        let representation = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 800,
            pixelsHigh: 400,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
        NSColor.systemRed.setFill()
        NSBezierPath(rect: CGRect(x: 0, y: 0, width: 800, height: 400)).fill()
        NSGraphicsContext.restoreGraphicsState()
        try XCTUnwrap(representation.representation(using: .png, properties: [:])).write(to: imageURL)

        let id = UUID()
        let artifact = ScreenshotArtifact(
            id: id,
            createdAt: Date(),
            captureMode: .region,
            relativePath: "Captures/pin.png",
            thumbnailRelativePath: nil,
            pointSize: .init(width: 400, height: 200),
            pixelSize: .init(width: 800, height: 400),
            uniformTypeIdentifier: "public.png",
            sha256: "test",
            displays: []
        )
        let manager = ScreenshotPinWindowManager(pathsProvider: {
            ScreenshotFeaturePaths(rootURL: root)
        })
        try manager.pin(
            artifact,
            preferredFrame: CGRect(x: 180, y: 220, width: 400, height: 200)
        )
        let panel = try XCTUnwrap(NSApp.windows.first {
            $0.identifier?.rawValue == "screenshot.pin.\(id.uuidString)"
        })
        defer { panel.close() }
        let identifiers = Set(descendants(of: try XCTUnwrap(panel.contentView)).compactMap {
            $0.identifier?.rawValue
        })

        XCTAssertTrue(identifiers.contains("screenshot.pin.opacity"))
        XCTAssertFalse(identifiers.contains("screenshot.pin.scale"))
        XCTAssertEqual(panel.frame.width, 400, accuracy: 0.5)
        XCTAssertEqual(
            panel.frame.height,
            200 + ScreenshotPinLayout.controlBarHeight,
            accuracy: 0.5
        )
        XCTAssertEqual(panel.frame.minX, 180, accuracy: 0.5)
        XCTAssertEqual(panel.frame.maxY, 420, accuracy: 0.5)
        XCTAssertLessThanOrEqual(ScreenshotPinLayout.controlBarHeight, 40)

        let initialWidth = panel.frame.width
        let cgEvent = try XCTUnwrap(CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 1,
            wheel1: 8,
            wheel2: 0,
            wheel3: 0
        ))
        let scrollEvent = try XCTUnwrap(NSEvent(cgEvent: cgEvent))
        try XCTUnwrap(panel.contentView).scrollWheel(with: scrollEvent)
        XCTAssertGreaterThan(panel.frame.width, initialWidth)
    }

    func testPinLayoutKeepsImageAspectRatioWithoutExternalControlBar() {
        let layout = ScreenshotPinLayout(baseImageSize: CGSize(width: 600, height: 300))

        XCTAssertEqual(ScreenshotPinLayout.controlBarHeight, 0)

        XCTAssertEqual(layout.imageSize(scale: 0.5), CGSize(width: 300, height: 150))
        XCTAssertEqual(
            layout.contentSize(scale: 0.5),
            CGSize(width: 300, height: 150 + ScreenshotPinLayout.controlBarHeight)
        )
        XCTAssertEqual(
            layout.contentSize(forRequestedWidth: 900),
            CGSize(width: 900, height: 450 + ScreenshotPinLayout.controlBarHeight)
        )
    }

    func testPinWheelScaleTracksDeltasInRealTimeAndClampsRange() {
        let enlarged = ScreenshotPinLayout.scale(current: 1, wheelDelta: 12, precise: true)
        let reduced = ScreenshotPinLayout.scale(current: 1, wheelDelta: -12, precise: true)

        XCTAssertGreaterThan(enlarged, 1)
        XCTAssertLessThan(reduced, 1)
        XCTAssertEqual(
            ScreenshotPinLayout.scale(current: 2.5, wheelDelta: 10_000, precise: false),
            2.5
        )
        XCTAssertEqual(
            ScreenshotPinLayout.scale(current: 0.25, wheelDelta: -10_000, precise: false),
            0.25
        )
    }

    @MainActor
    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants(of:))
    }

    func testReferenceOrderMatchesQQVideo() {
        XCTAssertEqual(
            SelectionToolbarItem.referenceOrder,
            [
                .rectangle,
                .ellipse,
                .line,
                .arrow,
                .freehand,
                .highlighter,
                .text,
                .numberedMarker,
                .callout,
                .note,
                .sticker,
                .mosaic,
                .watermark,
                .beautify,
                .scrollingCapture,
                .gifRecording,
                .recognizeText,
                .translate,
                .pin,
                .cancel,
                .save,
                .copy
            ]
        )
        XCTAssertEqual(SelectionToolbarItem.referenceOrder, SelectionToolbarItem.allCases)
    }

    func testTitlesAndObservedShortcutsMatchReferenceVideo() {
        let expected: [(SelectionToolbarItem, String, String?)] = [
            (.rectangle, "矩形", "R"),
            (.ellipse, "圆形", "O"),
            (.line, "直线", "L"),
            (.arrow, "箭头", nil),
            (.freehand, "绘画", nil),
            (.highlighter, "荧光笔", nil),
            (.text, "文本", "T"),
            (.numberedMarker, "数字点", "1"),
            (.callout, "批注", "C"),
            (.note, "备注", "N"),
            (.sticker, "贴纸", nil),
            (.mosaic, "马赛克", nil),
            (.watermark, "水印", nil),
            (.beautify, "美化", nil),
            (.scrollingCapture, "滚动截图", nil),
            (.gifRecording, "GIF 录制", nil),
            (.recognizeText, "文字识别", nil),
            (.translate, "翻译", nil),
            (.pin, "钉至桌面", "P"),
            (.cancel, "取消", "ESC"),
            (.save, "保存", nil),
            (.copy, "拷贝", nil)
        ]

        for (item, title, shortcut) in expected {
            XCTAssertEqual(item.title, title, "\(item) 标题错误")
            XCTAssertEqual(item.shortcut, shortcut, "\(item) 快捷键错误")
        }
    }

    func testQQPrimaryToolbarKeepsCoreActionsVisibleAndMovesExtensionsToOverflow() {
        XCTAssertEqual(
            SelectionToolbarItem.qqPrimaryOrder,
            [
                .rectangle,
                .ellipse,
                .arrow,
                .freehand,
                .text,
                .numberedMarker,
                .callout,
                .mosaic,
                .scrollingCapture,
                .recognizeText,
                .translate,
                .pin,
                .cancel,
                .save,
                .copy
            ]
        )
        XCTAssertEqual(
            Set(SelectionToolbarItem.qqPrimaryOrder + SelectionToolbarItem.qqOverflowOrder),
            Set(SelectionToolbarItem.allCases)
        )
        XCTAssertTrue(Set(SelectionToolbarItem.qqPrimaryOrder).isDisjoint(
            with: Set(SelectionToolbarItem.qqOverflowOrder)
        ))
    }

    func testQQOptionPanelUsesVerifiedWidthsAndCoversEditableCoreTools() {
        XCTAssertEqual(SelectionAnnotationOptions.lineWidths, [3, 6, 9])
        XCTAssertEqual(SelectionAnnotationOptions.fontSizes, [14, 18, 24])
        XCTAssertEqual(SelectionAnnotationOptions.lineWidthRange, 1...30)
        XCTAssertEqual(SelectionAnnotationOptions.fontSizeRange, 8...72)
        XCTAssertEqual(SelectionAnnotationOptions.colors.count, 8)

        let optionItems = SelectionToolbarItem.allCases.filter(\.supportsQQOptions)
        XCTAssertEqual(
            optionItems,
            [.rectangle, .ellipse, .line, .arrow, .freehand, .highlighter,
             .text, .numberedMarker, .callout, .note, .sticker, .mosaic]
        )
    }

    func testStickerCatalogProvidesDistinctRenderableChoices() {
        XCTAssertEqual(SelectionSticker.allCases.count, 6)
        XCTAssertEqual(Set(SelectionSticker.allCases.map(\.rawValue)).count, 6)
        XCTAssertTrue(SelectionSticker.allCases.allSatisfy { !$0.title.isEmpty })
    }

    func testWatermarkCatalogProvidesDistinctPresets() {
        XCTAssertEqual(SelectionWatermark.allCases.count, 4)
        XCTAssertEqual(Set(SelectionWatermark.allCases.map(\.rawValue)).count, 4)
        XCTAssertTrue(SelectionWatermark.allCases.allSatisfy { !$0.title.isEmpty })
    }

    func testBeautifyCatalogProvidesCompleteDistinctPresets() {
        XCTAssertEqual(SelectionBeautifyPreset.allCases.count, 4)
        XCTAssertEqual(Set(SelectionBeautifyPreset.allCases.map(\.rawValue)).count, 4)
        for preset in SelectionBeautifyPreset.allCases {
            XCTAssertFalse(preset.title.isEmpty)
            XCTAssertGreaterThan(preset.style.cornerRadius, 0)
            XCTAssertGreaterThan(preset.style.shadowRadius, 0)
            XCTAssertGreaterThan(preset.style.insets.top, 0)
            XCTAssertGreaterThanOrEqual(preset.style.backgroundGradient.colors.count, 2)
        }
    }

    func testItemsAreGroupedByTheirBehavior() {
        XCTAssertEqual(
            SelectionToolbarItem.referenceOrder.filter { $0.kind == .annotation },
            [.rectangle, .ellipse, .line, .arrow, .freehand, .highlighter,
             .text, .numberedMarker, .callout, .note, .sticker]
        )
        XCTAssertEqual(
            SelectionToolbarItem.referenceOrder.filter { $0.kind == .effect },
            [.mosaic, .watermark, .beautify]
        )
        XCTAssertEqual(
            SelectionToolbarItem.referenceOrder.filter { $0.kind == .captureExtension },
            [.scrollingCapture, .gifRecording]
        )
        XCTAssertEqual(
            SelectionToolbarItem.referenceOrder.filter { $0.kind == .recognition },
            [.recognizeText, .translate]
        )
        XCTAssertEqual(
            SelectionToolbarItem.referenceOrder.filter { $0.kind == .completion },
            [.pin, .cancel, .save, .copy]
        )
    }

    func testCaptureExtensionItemsFinishSelectionThroughBusinessActions() {
        XCTAssertEqual(
            SelectionToolbarItem.scrollingCapture.selectionCompletionAction,
            .scrollingCapture
        )
        XCTAssertEqual(
            SelectionToolbarItem.gifRecording.selectionCompletionAction,
            .gifRecording
        )
        XCTAssertEqual(
            SelectionToolbarItem.recognizeText.selectionCompletionAction,
            .recognizeText
        )
    }

    func testToolbarPrefersBelowSelection() {
        let frame = SelectionToolbarLayout.frame(
            selection: CGRect(x: 300, y: 400, width: 500, height: 250),
            toolbarSize: CGSize(width: 420, height: 76),
            in: CGRect(x: 0, y: 0, width: 1200, height: 800)
        )

        XCTAssertEqual(frame.maxY, 392)
        XCTAssertEqual(frame.maxX, 800)
    }

    func testToolbarFallsBackAboveWhenBelowHasNoRoom() {
        let selection = CGRect(x: 100, y: 30, width: 360, height: 180)
        let frame = SelectionToolbarLayout.frame(
            selection: selection,
            toolbarSize: CGSize(width: 420, height: 76),
            in: CGRect(x: 0, y: 0, width: 900, height: 700)
        )

        XCTAssertEqual(frame.minY, selection.maxY + SelectionToolbarLayout.selectionSpacing)
    }

    func testToolbarStaysInsideAllAvailableEdges() {
        let bounds = CGRect(x: 50, y: 80, width: 700, height: 420)
        let size = CGSize(width: 500, height: 76)

        for selection in [
            CGRect(x: -500, y: -300, width: 30, height: 30),
            CGRect(x: 740, y: 490, width: 100, height: 100),
            CGRect(x: 55, y: 90, width: 20, height: 20)
        ] {
            let frame = SelectionToolbarLayout.frame(
                selection: selection,
                toolbarSize: size,
                in: bounds
            )
            XCTAssertGreaterThanOrEqual(frame.minX, bounds.minX + SelectionToolbarLayout.edgeInset)
            XCTAssertLessThanOrEqual(frame.maxX, bounds.maxX - SelectionToolbarLayout.edgeInset)
            XCTAssertGreaterThanOrEqual(frame.minY, bounds.minY + SelectionToolbarLayout.edgeInset)
            XCTAssertLessThanOrEqual(frame.maxY, bounds.maxY - SelectionToolbarLayout.edgeInset)
        }
    }

    func testVeryNarrowBoundsStillPlaceToolbarAtVisibleInset() {
        let bounds = CGRect(x: 20, y: 30, width: 180, height: 160)
        let frame = SelectionToolbarLayout.frame(
            selection: CGRect(x: 40, y: 70, width: 80, height: 30),
            toolbarSize: CGSize(width: 420, height: 76),
            in: bounds
        )

        XCTAssertEqual(frame.minX, bounds.minX + SelectionToolbarLayout.edgeInset)
        XCTAssertGreaterThan(frame.intersection(bounds).width, 0)
        XCTAssertGreaterThan(frame.intersection(bounds).height, 0)
    }
}
