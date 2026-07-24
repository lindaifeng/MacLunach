import Foundation

public enum ScreenshotCaptureMode: String, Codable, CaseIterable, Hashable, Sendable {
    case region
    case window
    case fullScreen
    case allDisplays
    case ocrRegion
    case colorPicker
}

public enum ScreenshotCaptureDelay: Int, Codable, CaseIterable, Hashable, Sendable {
    case none = 0
    case threeSeconds = 3
    case fiveSeconds = 5
    case tenSeconds = 10
}

public enum ScreenshotWindowShadow: String, Codable, CaseIterable, Sendable {
    case included
    case excluded
}

public enum ScreenshotImageFormat: String, Codable, CaseIterable, Sendable {
    case png
    case jpeg
    case heif
}

public struct ScreenshotOutputOptions: Codable, Equatable, Sendable {
    public var format: ScreenshotImageFormat
    public var quality: Double

    public init(format: ScreenshotImageFormat = .png, quality: Double = 0.92) {
        self.format = format
        self.quality = quality
    }
}

public struct ScreenshotSize: Codable, Equatable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

public struct ScreenshotRect: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct ScreenshotDisplayDescriptor: Codable, Equatable, Sendable, Identifiable {
    public var id: UInt32
    public var frame: ScreenshotRect
    public var pixelSize: ScreenshotSize
    public var scaleFactor: Double

    public init(id: UInt32, frame: ScreenshotRect, pixelSize: ScreenshotSize, scaleFactor: Double) {
        self.id = id
        self.frame = frame
        self.pixelSize = pixelSize
        self.scaleFactor = scaleFactor
    }
}

public struct ScreenshotWindowDescriptor: Codable, Equatable, Sendable, Identifiable {
    public var id: UInt32
    public var ownerBundleIdentifier: String?
    public var title: String?
    public var frame: ScreenshotRect
    public var isOnScreen: Bool

    public init(
        id: UInt32,
        ownerBundleIdentifier: String?,
        title: String?,
        frame: ScreenshotRect,
        isOnScreen: Bool
    ) {
        self.id = id
        self.ownerBundleIdentifier = ownerBundleIdentifier
        self.title = title
        self.frame = frame
        self.isOnScreen = isOnScreen
    }
}

public struct ScreenshotSelectionContent: Codable, Equatable, Sendable {
    public var displays: [ScreenshotDisplayDescriptor]
    public var windows: [ScreenshotWindowDescriptor]

    public init(
        displays: [ScreenshotDisplayDescriptor],
        windows: [ScreenshotWindowDescriptor]
    ) {
        self.displays = displays
        self.windows = windows
    }
}

public enum ScreenshotCaptureTarget: Codable, Equatable, Sendable {
    case interactive
    case region(displayID: UInt32, rect: ScreenshotRect)
    case window(windowID: UInt32)
    case display(displayID: UInt32)
    case allDisplays(displayIDs: [UInt32])
}

public struct ScreenshotCaptureRequest: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var mode: ScreenshotCaptureMode
    public var delay: ScreenshotCaptureDelay
    public var target: ScreenshotCaptureTarget
    public var windowShadow: ScreenshotWindowShadow
    public var output: ScreenshotOutputOptions
    public var annotations: [ScreenshotAnnotation]
    public var history: ScreenshotHistoryConfiguration

    public init(
        id: UUID = UUID(),
        mode: ScreenshotCaptureMode,
        delay: ScreenshotCaptureDelay = .none,
        target: ScreenshotCaptureTarget,
        windowShadow: ScreenshotWindowShadow = .included,
        output: ScreenshotOutputOptions = .init(),
        annotations: [ScreenshotAnnotation] = [],
        history: ScreenshotHistoryConfiguration = .init()
    ) {
        self.id = id
        self.mode = mode
        self.delay = delay
        self.target = target
        self.windowShadow = windowShadow
        self.output = output
        self.annotations = annotations
        self.history = history
    }

    private enum CodingKeys: String, CodingKey {
        case id, mode, delay, target, windowShadow, output, annotations, history
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        mode = try container.decode(ScreenshotCaptureMode.self, forKey: .mode)
        delay = try container.decodeIfPresent(ScreenshotCaptureDelay.self, forKey: .delay) ?? .none
        target = try container.decode(ScreenshotCaptureTarget.self, forKey: .target)
        windowShadow = try container.decodeIfPresent(
            ScreenshotWindowShadow.self,
            forKey: .windowShadow
        ) ?? .included
        output = try container.decodeIfPresent(
            ScreenshotOutputOptions.self,
            forKey: .output
        ) ?? .init()
        annotations = try container.decodeIfPresent(
            [ScreenshotAnnotation].self,
            forKey: .annotations
        ) ?? []
        history = try container.decodeIfPresent(
            ScreenshotHistoryConfiguration.self,
            forKey: .history
        ) ?? .init()
    }
}

public struct ScreenshotArtifact: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var createdAt: Date
    public var captureMode: ScreenshotCaptureMode
    public var relativePath: String
    public var thumbnailRelativePath: String?
    public var pointSize: ScreenshotSize
    public var pixelSize: ScreenshotSize
    public var uniformTypeIdentifier: String
    public var sha256: String
    public var displays: [ScreenshotDisplayDescriptor]

    public init(
        id: UUID,
        createdAt: Date,
        captureMode: ScreenshotCaptureMode,
        relativePath: String,
        thumbnailRelativePath: String?,
        pointSize: ScreenshotSize,
        pixelSize: ScreenshotSize,
        uniformTypeIdentifier: String,
        sha256: String,
        displays: [ScreenshotDisplayDescriptor]
    ) {
        self.id = id
        self.createdAt = createdAt
        self.captureMode = captureMode
        self.relativePath = relativePath
        self.thumbnailRelativePath = thumbnailRelativePath
        self.pointSize = pointSize
        self.pixelSize = pixelSize
        self.uniformTypeIdentifier = uniformTypeIdentifier
        self.sha256 = sha256
        self.displays = displays
    }
}

/// 主进程完成滚动拼接后，将已经写入插件目录的产物交给截图服务登记到历史。
public struct ScreenshotArtifactRegistrationRequest: Codable, Equatable, Sendable {
    public var artifact: ScreenshotArtifact
    public var history: ScreenshotHistoryConfiguration

    public init(
        artifact: ScreenshotArtifact,
        history: ScreenshotHistoryConfiguration = .init()
    ) {
        self.artifact = artifact
        self.history = history
    }
}

public enum ScreenshotPermissionState: String, Codable, Equatable, Sendable {
    case notRequested
    case authorized
    case denied
    case restricted
}

public enum ScreenshotFeatureError: Error, Codable, Equatable, Sendable {
    case permissionDenied
    case cancelled
    case noDisplayAvailable
    case targetUnavailable
    case serviceTimedOut
    case serviceInterrupted
    case encodingFailed
    case recognitionFailed(message: String)
    case storageFailed(message: String)
    case migrationFailed(message: String)
    case incompatibleProtocol(expected: Int, received: Int)
    case responseMismatch(expected: UUID, received: UUID)
    case unsupportedAction(action: String)
    case serviceFailed(message: String)
    case serviceIsolated
}
