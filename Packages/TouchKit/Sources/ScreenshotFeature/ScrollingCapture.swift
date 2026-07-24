import CoreGraphics
import Foundation

public enum ScrollingDirection: Equatable, Sendable {
    case forward
    case backward
}

public enum ScrollingAppendResult: Equatable, Sendable {
    case duplicate
    case extended(newRows: Int, totalHeight: Int)
    case reverseIgnored
    case needsSlowerScrolling
    case reachedLengthLimit(totalHeight: Int)
}

public enum ScrollingCaptureError: Error, Equatable, Sendable {
    case invalidImage
    case inconsistentFrameSize
    case imageCreationFailed
}

public struct ScrollingFrameAligner: Sendable {
    public struct Configuration: Equatable, Sendable {
        public var minimumOverlap: Int
        public var duplicateErrorThreshold: Double
        public var alignmentErrorThreshold: Double
        public var sampleStride: Int

        public init(
            minimumOverlap: Int = 24,
            duplicateErrorThreshold: Double = 0.004,
            alignmentErrorThreshold: Double = 0.055,
            sampleStride: Int = 3
        ) {
            self.minimumOverlap = minimumOverlap
            self.duplicateErrorThreshold = duplicateErrorThreshold
            self.alignmentErrorThreshold = alignmentErrorThreshold
            self.sampleStride = sampleStride
        }
    }

    public struct Alignment: Equatable, Sendable {
        public var direction: ScrollingDirection
        public var newRows: Int
        public var confidence: Double

        public init(direction: ScrollingDirection, newRows: Int, confidence: Double) {
            self.direction = direction
            self.newRows = newRows
            self.confidence = confidence
        }
    }

    public enum Result: Equatable, Sendable {
        case duplicate
        case aligned(Alignment)
        case noReliableOverlap
    }

    public var configuration: Configuration

    public init(configuration: Configuration = .init()) {
        self.configuration = configuration
    }

    public func align(previous: CGImage, current: CGImage) throws -> Result {
        guard previous.width == current.width, previous.height == current.height else {
            throw ScrollingCaptureError.inconsistentFrameSize
        }
        let lhs = try PixelFrame(previous)
        let rhs = try PixelFrame(current)
        return align(previous: lhs, current: rhs, directions: [.forward, .backward])
    }

    fileprivate func align(
        previous lhs: PixelFrame,
        current rhs: PixelFrame,
        directions: [ScrollingDirection]
    ) -> Result {
        guard lhs.width == rhs.width, lhs.height == rhs.height else {
            return .noReliableOverlap
        }
        if error(
            lhs,
            rhs,
            lhsStart: 0,
            rhsStart: 0,
            count: lhs.height,
            maximumRowSamples: nil,
            pixelStrideMultiplier: 1,
            requiresTexture: false
        ) <= configuration.duplicateErrorThreshold {
            return .duplicate
        }

        let maximumShift = lhs.height - max(1, configuration.minimumOverlap)
        guard maximumShift > 0 else { return .noReliableOverlap }

        // 第一阶段只在固定数量的行和稀疏像素上搜索。这样搜索成本与候选位移数
        // 近似线性，避免选区较高时对每个位移都遍历整块重叠区域而阻塞实时预览。
        var coarseCandidates: [(direction: ScrollingDirection, shift: Int, error: Double)] = []
        coarseCandidates.reserveCapacity(8)
        for shift in 1...maximumShift {
            let overlap = lhs.height - shift
            for direction in directions {
                let starts = starts(for: direction, shift: shift)
                insertCandidate(
                    (direction: direction, shift: shift, error: error(
                        lhs,
                        rhs,
                        lhsStart: starts.lhs,
                        rhsStart: starts.rhs,
                        count: overlap,
                        maximumRowSamples: 14,
                        pixelStrideMultiplier: 4,
                        requiresTexture: true
                    )),
                    into: &coarseCandidates
                )
            }
        }

        // 第二阶段只对粗匹配最好的少量候选做多带全像素抽样验证。
        // 中位数意味着至少两个横向带必须同时吻合，能容忍一侧滚动条或局部动画，
        // 又不会把单带的偶然重复纹理当作可靠接缝。
        let verified = coarseCandidates.map { candidate in
            (
                direction: candidate.direction,
                shift: candidate.shift,
                error: error(
                    lhs,
                    rhs,
                    lhsStart: candidate.direction == .forward ? candidate.shift : 0,
                    rhsStart: candidate.direction == .forward ? 0 : candidate.shift,
                    count: lhs.height - candidate.shift,
                    maximumRowSamples: nil,
                    pixelStrideMultiplier: 1,
                    requiresTexture: true
                )
            )
        }.sorted { lhs, rhs in
            if lhs.error == rhs.error { return lhs.shift < rhs.shift }
            return lhs.error < rhs.error
        }
        guard let best = verified.first,
              best.error <= configuration.alignmentErrorThreshold else {
            return .noReliableOverlap
        }
        if best.error > configuration.duplicateErrorThreshold * 1.5,
           let alternative = verified.first(where: {
               $0.direction == best.direction && abs($0.shift - best.shift) >= 2
           }) {
            let requiredGap = max(0.003, best.error * 0.18)
            guard alternative.error - best.error >= requiredGap else {
                return .noReliableOverlap
            }
        }
        let confidence = max(0, min(1, 1 - best.error / configuration.alignmentErrorThreshold))
        return .aligned(.init(direction: best.direction, newRows: best.shift, confidence: confidence))
    }

