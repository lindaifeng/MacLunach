import CoreGraphics
import Foundation
import ImageIO
import ScreenshotFeature
import Vision

struct ScreenshotTextObservation: Equatable, Sendable {
    var text: String
    var confidence: Double
    var bounds: ScreenshotRect
}

struct ScreenshotBarcodeObservation: Equatable, Sendable {
    var payload: String
    var symbology: String
    var bounds: ScreenshotRect
}

struct ScreenshotRecognitionObservations: Equatable, Sendable {
    var text: [ScreenshotTextObservation]
    var barcodes: [ScreenshotBarcodeObservation]

    init(
        text: [ScreenshotTextObservation] = [],
        barcodes: [ScreenshotBarcodeObservation] = []
    ) {
        self.text = text
        self.barcodes = barcodes
    }
}

private actor ScreenshotRecognitionPermitPool {
    private struct Waiter {
        var id: UUID
        var continuation: CheckedContinuation<Bool, Never>
    }

    private let limit: Int
    private var activeCount = 0
    private var waiters: [Waiter] = []

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    func acquire() async throws {
        try Task.checkCancellation()
        if activeCount < limit {
            activeCount += 1
            return
        }
        let waiterID = UUID()
        let acquired = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters.append(.init(id: waiterID, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: waiterID) }
        }
        guard acquired else { throw CancellationError() }
        if Task.isCancelled {
            release()
            throw CancellationError()
        }
    }

    func release() {
        if waiters.isEmpty {
            activeCount -= 1
        } else {
            waiters.removeFirst().continuation.resume(returning: true)
        }
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
    }
}

private final class VisionCancellationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [VNRequest] = []
    private var cancelled = false

    func install(_ requests: [VNRequest]) {
        let shouldCancel = lock.withLock {
            self.requests = requests
            return cancelled
        }
        if shouldCancel { requests.forEach { $0.cancel() } }
    }

    func cancel() {
        let current = lock.withLock {
            cancelled = true
            return requests
        }
        current.forEach { $0.cancel() }
    }

    var isCancelled: Bool { lock.withLock { cancelled } }
}

public struct ScreenshotRecognitionEngine: Sendable {
    typealias Worker = @Sendable (
        _ imageURL: URL,
        _ configuration: ScreenshotOCRConfiguration
    ) async throws -> ScreenshotRecognitionObservations

    private let paths: ScreenshotFeaturePaths
    private let permits: ScreenshotRecognitionPermitPool
    private let worker: Worker

    public init(rootURL: URL, maximumConcurrentRecognitions: Int = 2) {
        self.init(
            rootURL: rootURL,
            maximumConcurrentRecognitions: maximumConcurrentRecognitions,
            worker: Self.performVisionRecognition
        )
    }

    init(
        rootURL: URL,
        maximumConcurrentRecognitions: Int = 2,
        worker: @escaping Worker
    ) {
        paths = ScreenshotFeaturePaths(rootURL: rootURL)
        permits = ScreenshotRecognitionPermitPool(limit: maximumConcurrentRecognitions)
        self.worker = worker
    }

    public func recognize(_ request: ScreenshotRecognitionRequest) async throws -> ScreenshotRecognitionResult {
        let imageURL: URL
        do {
            imageURL = try paths.resolve(relativePath: request.artifact.relativePath)
        } catch {
            throw ScreenshotFeatureError.recognitionFailed(message: "截图路径无效，无法识别")
        }

        do {
            try await permits.acquire()
        } catch is CancellationError {
            throw ScreenshotFeatureError.cancelled
        }
        let observations: ScreenshotRecognitionObservations
        do {
            observations = try await worker(imageURL, request.configuration)
            await permits.release()
        } catch {
            await permits.release()
            if error is CancellationError { throw ScreenshotFeatureError.cancelled }
            if let featureError = error as? ScreenshotFeatureError { throw featureError }
            throw ScreenshotFeatureError.recognitionFailed(message: String(describing: error))
        }
        guard !Task.isCancelled else { throw ScreenshotFeatureError.cancelled }

        let minimumConfidence = min(max(request.configuration.minimumTextConfidence, 0), 1)
        let blocks = observations.text
            .filter { $0.confidence >= minimumConfidence }
            .compactMap { observation -> ScreenshotRecognizedTextBlock? in
                let text = observation.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return .init(
                    text: text,
                    confidence: observation.confidence,
                    normalizedBounds: observation.bounds
                )
            }
            .sorted(by: Self.isBeforeInReadingOrder)
        let barcodes = request.configuration.recognizesBarcodes
            ? observations.barcodes.map {
                ScreenshotRecognizedBarcode(
                    payload: $0.payload,
                    symbology: $0.symbology,
                    normalizedBounds: $0.bounds
                )
            }
            : []

        return ScreenshotRecognitionResult(
            artifactID: request.artifact.id,
            fullText: blocks.map(\.text).joined(separator: "\n"),
            textBlocks: blocks,
            barcodes: barcodes
        )
    }

