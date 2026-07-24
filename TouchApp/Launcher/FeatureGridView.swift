import AppKit
import SwiftUI
import TouchFeatureAPI
import UniformTypeIdentifiers

struct ThemedScrollMetrics: Equatable {
    var contentHeight: CGFloat = 0
    var viewportHeight: CGFloat = 0
    var offset: CGFloat = 0

    var isScrollable: Bool {
        contentHeight > viewportHeight + 1
    }

    var thumbHeight: CGFloat {
        guard viewportHeight > 0, contentHeight > 0 else { return 0 }
        return max(34, viewportHeight * viewportHeight / contentHeight)
    }

    var thumbOffset: CGFloat {
        let maxOffset = max(0, contentHeight - viewportHeight)
        let trackTravel = max(0, viewportHeight - thumbHeight)
        guard maxOffset > 0 else { return 0 }
        return min(trackTravel, max(0, offset) / maxOffset * trackTravel)
    }
}

struct ThemedScrollContentMetrics: Equatable {
    var height: CGFloat = 0
    var minY: CGFloat = 0
}

struct ThemedScrollContentMetricsPreferenceKey: PreferenceKey {
    static let defaultValue = ThemedScrollContentMetrics()

    static func reduce(value: inout ThemedScrollContentMetrics, nextValue: () -> ThemedScrollContentMetrics) {
        value = nextValue()
    }
}

struct ThemedVerticalScrollBar: View {
    let metrics: ThemedScrollMetrics
    let theme: ThemeDefinition

    var body: some View {
        GeometryReader { geometry in
            if metrics.isScrollable {
                let thumbHeight = min(geometry.size.height, max(34, metrics.thumbHeight))
                let travel = max(0, geometry.size.height - thumbHeight)
                let thumbOffset = min(travel, max(0, metrics.thumbOffset))

                Capsule()
                    .fill(theme.accent.color.opacity(0.58))
                    .frame(width: 4, height: thumbHeight)
                    .shadow(color: theme.accent.color.opacity(0.2), radius: 2)
                    .offset(y: thumbOffset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
        .frame(width: 14)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

final class ThemedScrollIndicatorView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureScrollViews()
    }

    func configureScrollViews() {
        let apply = { [weak self] in
            guard let self, let root = self.window?.contentView else { return }
            var pending = [root]
            while let view = pending.popLast() {
                if let scrollView = view as? NSScrollView {
                    scrollView.scrollerStyle = .overlay
                    scrollView.hasVerticalScroller = false
                    scrollView.hasHorizontalScroller = false
                    scrollView.verticalScroller?.isHidden = true
                    scrollView.horizontalScroller?.isHidden = true
                    scrollView.verticalScroller?.alphaValue = 0
                    scrollView.horizontalScroller?.alphaValue = 0
                }
                pending.append(contentsOf: view.subviews)
            }
        }
        DispatchQueue.main.async(execute: apply)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: apply)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: apply)
    }
}

struct ThemedScrollIndicatorConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ThemedScrollIndicatorView(frame: .zero) }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { [weak nsView] in
            guard let indicatorView = nsView as? ThemedScrollIndicatorView else { return }
            indicatorView.configureScrollViews()
        }
    }
}

enum LauncherFeatureLayout: String, CaseIterable {
    case cards
    case keyboard

    var accessibilityLabel: String {
        switch self {
        case .cards: "卡片布局"
        case .keyboard: "键位布局"
        }
    }

    var symbolName: String {
        switch self {
        case .cards: "rectangle.grid.2x2"
        case .keyboard: "keyboard"
        }
    }
}

struct FeatureGridView: View {
    @EnvironmentObject private var featureStore: FeatureAreaStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var editingFeatureID: String?
    @State private var shortcutErrorMessage: String?
    @State private var scrollMetrics = ThemedScrollMetrics(viewportHeight: 336)
    let theme: ThemeDefinition