    private func insertCandidate(
        _ candidate: (direction: ScrollingDirection, shift: Int, error: Double),
        into candidates: inout [(direction: ScrollingDirection, shift: Int, error: Double)]
    ) {
        candidates.append(candidate)
        candidates.sort { lhs, rhs in
            if lhs.error == rhs.error { return lhs.shift < rhs.shift }
            return lhs.error < rhs.error
        }
        if candidates.count > 8 {
            candidates.removeLast(candidates.count - 8)
        }
    }

    private func error(
        _ lhs: PixelFrame,
        _ rhs: PixelFrame,
        lhsStart: Int,
        rhsStart: Int,
        count: Int,
        maximumRowSamples: Int?,
        pixelStrideMultiplier: Int,
        requiresTexture: Bool
    ) -> Double {
        let stride = max(1, configuration.sampleStride)
        let edgeInset = min(count / 5, max(2, lhs.height / 12))
        let localStart = edgeInset
        let localEnd = max(localStart + 1, count - edgeInset)
        let availableRows = max(1, localEnd - localStart)
        let rowStride: Int
        if let maximumRowSamples {
            rowStride = max(stride, Int(ceil(Double(availableRows) / Double(maximumRowSamples))))
        } else {
            rowStride = stride
        }
        let pixelStride = max(1, stride * max(1, pixelStrideMultiplier))
        let bands = horizontalBands(width: lhs.width)
        var bandErrors: [Double] = []
        bandErrors.reserveCapacity(bands.count)
        for band in bands {
            var total: UInt64 = 0
            var samples: UInt64 = 0
            var textureTotal: UInt64 = 0
            var textureSamples: UInt64 = 0
            var row = localStart
            while row < localEnd {
                let ly = lhsStart + row
                let ry = rhsStart + row
                var x = band.lowerBound
                while x < band.upperBound {
                    let li = (ly * lhs.width + x) * 4
                    let ri = (ry * rhs.width + x) * 4
                    let difference = UInt64(abs(Int(lhs.bytes[li]) - Int(rhs.bytes[ri])))
                        + UInt64(abs(Int(lhs.bytes[li + 1]) - Int(rhs.bytes[ri + 1])))
                        + UInt64(abs(Int(lhs.bytes[li + 2]) - Int(rhs.bytes[ri + 2])))
                    total += difference
                    samples += 3
                    if isTextured(lhs, x: x, y: ly) || isTextured(rhs, x: x, y: ry) {
                        textureTotal += difference
                        textureSamples += 3
                    }
                    x += pixelStride
                }
                row += rowStride
            }
            let normalized = samples == 0 ? 1 : Double(total) / Double(samples * 255)
            guard requiresTexture else {
                bandErrors.append(normalized)
                continue
            }
            let minimumTextureSamples = max(6, samples / 100)
            if textureSamples >= minimumTextureSamples {
                let textureError = Double(textureTotal) / Double(textureSamples * 255)
                bandErrors.append(normalized * 0.2 + textureError * 0.8)
            } else {
                // 纯色背景无法证明两个画面真正重叠。宁可等待下一帧，也不拼上歧义条带。
                bandErrors.append(min(1, normalized + 0.08))
            }
        }
        return bandErrors.sorted()[bandErrors.count / 2]
    }

