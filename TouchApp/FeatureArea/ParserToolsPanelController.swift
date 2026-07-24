import AppKit
import ParserToolsFeature
import SwiftUI

@MainActor
final class ParserToolsPanelController: NSObject, NSWindowDelegate {
    private let panel: ParserToolsPanel
    private let model = ParserToolsModel()
    private let onClose: () -> Void

    init(themeStore: ThemeStore, onClose: @escaping () -> Void) {
        self.onClose = onClose
        panel = ParserToolsPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1220, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.identifier = .init("parser-tools.window.close")
        panel.standardWindowButton(.miniaturizeButton)?.identifier = .init("parser-tools.window.minimize")
        panel.standardWindowButton(.zoomButton)?.identifier = .init("parser-tools.window.zoom")
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.minSize = NSSize(width: 900, height: 560)
        panel.contentView = NSHostingView(
            rootView: ParserToolsPanelView(model: model)
                .environmentObject(themeStore)
        )
        installWindowTopDragRegion(in: panel)
    }

    func show() {
        cancelFeaturePanelDismissal(panel)
        panel.center()
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }

    func windowDidResignKey(_ notification: Notification) {
        dismissFeaturePanelAfterResigningKey(panel, onHidden: onClose)
    }
}

private final class ParserToolsPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
private final class ParserToolsModel: ObservableObject {
    @Published var input = "" { didSet { inputDidChange() } }
    @Published private(set) var output = ""
    @Published private(set) var errorMessage: String?
    @Published var selectedTool: ParserTool = .json {
        didSet {
            selectedOperation = selectedTool.operations[0]
            resetResult()
            refreshIfAutomatic()
        }
    }
    @Published var selectedOperation: ParserOperation = .format {
        didSet {
            resetResult()
            refreshIfAutomatic()
        }
    }
    @Published var secret = "" { didSet { resetResult() } }
    private var transformTask: Task<Void, Never>?

    var requiresExplicitRun: Bool { selectedTool == .base64 || selectedTool == .jwt }

    var canRun: Bool {
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if selectedTool == .jwt, selectedOperation == .signHS256 { return !secret.isEmpty }
        return true
    }

    var inputStatistics: String {
        "\(input.count) 字符 · \(max(1, input.components(separatedBy: .newlines).count)) 行"
    }

    var outputStatistics: String {
        output.isEmpty ? "" : "\(output.count) 字符"
    }

    func clear() { input = "" }

    func pasteInput() {
        guard let value = NSPasteboard.general.string(forType: .string) else { return }
        input = value
    }

    func useOutputAsInput() {
        guard !output.isEmpty else { return }
        input = output
    }

    func copyOutput() {
        guard !output.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(output, forType: .string)
    }

    func runTransform() { scheduleTransform(delay: nil) }

    private func inputDidChange() {
        if requiresExplicitRun {
            resetResult()
        } else {
            scheduleTransform(delay: .milliseconds(80))
        }
    }

    private func refreshIfAutomatic() {
        guard !requiresExplicitRun else { return }
        scheduleTransform(delay: .milliseconds(80))
    }

    private func resetResult() {
        transformTask?.cancel()
        output = ""
        errorMessage = nil
    }

    private func scheduleTransform(delay: Duration?) {
        transformTask?.cancel()
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            resetResult()
            return
        }

        let source = input
        let tool = selectedTool
        let operation = selectedOperation
        let signingSecret = secret
        transformTask = Task { [weak self] in
            if let delay {
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try ParserTransformer.transform(
                        source,
                        tool: tool,
                        operation: operation,
                        secret: signingSecret
                    )
                }.value
                guard !Task.isCancelled else { return }
                self?.output = result
                self?.errorMessage = nil
            } catch {
                guard !Task.isCancelled else { return }
                self?.output = ""
                self?.errorMessage = error.localizedDescription
            }
        }
    }
}

