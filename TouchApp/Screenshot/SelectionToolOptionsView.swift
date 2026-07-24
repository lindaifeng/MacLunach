import AppKit
import ScreenshotFeature

@MainActor
final class SelectionToolOptionsView: NSView {
    var onLineWidth: ((Double) -> Void)?
    var onColor: ((ScreenshotAnnotationColor) -> Void)?
    var onFontSize: ((Double) -> Void)?

    private let stack = NSStackView()
    private let usesFontSize: Bool

    init(item: SelectionToolbarItem, options: SelectionAnnotationOptions) {
        usesFontSize = [.text, .numberedMarker, .callout, .note, .sticker].contains(item)
        super.init(frame: CGRect(x: 0, y: 0, width: 520, height: 44))
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.cgColor
        configure(item: item, options: options)
    }

    required init?(coder: NSCoder) { nil }

    private func configure(item: SelectionToolbarItem, options: SelectionAnnotationOptions) {
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        let values = usesFontSize ? SelectionAnnotationOptions.fontSizes : SelectionAnnotationOptions.lineWidths
        for (index, value) in values.enumerated() {
            let button = NSButton(
                title: usesFontSize ? "\(Int(value))" : "",
                target: self,
                action: usesFontSize ? #selector(selectFontSize(_:)) : #selector(selectLineWidth(_:))
            )
            button.tag = index
            button.isBordered = false
            button.wantsLayer = true
            button.layer?.cornerRadius = 5
            let selected = usesFontSize ? options.fontSize == value : options.lineWidth == value
            button.layer?.backgroundColor = selected ? NSColor(calibratedRed: 0, green: 0.60, blue: 1, alpha: 0.14).cgColor : NSColor.clear.cgColor
            if !usesFontSize {
                button.image = lineImage(width: value)
                button.imagePosition = .imageOnly
            }
            button.setAccessibilityLabel(usesFontSize ? "字号 \(Int(value))" : "线宽 \(Int(value))")
            button.widthAnchor.constraint(equalToConstant: 32).isActive = true
            button.heightAnchor.constraint(equalToConstant: 32).isActive = true
            stack.addArrangedSubview(button)
        }

        let range = usesFontSize
            ? SelectionAnnotationOptions.fontSizeRange
            : SelectionAnnotationOptions.lineWidthRange
        let slider = NSSlider(
            value: usesFontSize ? options.fontSize : options.lineWidth,
            minValue: range.lowerBound,
            maxValue: range.upperBound,
            target: self,
            action: usesFontSize ? #selector(changeFontSize(_:)) : #selector(changeLineWidth(_:))
        )
        slider.isContinuous = true
        let identifier = item == .arrow
            ? "screenshot.selection.options.arrow-size"
            : "screenshot.selection.options.\(item.rawValue)-size"
        slider.identifier = NSUserInterfaceItemIdentifier(identifier)
        slider.setAccessibilityIdentifier(identifier)
        slider.setAccessibilityLabel("\(item.hoverTitle)大小")
        slider.toolTip = "拖动调整\(item.hoverTitle)大小"
        slider.widthAnchor.constraint(equalToConstant: 112).isActive = true
        stack.addArrangedSubview(slider)

        stack.addArrangedSubview(separator())
        for (index, color) in SelectionAnnotationOptions.colors.enumerated() {
            let button = NSButton(title: "", target: self, action: #selector(selectColor(_:)))
            button.tag = index
            button.isBordered = false
            button.wantsLayer = true
            button.layer?.cornerRadius = 8
            button.layer?.backgroundColor = NSColor(screenshotColor: color).cgColor
            button.layer?.borderWidth = color == options.color ? 2 : 0.5
            button.layer?.borderColor = color == options.color
                ? NSColor(calibratedRed: 0, green: 0.60, blue: 1, alpha: 1).cgColor
                : NSColor.black.withAlphaComponent(0.18).cgColor
            button.setAccessibilityLabel("颜色 \(index + 1)")
            button.widthAnchor.constraint(equalToConstant: 16).isActive = true
            button.heightAnchor.constraint(equalToConstant: 16).isActive = true
            stack.addArrangedSubview(button)
        }

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    private func lineImage(width: Double) -> NSImage {
        let image = NSImage(size: CGSize(width: 24, height: 24))
        image.lockFocus()
        NSColor(calibratedWhite: 0.18, alpha: 1).setFill()
        NSBezierPath(ovalIn: CGRect(x: 12 - width / 2, y: 12 - width / 2, width: width, height: width)).fill()
        image.unlockFocus()
        return image
    }

    private func separator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.widthAnchor.constraint(equalToConstant: 1).isActive = true
        box.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return box
    }

    @objc private func selectLineWidth(_ sender: NSButton) {
        guard SelectionAnnotationOptions.lineWidths.indices.contains(sender.tag) else { return }
        onLineWidth?(SelectionAnnotationOptions.lineWidths[sender.tag])
    }

    @objc private func selectFontSize(_ sender: NSButton) {
        guard SelectionAnnotationOptions.fontSizes.indices.contains(sender.tag) else { return }
        onFontSize?(SelectionAnnotationOptions.fontSizes[sender.tag])
    }

    @objc private func selectColor(_ sender: NSButton) {
        guard SelectionAnnotationOptions.colors.indices.contains(sender.tag) else { return }
        onColor?(SelectionAnnotationOptions.colors[sender.tag])
    }


    @objc private func changeLineWidth(_ sender: NSSlider) {
        onLineWidth?(sender.doubleValue)
    }

    @objc private func changeFontSize(_ sender: NSSlider) {
        onFontSize?(sender.doubleValue)
    }
}
