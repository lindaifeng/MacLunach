import AppKit
import ScreenshotFeature
import SwiftUI

struct AnnotationInspectorView: View {
    @ObservedObject var state: AnnotationEditorState
    let appearance: AnnotationEditorAppearance

    var body: some View {
        Group {
            if let layer = state.selectedLayer {
                Form {
                    Section("图层") {
                        LabeledContent("类型", value: toolName(layer.kind))
                        LabeledContent("层级", value: String(layer.zIndex + 1))
                        HStack(spacing: 8) {
                            layerOrderButton(
                                title: "置底",
                                systemImage: "square.3.layers.3d.bottom.filled",
                                enabled: state.canMoveSelectedLayerBackward,
                                identifier: "send-to-back"
                            ) {
                                _ = try? state.sendSelectedLayerToBack()
                            }
                            layerOrderButton(
                                title: "下移",
                                systemImage: "square.2.layers.3d.bottom.filled",
                                enabled: state.canMoveSelectedLayerBackward,
                                identifier: "move-backward"
                            ) {
                                _ = try? state.moveSelectedLayerBackward()
                            }
                            layerOrderButton(
                                title: "上移",
                                systemImage: "square.2.layers.3d.top.filled",
                                enabled: state.canMoveSelectedLayerForward,
                                identifier: "move-forward"
                            ) {
                                _ = try? state.moveSelectedLayerForward()
                            }
                            layerOrderButton(
                                title: "置顶",
                                systemImage: "square.3.layers.3d.top.filled",
                                enabled: state.canMoveSelectedLayerForward,
                                identifier: "bring-to-front"
                            ) {
                                _ = try? state.bringSelectedLayerToFront()
                            }
                        }
                        .buttonStyle(.borderless)
                    }
                    if editableContent(of: layer) != nil {
                        Section("内容") {
                            TextField(
                                layer.kind == .note ? "便签内容" : "文字内容",
                                text: contentBinding(layer),
                                axis: .vertical
                            )
                            .lineLimit(1...5)
                            .accessibilityLabel("标注文字内容")
                            .accessibilityHint("编辑当前文字、便签、贴纸或水印图层的内容")
                            .accessibilityIdentifier("screenshot.annotation.inspector.content")
                        }
                    }
                    Section("外观") {
                        AnnotationColorControl(
                            "颜色",
                            selection: colorBinding(layer),
                            appearance: appearance,
                            identifier: "screenshot.annotation.inspector.color"
                        )
                            .accessibilityLabel("标注颜色")
                            .accessibilityHint("调整当前图层的颜色和颜色透明度")
                            .accessibilityIdentifier("screenshot.annotation.inspector.color")
                        VStack(alignment: .leading) {
                            Text("粗细 \(Int(layer.annotation.style.lineWidth))")
                            AnnotationRangeControl(
                                value: lineWidthBinding(layer),
                                in: 1...40,
                                step: 1,
                                accent: appearance.accent,
                                trackFill: appearance.chromeFill,
                                border: appearance.border
                            )
                                .accessibilityLabel("标注粗细")
                                .accessibilityHint("使用方向键逐级调整线条粗细")
                                .accessibilityIdentifier("screenshot.annotation.inspector.line-width")
                        }
                        VStack(alignment: .leading) {
                            Text("透明度 \(Int(layer.opacity * 100))%")
                            AnnotationRangeControl(
                                value: opacityBinding(layer),
                                in: 0.05...1,
                                step: 0.05,
                                accent: appearance.accent,
                                trackFill: appearance.chromeFill,
                                border: appearance.border
                            )
                                .accessibilityLabel("标注透明度")
                                .accessibilityHint("使用方向键逐级调整整个图层的透明度")
                                .accessibilityIdentifier("screenshot.annotation.inspector.opacity")
                        }
                        if layer.font != nil || layer.annotation.text != nil {
                            VStack(alignment: .leading) {
                                Text("字号 \(Int(layer.font?.size ?? layer.annotation.text?.fontSize ?? 18))")
                                AnnotationRangeControl(
                                    value: fontSizeBinding(layer),
                                    in: 8...96,
                                    step: 1,
                                    accent: appearance.accent,
                                    trackFill: appearance.chromeFill,
                                    border: appearance.border
                                )
                                    .accessibilityLabel("标注字号")
                                    .accessibilityHint("使用方向键逐级调整文字大小")
                                    .accessibilityIdentifier("screenshot.annotation.inspector.font-size")
                            }
                        }
                    }
                    Section("布局与效果") {
                        effectSlider(
                            title: "圆角",
                            value: effectBinding(layer, field: .cornerRadius),
                            range: 0...120,
                            identifier: "corner-radius"
                        )
                        DisclosureGroup("阴影") {
                            effectSlider(
                                title: "模糊",
                                value: effectBinding(layer, field: .shadowRadius),
                                range: 0...120,
                                identifier: "shadow-radius"
                            )
                            effectSlider(
                                title: "透明度",
                                value: effectBinding(layer, field: .shadowOpacity),
                                range: 0...1,
                                step: 0.05,
                                valueText: { "\(Int($0 * 100))%" },
                                identifier: "shadow-opacity"
                            )
                            effectSlider(
                                title: "水平偏移",
                                value: effectBinding(layer, field: .shadowOffsetX),
                                range: -80...80,
                                identifier: "shadow-offset-x"
                            )
                            effectSlider(
                                title: "垂直偏移",
                                value: effectBinding(layer, field: .shadowOffsetY),
                                range: -80...80,
                                identifier: "shadow-offset-y"
                            )
                        }
                        if layer.kind == .note || layer.kind == .beautify {
                            effectSlider(
                                title: layer.kind == .beautify ? "画布边距" : "内容边距",
                                value: effectBinding(layer, field: .contentInset),
                                range: 0...120,
                                identifier: "content-inset"
                            )
                            DisclosureGroup("背景渐变") {
                                AnnotationColorControl(
                                    "起始颜色",
                                    selection: gradientColorBinding(layer, isStart: true),
                                    appearance: appearance,
                                    identifier: "screenshot.annotation.inspector.gradient-start"
                                )
                                .accessibilityLabel("背景渐变起始颜色")
                                AnnotationColorControl(
                                    "结束颜色",
                                    selection: gradientColorBinding(layer, isStart: false),
                                    appearance: appearance,
                                    identifier: "screenshot.annotation.inspector.gradient-end"
                                )
                                .accessibilityLabel("背景渐变结束颜色")
                                effectSlider(
                                    title: "角度",
                                    value: effectBinding(layer, field: .gradientAngle),
                                    range: -180...180,
                                    identifier: "gradient-angle"
                                )
                            }
                        }
                    }
                    Section {
                        Button("删除图层", role: .destructive) {
                            _ = try? state.deleteSelectedLayer()
                        }
                        .keyboardShortcut(.delete, modifiers: [])
                        .accessibilityHint("删除当前选择的标注图层，可使用撤销恢复")
                        .accessibilityIdentifier("screenshot.annotation.inspector.delete")
                    }
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
            } else {
                ContentUnavailableView(
                    "未选择标注",
                    systemImage: "cursorarrow.click",
                    description: Text("在画布中点选一个标注后，可调整颜色、粗细和透明度。")
                )
                .accessibilityLabel("未选择标注图层")
            }
        }
        .background(appearance.inspectorFill)
        .frame(minWidth: 230, idealWidth: 250, maxWidth: 280)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("标注属性")
        .accessibilityIdentifier("screenshot.annotation.inspector")
    }

    private func layerOrderButton(
        title: String,
        systemImage: String,
        enabled: Bool,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(maxWidth: .infinity)
        }
        .disabled(!enabled)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityHint("调整当前图层在标注文档中的前后层级")
        .accessibilityIdentifier("screenshot.annotation.inspector.\(identifier)")
    }

