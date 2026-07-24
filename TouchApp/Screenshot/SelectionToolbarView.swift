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
    func selectionToolbar(_ toolbar: SelectionToolbarView, didChange options: SelectionAnnotationOptions)
}

/// QQ 风格的单行截图工具栏。高频动作直接显示，扩展能力保留在“更多”菜单中。
@MainActor
final class SelectionToolbarView: NSView {
    static let preferredSize = CGSize(width: 608, height: 44)

    /// 由 Overlay 在工具栏窗口边界之外显示，避免提示文字被 44pt 高的工具栏裁掉。
    var onHoverTitleChanged: ((String?, CGFloat) -> Void)?

    private weak var delegate: SelectionToolbarViewDelegate?
    private let buttonStack = NSStackView()
    private let moreButton = SelectionToolbarButton(title: "", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private var buttons: [SelectionToolbarItem: NSButton] = [:]
    private var buttonItems: [ObjectIdentifier: SelectionToolbarItem] = [:]
    private var selectedItem: SelectionToolbarItem?
    private var shadowIncluded = true
    private var showsWindowShadow = false
    private var statusMessage = ""
    private var annotationOptions = SelectionAnnotationOptions()
    private let optionsPopover = NSPopover()
    private var optionsItem: SelectionToolbarItem?

    /// 附加工具条显示时，Overlay 不应在每次参数回调后抢回 first responder，
    /// 否则 NSSlider 的连续跟踪会在第一帧就被中断。
    var keepsOverlayFocusSuspended: Bool { optionsPopover.isShown }

    init(delegate: SelectionToolbarViewDelegate) {
        self.delegate = delegate
        super.init(frame: CGRect(origin: .zero, size: Self.preferredSize))
        identifier = NSUserInterfaceItemIdentifier("screenshot.selection.toolbar")
        setAccessibilityElement(true)
        setAccessibilityIdentifier("screenshot.selection.toolbar")
        setAccessibilityLabel("截图工具栏")
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.cgColor
        layer?.cornerRadius = 6
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.black.withAlphaComponent(0.10).cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.18
        layer?.shadowRadius = 8
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        configureButtonRow()
        configureAccessibleStatus()
    }

    required init?(coder: NSCoder) { nil }

    func update(
        pixelSize: CGSize,
        windowShadowIncluded: Bool,
        showsWindowShadow: Bool,
        selectedItem: SelectionToolbarItem?,
        annotationOptions: SelectionAnnotationOptions
    ) {
        setAccessibilityValue("选区 \(Int(pixelSize.width)) × \(Int(pixelSize.height)) 像素")
        shadowIncluded = windowShadowIncluded
        self.showsWindowShadow = showsWindowShadow
        self.selectedItem = selectedItem
        self.annotationOptions = annotationOptions
        updateButtonAppearance()
        if let selectedItem,
           selectedItem.supportsQQOptions,
           let button = buttons[selectedItem] {
            if optionsItem != selectedItem || !optionsPopover.isShown {
                showOptions(for: selectedItem, relativeTo: button)
            }
        } else if selectedItem?.supportsQQOptions != true {
            optionsPopover.close()
            optionsItem = nil
        }
    }

    func showStatus(_ message: String) {
        statusMessage = message
        statusLabel.stringValue = message
        statusLabel.setAccessibilityLabel(message)
        statusLabel.isHidden = message.isEmpty
        toolTip = message.isEmpty ? nil : message
        setAccessibilityHelp(message.isEmpty ? "选择工具以编辑截图" : message)
    }

    func dismissOptions() {
        optionsPopover.close()
        optionsItem = nil
    }

    private func configureAccessibleStatus() {
        statusLabel.identifier = NSUserInterfaceItemIdentifier("screenshot.selection.toolbar.status")
        statusLabel.setAccessibilityIdentifier("screenshot.selection.toolbar.status")
        statusLabel.alphaValue = 0.01
        statusLabel.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        statusLabel.isHidden = true
        addSubview(statusLabel)
    }

    private func configureButtonRow() {
        buttonStack.orientation = .horizontal
        buttonStack.alignment = .centerY
        buttonStack.spacing = 2
        buttonStack.edgeInsets = NSEdgeInsets(top: 5, left: 8, bottom: 5, right: 8)
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(buttonStack)

        for item in SelectionToolbarItem.qqPrimaryOrder {
            if item == .scrollingCapture || item == .pin || item == .cancel {
                buttonStack.addArrangedSubview(separator())
            }
            let button = makeButton(for: item)
            buttons[item] = button
            buttonItems[ObjectIdentifier(button)] = item
            buttonStack.addArrangedSubview(button)
        }

        moreButton.identifier = NSUserInterfaceItemIdentifier("screenshot.selection.toolbar.more")
        moreButton.setAccessibilityIdentifier("screenshot.selection.toolbar.more")
        moreButton.setAccessibilityLabel("更多截图工具")
        moreButton.toolTip = "更多"
        moreButton.onHoverChanged = { [weak self, weak moreButton] isHovering in
            guard let self, let moreButton else { return }
            self.onHoverTitleChanged?(isHovering ? "更多" : nil, moreButton.frame.midX)
        }
        moreButton.isBordered = false
        moreButton.imagePosition = .imageOnly
        moreButton.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "更多")
        moreButton.contentTintColor = NSColor(calibratedWhite: 0.18, alpha: 1)
        moreButton.target = self
        moreButton.action = #selector(showMoreMenu(_:))
        moreButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            moreButton.widthAnchor.constraint(equalToConstant: 32),
            moreButton.heightAnchor.constraint(equalToConstant: 34)
        ])
        buttonStack.insertArrangedSubview(moreButton, at: buttonStack.arrangedSubviews.count - 2)

        NSLayoutConstraint.activate([
            buttonStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            buttonStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            buttonStack.topAnchor.constraint(equalTo: topAnchor),
            buttonStack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    private func makeButton(for item: SelectionToolbarItem) -> NSButton {
        let button = SelectionToolbarButton(title: "", target: self, action: #selector(chooseItem(_:)))
        button.identifier = NSUserInterfaceItemIdentifier("screenshot.selection.toolbar.\(item.rawValue)")
        button.setAccessibilityIdentifier("screenshot.selection.toolbar.\(item.rawValue)")
        button.setAccessibilityLabel(item.accessibilityLabel)
        button.toolTip = item.shortcut.map { "\(item.hoverTitle)  \($0)" } ?? item.hoverTitle
        button.setAccessibilityHelp("\(item.hoverTitle)功能")
        button.onHoverChanged = { [weak self, weak button] isHovering in
            guard let self, let button else { return }
            self.onHoverTitleChanged?(isHovering ? item.hoverTitle : nil, button.frame.midX)
        }
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.image = NSImage(systemSymbolName: item.systemImageName, accessibilityDescription: item.title)
        if button.image == nil {
            button.title = String(item.title.prefix(1))
            button.imagePosition = .noImage
            button.font = .systemFont(ofSize: 12, weight: .medium)
        }
        button.wantsLayer = true
        button.layer?.cornerRadius = 5
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
                ? NSColor(calibratedRed: 0, green: 0.60, blue: 1, alpha: 0.14).cgColor
                : NSColor.clear.cgColor
            button.contentTintColor = isSelected
                ? NSColor(calibratedRed: 0, green: 0.52, blue: 0.94, alpha: 1)
                : NSColor(calibratedWhite: 0.18, alpha: 1)
        }
        buttons[.cancel]?.contentTintColor = NSColor(calibratedWhite: 0.30, alpha: 1)
        buttons[.copy]?.contentTintColor = NSColor(calibratedRed: 0, green: 0.60, blue: 1, alpha: 1)
    }

    @objc private func chooseItem(_ sender: NSButton) {
        guard let item = buttonItems[ObjectIdentifier(sender)] else { return }
        delegate?.selectionToolbar(self, didChoose: item)
    }

    private func showOptions(for item: SelectionToolbarItem, relativeTo button: NSButton) {
        optionsPopover.close()
        optionsItem = item
        let optionsView = SelectionToolOptionsView(item: item, options: annotationOptions)
        optionsView.onLineWidth = { [weak self] value in
            guard let self else { return }
            annotationOptions.lineWidth = value
            delegate?.selectionToolbar(self, didChange: annotationOptions)
        }
        optionsView.onFontSize = { [weak self] value in
            guard let self else { return }
            annotationOptions.fontSize = value
            delegate?.selectionToolbar(self, didChange: annotationOptions)
        }
        optionsView.onColor = { [weak self] color in
            guard let self else { return }
            annotationOptions.color = color
            delegate?.selectionToolbar(self, didChange: annotationOptions)
        }
        let controller = NSViewController()
        controller.view = optionsView
        optionsPopover.contentViewController = controller
        optionsPopover.contentSize = optionsView.frame.size
        // 由工具栏和画布主动关闭，避免 transient popover 吞掉切换工具的首次点击。
        optionsPopover.behavior = .applicationDefined
        optionsPopover.animates = false
        optionsPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
    }

    @objc private func showMoreMenu(_ sender: NSButton) {
        let menu = NSMenu(title: "更多截图工具")
        for item in SelectionToolbarItem.qqOverflowOrder {
            let menuItem = NSMenuItem(
                title: item.title,
                action: #selector(chooseOverflowItem(_:)),
                keyEquivalent: ""
            )
            menuItem.target = self
            menuItem.representedObject = item.rawValue
            menuItem.image = NSImage(systemSymbolName: item.systemImageName, accessibilityDescription: item.title)
            menu.addItem(menuItem)
        }
        if showsWindowShadow {
            menu.addItem(.separator())
            let shadowItem = NSMenuItem(
                title: "保留窗口阴影",
                action: #selector(toggleShadow),
                keyEquivalent: ""
            )
            shadowItem.target = self
            shadowItem.state = shadowIncluded ? .on : .off
            menu.addItem(shadowItem)
        }
        if !statusMessage.isEmpty {
            menu.addItem(.separator())
            let statusItem = NSMenuItem(title: statusMessage, action: nil, keyEquivalent: "")
            statusItem.isEnabled = false
            menu.addItem(statusItem)
        }
        menu.popUp(positioning: nil, at: CGPoint(x: sender.frame.minX, y: sender.frame.maxY + 4), in: self)
    }

    @objc private func chooseOverflowItem(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let item = SelectionToolbarItem(rawValue: rawValue) else { return }
        switch item {
        case .sticker:
            showStickerMenu(relativeTo: moreButton)
        case .watermark:
            showWatermarkMenu(relativeTo: moreButton)
        case .beautify:
            showBeautifyMenu(relativeTo: moreButton)
        default:
            delegate?.selectionToolbar(self, didChoose: item)
        }
    }

    private func showStickerMenu(relativeTo button: NSButton) {
        let menu = NSMenu(title: "选择贴纸")
        for sticker in SelectionSticker.allCases {
            let item = NSMenuItem(title: "\(sticker.rawValue)  \(sticker.title)", action: #selector(chooseSticker(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = sticker.rawValue
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: CGPoint(x: button.frame.minX, y: button.frame.maxY + 4), in: self)
    }

    @objc private func chooseSticker(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        delegate?.selectionToolbar(self, didChooseSticker: value)
    }

    private func showWatermarkMenu(relativeTo button: NSButton) {
        let menu = NSMenu(title: "选择水印")
        for watermark in SelectionWatermark.allCases {
            let item = NSMenuItem(title: watermark.title, action: #selector(chooseWatermark(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = watermark.rawValue
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: CGPoint(x: button.frame.minX, y: button.frame.maxY + 4), in: self)
    }

    @objc private func chooseWatermark(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        delegate?.selectionToolbar(self, didChooseWatermark: value)
    }

    private func showBeautifyMenu(relativeTo button: NSButton) {
        let menu = NSMenu(title: "选择美化样式")
        for preset in SelectionBeautifyPreset.allCases {
            let item = NSMenuItem(title: preset.title, action: #selector(chooseBeautify(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = preset.rawValue
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: CGPoint(x: button.frame.minX, y: button.frame.maxY + 4), in: self)
    }

    @objc private func chooseBeautify(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String,
              let preset = SelectionBeautifyPreset(rawValue: value) else { return }
        delegate?.selectionToolbar(self, didChooseBeautify: preset)
    }

    @objc private func toggleShadow() {
        shadowIncluded.toggle()
        delegate?.selectionToolbar(self, setWindowShadowIncluded: shadowIncluded)
    }
}

@MainActor
private final class SelectionToolbarButton: NSButton {
    var onHoverChanged: ((Bool) -> Void)?
    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverArea = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChanged?(false)
    }
}