    var body: some View {
        ZStack {
            ScrollView(.vertical) {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.fixed(260), spacing: 16), count: 3),
                    alignment: .center,
                    spacing: 16
                ) {
                    ForEach(featureStore.visiblePlugins, id: \.manifest.id) { plugin in
                        FeatureCardView(
                            plugin: plugin,
                            shortcut: featureStore.shortcut(for: plugin.manifest.id),
                            state: featureStore.states[plugin.manifest.id] ?? .unloaded,
                            theme: theme,
                            action: { Task { await featureStore.perform(plugin.manifest.id) } },
                            edit: {
                                shortcutErrorMessage = nil
                                editingFeatureID = plugin.manifest.id
                            }
                        )
                        .draggable(plugin.manifest.id)
                        .dropDestination(for: String.self) { featureIDs, _ in
                            guard let sourceID = featureIDs.first else { return false }
                            featureStore.move(sourceID, before: plugin.manifest.id, animated: !reduceMotion)
                            return true
                        }
                        .background {
                            RightClickCapture {
                                shortcutErrorMessage = nil
                                editingFeatureID = plugin.manifest.id
                            }
                        }
                    }

                    ForEach(featureStore.launcherCustomActionKeys, id: \.self) { key in
                        if let action = featureStore.customAction(forLauncherKey: key) {
                            CustomActionCardView(
                                key: key,
                                action: action,
                                theme: theme
                            ) {
                                Task { await featureStore.performLauncherKey(key) }
                            }
                        }
                    }
                }
                .padding(.vertical, 1)
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(
                            key: ThemedScrollContentMetricsPreferenceKey.self,
                            value: ThemedScrollContentMetrics(
                                height: geometry.size.height,
                                minY: geometry.frame(in: .named("launcher-feature-grid-scroll")).minY
                            )
                        )
                    }
                }
            }
            .coordinateSpace(name: "launcher-feature-grid-scroll")
            .scrollIndicators(.hidden)
            .background(ThemedScrollIndicatorConfigurator())
            .frame(width: 812, height: 336)
            .onPreferenceChange(ThemedScrollContentMetricsPreferenceKey.self) { content in
                scrollMetrics = ThemedScrollMetrics(
                    contentHeight: content.height,
                    viewportHeight: 336,
                    offset: max(0, -content.minY)
                )
            }

            ThemedVerticalScrollBar(metrics: scrollMetrics, theme: theme)
                .frame(height: 336)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 1)

            if let editingFeatureID,
               let plugin = featureStore.visiblePlugins.first(where: { $0.manifest.id == editingFeatureID }) {
                theme.panel.tint.color.opacity(0.13)
                    .contentShape(Rectangle())
                    .onTapGesture { self.editingFeatureID = nil }
                    .zIndex(10)

                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("修改功能键位")
                                .font(.system(size: 16, weight: .semibold, design: .rounded))
                                .foregroundStyle(theme.text.secondary.color)
                            Text(plugin.manifest.name)
                                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                                .foregroundStyle(theme.text.weak.color)
                        }
                        Spacer()
                        Button {
                            self.editingFeatureID = nil
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(theme.text.weak.color)
                                .frame(width: 30, height: 30)
                                .background(theme.shortcut.fill.color, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("关闭快捷键设置")
                    }

                    SingleKeyRecorderView(
                        title: "按下新的功能键",
                        shortcut: featureStore.shortcut(for: editingFeatureID),
                        errorMessage: shortcutErrorMessage,
                        theme: theme
                    ) { shortcut in
                        shortcutErrorMessage = featureStore.updateShortcut(shortcut, for: editingFeatureID)
                        if shortcutErrorMessage == nil {
                            self.editingFeatureID = nil
                        }
                    }
                }
                .padding(18)
                .frame(width: 370)
                .background(theme.card.fill.color.opacity(0.98), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(theme.card.hoverBorder.color.opacity(0.9), lineWidth: 1)
                }
                .shadow(color: theme.panel.shadow.color.color.opacity(0.7), radius: 28, y: 16)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("launcher.shortcut-editor")
                .zIndex(11)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: editingFeatureID)
    }
}

struct FeatureKeyboardView: View {
    @EnvironmentObject private var featureStore: FeatureAreaStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var editingKey: String?
    @State private var editorAnchor: CGPoint?
    @State private var editorErrorMessage: String?
    @State private var editorMode: KeyboardEditorMode = .menu
    @State private var customActionTitle = ""
    @State private var customActionTarget = ""
    let theme: ThemeDefinition

