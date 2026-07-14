import Foundation

/// 原图与可编辑图层分离保存的标注项目。
///
/// 所有存储属性均不可变；编辑操作返回新文档，从而让撤销栈只复制小型值对象，
/// 不会把原始位图复制进命令历史。
public struct AnnotationDocument: Codable, Equatable, Identifiable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let id: UUID
    public let sourceImageRelativePath: String
    public let canvasSize: ScreenshotSize
    public let layers: [AnnotationLayer]
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        id: UUID = UUID(),
        sourceImageRelativePath: String,
        canvasSize: ScreenshotSize,
        layers: [AnnotationLayer] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.sourceImageRelativePath = sourceImageRelativePath
        self.canvasSize = canvasSize
        self.layers = Self.normalized(layers)
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public func replacingLayers(_ layers: [AnnotationLayer], updatedAt: Date = Date()) -> Self {
        Self(
            schemaVersion: schemaVersion,
            id: id,
            sourceImageRelativePath: sourceImageRelativePath,
            canvasSize: canvasSize,
            layers: layers,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    /// 项目损坏时回到原始图片，不沿用任何可能不可信的编辑图层。
    public func restoringOriginalImage(updatedAt: Date = Date()) -> Self {
        replacingLayers([], updatedAt: updatedAt)
    }

    private static func normalized(_ layers: [AnnotationLayer]) -> [AnnotationLayer] {
        layers
            .enumerated()
            .map { index, layer in layer.replacingZIndex(index) }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case id
        case sourceImageRelativePath
        case canvasSize
        case layers
        case createdAt
        case updatedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? Self.currentSchemaVersion
        id = try container.decode(UUID.self, forKey: .id)
        sourceImageRelativePath = try container.decode(String.self, forKey: .sourceImageRelativePath)
        canvasSize = try container.decode(ScreenshotSize.self, forKey: .canvasSize)
        let decodedLayers = try container.decodeIfPresent([AnnotationLayer].self, forKey: .layers) ?? []
        let orderedLayers = decodedLayers.enumerated().sorted { lhs, rhs in
            if lhs.element.zIndex == rhs.element.zIndex {
                return lhs.offset < rhs.offset
            }
            return lhs.element.zIndex < rhs.element.zIndex
        }.map(\.element)
        layers = Self.normalized(orderedLayers)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
            ?? Date(timeIntervalSince1970: 0)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }
}
