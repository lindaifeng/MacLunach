import Foundation

public enum ScreenshotServiceProtocolVersion {
    public static let current = 1
}

public struct ScreenshotServiceAction: Codable, Equatable, Sendable {
    public let name: String
    public let isIdempotent: Bool
    public let payload: Data?

    public init(name: String, isIdempotent: Bool, payload: Data? = nil) {
        self.name = name
        self.isIdempotent = isIdempotent
        self.payload = payload
    }

    public static let ping = ScreenshotServiceAction(name: "ping", isIdempotent: true)
    public static let health = ScreenshotServiceAction(name: "health", isIdempotent: true)
    public static let availableContent = ScreenshotServiceAction(
        name: "availableContent",
        isIdempotent: true
    )

    public static func custom(name: String, isIdempotent: Bool) -> Self {
        .init(name: name, isIdempotent: isIdempotent)
    }

    public static func capture(requestData: Data) -> Self {
        .init(name: "capture", isIdempotent: false, payload: requestData)
    }

    public static func sampleColor(requestData: Data) -> Self {
        .init(name: "sampleColor", isIdempotent: true, payload: requestData)
    }

    public static func recognize(requestData: Data) -> Self {
        .init(name: "recognize", isIdempotent: true, payload: requestData)
    }
}

public struct ScreenshotPong: Codable, Equatable, Sendable {
    public let processID: Int32

    public init(processID: Int32) {
        self.processID = processID
    }
}

public struct ScreenshotServiceHealth: Codable, Equatable, Sendable {
    public let processID: Int32
    public let activeRequestCount: Int

    public init(processID: Int32, activeRequestCount: Int) {
        self.processID = processID
        self.activeRequestCount = activeRequestCount
    }
}

public enum ScreenshotServiceFailure: Error, Codable, Equatable, Sendable {
    case incompatibleProtocol(expected: Int, received: Int)
    case unsupportedAction(String)
    case malformedRequest(String)
    case internalFailure(String)
    case cancelled
    case permissionDenied
    case noDisplayAvailable
    case targetUnavailable
    case encodingFailed
    case recognitionFailed(String)
    case storageFailed(String)
}