    private func colorBinding(_ layer: AnnotationLayer) -> Binding<Color> {
        Binding(
            get: {
                let value = state.selectedLayer?.annotation.style.color ?? layer.annotation.style.color
                return Color(
                    red: value.red,
                    green: value.green,
                    blue: value.blue,
                    opacity: value.alpha
                )
            },
            set: { color in
                guard let converted = NSColor(color).usingColorSpace(.deviceRGB) else { return }
                try? state.updateSelectedAppearance(
                    color: .init(
                        red: converted.redComponent,
                        green: converted.greenComponent,
                        blue: converted.blueComponent,
                        alpha: converted.alphaComponent
                    ),
                    coalescingKey: "inspector-color-\(layer.id.uuidString)"
                )
            }
        )
    }

    private func lineWidthBinding(_ layer: AnnotationLayer) -> Binding<Double> {
        Binding(
            get: { state.selectedLayer?.annotation.style.lineWidth ?? layer.annotation.style.lineWidth },
            set: {
                try? state.updateSelectedAppearance(
                    lineWidth: $0,
                    coalescingKey: "inspector-line-width-\(layer.id.uuidString)"
                )
            }
        )
    }

    private func opacityBinding(_ layer: AnnotationLayer) -> Binding<Double> {
        Binding(
            get: { state.selectedLayer?.opacity ?? layer.opacity },
            set: {
                try? state.updateSelectedAppearance(
                    opacity: $0,
                    coalescingKey: "inspector-opacity-\(layer.id.uuidString)"
                )
            }
        )
    }

