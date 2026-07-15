import ScreenshotFeature
import XCTest
@testable import 触达

@MainActor
final class AnnotationEditorStateTests: XCTestCase {
    func testArtifactCreatesCleanEmptyDocument() {
        let state = makeState()

        XCTAssertEqual(state.document.sourceImageRelativePath, "Captures/source.png")
        XCTAssertEqual(state.document.id, state.artifact.id)
        XCTAssertEqual(state.document.canvasSize, .init(width: 800, height: 600))
        XCTAssertTrue(state.document.layers.isEmpty)
        XCTAssertNil(state.selectedLayerID)
        XCTAssertFalse(state.isDirty)
        XCTAssertEqual(state.closeRequirement, .closeImmediately)
    }

    func testEveryToolHasAUniqueSingleKeyShortcut() {
        let shortcuts = AnnotationEditorTool.allCases.map(\.keyboardShortcut)

        XCTAssertEqual(Set(shortcuts).count, AnnotationEditorTool.allCases.count)
        XCTAssertTrue(shortcuts.allSatisfy { $0.count == 1 })
    }

    func testAddDeleteUndoAndRedoKeepSelectionValid() throws {
        let state = makeState()
        let layer = makeLayer()

        try state.add(layer)
        XCTAssertEqual(state.document.layers.map(\.id), [layer.id])
        XCTAssertEqual(state.selectedLayerID, layer.id)
        XCTAssertTrue(state.canUndo)
        XCTAssertTrue(state.isDirty)

        XCTAssertTrue(state.undo())
        XCTAssertTrue(state.document.layers.isEmpty)
        XCTAssertNil(state.selectedLayerID)
        XCTAssertTrue(state.canRedo)

        XCTAssertTrue(state.redo())
        XCTAssertEqual(state.document.layers.map(\.id), [layer.id])
        XCTAssertTrue(state.selectLayer(id: layer.id))
        XCTAssertTrue(try state.deleteSelectedLayer())
        XCTAssertTrue(state.document.layers.isEmpty)
        XCTAssertNil(state.selectedLayerID)

        XCTAssertTrue(state.undo())
        XCTAssertEqual(state.document.layers.map(\.id), [layer.id])
    }

    func testKeyboardLayerSelectionWrapsInDocumentOrder() throws {
        let first = makeLayer(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        )
        let second = makeLayer(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        )
        let third = makeLayer(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        )
        let state = makeState(document: makeDocument(layers: [first, second, third]))

        XCTAssertTrue(state.selectNextLayer())
        XCTAssertEqual(state.selectedLayerID, first.id)
        XCTAssertTrue(state.selectNextLayer())
        XCTAssertEqual(state.selectedLayerID, second.id)
        XCTAssertTrue(state.selectNextLayer())
        XCTAssertEqual(state.selectedLayerID, third.id)
        XCTAssertTrue(state.selectNextLayer())
        XCTAssertEqual(state.selectedLayerID, first.id)

        XCTAssertTrue(state.selectPreviousLayer())
        XCTAssertEqual(state.selectedLayerID, third.id)
        XCTAssertTrue(state.selectLayer(id: nil))
        XCTAssertTrue(state.selectPreviousLayer())
        XCTAssertEqual(state.selectedLayerID, third.id)

        let emptyState = makeState()
        XCTAssertFalse(emptyState.selectNextLayer())
        XCTAssertFalse(emptyState.selectPreviousLayer())
        XCTAssertNil(emptyState.selectedLayerID)
    }