    private func starts(for direction: ScrollingDirection, shift: Int) -> (lhs: Int, rhs: Int) {
        switch direction {
        case .forward: return (shift, 0)
        case .backward: return (0, shift)
        }
    }

    private func isTextured(_ frame: PixelFrame, x: Int, y: Int) -> Bool {
        let center = (y * frame.width + x) * 4
        let leftX = max(0, x - 1)
        let upperY = max(0, y - 1)
        let left = (y * frame.width + leftX) * 4
        let upper = (upperY * frame.width + x) * 4
        for channel in 0..<3 {
            if abs(Int(frame.bytes[center + channel]) - Int(frame.bytes[left + channel])) >= 10
                || abs(Int(frame.bytes[center + channel]) - Int(frame.bytes[upper + channel])) >= 10 {
                return true
            }
        }
        return false
    }

    private func horizontalBands(width: Int) -> [Range<Int>] {
        guard width >= 9 else { return [0..<width] }
        let margin = max(1, width / 20)
        let available = max(3, width - margin * 2)
        let third = max(1, available / 3)
        let first = margin..<min(width, margin + third)
        let secondStart = min(width - 1, margin + third)
        let second = secondStart..<min(width, secondStart + third)
        let thirdStart = min(width - 1, margin + third * 2)
        let thirdBand = thirdStart..<max(thirdStart + 1, width - margin)
        return [first, second, thirdBand].filter { !$0.isEmpty }
    }
}

public struct ScrollingImageStitcher: Sendable {
    public struct Configuration: Equatable, Sendable {
        /// 条带常驻内存的理论上限约为 `maximumPixelCount * 4` 字节；生成最终图时
        /// 还会再创建一块同尺寸位图，因此默认限制控制在可接受的峰值范围内。
        public var maximumPixelCount: Int
        public var maximumHeight: Int

        public init(
            maximumPixelCount: Int = 32_000_000,
            maximumHeight: Int = 32_768
        ) {
            self.maximumPixelCount = maximumPixelCount
            self.maximumHeight = maximumHeight
        }
    }

    private struct Segment: @unchecked Sendable {
        var image: CGImage
    }

    public private(set) var direction: ScrollingDirection?
    public private(set) var pixelHeight: Int
    public let pixelWidth: Int
    private var previous: Segment
    private var previousPixels: PixelFrame
    private var segments: [Segment]
    private let aligner: ScrollingFrameAligner
    private let configuration: Configuration

    public init(
        firstFrame: CGImage,
        aligner: ScrollingFrameAligner = .init(),
        configuration: Configuration = .init()
    ) throws {
        guard firstFrame.width > 0, firstFrame.height > 0 else {
            throw ScrollingCaptureError.invalidImage
        }
        previous = Segment(image: firstFrame)
        previousPixels = try PixelFrame(firstFrame)
        segments = [Segment(image: firstFrame)]
        pixelWidth = firstFrame.width
        pixelHeight = firstFrame.height
        self.aligner = aligner
        self.configuration = configuration
    }