    private let rows = [
        ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "-", "="],
        ["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"],
        ["a", "s", "d", "f", "g", "h", "j", "k", "l"],
        ["z", "x", "c", "v", "b", "n", "m"]
    ]

    var body: some View {
        VStack(spacing: LauncherKeyboardMetrics.verticalSpacing) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: LauncherKeyboardMetrics.horizontalSpacing) {
                    ForEach(row, id: \.self) { key in
                        if let action = featureStore.customAction(forLauncherKey: key) {
                            CustomActionKeyView(
                                key: key,
                                action: action,
                                theme: theme,
                                perform: { Task { await featureStore.performLauncherKey(key) } },
                                edit: { location in presentEditor(for: key, at: location) }
                            )
                        } else if let plugin = assignments[key] {
                            FeatureKeyView(
                                key: key,
                                plugin: plugin,
                                shortcut: featureStore.shortcut(for: plugin.manifest.id),
                                state: featureStore.states[plugin.manifest.id] ?? .unloaded,
                                theme: theme,
                                action: { Task { await featureStore.perform(plugin.manifest.id) } },
                                edit: { location in presentEditor(for: key, at: location) }
                            )
                        } else {
                            EmptyKeyView(
                                key: key,
                                theme: theme,
                                edit: { location in presentEditor(for: key, at: location) }
                            )
                        }
                    }
                }
            }
        }
        .coordinateSpace(name: LauncherKeyboardMetrics.coordinateSpaceName)
        .overlay { keyboardEditorOverlay }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: editingKey)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("功能键位")
        .accessibilityIdentifier("launcher.feature-keyboard")
    }

    private func presentEditor(for key: String, at location: CGPoint) {
        editorErrorMessage = nil
        editorMode = .menu
        customActionTitle = ""
        customActionTarget = ""
        editorAnchor = location
        editingKey = key
    }

    private func dismissEditor() {
        editingKey = nil
        editorAnchor = nil
        editorErrorMessage = nil
        editorMode = .menu
        customActionTitle = ""
        customActionTarget = ""
    }

    @ViewBuilder
    private var keyboardEditorOverlay: some View {
        GeometryReader { proxy in
            if let editingKey, let editorAnchor {
                let placement = editorPlacement(anchor: editorAnchor, availableSize: proxy.size)

                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(perform: dismissEditor)

                keyboardEditor(
                    for: editingKey,
                    pointerEdge: placement.pointerEdge,
                    pointerOffset: placement.pointerOffset
                )
                    .position(x: placement.centerX, y: placement.centerY)
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: placement.scaleAnchor)))
            }
        }
    }

    private func editorPlacement(anchor: CGPoint, availableSize: CGSize) -> KeyboardEditorPlacement {
        let width = LauncherKeyboardMetrics.editorWidth
        let height = estimatedEditorHeight
        let gap = LauncherKeyboardMetrics.editorPointerGap
        let centerX = min(max(anchor.x, width / 2), availableSize.width - width / 2)
        let shouldPresentBelow = anchor.y < availableSize.height * 0.57
        let anchorEdgeY = anchor.y + (shouldPresentBelow
            ? LauncherKeyboardMetrics.keySize / 2
            : -LauncherKeyboardMetrics.keySize / 2)
        let preferredCenterY = shouldPresentBelow
            ? anchorEdgeY + gap + height / 2
            : anchorEdgeY - gap - height / 2
        return KeyboardEditorPlacement(
            centerX: centerX,
            centerY: min(max(preferredCenterY, height / 2), availableSize.height - height / 2),
            pointerEdge: shouldPresentBelow ? .top : .bottom,
            pointerOffset: min(max(anchor.x - centerX, -(width / 2 - 28)), width / 2 - 28),
            scaleAnchor: shouldPresentBelow ? .top : .bottom
        )
    }

    private var estimatedEditorHeight: CGFloat {
        switch editorMode {
        case .menu: 238
        case .builtInFeatures: 232
        case .form(.shellScript): 274
        case .form: 232
        }
    }

    private func keyboardEditor(
        for key: String,
        pointerEdge: KeyboardEditorPointerEdge,
        pointerOffset: CGFloat
    ) -> some View {
        let currentPlugin = assignments[key]
        let currentCustomAction = featureStore.customAction(forLauncherKey: key)
        return VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 10) {
                Text(key.uppercased())
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.accent.color)
                    .frame(width: 34, height: 34)
                    .background(theme.card.selectedFill.color, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text("设置键位")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.text.primary.color)
                    Text(currentCustomAction.map { "当前：\($0.displayTitle)" }
                        ?? currentPlugin.map { "当前：\($0.manifest.name)" }
                        ?? "当前未分配功能")
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundStyle(theme.text.weak.color)
                }

                Spacer()

                Button(action: dismissEditor) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(theme.text.weak.color)
                        .frame(width: 26, height: 26)
                        .background(theme.shortcut.fill.color, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭键位设置")
                .accessibilityIdentifier("launcher.key-editor.close")
            }

            switch editorMode {
            case .menu:
                actionTypeMenu(key: key, hasCustomAction: currentCustomAction != nil)
            case .builtInFeatures:
                builtInFeatureMenu(key: key, currentPlugin: currentPlugin)
            case let .form(kind):
                customActionForm(kind: kind, key: key)
            }

            if let editorErrorMessage {
                Text(editorErrorMessage)
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(theme.text.failure.color)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, pointerEdge == .top ? 20 : 14)
        .padding(.bottom, pointerEdge == .bottom ? 20 : 14)
        .frame(width: LauncherKeyboardMetrics.editorWidth)
        .background(
            theme.card.fill.color.opacity(0.98),
            in: KeyboardEditorCalloutShape(pointerEdge: pointerEdge, pointerOffset: pointerOffset)
        )
        .overlay {
            KeyboardEditorCalloutShape(pointerEdge: pointerEdge, pointerOffset: pointerOffset)
                .stroke(theme.card.hoverBorder.color.opacity(0.9), lineWidth: 1)
        }
        .shadow(color: theme.panel.shadow.color.color.opacity(0.62), radius: 20, y: 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("设置 \(key.uppercased()) 键")
        .accessibilityIdentifier("launcher.key-editor")
    }

    private func actionTypeMenu(key: String, hasCustomAction: Bool) -> some View {
        VStack(spacing: 6) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 2), spacing: 6) {
                ForEach(LauncherCustomActionKind.allCases) { kind in
                    Button {
                        beginCustomAction(kind, key: key)
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: kind.symbolName)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(theme.icon.neutral.color)
                                .frame(width: 18)
                            Text(kind.title)
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .foregroundStyle(theme.text.secondary.color)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity, minHeight: 38)
                        .background(theme.shortcut.fill.color, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(ThemePressButtonStyle(theme: theme, reduceMotion: reduceMotion))
                    .accessibilityIdentifier("launcher.key-editor.type.\(kind.rawValue)")
                }
            }

            HStack(spacing: 6) {
                editorMenuButton(title: "内置功能", symbol: "square.grid.2x2") {
                    editorMode = .builtInFeatures
                }
                if hasCustomAction {
                    editorMenuButton(title: "清除设置", symbol: "trash") {
                        featureStore.removeCustomAction(for: key)
                        dismissEditor()
                    }
                }
            }
        }
    }

    private func editorMenuButton(
        title: String,
        symbol: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(theme.text.secondary.color)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 36)
            .background(theme.card.selectedFill.color, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(ThemePressButtonStyle(theme: theme, reduceMotion: reduceMotion))
    }

    private func builtInFeatureMenu(
        key: String,
        currentPlugin: (any FeaturePlugin)?
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Button {
                editorMode = .menu
                editorErrorMessage = nil
            } label: {
                Label("返回自定义类型", systemImage: "chevron.left")
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.text.weak.color)
            }
            .buttonStyle(.plain)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 2), spacing: 6) {
                ForEach(featureStore.visiblePlugins, id: \.manifest.id) { candidate in
                    assignmentButton(
                        candidate,
                        key: key,
                        isSelected: candidate.manifest.id == currentPlugin?.manifest.id
                    )
                }
            }
        }
    }

    private func customActionForm(kind: LauncherCustomActionKind, key: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Button {
                editorMode = .menu
                editorErrorMessage = nil
            } label: {
                Label("返回", systemImage: "chevron.left")
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.text.weak.color)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 5) {
                Text("显示名称")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.text.weak.color)
                TextField(kind.title, text: $customActionTitle)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(theme.text.primary.color)
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .background(theme.shortcut.fill.color, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(actionTargetLabel(for: kind))
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.text.weak.color)
                if kind == .shellScript {
                    TextEditor(text: $customActionTarget)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(theme.text.primary.color)
                        .scrollContentBackground(.hidden)
                        .padding(7)
                        .frame(height: 68)
                        .background(theme.shortcut.fill.color, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                } else {
                    TextField(actionTargetPlaceholder(for: kind), text: $customActionTarget)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(theme.text.primary.color)
                        .padding(.horizontal, 10)
                        .frame(height: 34)
                        .background(theme.shortcut.fill.color, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
            }

            HStack(spacing: 7) {
                Spacer()
                Button("取消") { editorMode = .menu }
                    .buttonStyle(CompactEditorButtonStyle(theme: theme, isPrimary: false))
                Button("保存") {
                    saveCustomAction(kind, key: key)
                }
                .buttonStyle(CompactEditorButtonStyle(theme: theme, isPrimary: true))
            }
        }
    }

    private func beginCustomAction(_ kind: LauncherCustomActionKind, key: String) {
        editorErrorMessage = nil
        switch kind {
        case .application, .file, .folder:
            chooseLocalItem(kind: kind, key: key)
        case .webPage, .shortcut, .shellScript:
            customActionTitle = ""
            customActionTarget = ""
            editorMode = .form(kind)
        }
    }

    private func chooseLocalItem(kind: LauncherCustomActionKind, key: String) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.canChooseDirectories = kind == .folder
        panel.canChooseFiles = kind != .folder
        panel.prompt = "选择"
        panel.message = "为 \(key.uppercased()) 键选择\(kind.title)"
        if kind == .application {
            panel.directoryURL = URL(fileURLWithPath: "/Applications")
            panel.allowedContentTypes = [.application]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let title = url.deletingPathExtension().lastPathComponent
        let action = LauncherCustomAction(kind: kind, title: title, target: url.path)
        editorErrorMessage = featureStore.assignCustomAction(action, to: key)
        if editorErrorMessage == nil {
            dismissEditor()
        }
    }

    private func saveCustomAction(_ kind: LauncherCustomActionKind, key: String) {
        let action = LauncherCustomAction(
            kind: kind,
            title: customActionTitle,
            target: customActionTarget
        )
        editorErrorMessage = featureStore.assignCustomAction(action, to: key)
        if editorErrorMessage == nil {
            dismissEditor()
        }
    }

    private func actionTargetLabel(for kind: LauncherCustomActionKind) -> String {
        switch kind {
        case .webPage: "网址"
        case .shortcut: "快捷指令名称"
        case .shellScript: "脚本内容"
        case .application, .file, .folder: "位置"
        }
    }

    private func actionTargetPlaceholder(for kind: LauncherCustomActionKind) -> String {
        switch kind {
        case .webPage: "例如 openai.com"
        case .shortcut: "例如 开始专注"
        case .shellScript: "输入要执行的 Shell 命令"
        case .application, .file, .folder: ""
        }
    }

    private func assignmentButton(
        _ plugin: any FeaturePlugin,
        key: String,
        isSelected: Bool
    ) -> some View {
        Button {
            editorErrorMessage = featureStore.assignKeyboardKey(key, to: plugin.manifest.id)
            if editorErrorMessage == nil {
                dismissEditor()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: plugin.manifest.symbolName)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isSelected ? theme.accent.color : theme.icon.neutral.color)
                Text(plugin.manifest.name)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.text.secondary.color)
                    .lineLimit(1)
                Spacer(minLength: 2)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(theme.accent.color)
                }
            }
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity, minHeight: 32)
            .background(
                isSelected ? theme.card.selectedFill.color : theme.shortcut.fill.color,
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(isSelected ? theme.accent.color.opacity(0.34) : theme.shortcut.border.color, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("将 \(key.uppercased()) 键设置为 \(plugin.manifest.name)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("launcher.key-editor.assign.\(plugin.manifest.id)")
    }

    /// 优先使用用户配置的真实主键。若主键不在可视键盘中或与另一组修饰键共用，
    /// 则分配到首个空键，保证所有可见功能始终有入口。
    private var assignments: [String: any FeaturePlugin] {
        let supportedKeys = rows.flatMap { $0 }
        var result: [String: any FeaturePlugin] = [:]
        var deferred: [any FeaturePlugin] = []

        for plugin in featureStore.visiblePlugins {
            let key = featureStore.shortcut(for: plugin.manifest.id).key.lowercased()
            if supportedKeys.contains(key),
               featureStore.customAction(forLauncherKey: key) == nil,
               result[key] == nil {
                result[key] = plugin
            } else {
                deferred.append(plugin)
            }
        }

        var emptyKeys = supportedKeys.filter {
            result[$0] == nil && featureStore.customAction(forLauncherKey: $0) == nil
        }.makeIterator()
        for plugin in deferred {
            guard let key = emptyKeys.next() else { break }
            result[key] = plugin
        }
        return result
    }
}

private enum KeyboardEditorMode: Equatable {
    case menu
    case builtInFeatures
    case form(LauncherCustomActionKind)
}

private struct CompactEditorButtonStyle: ButtonStyle {
    let theme: ThemeDefinition
    let isPrimary: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(isPrimary ? Color.white : theme.text.secondary.color)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(
                isPrimary ? theme.accent.color : theme.shortcut.fill.color,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .opacity(configuration.isPressed ? 0.78 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

private struct CustomActionKeyView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    let key: String
    let action: LauncherCustomAction
    let theme: ThemeDefinition
    let perform: () -> Void
    let edit: (CGPoint) -> Void

    var body: some View {
        Button(action: perform) {
            ZStack {
                RoundedRectangle(cornerRadius: LauncherKeyboardMetrics.cornerRadius, style: .continuous)
                    .fill((isHovered ? theme.card.hoverFill : theme.card.selectedFill).color)
                    .overlay {
                        RoundedRectangle(cornerRadius: LauncherKeyboardMetrics.cornerRadius, style: .continuous)
                            .stroke((isHovered ? theme.card.hoverBorder : theme.card.border).color, lineWidth: 1)
                    }

                VStack(spacing: 3) {
                    customActionIcon
                        .frame(width: 30, height: 30)
                        .accessibilityHidden(true)

                    Text(action.displayTitle)
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.92))
                        .multilineTextAlignment(.center)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
                .padding(.horizontal, 7)
                .offset(y: -2)

                Text(key.uppercased())
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.92))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background(theme.shortcut.fill.color.opacity(0.92), in: Capsule())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(6)
            }
            .frame(width: LauncherKeyboardMetrics.keySize, height: LauncherKeyboardMetrics.keySize)
            .overlay {
                GeometryReader { proxy in
                    RightClickCapture { localPoint in
                        let frame = proxy.frame(in: .named(LauncherKeyboardMetrics.coordinateSpaceName))
                        edit(CGPoint(x: frame.minX + localPoint.x, y: frame.minY + localPoint.y))
                    }
                }
            }
        }
        .buttonStyle(ThemePressButtonStyle(theme: theme, reduceMotion: reduceMotion))
        .offset(y: isHovered ? theme.motion.hoverOffset : 0)
        .animation(reduceMotion ? nil : .easeOut(duration: theme.motion.duration), value: isHovered)
        .onHover { isHovered = $0 }
        .help("\(action.displayTitle)  \(key.uppercased())")
        .accessibilityLabel("\(action.displayTitle)，键位 \(key.uppercased())，右键可修改")
        .accessibilityIdentifier("launcher.custom-key.\(key.lowercased())")
    }

    @ViewBuilder
    private var customActionIcon: some View {
        if action.kind == .application,
           FileManager.default.fileExists(atPath: action.target) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: action.target))
                .resizable()
                .interpolation(.high)
                .scaledToFit()
        } else {
            Image(systemName: action.kind.symbolName)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.88))
        }
    }
}

