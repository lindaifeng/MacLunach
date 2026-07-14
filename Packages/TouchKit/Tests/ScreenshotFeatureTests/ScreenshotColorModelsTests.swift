import Foundation
import ScreenshotFeature
import Testing

@Suite("ScreenshotColor")
struct ScreenshotColorModelsTests {
    @Test("输出标准 HEX、RGB 和 HSL 文本")
    func formatsColorText() {
        let orange = ScreenshotColor(red: 255, green: 128, blue: 0)

        #expect(orange.hexString == "#FF8000")
        #expect(orange.rgbString == "RGB(255, 128, 0)")
        #expect(orange.hslString == "HSL(30°, 100%, 50%)")
    }

    @Test("灰阶 HSL 不产生 NaN 且模型可 Codable 往返")
    func grayFormattingAndCodableRoundTrip() throws {
        let sample = ScreenshotColorSample(
            color: .init(red: 128, green: 128, blue: 128),
            loupeRGBA: Data([128, 128, 128, 255]),
            loupePixelSize: .init(width: 1, height: 1),
            centerPixel: .init(x: 0, y: 0)
        )

        #expect(sample.color.hslString == "HSL(0°, 0%, 50%)")
        #expect(try JSONDecoder().decode(
            ScreenshotColorSample.self,
            from: JSONEncoder().encode(sample)
        ) == sample)
    }
}
