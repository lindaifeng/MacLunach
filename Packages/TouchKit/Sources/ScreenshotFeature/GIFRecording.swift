import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum GIFRecordingAppendResult: Equatable, Sendable {
    case skipped
    case appended(frameCount: Int)
    case reachedDurationLimit
}

public struct GIFRecordingResult: Equatable, Sendable {
    public var outputURL: URL
    public var frameCount: Int
    public var duration: TimeInterval

    public init(outputURL: URL, frameCount: Int, duration: TimeInterval) {
        self.outputURL = outputURL
        self.frameCount = frameCount
        self.duration = duration
    }
}

public enum GIFRecordingError: Error, Equatable, Sendable {
    case invalidConfiguration
    case cannotCreateDestination
    case noFrames
    case alreadyFinished
    case encodingFailed
}

public actor GIFRecordingEncoder {
    private let outputURL: URL
    private let frameInterval: TimeInterval
    private let maximumDuration: TimeInterval
    private let destination: CGImageDestination
    private var firstTimestamp: TimeInterval?
    private var lastTimestamp: TimeInterval?
    private var frameCount = 0
    private var isFinished = false

    public init(outputURL: URL, framesPerSecond: Int = 15, maximumDuration: TimeInterval = 30) throws {
        guard framesPerSecond > 0, maximumDuration > 0 else {
            throw GIFRecordingError.invalidConfiguration
        }
        self.outputURL = outputURL
        frameInterval = 1 / Double(framesPerSecond)
        self.maximumDuration = maximumDuration
        try? FileManager.default.removeItem(at: outputURL)
        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            UTType.gif.identifier as CFString,
            0,
            nil
        ) else {
            throw GIFRecordingError.cannotCreateDestination
        }
        self.destination = destination
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFLoopCount: 0
            ]
        ] as CFDictionary)
    }

    public func append(_ image: CGImage, at timestamp: TimeInterval) throws -> GIFRecordingAppendResult {
        guard !isFinished else { throw GIFRecordingError.alreadyFinished }
        if let firstTimestamp, timestamp - firstTimestamp >= maximumDuration {
            return .reachedDurationLimit
        }
        if let lastTimestamp, timestamp - lastTimestamp + 0.000_001 < frameInterval {
            return .skipped
        }
        if firstTimestamp == nil { firstTimestamp = timestamp }
        lastTimestamp = timestamp
        let properties: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: frameInterval,
                kCGImagePropertyGIFUnclampedDelayTime: frameInterval
            ]
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        frameCount += 1
        return .appended(frameCount: frameCount)
    }

    public func finish() throws -> GIFRecordingResult {
        guard !isFinished else { throw GIFRecordingError.alreadyFinished }
        guard frameCount > 0 else { throw GIFRecordingError.noFrames }
        isFinished = true
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: outputURL)
            throw GIFRecordingError.encodingFailed
        }
        return .init(
            outputURL: outputURL,
            frameCount: frameCount,
            duration: max(frameInterval, (lastTimestamp ?? 0) - (firstTimestamp ?? 0) + frameInterval)
        )
    }

    public func cancel() {
        guard !isFinished else { return }
        isFinished = true
        try? FileManager.default.removeItem(at: outputURL)
    }
}
