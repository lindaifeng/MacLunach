import AppKit

@MainActor
protocol SelectionToolbarViewDelegate: AnyObject {
    func selectionToolbar(_ toolbar: SelectionToolbarView, didChoose item: SelectionToolbarItem)
    func selectionToolbar(_ toolbar: SelectionToolbarView, didChooseSticker value: String)
    func selectionToolbar(_ toolbar: SelectionToolbarView, didChooseWatermark value: String)
    func selectionToolbar(
        _ toolbar: SelectionToolbarView,
        didChooseBeautify preset: SelectionBeautifyPreset
    )
    func selectionToolbar(_ toolbar: SelectionToolbarView, setWindowShadowIncluded included: Bool)
}

@MainActor
final class SelectionToolbarView: NSVisualEffectView {
    static let preferredSize = CGSize(width: 748, height: 76)

    private weak var delegate: SelectionToolbarViewDelegate?
    private let sizeLabel = NSTextField(labelWithString: "")
    private let shadowButton = NSButton(title: "", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let buttonStack = NSStackView()
    private var buttons: [SelectionToolbarItem: NSButton] = [:]
    private var buttonItems: [ObjectIdentifier: SelectionToolbarItem] = [:]
    private var selectedItem: SelectionToolbarItem?
    private var shadowIncluded = true

    init(delegate: SelectionToolbarViewDelegate) {
        self.delegate = delegate
        super.init(frame: CGRect(origin: .zero, size: Self.preferredSize))
        identifier = NSUserInterfaceItemIdentifier("screenshot.selection.toolbar")
        setAccessibilityElement(true)
        setAccessibilityIdentifier("screenshot.selection.toolbar")
        setAccessibilityLabel("截图工具栏")
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.masksToBounds = true

        configureInfoRow()
        configureButtonRow()
    }

    required init?(coder: NSCoder) { nil }

    func update(
        pixelSize: CGSize,
        windowShadowIncluded: Bool,
        showsWindowShadow: Bool,
        selectedItem: SelectionToolbarItem?
    ) {
        sizeLabel.stringValue = "\(Int(pixelSize.width)) × \(Int(pixelSize.height))"
        sizeLabel.setAccessibilityValue("\(Int(pixelSize.width)) × \(Int(pixelSize.height)) 像素")
        shadowIncluded = windowShadowIncluded
        shadowButton.isHidden = !showsWindowShadow
        shadowButton.title = windowShadowIncluded ? "保留阴影⌄" : "去阴影⌄"
        self.selectedItem = selectedItem
        updateButtonAppearance()
    }

    func showStatus(_ message: String) {
        statusLabel.stringValue = message
        statusLabel.isHidden = message.isEmpty
    }

    private func configureInfoRow() {
        sizeLabel.identifier = NSUserInterfaceItemIdentifier("screenshot.selection.toolbar.size")
        sizeLabel.setAccessibilityIdentifier("screenshot.selection.toolbar.size")
        sizeLabel.setAccessibilityLabel("选区尺寸")
        sizeLabel.textColor = .labelColor
        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)

        shadowButton.identifier = NSUserInterfaceItemIdentifier("screenshot.selection.toolbar.shadow")
        shadowButton.setAccessibilityIdentifier("screenshot.selection.toolbar.shadow")
        shadowButton.setAccessibilityLabel("窗口阴影")
        shadowButton.bezelStyle = .inline
        shadowButton.font = .systemFont(ofSize: 12)
        shadowButton.target = self
        shadowButton.action = #selector(toggleShadow)

        statusLabel.identifier = NSUserInterfaceItemIdentifier("screenshot.selection.toolbar.status")
        statusLabel.setAccessibilityIdentifier("screenshot.selection.toolbar.status")
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.isHidden = true

        let infoStack = NSStackView(views: [sizeLabel, shadowButton, statusLabel])
        infoStack.orientation = .horizontal
        infoStack.alignment = .centerY
        infoStack.spacing = 10
        infoStack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        infoStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(infoStack)

        NSLayoutConstraint.activate([
            infoStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            infoStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            infoStack.topAnchor.constraint(equalTo: topAnchor),
            infoStack.heightAnchor.constraint(equalToConstant: 30)
        ])
    }