    func testSelectedLayerCanMoveThroughZOrderAndUndo() throws {
        let bottom = makeLayer(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            points: [.init(x: 10, y: 10), .init(x: 20, y: 20)]
        )
        let middle = makeLayer(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            points: [.init(x: 30, y: 30), .init(x: 40, y: 40)]
        )
        let top = makeLayer(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            points: [.init(x: 50, y: 50), .init(x: 60, y: 60)]
        )
        let state = makeState(document: makeDocument(layers: [bottom, middle, top]))
        XCTAssertTrue(state.selectLayer(id: middle.id))
        XCTAssertTrue(state.canMoveSelectedLayerBackward)
        XCTAssertTrue(state.canMoveSelectedLayerForward)

        XCTAssertTrue(try state.bringSelectedLayerToFront())
        XCTAssertEqual(state.document.layers.map(\.id), [bottom.id, top.id, middle.id])
        XCTAssertEqual(state.document.layers.map(\.zIndex), [0, 1, 2])
        XCTAssertFalse(state.canMoveSelectedLayerForward)
        XCTAssertTrue(state.canMoveSelectedLayerBackward)

        XCTAssertTrue(try state.sendSelectedLayerToBack())
        XCTAssertEqual(state.document.layers.map(\.id), [middle.id, bottom.id, top.id])
        XCTAssertFalse(state.canMoveSelectedLayerBackward)
        XCTAssertTrue(state.canMoveSelectedLayerForward)

        XCTAssertTrue(state.undo())
        XCTAssertEqual(state.document.layers.map(\.id), [bottom.id, top.id, middle.id])
        XCTAssertEqual(state.selectedLayerID, middle.id)
        XCTAssertTrue(state.undo())
        XCTAssertEqual(state.document.layers.map(\.id), [bottom.id, middle.id, top.id])
        XCTAssertFalse(state.isDirty)
    }

    func testKeyboardNudgeClampsWholeLayerToCanvasAndCanUndo() throws {
        let layer = makeLayer(
            points: [.init(x: 790, y: 590), .init(x: 795, y: 595)]
        )
        let document = makeDocument(layers: [layer])
        let state = makeState(document: document)
        XCTAssertTrue(state.selectLayer(id: layer.id))

        XCTAssertTrue(try state.nudgeSelectedLayer(deltaX: 10, deltaY: 10))
        XCTAssertEqual(
            state.selectedLayer?.annotation.points,
            [.init(x: 795, y: 595), .init(x: 800, y: 600)]
        )
        XCTAssertTrue(state.isDirty)

        XCTAssertTrue(state.undo())
        XCTAssertEqual(state.selectedLayer?.annotation.points, layer.annotation.points)
        XCTAssertFalse(state.isDirty)
    }

    func testResizeMapsAllPointsFromStableOriginalBoundsAndCoalescesUndo() throws {
        let layer = makeLayer(points: [
            .init(x: 20, y: 30),
            .init(x: 120, y: 30),
            .init(x: 70, y: 90)
        ])
        let state = makeState(document: makeDocument(layers: [layer]))
        XCTAssertTrue(state.selectLayer(id: layer.id))

        XCTAssertTrue(try state.resizeSelectedLayer(
            to: CGRect(x: 40, y: 50, width: 200, height: 120),
            from: layer.annotation.points,
            coalescingKey: "resize-gesture"
        ))
        XCTAssertTrue(try state.resizeSelectedLayer(
            to: CGRect(x: 60, y: 70, width: 300, height: 180),
            from: layer.annotation.points,
            coalescingKey: "resize-gesture"
        ))
        XCTAssertEqual(state.selectedLayer?.annotation.points, [
            .init(x: 60, y: 70),
            .init(x: 360, y: 70),
            .init(x: 210, y: 250)
        ])

        XCTAssertTrue(state.undo())
        XCTAssertEqual(state.selectedLayer, layer)
        XCTAssertFalse(state.canUndo)
        XCTAssertFalse(state.isDirty)
    }

    func testFailedSavePreservesDocumentAndCanRetry() async throws {
        let saver = SaveProbe(shouldFail: true)
        let state = makeState { document in
            try saver.save(document)
        }
        let layer = makeLayer()
        try state.add(layer)

        let firstSaveSucceeded = await state.save()
        XCTAssertFalse(firstSaveSucceeded)
        XCTAssertEqual(state.document.layers.map(\.id), [layer.id])
        XCTAssertTrue(state.isDirty)
        XCTAssertEqual(saver.documents.count, 1)
        guard case .failed(let message) = state.saveStatus else {
            return XCTFail("保存失败后应保留可重试错误")
        }
        XCTAssertTrue(message.contains("fixture save failed"))

        saver.shouldFail = false
        let retrySucceeded = await state.retrySave()
        XCTAssertTrue(retrySucceeded)
        XCTAssertEqual(saver.documents.count, 2)
        XCTAssertFalse(state.isDirty)
        XCTAssertEqual(state.saveStatus, .idle)
    }

