import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import ScreenshotFeature

@Suite("Scrolling capture stitching")
struct ScrollingCaptureTests {
    @Test("重复帧不追加")
    func duplicateFrameIsIgnored() throws {
        let frame = makeViewport(offset: 0)
        var stitcher = try ScrollingImageStitcher(firstFrame: frame)

        let result = try stitcher.append(frame)

        #expect(result == .duplicate)
        #expect(stitcher.pixelHeight == frame.height)
    }

    @Test("向下滚动只追加新增像素行")
    func downwardScrollAppendsOnlyNewRows() throws {
        let first = makeViewport(offset: 0)
        let second = makeViewport(offset: 9)
        var stitcher = try ScrollingImageStitcher(firstFrame: first)

        let result = try stitcher.append(second)
        let image = try stitcher.makeImage()

        #expect(result == .extended(newRows: 9, totalHeight: first.height + 9))
        #expect(stitcher.direction == .forward)
        #expect(image.width == first.width)
        #expect(image.height == first.height + 9)
        let expected = makeNoiseImage(width: first.width, height: first.height + 9, seed: 71)
        #expect(pixelBytes(image) == pixelBytes(expected))
    }

    @Test("连续滚动后最终像素与原内容完全一致")
    func continuousScrollHasNoRepeatedOrMissingRows() throws {
        let offsets = [0, 5, 13, 21]
        var stitcher = try ScrollingImageStitcher(firstFrame: makeViewport(offset: offsets[0]))

        for offset in offsets.dropFirst() {
            _ = try stitcher.append(makeViewport(offset: offset))
        }

        let image = try stitcher.makeImage()
        let expected = makeNoiseImage(width: 36, height: 61, seed: 71)
        #expect(image.height == 61)
        #expect(pixelBytes(image) == pixelBytes(expected))
    }

    @Test("大面积纯色聊天背景仍能按纹理行准确拼接")
    func sparseChatContentUsesTexturedRows() throws {
        let source = makeChatLikeImage(width: 90, height: 140)
        let first = source.cropping(to: CGRect(x: 0, y: 0, width: 90, height: 72))!
        let second = source.cropping(to: CGRect(x: 0, y: 13, width: 90, height: 72))!
        var stitcher = try ScrollingImageStitcher(firstFrame: first)

        let result = try stitcher.append(second)
        let image = try stitcher.makeImage()
        let expected = source.cropping(to: CGRect(x: 0, y: 0, width: 90, height: 85))!

        #expect(result == .extended(newRows: 13, totalHeight: 85))
        #expect(pixelBytes(image) == pixelBytes(expected))
    }

    @Test("方向锁定后反向滚动不扩展")
    func reverseScrollDoesNotExtendLockedCapture() throws {
        var stitcher = try ScrollingImageStitcher(firstFrame: makeViewport(offset: 0))
        _ = try stitcher.append(makeViewport(offset: 8))

        let result = try stitcher.append(makeViewport(offset: 4))

        #expect(result == .reverseIgnored)
        #expect(stitcher.pixelHeight == 48)
    }

    @Test("无足够重叠时提示减慢滚动")
    func missingOverlapRequestsSlowerScrolling() throws {
        var stitcher = try ScrollingImageStitcher(firstFrame: makeViewport(offset: 0))

        let unrelated = makeNoiseImage(width: 36, height: 40, seed: 999)
        let result = try stitcher.append(unrelated)

        #expect(result == .needsSlowerScrolling)
        #expect(stitcher.pixelHeight == 40)
    }

    @Test("达到安全长度后不再保留更多像素")
    func stopsBeforeMemoryLimit() throws {
        let first = makeViewport(offset: 0)
        var stitcher = try ScrollingImageStitcher(
            firstFrame: first,
            configuration: .init(maximumPixelCount: first.width * first.height + 1)
        )

        let result = try stitcher.append(makeViewport(offset: 9))

        #expect(result == .reachedLengthLimit(totalHeight: first.height))
        #expect(stitcher.pixelHeight == first.height)
    }
}

@Suite("GIF recording")
struct GIFRecordingTests {
    @Test("按 15 FPS 节流并生成可读动画")
    func throttlesAndEncodesGIF() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("touch-gif-\(UUID().uuidString).gif")
        defer { try? FileManager.default.removeItem(at: url) }
        let encoder = try GIFRecordingEncoder(outputURL: url, framesPerSecond: 15, maximumDuration: 30)
        let frame = makeNoiseImage(width: 16, height: 12, seed: 4)

        #expect(try await encoder.append(frame, at: 0) == .appended(frameCount: 1))
        #expect(try await encoder.append(frame, at: 0.01) == .skipped)
        #expect(try await encoder.append(frame, at: 1.0 / 15.0) == .appended(frameCount: 2))
        let result = try await encoder.finish()

        #expect(result.frameCount == 2)
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)
        #expect(source != nil)
        #expect(source.map(CGImageSourceGetCount) == 2)
    }

    @Test("30 秒时停止接受新帧")
    func stopsAtMaximumDuration() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("touch-gif-limit-\(UUID().uuidString).gif")
        defer { try? FileManager.default.removeItem(at: url) }
        let encoder = try GIFRecordingEncoder(outputURL: url, framesPerSecond: 15, maximumDuration: 30)
        let frame = makeNoiseImage(width: 8, height: 8, seed: 8)

        _ = try await encoder.append(frame, at: 10)
        #expect(try await encoder.append(frame, at: 40) == .reachedDurationLimit)
        await encoder.cancel()
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}

private func makeViewport(offset: Int, width: Int = 36, height: Int = 40) -> CGImage {
    let total = makeNoiseImage(width: width, height: height + 40, seed: 71)
    return total.cropping(to: CGRect(x: 0, y: offset, width: width, height: height))!
}

private func makeChatLikeImage(width: Int, height: Int) -> CGImage {
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    for y in 0..<height {
        let message = y / 17
        let isTextRow = (y + 3) % 17 < 3
        for x in 0..<width {
            let index = (y * width + x) * 4
            let messageWidth = 34 + (message * 11) % 45
            let leading = message.isMultiple(of: 2) ? 7 : max(7, width - messageWidth - 7)
            let insideMessage = isTextRow && x >= leading && x < leading + messageWidth
            let tone = insideMessage ? UInt8(28 + (message * 23) % 150) : 246
            bytes[index] = tone
            bytes[index + 1] = insideMessage ? UInt8(45 + (message * 17) % 130) : 246
            bytes[index + 2] = insideMessage ? UInt8(62 + (message * 13) % 110) : 246
            bytes[index + 3] = 255
        }
    }
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    return CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    )!
}

private func makeNoiseImage(width: Int, height: Int, seed: UInt64) -> CGImage {
    var state = seed
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    for index in stride(from: 0, to: bytes.count, by: 4) {
        state = state &* 6_364_136_223_846_793_005 &+ 1
        bytes[index] = UInt8(truncatingIfNeeded: state >> 24)
        bytes[index + 1] = UInt8(truncatingIfNeeded: state >> 32)
        bytes[index + 2] = UInt8(truncatingIfNeeded: state >> 40)
        bytes[index + 3] = 255
    }
    let data = Data(bytes) as CFData
    let provider = CGDataProvider(data: data)!
    return CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    )!
}

private func pixelBytes(_ image: CGImage) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let context = CGContext(
        data: &bytes,
        width: image.width,
        height: image.height,
        bitsPerComponent: 8,
        bytesPerRow: image.width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.translateBy(x: 0, y: CGFloat(image.height))
    context.scaleBy(x: 1, y: -1)
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return bytes
}
