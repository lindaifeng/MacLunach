import Foundation

public enum AnnotationCommandHistoryError: Error, Equatable, Sendable {
    case layerNotFound(UUID)
    case invalidCropLayer
}

public enum AnnotationCommandKind: Equatable, Sendable {
    case add(UUID)
    case remove(UUID)
    case update(UUID)
    case reorder(UUID)
    case crop
}

/// 非破坏性文档的命令历史。历史只保存文档值和图层元数据，不保存图片数据。
public struct AnnotationCommandHistory: Sendable {
    private struct Entry: Sendable {
        var kind: AnnotationCommandKind
        var before: AnnotationDocument
        var after: AnnotationDocument
        var coalescingKey: String?
    }

    public private(set) var document: AnnotationDocument
    private var undoEntries: [Entry] = []
    private var redoEntries: [Entry] = []

    public init(document: AnnotationDocument) {
        self.document = document
    }

    public var canUndo: Bool { !undoEntries.isEmpty }
    public var canRedo: Bool { !redoEntries.isEmpty }
    public var undoCount: Int { undoEntries.count }
    public var redoCount: Int { redoEntries.count }

    public mutating func add(_ layer: AnnotationLayer, at requestedIndex: Int? = nil) {
        var layers = document.layers
        let index = min(max(0, requestedIndex ?? layers.count), layers.count)
        layers.insert(layer.replacingZIndex(index), at: index)
        record(kind: .add(layer.id), after: document.replacingLayers(layers))
    }

    @discardableResult
    public mutating func remove(id: UUID) throws -> AnnotationLayer {
        guard let index = document.layers.firstIndex(where: { $0.id == id }) else {
            throw AnnotationCommandHistoryError.layerNotFound(id)
        }
        var layers = document.layers
        let removed = layers.remove(at: index)
        record(kind: .remove(id), after: document.replacingLayers(layers))
        return removed
    }

    /// 更新同一图层时传入稳定的 `coalescingKey`（例如一次拖动手势 ID），
    /// 连续事件会合并成一个撤销步骤。
    public mutating func update(
        _ layer: AnnotationLayer,
        coalescingKey: String? = nil
    ) throws {
        guard let index = document.layers.firstIndex(where: { $0.id == layer.id }) else {
            throw AnnotationCommandHistoryError.layerNotFound(layer.id)
        }
        var layers = document.layers
        layers[index] = layer.replacingZIndex(index)
        let after = document.replacingLayers(layers)

        if let coalescingKey,
           redoEntries.isEmpty,
           let lastIndex = undoEntries.indices.last,
           undoEntries[lastIndex].kind == .update(layer.id),
           undoEntries[lastIndex].coalescingKey == coalescingKey {
            undoEntries[lastIndex].after = after
            document = after
            return
        }
        record(kind: .update(layer.id), after: after, coalescingKey: coalescingKey)
    }

    public mutating func reorder(id: UUID, to requestedIndex: Int) throws {
        guard let sourceIndex = document.layers.firstIndex(where: { $0.id == id }) else {
            throw AnnotationCommandHistoryError.layerNotFound(id)
        }
        var layers = document.layers
        let layer = layers.remove(at: sourceIndex)
        let targetIndex = min(max(0, requestedIndex), layers.count)
        layers.insert(layer, at: targetIndex)
        record(kind: .reorder(id), after: document.replacingLayers(layers))
    }

    /// 裁剪作为唯一图层进入同一命令历史；新裁剪会替换旧裁剪，传 nil 可清除。
    public mutating func setCrop(_ cropLayer: AnnotationLayer?) throws {
        if let cropLayer, cropLayer.kind != .crop {
            throw AnnotationCommandHistoryError.invalidCropLayer
        }
        var layers = document.layers.filter { $0.kind != .crop }
        if let cropLayer {
            layers.append(cropLayer)
        }
        record(kind: .crop, after: document.replacingLayers(layers))
    }

    @discardableResult
    public mutating func undo() -> Bool {
        guard let entry = undoEntries.popLast() else { return false }
        document = entry.before
        redoEntries.append(entry)
        return true
    }

    @discardableResult
    public mutating func redo() -> Bool {
        guard let entry = redoEntries.popLast() else { return false }
        document = entry.after
        undoEntries.append(entry)
        return true
    }

    private mutating func record(
        kind: AnnotationCommandKind,
        after: AnnotationDocument,
        coalescingKey: String? = nil
    ) {
        undoEntries.append(
            Entry(kind: kind, before: document, after: after, coalescingKey: coalescingKey)
        )
        document = after
        redoEntries.removeAll(keepingCapacity: true)
    }
}
