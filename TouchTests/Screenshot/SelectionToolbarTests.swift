import CoreGraphics
import XCTest
@testable import 触达

final class SelectionToolbarTests: XCTestCase {
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
            (.copy, "拷贝", nil)
        ]

        for (item, title, shortcut) in expected {
            XCTAssertEqual(item.title, title, "\(item) 标题错误")
            XCTAssertEqual(item.shortcut, shortcut, "\(item) 快捷键错误")
        }
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
             .text, .numberedMarker, .note, .sticker]
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
            [.pin, .cancel, .copy]
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
        XCTAssertNil(SelectionToolbarItem.recognizeText.selectionCompletionAction)
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
