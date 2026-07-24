import Foundation
import TouchFeatureAPI

public enum ScreenshotAfterCaptureAction: String, Codable, CaseIterable, Sendable {
    case copyAndShowThumbnail
    case saveOnly
    case copyAndSave
    case annotate
}

public enum ScreenshotSaveLocation: Codable, Equatable, Sendable {
    case pluginDirectory
    case downloads
    case desktop
    case customBookmark(Data)
}

public enum ScreenshotThumbnailTimeout: Codable, Equatable, Sendable {
    case seconds(Int)
    case never
}

public enum ScreenshotAnnotationTool: String, Codable, CaseIterable, Hashable, Sendable {
    case arrow
    case line
    case rectangle
    case ellipse
    case pen
    case highlighter
    case text
    case stepNumber
    case mosaic
    case blur
    case magnifier
    case crop
}

public struct ScreenshotHistoryConfiguration: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    public var retentionDays: Int
    public var maximumItemCount: Int
    public var trashRetentionHours: Int
    public var keepsFilesWhenDisabled: Bool

    public init(
        isEnabled: Bool = true,
        retentionDays: Int = 30,
        maximumItemCount: Int = 500,
        trashRetentionHours: Int = 24,
        keepsFilesWhenDisabled: Bool = true
    ) {
        self.isEnabled = isEnabled
        self.retentionDays = retentionDays
        self.maximumItemCount = maximumItemCount
        self.trashRetentionHours = trashRetentionHours
        self.keepsFilesWhenDisabled = keepsFilesWhenDisabled
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        retentionDays = try values.decodeIfPresent(Int.self, forKey: .retentionDays) ?? 30
        maximumItemCount = try values.decodeIfPresent(Int.self, forKey: .maximumItemCount) ?? 500
        trashRetentionHours = try values.decodeIfPresent(Int.self, forKey: .trashRetentionHours) ?? 24
        keepsFilesWhenDisabled = try values.decodeIfPresent(Bool.self, forKey: .keepsFilesWhenDisabled) ?? true
    }
}

public struct ScreenshotAnnotationDefaults: Codable, Equatable, Sendable {
    public var tool: ScreenshotAnnotationTool
    public var colorHex: String
    public var lineWidth: Double
    public var fontName: String
    public var fontSize: Double
    public var opacity: Double
    public var cornerRadius: Double
    public var showsShadow: Bool
    public var padding: Double
    public var gradientStartHex: String
    public var gradientEndHex: String

    public init(
        tool: ScreenshotAnnotationTool = .arrow,
        colorHex: String = "#FF3B30",
        lineWidth: Double = 4,
        fontName: String = ".AppleSystemUIFont",
        fontSize: Double = 18,
        opacity: Double = 1,
        cornerRadius: Double = 0,
        showsShadow: Bool = false,
        padding: Double = 0,
        gradientStartHex: String = "#FFFFFF",
        gradientEndHex: String = "#E8E8E8"
    ) {
        self.tool = tool
        self.colorHex = colorHex
        self.lineWidth = lineWidth
        self.fontName = fontName
        self.fontSize = fontSize
        self.opacity = opacity
        self.cornerRadius = cornerRadius
        self.showsShadow = showsShadow
        self.padding = padding
        self.gradientStartHex = gradientStartHex
        self.gradientEndHex = gradientEndHex
    }

    public init(from decoder: Decoder) throws {
        let defaults = Self()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        tool = try values.decodeIfPresent(ScreenshotAnnotationTool.self, forKey: .tool) ?? defaults.tool
        colorHex = try values.decodeIfPresent(String.self, forKey: .colorHex) ?? defaults.colorHex
        lineWidth = try values.decodeIfPresent(Double.self, forKey: .lineWidth) ?? defaults.lineWidth
        fontName = try values.decodeIfPresent(String.self, forKey: .fontName) ?? defaults.fontName
        fontSize = try values.decodeIfPresent(Double.self, forKey: .fontSize) ?? defaults.fontSize
        opacity = try values.decodeIfPresent(Double.self, forKey: .opacity) ?? defaults.opacity
        cornerRadius = try values.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? defaults.cornerRadius
        showsShadow = try values.decodeIfPresent(Bool.self, forKey: .showsShadow) ?? defaults.showsShadow
        padding = try values.decodeIfPresent(Double.self, forKey: .padding) ?? defaults.padding
        gradientStartHex = try values.decodeIfPresent(String.self, forKey: .gradientStartHex) ?? defaults.gradientStartHex
        gradientEndHex = try values.decodeIfPresent(String.self, forKey: .gradientEndHex) ?? defaults.gradientEndHex
    }
}

