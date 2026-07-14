import Foundation
import Testing
@testable import ScreenshotFeature

@Test("全部基础标注类型可无损序列化")
func annotationKindsRoundTrip() throws {
    for kind in ScreenshotAnnotationKind.allCases {
        let annotation = ScreenshotAnnotation(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            kind: kind,
            points: [.init(x: 1.25, y: 2.5), .init(x: 80, y: 60)],
            style: .init(
                color: .init(red: 0.1, green: 0.2, blue: 0.3, alpha: 0.4),
                lineWidth: 3.5
            ),
            text: kind == .text ? .init(value: "示例文本", fontSize: 16) : nil
        )
        let encoded = try JSONEncoder().encode(annotation)
        #expect(try JSONDecoder().decode(ScreenshotAnnotation.self, from: encoded) == annotation)
    }
}

@Test("马赛克图层保留画笔宽度和像素块大小")
func mosaicAnnotationRoundTrip() throws {
    let annotation = ScreenshotAnnotation(
        kind: .mosaic,
        points: [.init(x: 12, y: 18), .init(x: 80, y: 42)],
        style: .init(color: .red, lineWidth: 28),
        mosaic: .init(blockSize: 9)
    )

    let encoded = try JSONEncoder().encode(annotation)
    let decoded = try JSONDecoder().decode(ScreenshotAnnotation.self, from: encoded)

    #expect(decoded == annotation)
    #expect(decoded.mosaic?.blockSize == 9)
}

@Test("贴纸图层保留图案和显示大小")
func stickerAnnotationRoundTrip() throws {
    let annotation = ScreenshotAnnotation(
        kind: .sticker,
        points: [.init(x: 48, y: 32)],
        style: .init(color: .red, lineWidth: 1),
        sticker: .init(value: "🎉", size: 36)
    )

    let encoded = try JSONEncoder().encode(annotation)
    let decoded = try JSONDecoder().decode(ScreenshotAnnotation.self, from: encoded)

    #expect(decoded == annotation)
    #expect(decoded.sticker == .init(value: "🎉", size: 36))
}

@Test("水印图层保留文本、透明度、角度和间距")
func watermarkAnnotationRoundTrip() throws {
    let annotation = ScreenshotAnnotation(
        kind: .watermark,
        points: [.init(x: 0, y: 0), .init(x: 320, y: 180)],
        style: .init(color: .red, lineWidth: 1),
        watermark: .init(
            value: "仅供内部使用",
            fontSize: 16,
            opacity: 0.22,
            angleDegrees: -24,
            spacing: 72
        )
    )

    let encoded = try JSONEncoder().encode(annotation)
    let decoded = try JSONDecoder().decode(ScreenshotAnnotation.self, from: encoded)

    #expect(decoded == annotation)
    #expect(decoded.watermark?.value == "仅供内部使用")
}

@Test("美化图层保留圆角、阴影、四边边距和渐变背景")
func beautifyAnnotationRoundTrip() throws {
    let beautify = ScreenshotAnnotationBeautify(
        cornerRadius: 18,
        shadowRadius: 16,
        shadowOpacity: 0.24,
        shadowOffsetX: 0,
        shadowOffsetY: 6,
        insets: .init(top: 30, right: 36, bottom: 42, left: 48),
        backgroundGradient: .init(
            colors: [
                .init(red: 0.35, green: 0.22, blue: 0.9),
                .init(red: 0.2, green: 0.75, blue: 0.95),
                .init(red: 0.45, green: 0.9, blue: 0.72)
            ],
            angleDegrees: 24
        )
    )
    let annotation = ScreenshotAnnotation(
        kind: .beautify,
        points: [.init(x: 0, y: 0), .init(x: 320, y: 180)],
        style: .init(color: .red, lineWidth: 1),
        beautify: beautify
    )

    let encoded = try JSONEncoder().encode(annotation)
    let decoded = try JSONDecoder().decode(ScreenshotAnnotation.self, from: encoded)

    #expect(decoded == annotation)
    #expect(decoded.beautify == beautify)
}

@Test("模糊与放大镜参数可无损序列化，裁剪边界保留在非破坏图层")
func localEffectsAndCropRoundTrip() throws {
    let annotations: [ScreenshotAnnotation] = [
        .init(
            kind: .blur,
            points: [.init(x: 12, y: 18), .init(x: 90, y: 72)],
            style: .init(color: .red, lineWidth: 1),
            blur: .init(radius: 14)
        ),
        .init(
            kind: .magnifier,
            points: [.init(x: 80, y: 60)],
            style: .init(color: .red, lineWidth: 3),
            magnifier: .init(magnification: 2.5, diameter: 128, borderWidth: 4)
        ),
        .init(
            kind: .crop,
            points: [.init(x: 10, y: 20), .init(x: 300, y: 180)],
            style: .init(color: .red, lineWidth: 1)
        )
    ]

    let encoded = try JSONEncoder().encode(annotations)
    let decoded = try JSONDecoder().decode([ScreenshotAnnotation].self, from: encoded)

    #expect(decoded == annotations)
    #expect(decoded[0].blur?.radius == 14)
    #expect(decoded[1].magnifier?.magnification == 2.5)
    #expect(decoded[2].points == [.init(x: 10, y: 20), .init(x: 300, y: 180)])
}

@Test("旧捕获请求缺少 annotations 时按空图层兼容")
func legacyCaptureRequestDefaultsToNoAnnotations() throws {
    let request = ScreenshotCaptureRequest(
        id: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
        mode: .region,
        target: .region(displayID: 1, rect: .init(x: 10, y: 20, width: 30, height: 40))
    )
    var object = try #require(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
    )
    object.removeValue(forKey: "annotations")

    let decoded = try JSONDecoder().decode(
        ScreenshotCaptureRequest.self,
        from: JSONSerialization.data(withJSONObject: object)
    )

    #expect(decoded.annotations.isEmpty)
    #expect(decoded.id == request.id)
    #expect(decoded.target == request.target)
}