    private func fontSizeBinding(_ layer: AnnotationLayer) -> Binding<Double> {
        Binding(
            get: {
                state.selectedLayer?.font?.size
                    ?? state.selectedLayer?.annotation.text?.fontSize
                    ?? layer.font?.size
                    ?? 18
            },
            set: {
                try? state.updateSelectedAppearance(
                    fontSize: $0,
                    coalescingKey: "inspector-font-size-\(layer.id.uuidString)"
                )
            }
        )
    }

    private func contentBinding(_ layer: AnnotationLayer) -> Binding<String> {
        Binding(
            get: { state.selectedLayer.flatMap(editableContent) ?? editableContent(of: layer) ?? "" },
            set: {
                _ = try? state.updateSelectedContent(
                    $0,
                    coalescingKey: "inspector-content-\(layer.id.uuidString)"
                )
            }
        )
    }

    private func editableContent(of layer: AnnotationLayer) -> String? {
        layer.annotation.text?.value
            ?? layer.annotation.sticker?.value
            ?? layer.annotation.watermark?.value
    }

    private enum EffectField: String {
        case cornerRadius
        case shadowRadius
        case shadowOpacity
        case shadowOffsetX
        case shadowOffsetY
        case contentInset
        case gradientAngle
    }

    private func effectBinding(_ layer: AnnotationLayer, field: EffectField) -> Binding<Double> {
        Binding(
            get: {
                let effects = state.selectedEffects ?? .init(
                    cornerRadius: 0,
                    shadowRadius: 0,
                    shadowOpacity: 0,
                    shadowOffsetX: 0,
                    shadowOffsetY: 0,
                    contentInset: 0,
                    gradientStart: .red,
                    gradientEnd: .yellow,
                    gradientAngle: 135
                )
                return switch field {
                case .cornerRadius: effects.cornerRadius
                case .shadowRadius: effects.shadowRadius
                case .shadowOpacity: effects.shadowOpacity
                case .shadowOffsetX: effects.shadowOffsetX
                case .shadowOffsetY: effects.shadowOffsetY
                case .contentInset: effects.contentInset
                case .gradientAngle: effects.gradientAngle
                }
            },
            set: { value in
                let key = "inspector-\(field.rawValue)-\(layer.id.uuidString)"
                switch field {
                case .cornerRadius:
                    try? state.updateSelectedEffects(cornerRadius: value, coalescingKey: key)
                case .shadowRadius:
                    try? state.updateSelectedEffects(shadowRadius: value, coalescingKey: key)
                case .shadowOpacity:
                    try? state.updateSelectedEffects(shadowOpacity: value, coalescingKey: key)
                case .shadowOffsetX:
                    try? state.updateSelectedEffects(shadowOffsetX: value, coalescingKey: key)
                case .shadowOffsetY:
                    try? state.updateSelectedEffects(shadowOffsetY: value, coalescingKey: key)
                case .contentInset:
                    try? state.updateSelectedEffects(contentInset: value, coalescingKey: key)
                case .gradientAngle:
                    try? state.updateSelectedEffects(gradientAngle: value, coalescingKey: key)
                }
            }
        )
    }

    private func gradientColorBinding(_ layer: AnnotationLayer, isStart: Bool) -> Binding<Color> {
        Binding(
            get: {
                let effects = state.selectedEffects
                let color = isStart ? effects?.gradientStart : effects?.gradientEnd
                let value = color ?? (isStart ? .red : .yellow)
                return Color(
                    red: value.red,
                    green: value.green,
                    blue: value.blue,
                    opacity: value.alpha
                )
            },
            set: { color in
                guard let converted = NSColor(color).usingColorSpace(.deviceRGB) else { return }
                let value = ScreenshotAnnotationColor(
                    red: converted.redComponent,
                    green: converted.greenComponent,
                    blue: converted.blueComponent,
                    alpha: converted.alphaComponent
                )
                let key = "inspector-gradient-\(isStart ? "start" : "end")-\(layer.id.uuidString)"
                if isStart {
                    try? state.updateSelectedEffects(gradientStart: value, coalescingKey: key)
                } else {
                    try? state.updateSelectedEffects(gradientEnd: value, coalescingKey: key)
                }
            }
        )
    }