private struct FeatureKeyView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    let key: String
    let plugin: any FeaturePlugin
    let shortcut: TouchFeatureAPI.KeyboardShortcut
    let state: FeatureState
    let theme: ThemeDefinition
    let action: () -> Void
    let edit: (CGPoint) -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                keySurface

                VStack(spacing: 3) {
                    LauncherFeatureIcon(
                        pluginID: plugin.manifest.id,
                        fallbackSymbolName: plugin.manifest.symbolName,
                        size: 30,
                        fallbackColor: theme.icon.primary.color
                    )

                    Text(plugin.manifest.name)
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.92))
                        .multilineTextAlignment(.center)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
                .padding(.horizontal, 7)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .offset(y: -2)

                Text(key.uppercased())
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.92))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background(theme.shortcut.fill.color.opacity(0.92), in: Capsule())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(6)

                if stateIndicator != nil {
                    Circle()
                        .fill(stateIndicator ?? .clear)
                        .frame(width: 7, height: 7)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(8)
                }
            }
            .frame(width: LauncherKeyboardMetrics.keySize, height: LauncherKeyboardMetrics.keySize)
            .overlay {
                GeometryReader { proxy in
                    RightClickCapture { localPoint in
                        let frame = proxy.frame(in: .named(LauncherKeyboardMetrics.coordinateSpaceName))
                        edit(CGPoint(x: frame.minX + localPoint.x, y: frame.minY + localPoint.y))
                    }
                }
            }
        }
        .buttonStyle(ThemePressButtonStyle(theme: theme, reduceMotion: reduceMotion))
        .offset(y: isHovered ? theme.motion.hoverOffset : 0)
        .animation(reduceMotion ? nil : .easeOut(duration: theme.motion.duration), value: isHovered)
        .onHover { isHovered = $0 }
        .help("\(plugin.manifest.name)  \(key.uppercased())")
        .accessibilityLabel("\(plugin.manifest.name)，键位 \(key.uppercased())，右键可修改")
        .accessibilityIdentifier("feature.\(plugin.manifest.id)")
    }

    private var keySurface: some View {
        RoundedRectangle(cornerRadius: LauncherKeyboardMetrics.cornerRadius, style: .continuous)
            .fill((isHovered ? theme.card.hoverFill : theme.card.selectedFill).color)
            .overlay(
                RoundedRectangle(cornerRadius: LauncherKeyboardMetrics.cornerRadius, style: .continuous)
                    .stroke((isHovered ? theme.card.hoverBorder : theme.card.border).color, lineWidth: 1)
            )
    }

    private var stateIndicator: Color? {
        switch state {
        case .available: nil
        case .running: theme.accent.color
        case .restricted: theme.text.permission.color
        case .failed: theme.text.failure.color
        case .disabled, .unloaded: theme.text.weak.color
        }
    }

}