public struct ScreenshotOCRConfiguration: Codable, Equatable, Sendable {
    public var recognitionLanguages: [String]
    public var copiesRecognizedText: Bool
    public var confirmsBeforeOpeningQRCode: Bool
    public var minimumTextConfidence: Double
    public var recognizesBarcodes: Bool

    public init(
        recognitionLanguages: [String] = ["zh-Hans", "en-US"],
        copiesRecognizedText: Bool = true,
        confirmsBeforeOpeningQRCode: Bool = true,
        minimumTextConfidence: Double = 0.3,
        recognizesBarcodes: Bool = true
    ) {
        self.recognitionLanguages = recognitionLanguages
        self.copiesRecognizedText = copiesRecognizedText
        self.confirmsBeforeOpeningQRCode = confirmsBeforeOpeningQRCode
        self.minimumTextConfidence = min(max(minimumTextConfidence, 0), 1)
        self.recognizesBarcodes = recognizesBarcodes
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        recognitionLanguages = try values.decodeIfPresent([String].self, forKey: .recognitionLanguages)
            ?? ["zh-Hans", "en-US"]
        copiesRecognizedText = try values.decodeIfPresent(Bool.self, forKey: .copiesRecognizedText) ?? true
        confirmsBeforeOpeningQRCode = try values.decodeIfPresent(Bool.self, forKey: .confirmsBeforeOpeningQRCode) ?? true
        minimumTextConfidence = min(max(
            try values.decodeIfPresent(Double.self, forKey: .minimumTextConfidence) ?? 0.3,
            0
        ), 1)
        recognizesBarcodes = try values.decodeIfPresent(Bool.self, forKey: .recognizesBarcodes) ?? true
    }
}

public struct ScreenshotPinConfiguration: Codable, Equatable, Sendable {
    public var restoresOnLaunch: Bool
    public var appearsAcrossSpaces: Bool
    public var defaultOpacity: Double

    public init(
        restoresOnLaunch: Bool = false,
        appearsAcrossSpaces: Bool = false,
        defaultOpacity: Double = 1
    ) {
        self.restoresOnLaunch = restoresOnLaunch
        self.appearsAcrossSpaces = appearsAcrossSpaces
        self.defaultOpacity = defaultOpacity
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        restoresOnLaunch = try values.decodeIfPresent(Bool.self, forKey: .restoresOnLaunch) ?? false
        appearsAcrossSpaces = try values.decodeIfPresent(Bool.self, forKey: .appearsAcrossSpaces) ?? false
        defaultOpacity = try values.decodeIfPresent(Double.self, forKey: .defaultOpacity) ?? 1
    }
}

public struct ScreenshotFeatureConfiguration: Codable, Equatable, Sendable {
    public var defaultMode: ScreenshotCaptureMode
    public var defaultDelay: ScreenshotCaptureDelay
    public var windowShadow: ScreenshotWindowShadow
    public var modeShortcuts: [ScreenshotCaptureMode: KeyboardShortcut]
    public var saveLocation: ScreenshotSaveLocation
    public var namingTemplate: String
    public var output: ScreenshotOutputOptions
    public var afterCaptureAction: ScreenshotAfterCaptureAction
    public var showsFloatingThumbnail: Bool
    public var thumbnailTimeout: ScreenshotThumbnailTimeout
    public var history: ScreenshotHistoryConfiguration
    public var annotation: ScreenshotAnnotationDefaults
    public var ocr: ScreenshotOCRConfiguration
    public var pin: ScreenshotPinConfiguration

    // Kept during the v1-to-v2 settings migration so existing controls retain their values.
    public var showsAnnotationToolbar: Bool
    public var copiesToClipboard: Bool
    public var showsPinAction: Bool

