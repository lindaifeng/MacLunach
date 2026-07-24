import Foundation
import Testing
import TouchFeatureAPI
@testable import ScreenshotFeature

@Test func screenshotConfigurationRoundTripsEveryV1Setting() throws {
    var configuration = ScreenshotFeatureConfiguration()
    configuration.defaultMode = .window
    configuration.defaultDelay = .fiveSeconds
    configuration.windowShadow = .excluded
    configuration.modeShortcuts = [
        .region: KeyboardShortcut(modifiers: [.command, .shift], key: "4"),
        .colorPicker: KeyboardShortcut(modifiers: [.control, .option], key: "c")
    ]
    configuration.saveLocation = .customBookmark(Data([0x01, 0x02, 0x03]))
    configuration.namingTemplate = "一念-{date}-{time}-{counter}"
    configuration.output = ScreenshotOutputOptions(format: .jpeg, quality: 0.81)
    configuration.afterCaptureAction = .copyAndSave
    configuration.showsFloatingThumbnail = false
    configuration.thumbnailTimeout = .never
    configuration.history = ScreenshotHistoryConfiguration(
        isEnabled: true,
        retentionDays: 45,
        maximumItemCount: 750,
        trashRetentionHours: 24
    )
    configuration.annotation = ScreenshotAnnotationDefaults(
        tool: .arrow,
        colorHex: "#FF3366",
        lineWidth: 6,
        fontName: "PingFang SC",
        fontSize: 20,
        opacity: 0.7,
        cornerRadius: 16,
        showsShadow: true,
        padding: 24,
        gradientStartHex: "#111111",
        gradientEndHex: "#333333"
    )
    configuration.ocr = ScreenshotOCRConfiguration(
        recognitionLanguages: ["zh-Hans", "en-US"],
        copiesRecognizedText: false,
        confirmsBeforeOpeningQRCode: true
    )
    configuration.pin = ScreenshotPinConfiguration(
        restoresOnLaunch: true,
        appearsAcrossSpaces: true,
        defaultOpacity: 0.66
    )

    let envelope = ScreenshotConfigurationEnvelope(configuration: configuration)
    let data = try JSONEncoder().encode(envelope)
    #expect(try JSONDecoder().decode(ScreenshotConfigurationEnvelope.self, from: data) == envelope)
    #expect(envelope.schemaVersion == ScreenshotConfigurationEnvelope.currentSchemaVersion)
}

@Test func screenshotConfigurationDefaultsMatchTheSpecification() {
    let configuration = ScreenshotFeatureConfiguration()

    #expect(configuration.defaultMode == .region)
    #expect(configuration.defaultDelay == .none)
    #expect(
        configuration.modeShortcuts[.allDisplays]
            == KeyboardShortcut(modifiers: [.command, .shift], key: "2")
    )
    #expect(configuration.afterCaptureAction == .copyAndShowThumbnail)
    #expect(configuration.copiesToClipboard)
    #expect(configuration.showsFloatingThumbnail)
    #expect(configuration.history.isEnabled)
    #expect(configuration.history.retentionDays == 30)
    #expect(configuration.history.maximumItemCount == 500)
    #expect(configuration.history.trashRetentionHours == 24)
    #expect(configuration.pin.defaultOpacity == 1)
    #expect(configuration.ocr.confirmsBeforeOpeningQRCode)
}

@Test func legacyThreeBooleanConfigurationDecodesWithNewDefaults() throws {
    let legacy = Data(
        #"{"showsAnnotationToolbar":false,"copiesToClipboard":false,"showsPinAction":true}"#.utf8
    )

    let configuration = try JSONDecoder().decode(ScreenshotFeatureConfiguration.self, from: legacy)

    #expect(!configuration.showsAnnotationToolbar)
    #expect(!configuration.copiesToClipboard)
    #expect(configuration.showsPinAction)
    #expect(configuration.defaultMode == .region)
    #expect(configuration.history == ScreenshotHistoryConfiguration())
    #expect(configuration.pin == ScreenshotPinConfiguration())
}

@Test func annotationToolCatalogContainsTheEntireV1Set() {
    #expect(Set(ScreenshotAnnotationTool.allCases) == Set([
        .arrow, .line, .rectangle, .ellipse, .pen, .highlighter,
        .text, .stepNumber, .mosaic, .blur, .magnifier, .crop
    ]))
}