private struct EmptyKeyView: View {
    let key: String
    let theme: ThemeDefinition
    let edit: (CGPoint) -> Void

    var body: some View {
        Text(key.uppercased())
            .font(.system(size: 15, weight: .semibold, design: .rounded))
            .foregroundStyle(theme.shortcut.text.color.opacity(0.66))
            .frame(width: LauncherKeyboardMetrics.keySize, height: LauncherKeyboardMetrics.keySize)
            .background {
                keyShape
                    .fill(theme.card.fill.color.opacity(0.72))
            }
            .overlay(keyShape.stroke(theme.card.border.color.opacity(0.72), lineWidth: 1))
            .overlay {
                GeometryReader { proxy in
                    RightClickCapture { localPoint in
                        let frame = proxy.frame(in: .named(LauncherKeyboardMetrics.coordinateSpaceName))
                        edit(CGPoint(x: frame.minX + localPoint.x, y: frame.minY + localPoint.y))
                    }
                }
            }
            .help("右键为 \(key.uppercased()) 键分配功能")
            .accessibilityLabel("未分配键位 \(key.uppercased())，右键可设置功能")
    }

    private var keyShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: LauncherKeyboardMetrics.cornerRadius, style: .continuous)
    }
}

private enum LauncherKeyboardMetrics {
    static let keySize: CGFloat = 68
    static let horizontalSpacing: CGFloat = 9
    static let verticalSpacing: CGFloat = 10
    static let cornerRadius: CGFloat = 16
    static let editorWidth: CGFloat = 318
    static let editorPointerGap: CGFloat = 5
    static let coordinateSpaceName = "launcher-feature-keyboard"
}

