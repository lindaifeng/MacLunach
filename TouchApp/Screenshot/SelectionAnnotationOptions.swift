import AppKit
import ScreenshotFeature

struct SelectionAnnotationOptions: Equatable {
    var color: ScreenshotAnnotationColor = .red
    var lineWidth: Double = 3
    var fontSize: Double = 18

    static let lineWidths: [Double] = [3, 6, 9]
    static let lineWidthRange: ClosedRange<Double> = 1...30
    static let arrowWidthRange: ClosedRange<Double> = lineWidthRange
    static let fontSizes: [Double] = [14, 18, 24]
    static let fontSizeRange: ClosedRange<Double> = 8...72
    static let colors: [ScreenshotAnnotationColor] = [
        .init(red: 1, green: 0.24, blue: 0.24),
        .init(red: 1, green: 0.64, blue: 0),
        .init(red: 1, green: 0.84, blue: 0),
        .init(red: 0.13, green: 0.76, blue: 0.36),
        .init(red: 0, green: 0.60, blue: 1),
        .init(red: 0.36, green: 0.32, blue: 0.86),
        .init(red: 0.12, green: 0.12, blue: 0.14),
        .init(red: 1, green: 1, blue: 1)
    ]
}

extension NSColor {
    convenience init(screenshotColor: ScreenshotAnnotationColor) {
        self.init(
            calibratedRed: screenshotColor.red,
            green: screenshotColor.green,
            blue: screenshotColor.blue,
            alpha: screenshotColor.alpha
        )
    }
}
