import CoreGraphics

enum SelectionHandle: String, CaseIterable, Sendable {
    case topLeft
    case top
    case topRight
    case right
    case bottomRight
    case bottom
    case bottomLeft
    case left
}

enum SelectionNudgeDirection: Sendable {
    case left
    case right
    case up
    case down
}

enum SelectionGeometry {
    static let defaultMinimumSize = CGSize(width: 8, height: 8)
    static let defaultHandleHitSize: CGFloat = 14
    static let labelOffset: CGFloat = 12

    static func dragRect(
        from anchor: CGPoint,
        to current: CGPoint,
        in bounds: CGRect,
        minimumSize: CGSize = defaultMinimumSize
    ) -> CGRect {
        guard bounds.width > 0, bounds.height > 0 else { return .zero }
        let start = clamped(anchor, to: bounds)
        let end = clamped(current, to: bounds)
        let width = min(max(0, minimumSize.width), bounds.width)
        let height = min(max(0, minimumSize.height), bounds.height)

        let horizontal = constrainedAxis(
            anchor: start.x,
            current: end.x,
            minimum: width,
            lowerBound: bounds.minX,
            upperBound: bounds.maxX
        )
        let vertical = constrainedAxis(
            anchor: start.y,
            current: end.y,
            minimum: height,
            lowerBound: bounds.minY,
            upperBound: bounds.maxY
        )
        return CGRect(
            x: horizontal.lower,
            y: vertical.lower,
            width: horizontal.upper - horizontal.lower,
            height: vertical.upper - vertical.lower
        )
    }

    static func resize(
        _ rect: CGRect,
        handle: SelectionHandle,
        to point: CGPoint,
        in bounds: CGRect,
        minimumSize: CGSize = defaultMinimumSize
    ) -> CGRect {
        let point = clamped(point, to: bounds)
        let minimumWidth = min(max(0, minimumSize.width), bounds.width)
        let minimumHeight = min(max(0, minimumSize.height), bounds.height)
        var minX = rect.minX
        var maxX = rect.maxX
        var minY = rect.minY
        var maxY = rect.maxY

        switch handle {
        case .topLeft, .left, .bottomLeft:
            minX = min(max(bounds.minX, point.x), maxX - minimumWidth)
        case .topRight, .right, .bottomRight:
            maxX = max(min(bounds.maxX, point.x), minX + minimumWidth)
        case .top, .bottom:
            break
        }

        switch handle {
        case .topLeft, .top, .topRight:
            minY = min(max(bounds.minY, point.y), maxY - minimumHeight)
        case .bottomLeft, .bottom, .bottomRight:
            maxY = max(min(bounds.maxY, point.y), minY + minimumHeight)
        case .left, .right:
            break
        }

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    static func move(_ rect: CGRect, by delta: CGVector, in bounds: CGRect) -> CGRect {
        guard rect.width <= bounds.width, rect.height <= bounds.height else {
            return CGRect(
                x: bounds.minX,
                y: bounds.minY,
                width: min(rect.width, bounds.width),
                height: min(rect.height, bounds.height)
            )
        }
        let dx = min(max(delta.dx, bounds.minX - rect.minX), bounds.maxX - rect.maxX)
        let dy = min(max(delta.dy, bounds.minY - rect.minY), bounds.maxY - rect.maxY)
        return rect.offsetBy(dx: dx, dy: dy)
    }

    static func nudge(
        _ rect: CGRect,
        direction: SelectionNudgeDirection,
        accelerated: Bool,
        in bounds: CGRect
    ) -> CGRect {
        let distance: CGFloat = accelerated ? 10 : 1
        let delta: CGVector
        switch direction {
        case .left: delta = CGVector(dx: -distance, dy: 0)
        case .right: delta = CGVector(dx: distance, dy: 0)
        case .up: delta = CGVector(dx: 0, dy: -distance)
        case .down: delta = CGVector(dx: 0, dy: distance)
        }
        return move(rect, by: delta, in: bounds)
    }

    static func pixelSize(for rect: CGRect, scaleFactor: CGFloat) -> CGSize {
        guard scaleFactor > 0 else { return .zero }
        let minX = floor(rect.minX * scaleFactor)
        let minY = floor(rect.minY * scaleFactor)
        let maxX = ceil(rect.maxX * scaleFactor)
        let maxY = ceil(rect.maxY * scaleFactor)
        return CGSize(width: maxX - minX, height: maxY - minY)
    }

    static func covers(_ rect: CGRect, _ bounds: CGRect, tolerance: CGFloat = 1) -> Bool {
        guard rect.width > 0, rect.height > 0, bounds.width > 0, bounds.height > 0 else {
            return false
        }
        let tolerance = max(0, tolerance)
        return abs(rect.minX - bounds.minX) <= tolerance
            && abs(rect.minY - bounds.minY) <= tolerance
            && abs(rect.maxX - bounds.maxX) <= tolerance
            && abs(rect.maxY - bounds.maxY) <= tolerance
    }

    static func handleCenters(for rect: CGRect) -> [SelectionHandle: CGPoint] {
        let midX = rect.midX
        let midY = rect.midY
        return [
            .topLeft: CGPoint(x: rect.minX, y: rect.minY),
            .top: CGPoint(x: midX, y: rect.minY),
            .topRight: CGPoint(x: rect.maxX, y: rect.minY),
            .right: CGPoint(x: rect.maxX, y: midY),
            .bottomRight: CGPoint(x: rect.maxX, y: rect.maxY),
            .bottom: CGPoint(x: midX, y: rect.maxY),
            .bottomLeft: CGPoint(x: rect.minX, y: rect.maxY),
            .left: CGPoint(x: rect.minX, y: midY)
        ]
    }

    static func handle(
        at point: CGPoint,
        in rect: CGRect,
        hitSize: CGFloat = defaultHandleHitSize
    ) -> SelectionHandle? {
        let half = hitSize / 2
        return SelectionHandle.allCases.first { handle in
            guard let center = handleCenters(for: rect)[handle] else { return false }
            return CGRect(x: center.x - half, y: center.y - half, width: hitSize, height: hitSize)
                .contains(point)
        }
    }

    static func labelFrame(
        pointer: CGPoint,
        labelSize: CGSize,
        in bounds: CGRect
    ) -> CGRect {
        var x = pointer.x + labelOffset
        var y = pointer.y + labelOffset
        if x + labelSize.width > bounds.maxX {
            x = pointer.x - labelOffset - labelSize.width
        }
        if y + labelSize.height > bounds.maxY {
            y = pointer.y - labelOffset - labelSize.height
        }
        x = min(max(x, bounds.minX), max(bounds.minX, bounds.maxX - labelSize.width))
        y = min(max(y, bounds.minY), max(bounds.minY, bounds.maxY - labelSize.height))
        return CGRect(origin: CGPoint(x: x, y: y), size: labelSize)
    }

    private static func clamped(_ point: CGPoint, to bounds: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )
    }

    private static func constrainedAxis(
        anchor: CGFloat,
        current: CGFloat,
        minimum: CGFloat,
        lowerBound: CGFloat,
        upperBound: CGFloat
    ) -> (lower: CGFloat, upper: CGFloat) {
        if current >= anchor {
            let upper = min(upperBound, max(current, anchor + minimum))
            return (max(lowerBound, upper - max(minimum, upper - anchor)), upper)
        }
        let lower = max(lowerBound, min(current, anchor - minimum))
        return (lower, min(upperBound, max(anchor, lower + minimum)))
    }
}