struct RightClickCapture: NSViewRepresentable {
    let action: (CGPoint) -> Void

    init(action: @escaping (CGPoint) -> Void) {
        self.action = action
    }

    init(action: @escaping () -> Void) {
        self.action = { _ in action() }
    }

    func makeNSView(context: Context) -> RightClickView {
        let view = RightClickView()
        view.action = action
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ nsView: RightClickView, context: Context) {
        nsView.action = action
    }

    static func dismantleNSView(_ nsView: RightClickView, coordinator: ()) {
        nsView.stopMonitoring()
    }

    final class RightClickView: NSView {
        var action: ((CGPoint) -> Void)?
        private var eventMonitor: Any?

        override var isFlipped: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            updateEventMonitor()
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        private func updateEventMonitor() {
            if let eventMonitor {
                NSEvent.removeMonitor(eventMonitor)
                self.eventMonitor = nil
            }
            guard window != nil else { return }
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
                guard let self,
                      event.window === window,
                      bounds.contains(convert(event.locationInWindow, from: nil)) else {
                    return event
                }
                let localPoint = convert(event.locationInWindow, from: nil)
                action?(CGPoint(x: localPoint.x, y: localPoint.y))
                return nil
            }
        }

        func stopMonitoring() {
            if let eventMonitor {
                NSEvent.removeMonitor(eventMonitor)
                self.eventMonitor = nil
            }
        }
    }
}