    func testUnsavedCloseSupportsCancelDiscardSaveAndSaveFailure() async throws {
        let cancelState = makeState()
        try cancelState.add(makeLayer())
        XCTAssertEqual(cancelState.closeRequirement, .confirmUnsavedChanges)
        let cancelOutcome = await cancelState.resolveClose(choice: .cancel)
        XCTAssertEqual(cancelOutcome, .remainOpen)
        XCTAssertTrue(cancelState.isDirty)

        let discardOutcome = await cancelState.resolveClose(choice: .discard)
        XCTAssertEqual(discardOutcome, .close)

        let successfulSaver = SaveProbe()
        let saveState = makeState { try successfulSaver.save($0) }
        try saveState.add(makeLayer())
        let saveOutcome = await saveState.resolveClose(choice: .save)
        XCTAssertEqual(saveOutcome, .close)
        XCTAssertFalse(saveState.isDirty)
        XCTAssertEqual(successfulSaver.documents.count, 1)

        let failingSaver = SaveProbe(shouldFail: true)
        let failureState = makeState { try failingSaver.save($0) }
        try failureState.add(makeLayer())
        let failureOutcome = await failureState.resolveClose(choice: .save)
        XCTAssertEqual(failureOutcome, .remainOpen)
        XCTAssertTrue(failureState.isDirty)
        XCTAssertEqual(failureState.document.layers.count, 1)
    }

    func testEveryEditorToolCreatesAValidLayerAndCropRemainsUnique() throws {
        let state = makeState()
        let tools = AnnotationEditorTool.allCases.filter { $0.annotationKind != nil }

        for tool in tools {
            guard let kind = tool.annotationKind else { continue }
            let layer = try state.createLayer(
                kind: kind,
                points: [.init(x: 20, y: 30), .init(x: 140, y: 100)]
            )
            XCTAssertEqual(layer.kind, kind)
            XCTAssertFalse(layer.annotation.points.isEmpty)
        }
        XCTAssertEqual(state.document.layers.count, tools.count)
        XCTAssertEqual(state.document.layers.filter { $0.kind == .crop }.count, 1)

        let replacement = try state.createLayer(
            kind: .crop,
            points: [.init(x: 50, y: 60), .init(x: 300, y: 260)]
        )
        XCTAssertEqual(state.document.layers.filter { $0.kind == .crop }.map(\.id), [replacement.id])
        XCTAssertEqual(state.selectedLayerID, replacement.id)
    }

    func testCropIsStagedWithoutDirtyingDocumentUntilConfirmedAndCanBeCancelled() throws {
        let existingCrop = AnnotationLayer(
            annotation: .init(
                kind: .crop,
                points: [.init(x: 20, y: 30), .init(x: 700, y: 500)],
                style: .init(color: .red, lineWidth: 3)
            )
        )
        let state = makeState(document: makeDocument(layers: [existingCrop]))
        let originalDocument = state.document

        XCTAssertTrue(state.stageCrop(points: [
            .init(x: 620, y: 480),
            .init(x: 80, y: 70)
        ]))
        XCTAssertEqual(
            state.pendingCropPoints,
            [.init(x: 80, y: 70), .init(x: 620, y: 480)]
        )
        XCTAssertEqual(state.document, originalDocument)
        XCTAssertFalse(state.isDirty)
        XCTAssertTrue(state.canUndo)

        XCTAssertTrue(state.cancelPendingCrop())
        XCTAssertNil(state.pendingCropPoints)
        XCTAssertEqual(state.document, originalDocument)
        XCTAssertFalse(state.isDirty)

        XCTAssertTrue(state.stageCrop(points: [
            .init(x: -10, y: -20),
            .init(x: 900, y: 700)
        ]))
        let replacement = try XCTUnwrap(state.confirmPendingCrop())
        XCTAssertEqual(
            replacement.annotation.points,
            [.init(x: 0, y: 0), .init(x: 800, y: 600)]
        )
        XCTAssertNil(state.pendingCropPoints)
        XCTAssertEqual(state.selectedTool, .select)
        XCTAssertEqual(state.document.layers.filter { $0.kind == .crop }.map(\.id), [replacement.id])
        XCTAssertTrue(state.isDirty)

        XCTAssertTrue(state.undo())
        XCTAssertEqual(state.document, originalDocument)
        XCTAssertFalse(state.isDirty)
    }

