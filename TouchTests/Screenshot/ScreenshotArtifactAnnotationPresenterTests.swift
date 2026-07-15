import AppKit
import ScreenshotFeature
import XCTest
@testable import 触达

@MainActor
final class ScreenshotArtifactAnnotationPresenterTests: XCTestCase {
    func testBuiltInPresenterRestoresProjectAndReusesExistingEditor() async throws {
        let artifact = makeArtifact()
        let restoredDocument = AnnotationDocument(
            id: artifact.id,
            sourceImageRelativePath: artifact.relativePath,
            canvasSize: artifact.pointSize,
            layers: [makeLayer()],
            createdAt: artifact.createdAt,
            updatedAt: artifact.createdAt
        )
        var loadCount = 0
        var receivedProjectPath: String?
        var receivedDocument: AnnotationDocument?
        let editor = AnnotationEditorPresentationSpy()
        let editorCreated = expectation(description: "编辑器已使用恢复项目创建")
        let presenter = makePresenter(
            projectLoader: { projectPath, _ in
                loadCount += 1
                receivedProjectPath = projectPath
                return restoredDocument
            },
            controllerFactory: { _, _, _, document, _ in
                receivedDocument = document
                editorCreated.fulfill()
                return editor
            }
        )

        try presenter.presentForAnnotation(artifact)
        await fulfillment(of: [editorCreated], timeout: 1)

        XCTAssertEqual(
            receivedProjectPath,
            AnnotationProjectPaths.relativePath(documentID: artifact.id)
        )
        XCTAssertEqual(receivedDocument, restoredDocument)
        XCTAssertEqual(loadCount, 1)
        XCTAssertEqual(editor.presentCount, 1)

        try presenter.presentForAnnotation(artifact)
        XCTAssertEqual(loadCount, 1, "重复打开同一截图不应再次读取项目")
        XCTAssertEqual(editor.presentCount, 2, "重复打开应唤回已有编辑器窗口")
    }

    func testBuiltInPresenterFallsBackWithoutLayersWhenProjectLoadFails() async throws {
        let artifact = makeArtifact()
        var receivedDocument: AnnotationDocument?
        let editorCreated = expectation(description: "项目失败后仍创建编辑器")
        let presenter = makePresenter(
            projectLoader: { _, _ in
                throw FixtureError.projectLoadFailed
            },
            controllerFactory: { _, _, _, document, _ in
                receivedDocument = document
                editorCreated.fulfill()
                return AnnotationEditorPresentationSpy()
            }
        )

        try presenter.presentForAnnotation(artifact)
        await fulfillment(of: [editorCreated], timeout: 1)

        XCTAssertEqual(receivedDocument?.id, artifact.id)
        XCTAssertEqual(receivedDocument?.sourceImageRelativePath, artifact.relativePath)
        XCTAssertEqual(receivedDocument?.canvasSize, artifact.pointSize)
        XCTAssertTrue(receivedDocument?.layers.isEmpty == true)
    }

    func testBuiltInPresenterRejectsUnreadableSourceBeforeLoadingProject() {
        let artifact = makeArtifact()
        var didLoadProject = false
        let presenter = BuiltInScreenshotArtifactAnnotationPresenter(
            pathsProvider: { ScreenshotFeaturePaths(rootURL: URL(fileURLWithPath: "/tmp/fixture")) },
            imageLoader: { _ in nil },
            projectLoader: { _, fallback in
                didLoadProject = true
                return fallback
            },
            controllerFactory: { _, _, _, _, _ in AnnotationEditorPresentationSpy() }
        )

        XCTAssertThrowsError(try presenter.presentForAnnotation(artifact)) { error in
            XCTAssertEqual(
                error as? ScreenshotArtifactAnnotationPresentationError,
                .imageLoadFailed(relativePath: artifact.relativePath)
            )
        }
        XCTAssertFalse(didLoadProject)
    }

    private func makePresenter(
        projectLoader: @escaping BuiltInScreenshotArtifactAnnotationPresenter.ProjectLoader,
        controllerFactory: @escaping BuiltInScreenshotArtifactAnnotationPresenter.ControllerFactory
    ) -> BuiltInScreenshotArtifactAnnotationPresenter {
        BuiltInScreenshotArtifactAnnotationPresenter(
            pathsProvider: { ScreenshotFeaturePaths(rootURL: URL(fileURLWithPath: "/tmp/fixture")) },
            imageLoader: { _ in NSImage(size: NSSize(width: 800, height: 600)) },
            projectLoader: projectLoader,
            controllerFactory: controllerFactory
        )
    }

    private func makeArtifact() -> ScreenshotArtifact {
        ScreenshotArtifact(
            id: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
            createdAt: Date(timeIntervalSince1970: 100),
            captureMode: .region,
            relativePath: "Captures/source.png",
            thumbnailRelativePath: "Thumbnails/source.png",
            pointSize: .init(width: 800, height: 600),
            pixelSize: .init(width: 1_600, height: 1_200),
            uniformTypeIdentifier: "public.png",
            sha256: "fixture",
            displays: []
        )
    }

    private func makeLayer() -> AnnotationLayer {
        AnnotationLayer(
            annotation: .init(
                id: UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!,
                kind: .rectangle,
                points: [.init(x: 20, y: 30), .init(x: 120, y: 90)],
                style: .init(color: .red, lineWidth: 3)
            )
        )
    }
}

@MainActor
private final class AnnotationEditorPresentationSpy: AnnotationEditorPresenting {
    private(set) var presentCount = 0

    func present() {
        presentCount += 1
    }
}

private enum FixtureError: Error {
    case projectLoadFailed
}
