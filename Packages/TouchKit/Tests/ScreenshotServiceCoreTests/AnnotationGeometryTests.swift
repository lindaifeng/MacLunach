import CoreGraphics
import ScreenshotFeature
import Testing
@testable import ScreenshotServiceCore

@Suite("标注几何")
struct AnnotationGeometryTests {
    @Test("Retina point 坐标转换为左下角 pixel 坐标")
    func pointCoordinatesConvertToRetinaPixels() {
        let points = AnnotationGeometry.pixelPoints(
            for: [.init(x: 10, y: 15)],
            pointSize: .init(width: 100, height: 50),
            pixelWidth: 200,
            pixelHeight: 100
        )

        #expect(points == [CGPoint(x: 20, y: 70)])
    }

    @Test("非有限坐标会被过滤")
    func nonFinitePointsAreFiltered() {
        let points = AnnotationGeometry.pixelPoints(
            for: [
                .init(x: .nan, y: 1),
                .init(x: 1, y: .infinity),
                .init(x: 2, y: 3)
            ],
            pointSize: .init(width: 10, height: 10),
            pixelWidth: 10,
            pixelHeight: 10
        )

        #expect(points == [CGPoint(x: 2, y: 7)])
    }

    @Test("裁剪边界按 floor 和 ceil 覆盖完整像素")
    func cropRectRoundsOutward() {
        let rect = AnnotationGeometry.pixelCropRect(
            sourcePointSize: .init(width: 10, height: 10),
            imageWidth: 30,
            imageHeight: 20,
            cropRect: CGRect(x: 1.2, y: 2.2, width: 3.2, height: 3.2)
        )

        #expect(rect == CGRect(x: 3, y: 4, width: 11, height: 7))
    }

    @Test("极短箭头不会生成不稳定箭头头部")
    func veryShortArrowHasNoHead() {
        let result = AnnotationGeometry.arrowHeadPoints(
            from: .init(x: 10, y: 10),
            to: .init(x: 10.25, y: 10.25),
            size: 8
        )

        #expect(result == nil)
    }
}