    func testInspectorAppearanceChangesCanUndo() throws {
        let state = makeState()
        let original = makeLayer()
        let blue = ScreenshotAnnotationColor(red: 0.1, green: 0.2, blue: 0.9)
        try state.add(original)

        try state.updateSelectedAppearance(
            color: blue,
            lineWidth: 9,
            opacity: 0.4,
            fontSize: 28
        )
        XCTAssertEqual(state.selectedLayer?.annotation.style.color, blue)
        XCTAssertEqual(state.selectedLayer?.annotation.style.lineWidth, 9)
        XCTAssertEqual(state.selectedLayer?.opacity, 0.4)
        XCTAssertEqual(state.selectedLayer?.font?.size, 28)

        XCTAssertTrue(state.undo())
        XCTAssertEqual(state.selectedLayer, original)
    }

    func testEditingDuringSaveKeepsNewerChangesDirty() async throws {
        let gate = AsyncSaveGate()
        let state = makeState { document in
            await gate.save(document)
        }
        let first = makeLayer()
        try state.add(first)

        let saveTask = Task { await state.save() }
        await Task.yield()
        let second = makeLayer(points: [.init(x: 200, y: 200), .init(x: 260, y: 250)])
        try state.add(second)
        gate.finish()

        let saveSucceeded = await saveTask.value
        XCTAssertTrue(saveSucceeded)
        XCTAssertEqual(gate.documents.first?.layers.map(\.id), [first.id])
        XCTAssertEqual(state.document.layers.map(\.id), [first.id, second.id])
        XCTAssertTrue(state.isDirty)
    }

    func testTextContentAndLayerEffectsAreEditableAndUndoable() throws {
        let note = AnnotationLayer(
            annotation: .init(
                kind: .note,
                points: [.init(x: 40, y: 50), .init(x: 260, y: 180)],
                style: .init(color: .red, lineWidth: 2),
                text: .init(value: "旧便签", fontSize: 18)
            ),
            font: .init(size: 18),
            cornerRadius: 8,
            contentInsets: .uniform(8)
        )
        let state = makeState(document: makeDocument(layers: [note]))
        XCTAssertTrue(state.selectLayer(id: note.id))

        XCTAssertTrue(try state.updateSelectedContent("新的便签内容"))
        try state.updateSelectedEffects(
            cornerRadius: 22,
            shadowRadius: 14,
            shadowOpacity: 0.35,
            shadowOffsetX: 3,
            shadowOffsetY: 7,
            contentInset: 18,
            gradientStart: .init(red: 0.2, green: 0.4, blue: 0.9),
            gradientEnd: .init(red: 0.8, green: 0.3, blue: 0.6),
            gradientAngle: 45
        )

        XCTAssertEqual(state.selectedLayer?.annotation.text?.value, "新的便签内容")
        XCTAssertEqual(state.selectedEffects?.cornerRadius, 22)
        XCTAssertEqual(state.selectedEffects?.shadowRadius, 14)
        XCTAssertEqual(state.selectedEffects?.shadowOpacity, 0.35)
        XCTAssertEqual(state.selectedEffects?.shadowOffsetX, 3)
        XCTAssertEqual(state.selectedEffects?.shadowOffsetY, 7)
        XCTAssertEqual(state.selectedEffects?.contentInset, 18)
        XCTAssertEqual(state.selectedEffects?.gradientAngle, 45)

        XCTAssertTrue(state.undo())
        XCTAssertEqual(state.selectedEffects?.cornerRadius, 8)
        XCTAssertEqual(state.selectedEffects?.contentInset, 8)
        XCTAssertNil(state.selectedLayer?.shadow)
        XCTAssertTrue(state.undo())
        XCTAssertEqual(state.selectedLayer?.annotation.text?.value, "旧便签")
    }