    private static func isBeforeInReadingOrder(
        _ lhs: ScreenshotRecognizedTextBlock,
        _ rhs: ScreenshotRecognizedTextBlock
    ) -> Bool {
        let verticalTolerance = 0.02
        let lhsTop = lhs.normalizedBounds.y + lhs.normalizedBounds.height
        let rhsTop = rhs.normalizedBounds.y + rhs.normalizedBounds.height
        if abs(lhsTop - rhsTop) > verticalTolerance { return lhsTop > rhsTop }
        return lhs.normalizedBounds.x < rhs.normalizedBounds.x
    }

    private static func performVisionRecognition(
        imageURL: URL,
        configuration: ScreenshotOCRConfiguration
    ) async throws -> ScreenshotRecognitionObservations {
        let cancellation = VisionCancellationBox()
        let visionTask = Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw ScreenshotFeatureError.recognitionFailed(message: "截图文件无法读取")
            }
            let orientation = Self.orientation(of: source)
            let textRequest = VNRecognizeTextRequest()
            textRequest.recognitionLevel = .accurate
            textRequest.usesLanguageCorrection = true
            textRequest.automaticallyDetectsLanguage = configuration.recognitionLanguages.isEmpty
            if !configuration.recognitionLanguages.isEmpty {
                textRequest.recognitionLanguages = configuration.recognitionLanguages
            }
            let barcodeRequest = VNDetectBarcodesRequest()
            let requests: [VNRequest] = configuration.recognizesBarcodes
                ? [textRequest, barcodeRequest]
                : [textRequest]
            cancellation.install(requests)
            if cancellation.isCancelled { throw CancellationError() }

            let handler = VNImageRequestHandler(cgImage: image, orientation: orientation)
            try handler.perform(requests)
            if cancellation.isCancelled { throw CancellationError() }

            let text = (textRequest.results ?? []).compactMap { observation -> ScreenshotTextObservation? in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                return ScreenshotTextObservation(
                    text: candidate.string,
                    confidence: Double(candidate.confidence),
                    bounds: Self.rect(observation.boundingBox)
                )
            }
            let barcodes = (barcodeRequest.results ?? []).compactMap {
                observation -> ScreenshotBarcodeObservation? in
                guard let payload = observation.payloadStringValue, !payload.isEmpty else { return nil }
                return ScreenshotBarcodeObservation(
                    payload: payload,
                    symbology: observation.symbology.rawValue,
                    bounds: Self.rect(observation.boundingBox)
                )
            }
            return ScreenshotRecognitionObservations(text: text, barcodes: barcodes)
        }

        return try await withTaskCancellationHandler {
            try await visionTask.value
        } onCancel: {
            cancellation.cancel()
            visionTask.cancel()
        }
    }

    private static func orientation(of source: CGImageSource) -> CGImagePropertyOrientation {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let number = properties[kCGImagePropertyOrientation] as? NSNumber else { return .up }
        return CGImagePropertyOrientation(rawValue: number.uint32Value) ?? .up
    }

    private static func rect(_ rect: CGRect) -> ScreenshotRect {
        .init(x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.height)
    }
}