private enum KeyboardEditorPointerEdge: Equatable {
    case top
    case bottom
}

private struct KeyboardEditorPlacement {
    let centerX: CGFloat
    let centerY: CGFloat
    let pointerEdge: KeyboardEditorPointerEdge
    let pointerOffset: CGFloat
    let scaleAnchor: UnitPoint
}

private struct KeyboardEditorCalloutShape: Shape {
    let pointerEdge: KeyboardEditorPointerEdge
    let pointerOffset: CGFloat

    func path(in rect: CGRect) -> Path {
        let pointerWidth: CGFloat = 12
        let pointerHeight: CGFloat = 8
        let cornerRadius: CGFloat = 17
        let bodyRect: CGRect

        switch pointerEdge {
        case .top:
            bodyRect = CGRect(
                x: rect.minX,
                y: rect.minY + pointerHeight,
                width: rect.width,
                height: rect.height - pointerHeight
            )
        case .bottom:
            bodyRect = CGRect(
                x: rect.minX,
                y: rect.minY,
                width: rect.width,
                height: rect.height - pointerHeight
            )
        }

        var path = Path(roundedRect: bodyRect, cornerRadius: cornerRadius)
        let centerX = rect.midX + pointerOffset
        var pointer = Path()
        switch pointerEdge {
        case .top:
            pointer.move(to: CGPoint(x: centerX, y: rect.minY))
            pointer.addLine(to: CGPoint(x: centerX - pointerWidth / 2, y: bodyRect.minY))
            pointer.addLine(to: CGPoint(x: centerX + pointerWidth / 2, y: bodyRect.minY))
        case .bottom:
            pointer.move(to: CGPoint(x: centerX, y: rect.maxY))
            pointer.addLine(to: CGPoint(x: centerX - pointerWidth / 2, y: bodyRect.maxY))
            pointer.addLine(to: CGPoint(x: centerX + pointerWidth / 2, y: bodyRect.maxY))
        }
        pointer.closeSubpath()
        path.addPath(pointer)
        return path
    }
}

struct LauncherLayoutSwitcher: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var selection: LauncherFeatureLayout
    let theme: ThemeDefinition

    var body: some View {
        HStack(spacing: 0) {
            ForEach(LauncherFeatureLayout.allCases, id: \.self) { layout in
                Button {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: theme.motion.duration)) {
                        selection = layout
                    }
                } label: {
                    Image(systemName: layout.symbolName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(selection == layout ? theme.accent.color : theme.text.weak.color)
                        .frame(width: 30, height: 26)
                        .background(
                            selection == layout ? theme.card.selectedFill.color : .clear,
                            in: layoutButtonShape
                        )
                        .frame(width: 36, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(layout.accessibilityLabel)
                .accessibilityAddTraits(selection == layout ? .isSelected : [])
                .accessibilityIdentifier("launcher.layout.\(layout.rawValue)")
            }
        }
        .background(theme.shortcut.fill.color, in: switcherShape)
        .overlay(switcherShape.stroke(theme.shortcut.border.color, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("功能区布局")
        .accessibilityIdentifier("launcher.layout.switcher")
    }

    private var switcherShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 11, style: .continuous)
    }

    private var layoutButtonShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
    }
}
