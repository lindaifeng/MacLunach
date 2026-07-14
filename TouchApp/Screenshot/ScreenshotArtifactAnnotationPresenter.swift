import AppKit
import ScreenshotFeature

@MainActor
protocol ScreenshotArtifactAnnotationPresenting: AnyObject {
    func presentForAnnotation(_ artifact: ScreenshotArtifact) throws
}

enum ScreenshotArtifactAnnotationPresentationError: Error, Equatable {
    case openFailed(relativePath: String)
}

/// 在内建捕获后编辑器完成前，将原图交给系统默认图片编辑器。
/// 路径仍通过 ScreenshotFeaturePaths 校验，避免接受不可信的绝对路径或路径遍历。
@MainActor
final class SystemScreenshotArtifactAnnotationPresenter: ScreenshotArtifactAnnotationPresenting {
    typealias PathsProvider = () throws -> ScreenshotFeaturePaths
    typealias OpenURL = (URL) -> Bool

    private let pathsProvider: PathsProvider
    private let openURL: OpenURL

    init(
        pathsProvider: @escaping PathsProvider = { try ScreenshotFeaturePaths.applicationSupport() },
        openURL: @escaping OpenURL = { NSWorkspace.shared.open($0) }
    ) {
        self.pathsProvider = pathsProvider
        self.openURL = openURL
    }

    func presentForAnnotation(_ artifact: ScreenshotArtifact) throws {
        let url = try pathsProvider().resolve(relativePath: artifact.relativePath)
        guard openURL(url) else {
            throw ScreenshotArtifactAnnotationPresentationError.openFailed(
                relativePath: artifact.relativePath
            )
        }
    }
}