    public init(
        defaultMode: ScreenshotCaptureMode = .region,
        defaultDelay: ScreenshotCaptureDelay = .none,
        windowShadow: ScreenshotWindowShadow = .included,
        modeShortcuts: [ScreenshotCaptureMode: KeyboardShortcut] = [
            .allDisplays: .init(modifiers: [.option, .shift], key: "2"),
            .colorPicker: .init(modifiers: [.control, .option], key: "c")
        ],
        saveLocation: ScreenshotSaveLocation = .downloads,
        namingTemplate: String = "一念-{date}-{time}",
        output: ScreenshotOutputOptions = .init(),
        afterCaptureAction: ScreenshotAfterCaptureAction = .copyAndShowThumbnail,
        showsFloatingThumbnail: Bool = true,
        thumbnailTimeout: ScreenshotThumbnailTimeout = .seconds(5),
        history: ScreenshotHistoryConfiguration = .init(),
        annotation: ScreenshotAnnotationDefaults = .init(),
        ocr: ScreenshotOCRConfiguration = .init(),
        pin: ScreenshotPinConfiguration = .init(),
        showsAnnotationToolbar: Bool = true,
        copiesToClipboard: Bool = true,
        showsPinAction: Bool = true
    ) {
        self.defaultMode = defaultMode
        self.defaultDelay = defaultDelay
        self.windowShadow = windowShadow
        self.modeShortcuts = modeShortcuts
        self.saveLocation = saveLocation
        self.namingTemplate = namingTemplate
        self.output = output
        self.afterCaptureAction = afterCaptureAction
        self.showsFloatingThumbnail = showsFloatingThumbnail
        self.thumbnailTimeout = thumbnailTimeout
        self.history = history
        self.annotation = annotation
        self.ocr = ocr
        self.pin = pin
        self.showsAnnotationToolbar = showsAnnotationToolbar
        self.copiesToClipboard = copiesToClipboard
        self.showsPinAction = showsPinAction
    }

    public init(from decoder: Decoder) throws {
        let defaults = Self()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        defaultMode = try values.decodeIfPresent(ScreenshotCaptureMode.self, forKey: .defaultMode) ?? defaults.defaultMode
        defaultDelay = try values.decodeIfPresent(ScreenshotCaptureDelay.self, forKey: .defaultDelay) ?? defaults.defaultDelay
        windowShadow = try values.decodeIfPresent(ScreenshotWindowShadow.self, forKey: .windowShadow) ?? defaults.windowShadow
        modeShortcuts = try values.decodeIfPresent([ScreenshotCaptureMode: KeyboardShortcut].self, forKey: .modeShortcuts)
            ?? defaults.modeShortcuts
        saveLocation = try values.decodeIfPresent(ScreenshotSaveLocation.self, forKey: .saveLocation) ?? defaults.saveLocation
        namingTemplate = try values.decodeIfPresent(String.self, forKey: .namingTemplate) ?? defaults.namingTemplate
        output = try values.decodeIfPresent(ScreenshotOutputOptions.self, forKey: .output) ?? defaults.output
        afterCaptureAction = try values.decodeIfPresent(ScreenshotAfterCaptureAction.self, forKey: .afterCaptureAction)
            ?? defaults.afterCaptureAction
        showsFloatingThumbnail = try values.decodeIfPresent(Bool.self, forKey: .showsFloatingThumbnail)
            ?? defaults.showsFloatingThumbnail
        thumbnailTimeout = try values.decodeIfPresent(ScreenshotThumbnailTimeout.self, forKey: .thumbnailTimeout)
            ?? defaults.thumbnailTimeout
        history = try values.decodeIfPresent(ScreenshotHistoryConfiguration.self, forKey: .history) ?? defaults.history
        annotation = try values.decodeIfPresent(ScreenshotAnnotationDefaults.self, forKey: .annotation) ?? defaults.annotation
        ocr = try values.decodeIfPresent(ScreenshotOCRConfiguration.self, forKey: .ocr) ?? defaults.ocr
        pin = try values.decodeIfPresent(ScreenshotPinConfiguration.self, forKey: .pin) ?? defaults.pin
        showsAnnotationToolbar = try values.decodeIfPresent(Bool.self, forKey: .showsAnnotationToolbar)
            ?? defaults.showsAnnotationToolbar
        copiesToClipboard = try values.decodeIfPresent(Bool.self, forKey: .copiesToClipboard)
            ?? defaults.copiesToClipboard
        showsPinAction = try values.decodeIfPresent(Bool.self, forKey: .showsPinAction) ?? defaults.showsPinAction
    }
}

public struct ScreenshotConfigurationEnvelope: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    public var configuration: ScreenshotFeatureConfiguration

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        configuration: ScreenshotFeatureConfiguration
    ) {
        self.schemaVersion = schemaVersion
        self.configuration = configuration
    }
}
