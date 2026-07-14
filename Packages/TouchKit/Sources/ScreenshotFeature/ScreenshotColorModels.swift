import Foundation

public struct ScreenshotPoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct ScreenshotColor: Codable, Equatable, Sendable {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8
    public var alpha: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8 = 255) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public var hexString: String {
        String(format: "#%02X%02X%02X", red, green, blue)
    }

    public var rgbString: String {
        "RGB(\(red), \(green), \(blue))"
    }

    public var hslString: String {
        let r = Double(red) / 255
        let g = Double(green) / 255
        let b = Double(blue) / 255
        let maximum = max(r, g, b)
        let minimum = min(r, g, b)
        let delta = maximum - minimum
        let lightness = (maximum + minimum) / 2

        let hue: Double
        let saturation: Double
        if delta == 0 {
            hue = 0
            saturation = 0
        } else {
            saturation = delta / (1 - abs(2 * lightness - 1))
            if maximum == r {
                hue = 60 * ((g - b) / delta).truncatingRemainder(dividingBy: 6)
            } else if maximum == g {
                hue = 60 * (((b - r) / delta) + 2)
            } else {
                hue = 60 * (((r - g) / delta) + 4)
            }
        }

        let normalizedHue = hue < 0 ? hue + 360 : hue
        return "HSL(\(Int(normalizedHue.rounded()))°, \(Int((saturation * 100).rounded()))%, \(Int((lightness * 100).rounded()))%)"
    }
}

public struct ScreenshotColorSampleRequest: Codable, Equatable, Sendable {
    public var displayID: UInt32
    /// 以虚拟桌面左上角为原点的 point 坐标。
    public var desktopPoint: ScreenshotPoint
    /// 放大镜采样区域的物理像素边长。引擎会规范为不超过 31 的奇数。
    public var loupePixelDiameter: Int

    public init(
        displayID: UInt32,
        desktopPoint: ScreenshotPoint,
        loupePixelDiameter: Int = 11
    ) {
        self.displayID = displayID
        self.desktopPoint = desktopPoint
        self.loupePixelDiameter = loupePixelDiameter
    }
}

public struct ScreenshotColorSample: Codable, Equatable, Sendable {
    public var color: ScreenshotColor
    /// 标准 sRGB、每像素 RGBA8、行优先且从左上角开始。
    public var loupeRGBA: Data
    public var loupePixelSize: ScreenshotSize
    public var centerPixel: ScreenshotPoint

    public init(
        color: ScreenshotColor,
        loupeRGBA: Data,
        loupePixelSize: ScreenshotSize,
        centerPixel: ScreenshotPoint
    ) {
        self.color = color
        self.loupeRGBA = loupeRGBA
        self.loupePixelSize = loupePixelSize
        self.centerPixel = centerPixel
    }
}
