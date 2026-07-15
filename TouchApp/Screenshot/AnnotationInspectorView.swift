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
                        ColorPicker("颜色", selection: colorBinding(layer), supportsOpacity: true)
                            .accessibilityLabel("标注颜色")
                            .accessibilityHint("调整当前图层的颜色和颜色透明度")
                            .accessibilityIdentifier("screenshot.annotation.inspector.color")
                        VStack(alignment: .leading) {
                            Text("粗细 \(Int(layer.annotation.style.lineWidth))")
                            Slider(value: lineWidthBinding(layer), in: 1...40, step: 1)
                                .accessibilityLabel("标注粗细")
                                .accessibilityHint("使用方向键逐级调整线条粗细")
                                .accessibilityIdentifier("screenshot.annotation.inspector.line-width")
                        }
                        VStack(alignment: .leading) {
                            Text("透明度 \(Int(layer.opacity * 100))%")
                            Slider(value: opacityBinding(layer), in: 0.05...1, step: 0.05)
                                .accessibilityLabel("标注透明度")
                                .accessibilityHint("使用方向键逐级调整整个图层的透明度")
                                .accessibilityIdentifier("screenshot.annotation.inspector.opacity")
                        }
                        if layer.font != nil || layer.annotation.text != nil {
                            VStack(alignment: .leading) {
                                Text("字号 \(Int(layer.font?.size ?? layer.annotation.text?.fontSize ?? 18))")
                                Slider(value: fontSizeBinding(layer), in: 8...96, step: 1)
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
                                ColorPicker(
                                    "起始颜色",
                                    selection: gradientColorBinding(layer, isStart: true),
                                    supportsOpacity: true
                                )
                                .accessibilityIdentifier("screenshot.annotation.inspector.gradient-start")
                                .accessibilityLabel("背景渐变起始颜色")
                                ColorPicker(
                                    "结束颜色",
                                    selection: gradientColorBinding(layer, isStart: false),
                                    supportsOpacity: true
                                )
                                .accessibilityIdentifier("screenshot.annotation.inspector.gradient-end")
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
            Slider(value: value, in: range, step: step)
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
