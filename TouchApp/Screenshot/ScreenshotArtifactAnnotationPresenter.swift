import AppKit
import ScreenshotFeature

@MainActor
protocol ScreenshotArtifactAnnotationPresenting: AnyObject {
    func presentForAnnotation(_ artifact: ScreenshotArtifact) throws
}

@MainActor
protocol AnnotationEditorPresenting: AnyObject {
    func present()
}

extension AnnotationEditorController: AnnotationEditorPresenting {}

enum ScreenshotArtifactAnnotationPresentationError: Error, Equatable {
    case openFailed(relativePath: String)
    case imageLoadFailed(relativePath: String)
}

/// 将原图交给系统默认图片编辑器的兼容实现。路径仍通过 ScreenshotFeaturePaths
/// 校验，避免接受不可信的绝对路径或路径遍历。
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

/// 使用触达自己的非破坏性图层编辑器打开截图；同一截图重复触发时复用已有窗口。
@MainActor
final class BuiltInScreenshotArtifactAnnotationPresenter: ScreenshotArtifactAnnotationPresenting {
    typealias PathsProvider = () throws -> ScreenshotFeaturePaths
    typealias ImageLoader = (URL) -> NSImage?
    typealias ProjectLoader = @MainActor (String, AnnotationDocument) async throws -> AnnotationDocument
    typealias ControllerFactory = @MainActor (
        ScreenshotArtifact,
        NSImage,
        URL,
        AnnotationDocument,
        @escaping (UUID) -> Void
    ) -> any AnnotationEditorPresenting

    private let pathsProvider: PathsProvider
    private let imageLoader: ImageLoader
    private let projectLoader: ProjectLoader
    private let controllerFactory: ControllerFactory
    private var controllers: [UUID: any AnnotationEditorPresenting] = [:]
    private var loadingArtifactIDs: Set<UUID> = []

    init(
        client: ScreenshotClient,
        themeStore: ThemeStore = ThemeStore(),
        pathsProvider: @escaping PathsProvider = { try ScreenshotFeaturePaths.applicationSupport() },
        imageLoader: @escaping ImageLoader = { NSImage(contentsOf: $0) }
    ) {
        self.pathsProvider = pathsProvider
        self.imageLoader = imageLoader
        projectLoader = { relativePath, fallbackDocument in
            try await client.loadAnnotationProject(
                relativePath: relativePath,
                fallbackDocument: fallbackDocument
            ).document
        }
        controllerFactory = { artifact, sourceImage, sourceURL, document, onClose in
            AnnotationEditorController(
                artifact: artifact,
                sourceImage: sourceImage,
                sourceURL: sourceURL,
                document: document,
                client: client,
                themeStore: themeStore,
                onClose: onClose
            )
        }
    }

    init(
        pathsProvider: @escaping PathsProvider,
        imageLoader: @escaping ImageLoader,
        projectLoader: @escaping ProjectLoader,
        controllerFactory: @escaping ControllerFactory
    ) {
        self.pathsProvider = pathsProvider
        self.imageLoader = imageLoader
        self.projectLoader = projectLoader
        self.controllerFactory = controllerFactory
    }

    func presentForAnnotation(_ artifact: ScreenshotArtifact) throws {
        if let controller = controllers[artifact.id] {
            controller.present()
            return
        }
        guard !loadingArtifactIDs.contains(artifact.id) else { return }

        let sourceURL = try pathsProvider().resolve(relativePath: artifact.relativePath)
        guard let sourceImage = imageLoader(sourceURL) else {
            throw ScreenshotArtifactAnnotationPresentationError.imageLoadFailed(
                relativePath: artifact.relativePath
            )
        }
        let fallbackDocument = AnnotationDocument(
            id: artifact.id,
            sourceImageRelativePath: artifact.relativePath,
            canvasSize: artifact.pointSize,
            createdAt: artifact.createdAt,
            updatedAt: artifact.createdAt
        )
        loadingArtifactIDs.insert(artifact.id)

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.loadingArtifactIDs.remove(artifact.id) }
            let projectPath = AnnotationProjectPaths.relativePath(documentID: artifact.id)
            let loadedDocument = try? await self.projectLoader(projectPath, fallbackDocument)
            guard self.controllers[artifact.id] == nil else {
                self.controllers[artifact.id]?.present()
                return
            }
            let controller = self.controllerFactory(
                artifact,
                sourceImage,
                sourceURL,
                loadedDocument ?? fallbackDocument,
                { [weak self] artifactID in
                    self?.controllers.removeValue(forKey: artifactID)
                }
            )
            self.controllers[artifact.id] = controller
            controller.present()
        }
    }
}
