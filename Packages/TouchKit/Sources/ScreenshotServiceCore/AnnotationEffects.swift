import CoreGraphics
import CoreImage
import Foundation
import ScreenshotFeature

/// 可跨请求复用的 Core Image 效果上下文。CIContext 本身是线程安全的，包装类型显式承担并发约束。
public final class AnnotationEffects: @unchecked Sendable {
    public static let shared = AnnotationEffects()

    private let context: CIContext

    public init(context: CIContext = CIContext(options: [
        .cacheIntermediates: false,
        .priorityRequestLow: false
    ])) {
        self.context = context
    }

    public func gaussianBlur(image: CGImage, radius: Double) throws -> CGImage {
        let input = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CIGaussianBlur") else {
            throw ScreenshotFeatureError.encodingFailed
        }
        filter.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(min(max(radius.isFinite ? radius : 0, 0), 256), forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage?.cropped(to: input.extent),
              let image = context.createCGImage(output, from: input.extent) else {
            throw ScreenshotFeatureError.encodingFailed
        }
        return image
    }
}
