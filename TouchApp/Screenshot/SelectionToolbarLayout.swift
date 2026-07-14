import CoreGraphics

struct SelectionToolbarLayout {
    static let selectionSpacing: CGFloat = 8
    static let edgeInset: CGFloat = 8

    /// AppKit 本地坐标中优先放在选区下方；空间不足时放到选区上方。
    static func frame(
        selection: CGRect,
        toolbarSize: CGSize,
        in bounds: CGRect
    ) -> CGRect {
        let minimumX = bounds.minX + edgeInset
        let maximumX = max(minimumX, bounds.maxX - edgeInset - toolbarSize.width)
        let x = min(max(selection.maxX - toolbarSize.width, minimumX), maximumX)

        let belowY = selection.minY - selectionSpacing - toolbarSize.height
        let aboveY = selection.maxY + selectionSpacing
        let preferredY = belowY >= bounds.minY + edgeInset ? belowY : aboveY
        let minimumY = bounds.minY + edgeInset
        let maximumY = max(minimumY, bounds.maxY - edgeInset - toolbarSize.height)
        let y = min(max(preferredY, minimumY), maximumY)

        return CGRect(origin: CGPoint(x: x, y: y), size: toolbarSize)
    }
}