    func testBeautifyEffectsUpdateDedicatedRendererPayload() throws {
        let state = makeState()
        let beautify = try state.createLayer(
            kind: .beautify,
            points: [.init(x: 0, y: 0), .init(x: 800, y: 600)]
        )
        let start = ScreenshotAnnotationColor(red: 0.1, green: 0.2, blue: 0.3)
        let end = ScreenshotAnnotationColor(red: 0.8, green: 0.7, blue: 0.6)

        try state.updateSelectedEffects(
            cornerRadius: 30,
            shadowRadius: 20,
            shadowOpacity: 0.4,
            shadowOffsetX: -4,
            shadowOffsetY: 16,
            contentInset: 42,
            gradientStart: start,
            gradientEnd: end,
            gradientAngle: 90
        )

        let payload = try XCTUnwrap(state.selectedLayer?.annotation.beautify)
        XCTAssertEqual(state.selectedLayerID, beautify.id)
        XCTAssertEqual(payload.cornerRadius, 30)
        XCTAssertEqual(payload.shadowRadius, 20)
        XCTAssertEqual(payload.shadowOpacity, 0.4)
        XCTAssertEqual(payload.shadowOffsetX, -4)
        XCTAssertEqual(payload.shadowOffsetY, 16)
        XCTAssertEqual(payload.insets, .uniform(42))
        XCTAssertEqual(payload.backgroundGradient.colors, [start, end])
        XCTAssertEqual(payload.backgroundGradient.angleDegrees, 90)
        XCTAssertNil(state.selectedLayer?.backgroundGradient)

        XCTAssertTrue(state.undo())
        XCTAssertNotEqual(state.selectedLayer?.annotation.beautify, payload)
    }
}

@MainActor
private final class SaveProbe {
    var shouldFail: Bool
    private(set) var documents: [AnnotationDocument] = []

    init(shouldFail: Bool = false) {
        self.shouldFail = shouldFail
    }

    func save(_ document: AnnotationDocument) throws {
        documents.append(document)
        if shouldFail {
            throw SaveProbeError.failed
        }
    }
}

@MainActor
private final class AsyncSaveGate {
    private(set) var documents: [AnnotationDocument] = []
    private var continuation: CheckedContinuation<Void, Never>?

    func save(_ document: AnnotationDocument) async {
        documents.append(document)
        await withCheckedContinuation { continuation = $0 }
    }

    func finish() {
        continuation?.resume()
        continuation = nil
    }
}

private enum SaveProbeError: LocalizedError {
    case failed

    var errorDescription: String? { "fixture save failed" }
}

@MainActor
private func makeState(
    document: AnnotationDocument? = nil,
    save: @escaping AnnotationEditorState.SaveHandler = { _ in }
) -> AnnotationEditorState {
    AnnotationEditorState(
        artifact: makeArtifact(),
        document: document,
        save: save
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

private func makeDocument(layers: [AnnotationLayer]) -> AnnotationDocument {
    AnnotationDocument(
        id: UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!,
        sourceImageRelativePath: "Captures/source.png",
        canvasSize: .init(width: 800, height: 600),
        layers: layers,
        createdAt: Date(timeIntervalSince1970: 100),
        updatedAt: Date(timeIntervalSince1970: 100)
    )
}

private func makeLayer(
    id: UUID = UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!,
    points: [ScreenshotAnnotationPoint] = [
        .init(x: 20, y: 30),
        .init(x: 120, y: 90)
    ]
) -> AnnotationLayer {
    AnnotationLayer(
        annotation: .init(
            id: id,
            kind: .rectangle,
            points: points,
            style: .init(color: .red, lineWidth: 3)
        )
    )
}
