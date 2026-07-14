import Foundation
import Testing
@testable import ScreenshotFeature

@Suite("AnnotationDocument")
struct AnnotationDocumentTests {
    @Test("全部图层类型及通用样式可序列化，未知新字段会被忽略")
    func allLayerKindsAndAppearanceRoundTrip() throws {
        for (index, kind) in ScreenshotAnnotationKind.allCases.enumerated() {
            let annotation = ScreenshotAnnotation(
                id: UUID(),
                kind: kind,
                points: [.init(x: 4, y: 8), .init(x: 120, y: 80)],
                style: .init(
                    color: .init(red: 0.1, green: 0.2, blue: 0.3, alpha: 0.8),
                    lineWidth: 4
                ),
                text: [.text, .numberedMarker, .note].contains(kind)
                    ? .init(value: "触达", fontSize: 18)
                    : nil,
                mosaic: kind == .mosaic ? .init(blockSize: 12) : nil,
                blur: kind == .blur ? .init(radius: 16) : nil,
                magnifier: kind == .magnifier ? .init() : nil,
                sticker: kind == .sticker ? .init(value: "✅", size: 36) : nil,
                watermark: kind == .watermark
                    ? .init(value: "机密", fontSize: 16, opacity: 0.2, angleDegrees: -20, spacing: 64)
                    : nil,
                beautify: kind == .beautify
                    ? .init(
                        cornerRadius: 16,
                        shadowRadius: 12,
                        shadowOpacity: 0.25,
                        shadowOffsetX: 0,
                        shadowOffsetY: 4,
                        insets: .uniform(28),
                        backgroundGradient: .init(
                            colors: [.red, .yellow],
                            angleDegrees: 35
                        )
                    )
                    : nil
            )
            let layer = AnnotationLayer(
                annotation: annotation,
                opacity: 0.75,
                zIndex: index,
                font: .init(familyName: "PingFang SC", size: 18, weight: 0.4),
                cornerRadius: 9,
                shadow: .init(
                    color: .init(red: 0, green: 0, blue: 0, alpha: 0.3),
                    radius: 8,
                    offsetX: 1,
                    offsetY: 3
                ),
                contentInsets: .init(top: 8, right: 10, bottom: 12, left: 14),
                backgroundGradient: .init(colors: [.red, .yellow], angleDegrees: 45)
            )

            var object = try #require(
                JSONSerialization.jsonObject(with: JSONEncoder().encode(layer)) as? [String: Any]
            )
            object["futureLayerAttribute"] = ["enabled": true]
            let decoded = try JSONDecoder().decode(
                AnnotationLayer.self,
                from: JSONSerialization.data(withJSONObject: object)
            )

            #expect(decoded == layer)
            #expect(decoded.kind == kind)
        }
    }

    @Test("项目只引用原图路径并按 z-order 恢复图层")
    func projectRoundTripKeepsSourceSeparateAndOrdersLayers() throws {
        let lower = makeLayer(id: "11111111-1111-1111-1111-111111111111", kind: .rectangle, zIndex: 2)
        let upper = makeLayer(id: "22222222-2222-2222-2222-222222222222", kind: .text, zIndex: 9)
        let document = AnnotationDocument(
            id: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
            sourceImageRelativePath: "Captures/2026/07/source.png",
            canvasSize: .init(width: 1_440, height: 900),
            layers: [lower, upper],
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 200)
        )
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(document)) as? [String: Any]
        )
        object["futureProjectMetadata"] = "ignored"
        var encodedLayers = try #require(object["layers"] as? [[String: Any]])
        encodedLayers.reverse()
        object["layers"] = encodedLayers

        let decoded = try JSONDecoder().decode(
            AnnotationDocument.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        #expect(decoded.sourceImageRelativePath == "Captures/2026/07/source.png")
        #expect(decoded.layers.map(\.id) == [lower.id, upper.id])
        #expect(decoded.layers.map(\.zIndex) == [0, 1])
        #expect(decoded.canvasSize == .init(width: 1_440, height: 900))
    }
}

private func makeLayer(id: String, kind: ScreenshotAnnotationKind, zIndex: Int = 0) -> AnnotationLayer {
    AnnotationLayer(
        annotation: .init(
            id: UUID(uuidString: id)!,
            kind: kind,
            points: [.init(x: 1, y: 2), .init(x: 40, y: 30)],
            style: .init(color: .red, lineWidth: 3),
            text: kind == .text ? .init(value: "文字", fontSize: 16) : nil
        ),
        zIndex: zIndex
    )
}