    private func effectSlider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double = 1,
        valueText: (Double) -> String = { String(Int($0)) },
        identifier: String
    ) -> some View {
        VStack(alignment: .leading) {
            Text("\(title) \(valueText(value.wrappedValue))")
            AnnotationRangeControl(
                value: value,
                in: range,
                step: step,
                accent: appearance.accent,
                trackFill: appearance.chromeFill,
                border: appearance.border
            )
                .accessibilityLabel(title)
                .accessibilityValue(valueText(value.wrappedValue))
                .accessibilityHint("使用方向键逐级调整\(title)")
                .accessibilityIdentifier("screenshot.annotation.inspector.\(identifier)")
        }
    }

    private func toolName(_ kind: ScreenshotAnnotationKind) -> String {
        AnnotationEditorTool(rawValue: kind.rawValue)?.title ?? kind.rawValue
    }
}

struct AnnotationRangeControl: View {
    @Binding private var value: Double
    private let range: ClosedRange<Double>
    private let step: Double
    private let accent: Color
    private let trackFill: Color
    private let border: Color

    @Environment(\.isEnabled) private var isEnabled

    init(
        value: Binding<Double>,
        in range: ClosedRange<Double>,
        step: Double,
        accent: Color = .accentColor,
        trackFill: Color = Color(nsColor: .controlBackgroundColor),
        border: Color = Color.primary.opacity(0.18)
    ) {
        _value = value
        self.range = range
        self.step = step
        self.accent = accent
        self.trackFill = trackFill
        self.border = border
    }

    var body: some View {
        GeometryReader { proxy in
            let thumbDiameter: CGFloat = 16
            let width = max(proxy.size.width, thumbDiameter)
            let progress = normalizedValue

            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(trackFill)
                    .frame(height: 8)
                    .overlay {
                        Capsule(style: .continuous).stroke(border, lineWidth: 1)
                    }

                Capsule(style: .continuous)
                    .fill(accent)
                    .frame(width: max(thumbDiameter / 2, progress * width), height: 8)

                Circle()
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .frame(width: thumbDiameter, height: thumbDiameter)
                    .shadow(color: Color.black.opacity(0.16), radius: 2, y: 1)
                    .overlay { Circle().stroke(accent.opacity(0.48), lineWidth: 1) }
                    .offset(x: progress * (width - thumbDiameter))
            }
            .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        setValue(at: gesture.location.x, width: width)
                    }
            )
        }
        .frame(height: 24)
        .opacity(isEnabled ? 1 : 0.48)
        .focusable()
        .onMoveCommand { direction in
            switch direction {
            case .left, .down: adjust(by: -1)
            case .right, .up: adjust(by: 1)
            default: break
            }
        }
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: adjust(by: 1)
            case .decrement: adjust(by: -1)
            @unknown default: break
            }
        }
    }

    private var normalizedValue: CGFloat {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return min(max(CGFloat((value - range.lowerBound) / span), 0), 1)
    }

    private func setValue(at position: CGFloat, width: CGFloat) {
        guard isEnabled, width > 0 else { return }
        let fraction = Double(min(max(position / width, 0), 1))
        value = quantized(range.lowerBound + fraction * (range.upperBound - range.lowerBound))
    }

    private func adjust(by amount: Double) {
        guard isEnabled else { return }
        value = quantized(value + amount * step)
    }

    private func quantized(_ rawValue: Double) -> Double {
        let snapped = (rawValue / step).rounded() * step
        return min(max(snapped, range.lowerBound), range.upperBound)
    }
}

struct AnnotationColorControl: View {
    private let title: String
    @Binding private var color: Color
    private let appearance: AnnotationEditorAppearance
    private let identifier: String

    @State private var isPalettePresented = false
    @StateObject private var systemColorPanel = AnnotationSystemColorPanel()

    init(
        _ title: String,
        selection: Binding<Color>,
        appearance: AnnotationEditorAppearance,
        identifier: String
    ) {
        self.title = title
        _color = selection
        self.appearance = appearance
        self.identifier = identifier
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
            Spacer(minLength: 12)
            Button {
                isPalettePresented = true
            } label: {
                HStack(spacing: 7) {
                    colorSwatch
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.secondary)
                }
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(appearance.chromeFill, in: Capsule(style: .continuous))
                .overlay {
                    Capsule(style: .continuous)
                        .stroke(appearance.border, lineWidth: 1)
                }
            }
            .buttonStyle(.plain)
            .popover(isPresented: $isPalettePresented, arrowEdge: .bottom) {
                palette
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityValue(colorDescription)
        .accessibilityIdentifier(identifier)
    }

