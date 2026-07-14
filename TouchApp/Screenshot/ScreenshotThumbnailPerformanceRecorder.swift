import Foundation
import os

/// 记录截图服务返回产物后，到浮动缩略图进入首个主线程渲染周期的耗时。
@MainActor
final class ScreenshotThumbnailPerformanceRecorder {
    static let shared = ScreenshotThumbnailPerformanceRecorder()

    private let signposter = OSSignposter(
        subsystem: "me.touch.launcher",
        category: "ScreenshotPerformance"
    )
    private var intervalState: OSSignpostIntervalState?
    private var startNanoseconds: UInt64?
    private var preparedCompletion: ((Double) -> Void)?

    private init() {}

    /// 性能 fixture 在下一次截图前注册一次性回调；正常使用无需调用。
    func prepareNextSample(completion: @escaping (Double) -> Void) {
        preparedCompletion = completion
    }

    func begin() {
        cancelInterval(preservingPreparedCompletion: true)
        intervalState = signposter.beginInterval("ScreenshotArtifactToThumbnailFrame")
        startNanoseconds = DispatchTime.now().uptimeNanoseconds
    }

    func endAfterRenderedFrame() {
        guard let startNanoseconds else { return }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - startNanoseconds) / 1_000_000
        if let intervalState {
            signposter.endInterval("ScreenshotArtifactToThumbnailFrame", intervalState)
        }
        let completion = preparedCompletion
        intervalState = nil
        self.startNanoseconds = nil
        preparedCompletion = nil
        completion?(elapsed)
    }

    func cancel() {
        cancelInterval(preservingPreparedCompletion: false)
    }

    private func cancelInterval(preservingPreparedCompletion: Bool) {
        if let intervalState {
            signposter.endInterval("ScreenshotArtifactToThumbnailFrame", intervalState)
        }
        intervalState = nil
        startNanoseconds = nil
        if !preservingPreparedCompletion {
            preparedCompletion = nil
        }
    }
}
