import Foundation
import ScreenshotFeature

public struct DisplayCaptureGeometry: Equatable, Sendable {
    public let displayID: UInt32
    public let globalRect: ScreenshotRect
    public let sourceRect: ScreenshotRect
    public let pixelSize: ScreenshotSize

    public init(
        displayID: UInt32,
        globalRect: ScreenshotRect,
        sourceRect: ScreenshotRect,
        pixelSize: ScreenshotSize
    ) {
        self.displayID = displayID
        self.globalRect = globalRect
        self.sourceRect = sourceRect
        self.pixelSize = pixelSize
    }
}

public struct CompositeDisplayPlacement: Equatable, Sendable {
    public let display: ScreenshotDisplayDescriptor
    public let destinationRect: ScreenshotRect

    public init(display: ScreenshotDisplayDescriptor, destinationRect: ScreenshotRect) {
        self.display = display
        self.destinationRect = destinationRect
    }
}

public struct CompositeDisplayLayout: Equatable, Sendable {
    public let pointBounds: ScreenshotRect
    public let pixelSize: ScreenshotSize
    public let scaleFactor: Double
    public let placements: [CompositeDisplayPlacement]

    public init(
        pointBounds: ScreenshotRect,
        pixelSize: ScreenshotSize,
        scaleFactor: Double,
        placements: [CompositeDisplayPlacement]
    ) {
        self.pointBounds = pointBounds
        self.pixelSize = pixelSize
        self.scaleFactor = scaleFactor
        self.placements = placements
    }
}

public enum DisplayGeometry {
    public static func captureGeometry(
        for requestedRect: ScreenshotRect,
        on display: ScreenshotDisplayDescriptor
    ) throws -> DisplayCaptureGeometry {
        guard requestedRect.width > 0,
              requestedRect.height > 0,
              display.frame.width > 0,
              display.frame.height > 0,
              display.scaleFactor > 0 else {
            throw ScreenshotFeatureError.targetUnavailable
        }

        let intersection = intersect(requestedRect, display.frame)
        guard intersection.width > 0, intersection.height > 0 else {
            throw ScreenshotFeatureError.targetUnavailable
        }

        let scale = display.scaleFactor
        let localMinX = intersection.x - display.frame.x
        let localMinY = intersection.y - display.frame.y
        let localMaxX = localMinX + intersection.width
        let localMaxY = localMinY + intersection.height

        let pixelMinX = max(0, floor(localMinX * scale))
        let pixelMinY = max(0, floor(localMinY * scale))
        let pixelMaxX = min(display.pixelSize.width, ceil(localMaxX * scale))
        let pixelMaxY = min(display.pixelSize.height, ceil(localMaxY * scale))
        guard pixelMaxX > pixelMinX, pixelMaxY > pixelMinY else {
            throw ScreenshotFeatureError.targetUnavailable
        }

        let source = ScreenshotRect(
            x: pixelMinX / scale,
            y: pixelMinY / scale,
            width: (pixelMaxX - pixelMinX) / scale,
            height: (pixelMaxY - pixelMinY) / scale
        )
        return DisplayCaptureGeometry(
            displayID: display.id,
            globalRect: .init(
                x: display.frame.x + source.x,
                y: display.frame.y + source.y,
                width: source.width,
                height: source.height
            ),
            sourceRect: source,
            pixelSize: .init(width: pixelMaxX - pixelMinX, height: pixelMaxY - pixelMinY)
        )
    }

    public static func compositeLayout(
        for displays: [ScreenshotDisplayDescriptor]
    ) throws -> CompositeDisplayLayout {
        guard let first = displays.first,
              displays.allSatisfy({ $0.frame.width > 0 && $0.frame.height > 0 && $0.scaleFactor > 0 }) else {
            throw ScreenshotFeatureError.noDisplayAvailable
        }

        let minX = displays.reduce(first.frame.x) { min($0, $1.frame.x) }
        let minY = displays.reduce(first.frame.y) { min($0, $1.frame.y) }
        let maxX = displays.reduce(first.frame.x + first.frame.width) {
            max($0, $1.frame.x + $1.frame.width)
        }
        let maxY = displays.reduce(first.frame.y + first.frame.height) {
            max($0, $1.frame.y + $1.frame.height)
        }
        let scale = displays.map(\.scaleFactor).max() ?? 1
        let bounds = ScreenshotRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        let placements = displays.map { display in
            CompositeDisplayPlacement(
                display: display,
                destinationRect: .init(
                    x: (display.frame.x - minX) * scale,
                    y: (display.frame.y - minY) * scale,
                    width: display.frame.width * scale,
                    height: display.frame.height * scale
                )
            )
        }
        return CompositeDisplayLayout(
            pointBounds: bounds,
            pixelSize: .init(width: ceil(bounds.width * scale), height: ceil(bounds.height * scale)),
            scaleFactor: scale,
            placements: placements
        )
    }

    private static func intersect(_ lhs: ScreenshotRect, _ rhs: ScreenshotRect) -> ScreenshotRect {
        let minX = max(lhs.x, rhs.x)
        let minY = max(lhs.y, rhs.y)
        let maxX = min(lhs.x + lhs.width, rhs.x + rhs.width)
        let maxY = min(lhs.y + lhs.height, rhs.y + rhs.height)
        return .init(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
    }
}
