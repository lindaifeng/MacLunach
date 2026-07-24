import AppKit
import SwiftUI

struct AnnotationEditorView: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    @ObservedObject var state: AnnotationEditorState
    let sourceImage: NSImage
    let onCopy: () -> Void
    let onExport: () -> Void

    var body: some View {
        let appearance = AnnotationEditorAppearance.make(
            theme: themeStore.theme,
            colorScheme: colorScheme,
            reduceTransparency: reduceTransparency || hasArgument("--reduce-transparency"),
            increasedContrast: colorSchemeContrast == .increased || hasArgument("--increase-contrast")
        )
        let theme = ThemeRegistry.shared.definition(for: themeStore.theme)

        ZStack {
            GlassBackground(
                theme: theme,
                reduceTransparency: appearance.reduceTransparency
            )
            if appearance.reduceTransparency {
                Color(nsColor: .windowBackgroundColor)
            }
            appearance.tintOverlay

            VStack(spacing: 0) {
                toolbar(appearance: appearance)
                horizontalDivider(appearance)
                HStack(spacing: 0) {
                    AnnotationCanvasView(
                        state: state,
                        sourceImage: sourceImage,
                        appearance: appearance
                    )
                    .frame(minWidth: 560, minHeight: 420)
                    verticalDivider(appearance)
                    AnnotationInspectorView(state: state, appearance: appearance)
                }
                horizontalDivider(appearance)
                statusBar(appearance: appearance)
            }
        }
        .frame(minWidth: 820, minHeight: 560)
        .tint(appearance.accent)
        .animation(
            reduceMotion || hasArgument("--reduce-motion")
                ? nil
                : .easeInOut(duration: 0.18),
            value: themeStore.theme
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("截图标注编辑器，\(appearance.accessibilitySummary)")
        .accessibilityValue(appearance.accessibilitySummary)
        .accessibilityIdentifier("screenshot.annotation.editor")
    }

    private func toolbar(appearance: AnnotationEditorAppearance) -> some View {
        HStack(spacing: 8) {
            Button {
                _ = state.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .disabled(!state.canUndo)
            .help("撤销（⌘Z）")
            .accessibilityLabel("撤销")
            .accessibilityHint("撤销上一次标注修改")
            .accessibilityIdentifier("screenshot.annotation.undo")

            Button {
                _ = state.redo()
            } label: {
                Image(systemName: "arrow.uturn.forward")
            }
            .disabled(!state.canRedo)
            .help("重做（⇧⌘Z）")
            .accessibilityLabel("重做")
            .accessibilityHint("恢复上一次撤销的标注修改")
            .accessibilityIdentifier("screenshot.annotation.redo")

            Button {
                _ = state.selectPreviousLayer()
            } label: {
                Image(systemName: "chevron.backward.2")
            }
            .disabled(state.document.layers.isEmpty)
            .help("选择上一个图层（⌥[）")
            .accessibilityLabel("选择上一个图层")
            .accessibilityHint("按文档顺序循环选择前一个标注图层")
            .accessibilityIdentifier("screenshot.annotation.layer.previous")

            Button {
                _ = state.selectNextLayer()
            } label: {
                Image(systemName: "chevron.forward.2")
            }
            .disabled(state.document.layers.isEmpty)
            .help("选择下一个图层（⌥]）")
            .accessibilityLabel("选择下一个图层")
            .accessibilityHint("按文档顺序循环选择后一个标注图层")
            .accessibilityIdentifier("screenshot.annotation.layer.next")

            Divider().frame(height: 24)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(AnnotationEditorTool.allCases) { tool in
                        Button {
                            NSApp.keyWindow?.makeFirstResponder(nil)
                            state.selectedTool = tool
                        } label: {
                            ZStack(alignment: .bottomTrailing) {
                                Image(systemName: tool.symbolName)
                                    .frame(width: 20, height: 20)
                                if state.selectedTool == tool {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 8, weight: .bold))
                                        .accessibilityHidden(true)
                                }
                            }
                        }
                        .buttonStyle(.bordered)
                        .tint(state.selectedTool == tool ? .accentColor : nil)
                        .help("\(tool.title)（\(tool.keyboardShortcut.uppercased())）")
                        .accessibilityLabel(tool.title)
                        .accessibilityValue(state.selectedTool == tool ? "已选择" : "未选择")
                        .accessibilityHint("切换到\(tool.title)工具，快捷键 \(tool.keyboardShortcut.uppercased())")
                        .accessibilityIdentifier("screenshot.annotation.tool.\(tool.rawValue)")
                    }
                }
            }

            Spacer(minLength: 8)

            Button("复制", action: onCopy)
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .help("复制最终渲染图片（⇧⌘C）")
                .accessibilityHint("将带有全部标注的图片复制到剪贴板")
                .accessibilityIdentifier("screenshot.annotation.copy")

            Button("另存为…", action: onExport)
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .help("另存为 PNG、JPEG 或 HEIF（⇧⌘S）")
                .accessibilityHint("打开保存面板并选择图片格式与质量")
                .accessibilityIdentifier("screenshot.annotation.export")

            Button {
                Task { await state.save() }
            } label: {
                if state.isSaving {
                    ProgressView().controlSize(.small)
                } else {
                    Text("保存项目")
                }
            }
            .disabled(state.isSaving || !state.isDirty)
            .keyboardShortcut("s", modifiers: .command)
            .accessibilityLabel(state.isSaving ? "正在保存项目" : "保存项目")
            .accessibilityHint("保存可继续编辑的标注图层项目")
            .accessibilityIdentifier("screenshot.annotation.save")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: 48)
        .background(appearance.chromeFill)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("标注工具栏")
        .accessibilityIdentifier("screenshot.annotation.toolbar")
    }

    @ViewBuilder
    private func statusBar(appearance: AnnotationEditorAppearance) -> some View {
        HStack {
            Text("\(Int(state.document.canvasSize.width)) × \(Int(state.document.canvasSize.height)) pt")
            Spacer()
            switch state.saveStatus {
            case .idle:
                Text(state.isDirty ? "有未保存修改" : "已保存")
                    .foregroundStyle(.secondary)
            case .saving:
                Text("正在保存项目…").foregroundStyle(.secondary)
            case .failed(let message):
                Text("保存失败：\(message)")
                    .foregroundStyle(.red)
                    .lineLimit(1)
                Button("重试") { Task { await state.retrySave() } }
                    .accessibilityIdentifier("screenshot.annotation.retry-save")
            }
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(appearance.chromeFill)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("编辑器状态")
    }

    private func horizontalDivider(_ appearance: AnnotationEditorAppearance) -> some View {
        Rectangle()
            .fill(appearance.border)
            .frame(height: 1)
            .accessibilityHidden(true)
    }

    private func verticalDivider(_ appearance: AnnotationEditorAppearance) -> some View {
        Rectangle()
            .fill(appearance.border)
            .frame(width: 1)
            .accessibilityHidden(true)
    }

    private func hasArgument(_ argument: String) -> Bool {
        CommandLine.arguments.contains(argument)
    }
}