private struct ParserToolsPanelView: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var model: ParserToolsModel
    @State private var showsToolMenu = false
    @State private var splitRatio: CGFloat = 0.5
    @State private var splitStartRatio: CGFloat?

    private var theme: ThemeDefinition { ThemeRegistry.shared.definition(for: themeStore.theme) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            PanelThemeBackground(
                theme: theme,
                reduceTransparency: reduceTransparency,
                themeColorOpacity: themeStore.themeColorOpacity
            )

            VStack(spacing: 0) {
                header
                Rectangle()
                    .fill(theme.card.border.color.opacity(0.42))
                    .frame(height: 1)
                workspace
            }

            if showsToolMenu {
                toolMenu
                    .padding(.top, 74)
                    .padding(.leading, 20)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .zIndex(10)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(theme.panel.edgeBorder.color, lineWidth: 1)
        }
        .ignoresSafeArea(.container, edges: .top)
        .onExitCommand { showsToolMenu = false }
    }

    private var header: some View {
        VStack(spacing: 0) {
            // 为原生红黄绿窗口按钮保留独立标题带，工具栏从下一行开始。
            Color.clear
                .frame(height: 26)
                .allowsHitTesting(false)

            HStack(spacing: 14) {
                toolSelector

                if model.selectedTool.operations.count > 1 {
                    Rectangle()
                        .fill(theme.card.border.color.opacity(0.42))
                        .frame(width: 1, height: 24)
                    operationSelector
                }

                Spacer(minLength: 12)
            }
            .padding(.horizontal, 20)
            .frame(height: 52)
        }
        .frame(height: 78)
        .background(theme.card.fill.color.opacity(0.2))
        .animation(reduceMotion ? nil : .easeOut(duration: theme.motion.duration), value: model.selectedTool)
        .zIndex(4)
    }

    private var toolSelector: some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                showsToolMenu.toggle()
            }
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(theme.icon.brandGradient.gradient)
                    Image(systemName: model.selectedTool.symbolName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.white)
                }
                .frame(width: 32, height: 32)
                .shadow(color: theme.accent.color.opacity(0.22), radius: 7, y: 3)

                Text(model.selectedTool.title)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.text.primary.color)

                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(theme.text.secondary.color)
                    .rotationEffect(.degrees(showsToolMenu ? 180 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("parser-tools.tool-selector")
        .accessibilityLabel("当前工具：\(model.selectedTool.title)，点击切换")
    }

    private var operationSelector: some View {
        HStack(spacing: 3) {
            ForEach(model.selectedTool.operations) { operation in
                Button {
                    model.selectedOperation = operation
                } label: {
                    Text(operation.title)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(
                            model.selectedOperation == operation
                                ? theme.accent.color
                                : theme.text.secondary.color
                        )
                        .padding(.horizontal, 11)
                        .frame(height: 28)
                        .background(
                            model.selectedOperation == operation
                                ? theme.card.fill.color.opacity(0.94)
                                : Color.clear,
                            in: Capsule()
                        )
                        .overlay {
                            if model.selectedOperation == operation {
                                Capsule().stroke(theme.accent.color.opacity(0.26), lineWidth: 1)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("parser-tools.operation.\(operation.rawValue)")
            }
        }
        .padding(3)
        .background(theme.panel.fallback.color.opacity(0.3), in: Capsule())
    }

    private var toolMenu: some View {
        VStack(spacing: 5) {
            ForEach(ParserTool.allCases) { tool in
                Button {
                    model.selectedTool = tool
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.14)) {
                        showsToolMenu = false
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: tool.symbolName)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(tool == model.selectedTool ? theme.accent.color : theme.icon.secondary.color)
                            .frame(width: 24)
                        Text(tool.title)
                            .font(.system(size: 12.5, weight: tool == model.selectedTool ? .semibold : .medium))
                            .foregroundStyle(tool == model.selectedTool ? theme.accent.color : theme.text.primary.color)
                        Spacer()
                        if tool == model.selectedTool {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(theme.accent.color)
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(width: 268, height: 43)
                    .background(
                        tool == model.selectedTool
                            ? theme.accent.color.opacity(0.12)
                            : Color.clear,
                        in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("parser-tools.tool.\(tool.rawValue)")
            }
        }
        .padding(8)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(theme.panel.fallback.color.opacity(reduceTransparency ? 1 : 0.96))
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(theme.panel.edgeBorder.color, lineWidth: 1)
        }
        .shadow(color: theme.panel.shadow.color.color.opacity(0.82), radius: 24, y: 12)
    }

    private var workspace: some View {
        Group {
            if model.requiresExplicitRun {
                explicitWorkspace
            } else {
                automaticWorkspace
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: model.selectedTool)
    }

    private var automaticWorkspace: some View {
        GeometryReader { proxy in
            let handleWidth: CGFloat = 8
            let gaps: CGFloat = 20
            let available = max(1, proxy.size.width - 36 - handleWidth - gaps)
            HStack(spacing: 10) {
                editorPane
                    .frame(width: available * splitRatio)
                splitHandle(contentWidth: available)
                resultPane
                    .frame(width: available * (1 - splitRatio))
            }
            .padding(18)
        }
    }

    private var explicitWorkspace: some View {
        VStack(spacing: 14) {
            editorPane
                .frame(minHeight: 190)

            HStack(spacing: 14) {
                if model.selectedTool == .jwt {
                    HStack(spacing: 10) {
                        Image(systemName: "key.horizontal")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(theme.accent.color)
                        SecureField(jwtSecretPlaceholder, text: $model.secret)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(theme.text.primary.color)
                    }
                    .padding(.horizontal, 14)
                    .frame(width: 320, height: 40)
                    .background(theme.card.fill.color.opacity(0.72), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .stroke(theme.card.border.color.opacity(0.54), lineWidth: 1)
                    }
                    .accessibilityIdentifier("parser-tools.jwt-secret")
                }

                Spacer()
                runButton
            }
            .frame(height: 42)

            resultPane
                .frame(minHeight: 190)
        }
        .padding(18)
    }

    private var runButton: some View {
        Button(action: model.runTransform) {
            HStack(spacing: 7) {
                Image(systemName: model.selectedTool == .base64 ? "arrow.triangle.2.circlepath" : "play.fill")
                    .font(.system(size: 10, weight: .bold))
                Text(runButtonTitle)
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .foregroundStyle(Color.white)
            .padding(.horizontal, 18)
            .frame(height: 40)
            .background(
                model.canRun ? theme.accent.color : theme.accent.color.opacity(0.35),
                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
            )
        }
        .buttonStyle(ThemePressButtonStyle(theme: theme, reduceMotion: reduceMotion))
        .disabled(!model.canRun)
        .accessibilityIdentifier("parser-tools.run")
    }

    private var runButtonTitle: String {
        switch model.selectedTool {
        case .base64:
            model.selectedOperation == .encode ? "编码" : "解码"
        case .jwt:
            model.selectedOperation == .signHS256 ? "生成签名" : "解析"
        default:
            "转换"
        }
    }

    private var jwtSecretPlaceholder: String {
        model.selectedOperation == .signHS256
            ? "HS256 密钥"
            : "校验密钥（可选）"
    }

    private var editorPane: some View {
        VStack(spacing: 0) {
            paneHeader(
                title: inputTitle,
                detail: model.inputStatistics,
                actions: [
                    PaneAction(title: "粘贴", symbol: "doc.on.clipboard", enabled: true, action: model.pasteInput),
                    PaneAction(title: "清空", symbol: "trash", enabled: !model.input.isEmpty, action: model.clear)
                ]
            )
            Rectangle().fill(theme.card.border.color.opacity(0.34)).frame(height: 1)
            ZStack(alignment: .topLeading) {
                ParserTextView(
                    text: $model.input,
                    isEditable: true,
                    theme: theme,
                    highlightsSyntax: false
                )
                if model.input.isEmpty {
                    Text(model.selectedTool.inputHint)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(theme.text.weak.color)
                        .padding(.leading, 24)
                        .padding(.top, 24)
                    .allowsHitTesting(false)
                }
            }
            .background(theme.card.fill.color.opacity(0.3))
        }
        .background(theme.card.fill.color.opacity(0.18), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(theme.card.border.color.opacity(0.58), lineWidth: 1)
        }
    }

    private var inputTitle: String {
        if model.selectedTool == .jwt {
            return model.selectedOperation == .signHS256 ? "Payload" : "Token"
        }
        return "输入"
    }

    private var resultPane: some View {
        VStack(spacing: 0) {
            paneHeader(
                title: "结果",
                detail: model.outputStatistics,
                actions: [
                    PaneAction(title: "复制", symbol: "doc.on.doc", enabled: !model.output.isEmpty, action: model.copyOutput)
                ]
            )
            Rectangle().fill(theme.card.border.color.opacity(0.34)).frame(height: 1)
            ZStack(alignment: .topLeading) {
                ParserTextView(
                    text: .constant(model.output),
                    isEditable: false,
                    theme: theme,
                    highlightsSyntax: model.selectedTool != .base64 && model.selectedTool != .javascript
                )
                if let error = model.errorMessage {
                    errorState(error)
                } else if model.output.isEmpty {
                    emptyResult
                }
            }
            .background(theme.card.fill.color.opacity(0.25))
            .accessibilityIdentifier("parser-tools.result")
            .accessibilityValue(model.output)
        }
        .background(theme.card.fill.color.opacity(0.2), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(theme.card.border.color.opacity(0.58), lineWidth: 1)
        }
    }

    private func paneHeader(
        title: String,
        detail: String,
        actions: [PaneAction]
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.text.primary.color)
            if !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(theme.text.weak.color)
            }
            Spacer()
            ForEach(actions) { item in
                Button(action: item.action) {
                    Label(item.title, systemImage: item.symbol)
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(item.enabled ? theme.text.secondary.color : theme.text.weak.color.opacity(0.45))
                        .padding(.horizontal, 9)
                        .frame(height: 26)
                        .background(theme.card.fill.color.opacity(item.enabled ? 0.52 : 0.2), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!item.enabled)
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 40)
        .background(theme.card.fill.color.opacity(0.3))
    }

    private func splitHandle(contentWidth: CGFloat) -> some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 8)
            .overlay {
                Rectangle()
                    .fill(theme.card.border.color.opacity(0.62))
                    .frame(width: 1)
            }
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if splitStartRatio == nil { splitStartRatio = splitRatio }
                        splitRatio = min(0.75, max(0.25, (splitStartRatio ?? splitRatio) + value.translation.width / contentWidth))
                    }
                    .onEnded { _ in splitStartRatio = nil }
            )
            .onTapGesture(count: 2) {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { splitRatio = 0.5 }
            }
            .onContinuousHover { phase in
                switch phase {
                case .active: NSCursor.resizeLeftRight.set()
                case .ended: NSCursor.arrow.set()
                }
            }
            .accessibilityIdentifier("parser-tools.split-divider")
            .accessibilityLabel("拖动调整输入和结果宽度，双击恢复等宽")
    }

    private func errorState(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(theme.text.failure.color)
            Text(message)
                .font(.system(size: 11.5))
                .foregroundStyle(theme.text.secondary.color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .allowsHitTesting(false)
    }

    private var emptyResult: some View {
        Text("暂无结果")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(theme.text.weak.color)
            .padding(24)
        .allowsHitTesting(false)
    }
}

private struct PaneAction: Identifiable {
    let id = UUID()
    let title: String
    let symbol: String
    let enabled: Bool
    let action: () -> Void
}

private struct ParserTextView: NSViewRepresentable {
    @Binding var text: String
    let isEditable: Bool
    let theme: ThemeDefinition
    let highlightsSyntax: Bool

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.allowsUndo = isEditable
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 22, height: 22)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.lineFragmentPadding = 0
        textView.minSize = NSSize(width: 0, height: scrollView.contentSize.height)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        scrollView.documentView = textView
        context.coordinator.textView = textView
        applyAppearance(to: textView)
        textView.string = text
        applyHighlighting(to: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        textView.isEditable = isEditable
        if textView.string != text {
            let selected = textView.selectedRange()
            textView.string = text
            textView.setSelectedRange(NSRange(location: min(selected.location, text.utf16.count), length: 0))
        }
        applyAppearance(to: textView)
        applyHighlighting(to: textView)
    }

    private func applyAppearance(to textView: NSTextView) {
        textView.font = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
        textView.textColor = NSColor(theme.text.primary.color)
        textView.insertionPointColor = NSColor(theme.accent.color)
        textView.selectedTextAttributes = [
            .backgroundColor: NSColor(theme.accent.color.opacity(0.24)),
            .foregroundColor: NSColor(theme.text.primary.color)
        ]
        textView.typingAttributes = baseAttributes
    }

    private var baseAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        return [
            .font: NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular),
            .foregroundColor: NSColor(theme.text.primary.color),
            .paragraphStyle: paragraph
        ]
    }

    private func applyHighlighting(to textView: NSTextView) {
        guard highlightsSyntax, !textView.string.isEmpty else {
            textView.textStorage?.setAttributes(baseAttributes, range: NSRange(location: 0, length: textView.string.utf16.count))
            return
        }
        let storage = textView.textStorage
        let range = NSRange(location: 0, length: textView.string.utf16.count)
        storage?.beginEditing()
        storage?.setAttributes(baseAttributes, range: range)
        highlight(#"\"(?:\\.|[^\"\\])*\""#, color: theme.text.success.color, in: textView)
        highlight(#"\"(?:\\.|[^\"\\])*\"(?=\s*:)"#, color: theme.auxiliaryAccent.color, in: textView)
        highlight(#"(?<![A-Za-z])[-+]?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?"#, color: theme.accent.color, in: textView)
        highlight(#"\b(?:true|false|null)\b"#, color: theme.text.permission.color, in: textView)
        storage?.endEditing()
    }

    private func highlight(_ pattern: String, color: Color, in textView: NSTextView) {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let range = NSRange(location: 0, length: textView.string.utf16.count)
        for match in regex.matches(in: textView.string, range: range) {
            textView.textStorage?.addAttribute(.foregroundColor, value: NSColor(color), range: match.range)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ParserTextView
        var textView: NSTextView?

        init(parent: ParserTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard parent.isEditable, let textView else { return }
            parent.text = textView.string
        }
    }
}