    private var colorSwatch: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(color)
            .frame(width: 20, height: 20)
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(appearance.border.opacity(0.8), lineWidth: 1)
            }
    }

    private var palette: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.primary)

            LazyVGrid(
                columns: Array(repeating: GridItem(.fixed(28), spacing: 7), count: 6),
                spacing: 7
            ) {
                ForEach(Self.palette.indices, id: \.self) { index in
                    let candidate = Self.palette[index]
                    Button {
                        color = candidate.opacity(currentOpacity)
                    } label: {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(candidate)
                            .frame(width: 28, height: 28)
                            .overlay {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .stroke(
                                        isSameColor(candidate) ? appearance.accent : appearance.border,
                                        lineWidth: isSameColor(candidate) ? 2 : 1
                                    )
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("预设颜色 \(index + 1)")
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("透明度 \(Int((currentOpacity * 100).rounded()))%")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.secondary)
                AnnotationRangeControl(
                    value: opacityBinding,
                    in: 0...1,
                    step: 0.05,
                    accent: appearance.accent,
                    trackFill: appearance.chromeFill,
                    border: appearance.border
                )
                .accessibilityLabel("\(title)透明度")
            }

            Button {
                systemColorPanel.present(color: color) { selectedColor in
                    color = Color(nsColor: selectedColor)
                }
            } label: {
                Label("精确调色…", systemImage: "eyedropper")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.primary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 30)
                    .background(appearance.chromeFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(appearance.border, lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)
            .accessibilityHint("在 macOS 系统颜色面板中输入或拾取任意颜色")
        }
        .padding(14)
        .frame(width: 230)
        .background(appearance.inspectorFill)
    }

    private var currentOpacity: Double {
        rgbColor.alphaComponent
    }

    private var opacityBinding: Binding<Double> {
        Binding(
            get: { currentOpacity },
            set: { opacity in
                color = Color(nsColor: rgbColor.withAlphaComponent(opacity))
            }
        )
    }

    private var rgbColor: NSColor {
        NSColor(color).usingColorSpace(.deviceRGB) ?? .white
    }

    private var colorDescription: String {
        "红 \(Int((rgbColor.redComponent * 255).rounded()))，绿 \(Int((rgbColor.greenComponent * 255).rounded()))，蓝 \(Int((rgbColor.blueComponent * 255).rounded()))，透明度 \(Int((currentOpacity * 100).rounded()))%"
    }

    private func isSameColor(_ candidate: Color) -> Bool {
        guard let candidateColor = NSColor(candidate).usingColorSpace(.deviceRGB) else { return false }
        return abs(candidateColor.redComponent - rgbColor.redComponent) < 0.01
            && abs(candidateColor.greenComponent - rgbColor.greenComponent) < 0.01
            && abs(candidateColor.blueComponent - rgbColor.blueComponent) < 0.01
    }

    private static let palette: [Color] = [
        Color(red: 0.13, green: 0.16, blue: 0.21),
        Color.white,
        Color(red: 0.95, green: 0.30, blue: 0.28),
        Color(red: 0.97, green: 0.57, blue: 0.18),
        Color(red: 0.98, green: 0.82, blue: 0.20),
        Color(red: 0.32, green: 0.75, blue: 0.42),
        Color(red: 0.20, green: 0.66, blue: 0.92),
        Color(red: 0.38, green: 0.43, blue: 0.95),
        Color(red: 0.64, green: 0.42, blue: 0.91),
        Color(red: 0.92, green: 0.38, blue: 0.70),
        Color(red: 0.52, green: 0.60, blue: 0.70),
        Color(red: 0.50, green: 0.34, blue: 0.22)
    ]
}

@MainActor
private final class AnnotationSystemColorPanel: NSObject, ObservableObject {
    private var colorHandler: ((NSColor) -> Void)?

    func present(color: Color, onColorChange: @escaping (NSColor) -> Void) {
        let panel = NSColorPanel.shared
        colorHandler = onColorChange
        panel.showsAlpha = true
        panel.color = NSColor(color)
        panel.setTarget(self)
        panel.setAction(#selector(colorDidChange(_:)))
        panel.orderFront(nil)
    }

    @objc private func colorDidChange(_ sender: NSColorPanel) {
        colorHandler?(sender.color)
    }
}
