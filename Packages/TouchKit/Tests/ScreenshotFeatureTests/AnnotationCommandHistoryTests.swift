import Foundation
import Testing
@testable import ScreenshotFeature

@Suite("AnnotationCommandHistory")
struct AnnotationCommandHistoryTests {
    @Test("add remove update reorder crop 均可撤销重做")
    func allCommandsUndoAndRedo() throws {
        let first = historyLayer(id: "11111111-1111-1111-1111-111111111111", kind: .rectangle)
        let second = historyLayer(id: "22222222-2222-2222-2222-222222222222", kind: .ellipse)
        let crop = historyLayer(id: "33333333-3333-3333-3333-333333333333", kind: .crop)
        var history = AnnotationCommandHistory(document: emptyDocument())

        history.add(first)
        history.add(second)
        try history.reorder(id: second.id, to: 0)
        let movedFirst = first.replacingAnnotation(
            ScreenshotAnnotation(
                id: first.id,
                kind: .rectangle,
                points: [.init(x: 20, y: 25), .init(x: 90, y: 80)],
                style: .init(color: .red, lineWidth: 3)
            )
        )
        try history.update(movedFirst)
        try history.setCrop(crop)
        let removed = try history.remove(id: second.id)

        #expect(removed.id == second.id)
        #expect(history.document.layers.map(\.id) == [movedFirst.id, crop.id])

        for _ in 0..<6 {
            let didUndo = history.undo()
            #expect(didUndo)
        }
        #expect(history.document.layers.isEmpty)
        #expect(!history.canUndo)

        for _ in 0..<6 {
            let didRedo = history.redo()
            #expect(didRedo)
        }
        #expect(history.document.layers.map(\.id) == [movedFirst.id, crop.id])
        #expect(!history.canRedo)
    }

    @Test("撤销后执行新命令会清空 redo 分支")
    func newCommandClearsRedoBranch() {
        var history = AnnotationCommandHistory(document: emptyDocument())
        history.add(historyLayer(id: "11111111-1111-1111-1111-111111111111", kind: .line))
        history.add(historyLayer(id: "22222222-2222-2222-2222-222222222222", kind: .arrow))

        let didUndo = history.undo()
        #expect(didUndo)
        #expect(history.canRedo)
        history.add(historyLayer(id: "33333333-3333-3333-3333-333333333333", kind: .text))

        #expect(!history.canRedo)
        let didRedo = history.redo()
        #expect(!didRedo)
    }

    @Test("同一拖动手势的连续更新合并为单个撤销步骤")
    func continuousDragUpdatesCoalesce() throws {
        let original = historyLayer(id: "11111111-1111-1111-1111-111111111111", kind: .rectangle)
        var history = AnnotationCommandHistory(
            document: emptyDocument().replacingLayers([original])
        )
        let firstMove = moved(original, x: 10)
        let secondMove = moved(original, x: 30)

        try history.update(firstMove, coalescingKey: "drag-1")
        try history.update(secondMove, coalescingKey: "drag-1")

        #expect(history.undoCount == 1)
        #expect(history.document.layers.first?.annotation.points.first?.x == 30)
        let didUndo = history.undo()
        #expect(didUndo)
        #expect(history.document.layers.first == original.replacingZIndex(0))
        let didRedo = history.redo()
        #expect(didRedo)
        #expect(history.document.layers.first?.annotation.points.first?.x == 30)
    }

    @Test("裁剪命令只保留最后一层且拒绝非裁剪图层")
    func cropIsUniqueAndValidated() throws {
        let crop1 = historyLayer(id: "11111111-1111-1111-1111-111111111111", kind: .crop)
        let crop2 = historyLayer(id: "22222222-2222-2222-2222-222222222222", kind: .crop)
        var history = AnnotationCommandHistory(document: emptyDocument())

        try history.setCrop(crop1)
        try history.setCrop(crop2)
        #expect(history.document.layers.filter { $0.kind == .crop }.map(\.id) == [crop2.id])

        #expect(throws: AnnotationCommandHistoryError.invalidCropLayer) {
            try history.setCrop(historyLayer(
                id: "33333333-3333-3333-3333-333333333333",
                kind: .rectangle
            ))
        }
    }
}

private func emptyDocument() -> AnnotationDocument {
    AnnotationDocument(
        id: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
        sourceImageRelativePath: "Captures/original.png",
        canvasSize: .init(width: 800, height: 600),
        createdAt: Date(timeIntervalSince1970: 100),
        updatedAt: Date(timeIntervalSince1970: 100)
    )
}

private func historyLayer(id: String, kind: ScreenshotAnnotationKind) -> AnnotationLayer {
    AnnotationLayer(
        annotation: .init(
            id: UUID(uuidString: id)!,
            kind: kind,
            points: [.init(x: 1, y: 2), .init(x: 40, y: 30)],
            style: .init(color: .red, lineWidth: 3),
            text: kind == .text ? .init(value: "文本", fontSize: 16) : nil
        )
    )
}

private func moved(_ layer: AnnotationLayer, x: Double) -> AnnotationLayer {
    layer.replacingAnnotation(
        ScreenshotAnnotation(
            id: layer.id,
            kind: layer.kind,
            points: [.init(x: x, y: 2), .init(x: x + 40, y: 30)],
            style: layer.annotation.style,
            text: layer.annotation.text
        )
    )
}