    public mutating func append(_ frame: CGImage) throws -> ScrollingAppendResult {
        guard frame.width == pixelWidth, frame.height == previous.image.height else {
            throw ScrollingCaptureError.inconsistentFrameSize
        }
        let currentPixels = try PixelFrame(frame)
        let expectedDirection = direction ?? .forward
        let primary = aligner.align(
            previous: previousPixels,
            current: currentPixels,
            directions: [expectedDirection]
        )
        switch primary {
        case .duplicate:
            return .duplicate
        case .noReliableOverlap:
            if direction != nil {
                let opposite: ScrollingDirection = expectedDirection == .forward ? .backward : .forward
                if case .aligned = aligner.align(
                    previous: previousPixels,
                    current: currentPixels,
                    directions: [opposite]
                ) {
                    return .reverseIgnored
                }
            }
            return .needsSlowerScrolling
        case let .aligned(alignment):
            guard alignment.newRows > 0, alignment.newRows < frame.height else {
                return .needsSlowerScrolling
            }
            let proposedHeight = pixelHeight + alignment.newRows
            let proposedPixelCount = proposedHeight.multipliedReportingOverflow(by: pixelWidth)
            guard !proposedPixelCount.overflow,
                  proposedHeight <= configuration.maximumHeight,
                  proposedPixelCount.partialValue <= configuration.maximumPixelCount else {
                return .reachedLengthLimit(totalHeight: pixelHeight)
            }
            let cropRect: CGRect
            switch alignment.direction {
            case .forward:
                cropRect = CGRect(
                    x: 0,
                    y: frame.height - alignment.newRows,
                    width: frame.width,
                    height: alignment.newRows
                )
            case .backward:
                cropRect = CGRect(x: 0, y: 0, width: frame.width, height: alignment.newRows)
            }
            let strip = try Self.copyStrip(from: frame, cropRect: cropRect)
            if alignment.direction == .forward {
                segments.append(.init(image: strip))
            } else {
                segments.insert(.init(image: strip), at: 0)
            }
            direction = alignment.direction
            previous = .init(image: frame)
            previousPixels = currentPixels
            pixelHeight += alignment.newRows
            return .extended(newRows: alignment.newRows, totalHeight: pixelHeight)
        }
    }

    /// `CGImage.cropping(to:)` 可以与原图共享 data provider。若直接保存裁剪结果，
    /// 每个几十像素高的条带仍可能把一整张 Retina 帧留在内存里。这里强制复制为
    /// 独立位图，使常驻内存只随最终长图的真实像素量增长。
    private static func copyStrip(from image: CGImage, cropRect: CGRect) throws -> CGImage {
        let width = Int(cropRect.width)
        let height = Int(cropRect.height)
        guard width > 0,
              height > 0,
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw ScrollingCaptureError.imageCreationFailed
        }
        guard let cropped = image.cropping(to: cropRect) else {
            throw ScrollingCaptureError.imageCreationFailed
        }
        context.interpolationQuality = .none
        // 先由 CoreGraphics 按 CGImage 的像素坐标裁剪，再绘制到新位图，
        // 避免手工变换 y 轴时改变现有截图流程的上下方向。
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let strip = context.makeImage() else {
            throw ScrollingCaptureError.imageCreationFailed
        }
        return strip
    }

    public func makePreview(maximumWidth: Int = 180, maximumHeight: Int = 420) throws -> CGImage {
        guard maximumWidth > 0, maximumHeight > 0 else {
            throw ScrollingCaptureError.imageCreationFailed
        }
        let scale = min(
            1,
            min(Double(maximumWidth) / Double(pixelWidth), Double(maximumHeight) / Double(pixelHeight))
        )
        let width = max(1, Int((Double(pixelWidth) * scale).rounded()))
        let height = max(1, Int((Double(pixelHeight) * scale).rounded()))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ScrollingCaptureError.imageCreationFailed
        }
        context.interpolationQuality = .high
        var top = pixelHeight
        for segment in segments {
            top -= segment.image.height
            context.draw(
                segment.image,
                in: CGRect(
                    x: 0,
                    y: Double(top) * scale,
                    width: Double(pixelWidth) * scale,
                    height: Double(segment.image.height) * scale
                )
            )
        }
        guard let image = context.makeImage() else {
            throw ScrollingCaptureError.imageCreationFailed
        }
        return image
    }

    public func makeImage() throws -> CGImage {
        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: pixelWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ScrollingCaptureError.imageCreationFailed
        }
        context.interpolationQuality = .none
        var top = pixelHeight
        for segment in segments {
            top -= segment.image.height
            context.draw(
                segment.image,
                in: CGRect(x: 0, y: top, width: segment.image.width, height: segment.image.height)
            )
        }
        guard let image = context.makeImage() else {
            throw ScrollingCaptureError.imageCreationFailed
        }
        return image
    }
}

private struct PixelFrame {
    var width: Int
    var height: Int
    var bytes: [UInt8]

    init(_ image: CGImage) throws {
        width = image.width
        height = image.height
        bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ScrollingCaptureError.invalidImage
        }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
}
