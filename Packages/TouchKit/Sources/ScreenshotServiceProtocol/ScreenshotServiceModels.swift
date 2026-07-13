import Foundation

public enum ScreenshotServiceProtocolVersion {
    public static let current = 1
}

public struct ScreenshotServiceAction: Codable, Equatable, Sendable {
    public let name: String
    public let isIdempotent: Bool

    public init(name: String, isIdempotent: Bool) {
        self.name = name
        self.isIdempotent = isIdempotent
    }

    public static let ping = ScreenshotServiceAction(name: "ping", isIdempotent: true)
    public static let health = ScreenshotServiceAction(name: "health", isIdempotent: true)

    public static func custom(name: String, isIdempotent: Bool) -> Self {
        .init(name: name, isIdempotent: isIdempotent)
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
}