    private func configureButtonRow() {
        buttonStack.orientation = .horizontal
        buttonStack.alignment = .centerY
        buttonStack.spacing = 2
        buttonStack.edgeInsets = NSEdgeInsets(top: 3, left: 8, bottom: 5, right: 8)
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(buttonStack)

        for item in SelectionToolbarItem.referenceOrder {
            if item == .scrollingCapture || item == .pin || item == .cancel {
                buttonStack.addArrangedSubview(separator())
            }
            let button = makeButton(for: item)
            buttons[item] = button
            buttonItems[ObjectIdentifier(button)] = item
            buttonStack.addArrangedSubview(button)
        }

        NSLayoutConstraint.activate([
            buttonStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            buttonStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            buttonStack.topAnchor.constraint(equalTo: topAnchor, constant: 30),
            buttonStack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    private func makeButton(for item: SelectionToolbarItem) -> NSButton {
        let button = NSButton(title: "", target: self, action: #selector(chooseItem(_:)))
        button.identifier = NSUserInterfaceItemIdentifier("screenshot.selection.toolbar.\(item.rawValue)")
        button.setAccessibilityIdentifier("screenshot.selection.toolbar.\(item.rawValue)")
        button.setAccessibilityLabel(item.accessibilityLabel)
        button.toolTip = item.shortcut.map { "\(item.title)  \($0)" } ?? item.title
        button.isBordered = false
        button.bezelStyle = .inline
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.image = NSImage(systemSymbolName: item.systemImageName, accessibilityDescription: item.title)
        if button.image == nil {
            button.title = String(item.title.prefix(1))
            button.imagePosition = .noImage
            button.font = .systemFont(ofSize: 12, weight: .medium)
        }
        button.wantsLayer = true
        button.layer?.cornerRadius = 6
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 32),
            button.heightAnchor.constraint(equalToConstant: 34)
        ])
        return button
    }

    private func separator() -> NSView {
        let view = NSBox()
        view.boxType = .separator
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: 1).isActive = true
        view.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return view
    }

    private func updateButtonAppearance() {
        for (item, button) in buttons {
            let isSelected = item == selectedItem && item.kind != .completion
            button.layer?.backgroundColor = isSelected
                ? NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor
                : NSColor.clear.cgColor
            button.contentTintColor = isSelected ? .controlAccentColor : .labelColor
        }
        buttons[.cancel]?.contentTintColor = .systemRed
        buttons[.copy]?.contentTintColor = .systemGreen
    }

    @objc private func chooseItem(_ sender: NSButton) {
        guard let item = buttonItems[ObjectIdentifier(sender)] else { return }
        if item == .sticker {
            showStickerMenu(relativeTo: sender)
            return
        }
        if item == .watermark {
            showWatermarkMenu(relativeTo: sender)
            return
        }
        if item == .beautify {
            showBeautifyMenu(relativeTo: sender)
            return
        }
        delegate?.selectionToolbar(self, didChoose: item)
    }

    private func showStickerMenu(relativeTo button: NSButton) {
        let menu = NSMenu(title: "选择贴纸")
        for sticker in SelectionSticker.allCases {
            let item = NSMenuItem(
                title: "\(sticker.rawValue)  \(sticker.title)",
                action: #selector(chooseSticker(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = sticker.rawValue
            item.setAccessibilityLabel("贴纸，\(sticker.title)")
            menu.addItem(item)
        }
        menu.popUp(
            positioning: nil,
            at: CGPoint(x: button.frame.minX, y: button.frame.maxY + 4),
            in: self
        )
    }

    @objc private func chooseSticker(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        delegate?.selectionToolbar(self, didChooseSticker: value)
    }

    private func showWatermarkMenu(relativeTo button: NSButton) {
        let menu = NSMenu(title: "选择水印")
        for watermark in SelectionWatermark.allCases {
            let item = NSMenuItem(
                title: watermark.title,
                action: #selector(chooseWatermark(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = watermark.rawValue
            item.setAccessibilityLabel("水印，\(watermark.title)")
            menu.addItem(item)
        }
        menu.popUp(
            positioning: nil,
            at: CGPoint(x: button.frame.minX, y: button.frame.maxY + 4),
            in: self
        )
    }

    @objc private func chooseWatermark(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        delegate?.selectionToolbar(self, didChooseWatermark: value)
    }

    private func showBeautifyMenu(relativeTo button: NSButton) {
        let menu = NSMenu(title: "选择美化样式")
        for preset in SelectionBeautifyPreset.allCases {
            let item = NSMenuItem(
                title: preset.title,
                action: #selector(chooseBeautify(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = preset.rawValue
            item.setAccessibilityLabel("美化，\(preset.title)")
            menu.addItem(item)
        }
        menu.popUp(
            positioning: nil,
            at: CGPoint(x: button.frame.minX, y: button.frame.maxY + 4),
            in: self
        )
    }

    @objc private func chooseBeautify(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String,
              let preset = SelectionBeautifyPreset(rawValue: value) else { return }
        delegate?.selectionToolbar(self, didChooseBeautify: preset)
    }

    @objc private func toggleShadow() {
        shadowIncluded.toggle()
        shadowButton.title = shadowIncluded ? "保留阴影⌄" : "去阴影⌄"
        delegate?.selectionToolbar(self, setWindowShadowIncluded: shadowIncluded)
    }
}
