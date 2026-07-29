import AppKit
import OCRFeature
import SwiftUI
import TouchFeatureAPI

typealias OCRCopyWriter = @MainActor (_ text: String) -> Bool

typealias OCRConfigurationProvider = @MainActor () -> OCRFeatureConfiguration

private enum OCRWorkspaceMetrics {
    static let compactWindowHeight: CGFloat = 252
    static let maximumWindowHeight: CGFloat = 486

    // 紧凑窗口：标题 40 + 预览 104 + 间距 15 + 编辑区 49
    // + 操作栏 32 + 底部留白 12 = 252pt。
    static let editorMinimumHeight: CGFloat = 49
    static let nonEditorWindowHeight = compactWindowHeight - editorMinimumHeight
    static let editorMaximumHeight = maximumWindowHeight - nonEditorWindowHeight
    static let editorHorizontalPadding: CGFloat = 14
    static let editorVerticalPadding: CGFloat = 2
}

@MainActor
final class OCRPanelController: NSObject, NSWindowDelegate, FeaturePanelSessionController {
    // 参考图是 Retina 2× 截图：约 780 × 503 像素，对应 390 × 252 点。
    private static let defaultWindowSize = NSSize(
        width: 390,
        height: OCRWorkspaceMetrics.compactWindowHeight
    )
    private static let minimumWindowSize = NSSize(width: 360, height: 240)

    private let panel: OCRPanel
    private let model: OCRWorkspaceModel
    private let screenshotCoordinator: any WorkspaceTextCapturing
    private let onTranslate: (TextTranslationRequest) -> Void
    private let onPresented: () -> Void
    private let onClose: () -> Void
    private var isPinned = false

    init(
        screenshotCoordinator: any WorkspaceTextCapturing,
        themeStore: ThemeStore,
        configurationProvider: @escaping OCRConfigurationProvider = { .init() },
        copyWriter: @escaping OCRCopyWriter = OCRPanelController.writeToSystemPasteboard,
        onTranslate: @escaping (TextTranslationRequest) -> Void,
        onPresented: @escaping () -> Void = {},
        onClose: @escaping () -> Void
    ) {
        self.screenshotCoordinator = screenshotCoordinator
        self.onTranslate = onTranslate
        self.onPresented = onPresented
        self.onClose = onClose
        model = OCRWorkspaceModel(
            configurationProvider: configurationProvider,
            copyWriter: copyWriter
        )
        panel = OCRPanel(
            contentRect: NSRect(origin: .zero, size: Self.defaultWindowSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        panel.title = "文字识别"
        panel.identifier = NSUserInterfaceItemIdentifier("ocr.window")
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = false
        panel.level = .floating
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.minSize = Self.minimumWindowSize

        let hostingView = NSHostingView(
            rootView: OCRWorkspaceView(
                model: model,
                onCapture: { [weak self] in self?.captureText() },
                onTranslate: { [weak self] in self?.translateText() },
                onOpenSettings: { [weak self] in self?.openSettings() },
                onPinChange: { [weak self] isPinned in self?.setPinned(isPinned) },
                onPreferredHeightChange: { [weak self] height in
                    self?.resizePanel(toPreferredHeight: height)
                }
            )
            .environmentObject(themeStore)
        )
        hostingView.sizingOptions = []
        panel.contentView = hostingView
        // TextEditor 会提供较大的理想尺寸；挂载后重新锁定参考图的点尺寸。
        panel.setFrame(
            NSRect(origin: panel.frame.origin, size: Self.defaultWindowSize),
            display: false
        )
        // 标题与右侧动作和原生交通灯位于同一标题栏高度。拖动层只覆盖中间
        // 的标题/空白区域，不能遮挡左侧交通灯或右侧设置、置顶按钮。
        installWindowTopDragRegion(
            in: panel,
            height: 40,
            leadingInset: 70,
            trailingInset: 80
        )
    }

    func show() {
        captureInitialText()
    }

    func show(result: ScreenTextCaptureResult) {
        model.apply(result)
        presentPanel()
    }

    var sessionWindow: NSWindow { panel }
    var remainsVisibleWhenApplicationIsInactive: Bool { isPinned }

    var isPanelVisible: Bool { panel.isVisible }

    var recognizedTextForTesting: String { model.text }
    var previewImageDataForTesting: Data? { model.previewImageData }
    var windowSizeForTesting: NSSize { panel.frame.size }
    var copyConfirmationForTesting: String? { model.copyConfirmation }

    func applyResultForTesting(_ result: ScreenTextCaptureResult) {
        model.apply(result)
    }

    func copyRecognizedTextForTesting() {
        model.copy()
    }

    func windowWillClose(_ notification: Notification) {
        screenshotCoordinator.cancelWorkspaceTextCapture()
        model.prepareForClose()
        clearPinnedState()
        onClose()
    }

    func windowDidResignKey(_ notification: Notification) {
        dismissFeaturePanelAfterResigningKey(panel, keepsVisible: isPinned)
    }

    private func presentPanel() {
        cancelFeaturePanelDismissal(panel)
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        onPresented()
    }

    private func captureInitialText() {
        Task { [weak self] in
            guard let self else { return }
            do {
                model.apply(try await screenshotCoordinator.captureTextForWorkspace())
                presentPanel()
            } catch {
                model.captureFailed(error)
                onClose()
            }
        }
    }

    private func captureText() {
        panel.orderOut(nil)
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await screenshotCoordinator.captureTextForWorkspace()
                model.apply(result)
            } catch {
                model.captureFailed(error)
            }
            presentPanel()
        }
    }

    private func translateText() {
        guard let request = model.translationRequest else { return }
        panel.orderOut(nil)
        onTranslate(request)
    }

    private func openSettings() {
        NotificationCenter.default.post(
            name: .openTouchSettings,
            object: TouchSettingsDestination(
                section: .featureArea,
                featureID: OCRFeaturePlugin.id
            )
        )
    }

    private func setPinned(_ isPinned: Bool) {
        self.isPinned = isPinned
        panel.isFloatingPanel = isPinned
        panel.level = isPinned ? .statusBar : .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = isPinned
            ? [.canJoinAllSpaces, .fullScreenAuxiliary]
            : []
        panel.makeKeyAndOrderFront(nil)
    }

    private func clearPinnedState() {
        isPinned = false
        panel.isFloatingPanel = false
        panel.level = .floating
        panel.collectionBehavior = []
    }

    private func resizePanel(toPreferredHeight preferredHeight: CGFloat) {
        let compactHeight = Self.defaultWindowSize.height
        let visibleFrame = (panel.screen ?? NSScreen.main)?.visibleFrame
        let screenMaximumHeight = visibleFrame.map {
            max(compactHeight, $0.height - 32)
        } ?? OCRWorkspaceMetrics.maximumWindowHeight
        let maximumHeight = min(
            OCRWorkspaceMetrics.maximumWindowHeight,
            screenMaximumHeight
        )
        let targetHeight = min(max(preferredHeight, compactHeight), maximumHeight)
        guard abs(panel.frame.height - targetHeight) > 0.5 else { return }

        // 与截图翻译保持一致：标题栏位置优先不动，内容向下展开；只有碰到
        // 屏幕可用边界时才整体回收，避免 486pt 窗口被 Dock 遮挡。
        let currentFrame = panel.frame
        var targetFrame = NSRect(
            x: currentFrame.minX,
            y: currentFrame.maxY - targetHeight,
            width: currentFrame.width,
            height: targetHeight
        )
        if let visibleFrame {
            let safeFrame = visibleFrame.insetBy(dx: 16, dy: 16)
            if targetFrame.minY < safeFrame.minY {
                targetFrame.origin.y = safeFrame.minY
            }
            if targetFrame.maxY > safeFrame.maxY {
                targetFrame.origin.y = safeFrame.maxY - targetHeight
            }
        }
        panel.setFrame(targetFrame, display: true, animate: false)
    }

    static func writeToSystemPasteboard(_ text: String) -> Bool {
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(text, forType: .string)
    }
}

private final class OCRPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
private final class OCRWorkspaceModel: ObservableObject {
    @Published var text = ""
    @Published private(set) var previewImageData: Data?
    @Published private(set) var recognizedLanguageCode: String?
    @Published private(set) var copyConfirmation: String?
    @Published private(set) var emptyMessage = "框选屏幕区域后，识别内容会显示在这里"

    private let configurationProvider: OCRConfigurationProvider
    private let copyWriter: OCRCopyWriter
    private var copyFeedbackTask: Task<Void, Never>?

    init(
        configurationProvider: @escaping OCRConfigurationProvider,
        copyWriter: @escaping OCRCopyWriter
    ) {
        self.configurationProvider = configurationProvider
        self.copyWriter = copyWriter
    }

    var hasText: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var translationRequest: TextTranslationRequest? {
        let source = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return nil }
        return .init(
            text: source,
            source: .ocrWorkspace,
            recognizedLanguageCode: recognizedLanguageCode
        )
    }

    func apply(_ result: ScreenTextCaptureResult) {
        text = result.text
        previewImageData = result.previewImageData
        recognizedLanguageCode = result.recognizedLanguageCode
        emptyMessage = "框选屏幕区域后，识别内容会显示在这里"
        hideCopyConfirmation()

        let configuration = configurationProvider()
        if configuration.automaticallyCopiesRecognizedText, hasText, copyWriter(text) {
            showCopyConfirmation()
        }
    }

    func captureFailed(_ error: Error) {
        emptyMessage = error.localizedDescription
    }

    func copy() {
        guard hasText, copyWriter(text) else { return }
        showCopyConfirmation()
    }

    func clear() {
        text = ""
        recognizedLanguageCode = nil
        emptyMessage = "识别内容已清空"
        hideCopyConfirmation()
    }

    func prepareForClose() {
        copyFeedbackTask?.cancel()
        copyFeedbackTask = nil
        copyConfirmation = nil
        previewImageData = nil
        text = ""
        recognizedLanguageCode = nil
    }

    private func showCopyConfirmation() {
        copyFeedbackTask?.cancel()
        copyConfirmation = "拷贝成功"
        copyFeedbackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled else { return }
            self?.copyConfirmation = nil
        }
    }

    private func hideCopyConfirmation() {
        copyFeedbackTask?.cancel()
        copyFeedbackTask = nil
        copyConfirmation = nil
    }
}

private struct OCRWorkspaceView: View {
    @ObservedObject var model: OCRWorkspaceModel
    let onCapture: () -> Void
    let onTranslate: () -> Void
    let onOpenSettings: () -> Void
    let onPinChange: (Bool) -> Void
    let onPreferredHeightChange: (CGFloat) -> Void

    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var isPinned = false
    @State private var naturalTextHeight = OCRWorkspaceMetrics.editorMinimumHeight

    private var theme: ThemeDefinition {
        ThemeRegistry.shared.definition(for: themeStore.theme)
    }

    private var secondaryControlOpacity: Double {
        theme.id == .graphite ? 0.74 : 1
    }

    private var actionControlOpacity: Double {
        theme.id == .graphite ? 0.86 : 1
    }

    private var editorHeight: CGFloat {
        min(
            max(ceil(naturalTextHeight), OCRWorkspaceMetrics.editorMinimumHeight),
            OCRWorkspaceMetrics.editorMaximumHeight
        )
    }

    private var preferredWindowHeight: CGFloat {
        OCRWorkspaceMetrics.nonEditorWindowHeight + editorHeight
    }

    private var allowsEditorScrolling: Bool {
        naturalTextHeight > OCRWorkspaceMetrics.editorMaximumHeight + 0.5
    }

    var body: some View {
        ZStack(alignment: .top) {
            TextWorkflowWorkspaceBackground(
                theme: theme,
                reduceTransparency: reduceTransparency,
                themeColorOpacity: themeStore.themeColorOpacity
            )

            VStack(spacing: 0) {
                header
                workspace
            }

            if model.copyConfirmation != nil {
                OCRCopyConfirmationToast(theme: theme)
                    .padding(.top, 15.5)
                    .accessibilityIdentifier("ocr.copy-toast")
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .scale(scale: 0.94, anchor: .top).combined(with: .opacity)
                    )
                    .zIndex(20)
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .preferredColorScheme(theme.preferredColorScheme)
        .tint(theme.interactiveAccent.color)
        .animation(
            reduceMotion ? nil : .easeOut(duration: theme.motion.duration),
            value: model.copyConfirmation
        )
        .onAppear {
            onPreferredHeightChange(preferredWindowHeight)
        }
        .onChange(of: preferredWindowHeight) { _, height in
            onPreferredHeightChange(height)
        }
    }

    private var header: some View {
        HStack(spacing: 5.5) {
            Text("文字识别")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(theme.text.primary.color)
                .accessibilityLabel("文字识别")
                .accessibilityIdentifier("ocr.title")

            Spacer(minLength: 12)

            TextWorkspaceToolbarButton(
                assetName: "MaterialSettings",
                tooltip: "文字识别设置",
                accessibilityLabel: "打开文字识别设置",
                theme: theme,
                size: 28,
                iconSize: 17,
                action: onOpenSettings
            )
            .accessibilityIdentifier("ocr.settings")
            .opacity(secondaryControlOpacity)

            TextWorkspaceToolbarButton(
                assetName: "MaterialPushPin",
                tooltip: isPinned ? "取消置顶" : "置顶窗口",
                accessibilityLabel: isPinned ? "取消置顶" : "置顶文字识别窗口",
                theme: theme,
                isSelected: isPinned,
                size: 28,
                iconSize: 17,
                action: togglePinned
            )
            .accessibilityIdentifier("ocr.pin")
            .accessibilityValue(isPinned ? "已置顶" : "未置顶")
            .opacity(isPinned ? 1 : secondaryControlOpacity)
        }
        .padding(.leading, 76)
        .padding(.trailing, 10.5)
        .frame(height: 40)
    }

    private var workspace: some View {
        VStack(spacing: 0) {
            preview
                .frame(height: 104)

            Color.clear.frame(height: 15)

            editor
                .frame(height: editorHeight)

            actionToolbar
                .frame(height: 32)
                .padding(.bottom, 12)
        }
        .frame(maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ocr.canvas")
    }

    @ViewBuilder
    private var preview: some View {
        if let data = model.previewImageData,
           let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(maxWidth: 247, maxHeight: 104)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .accessibilityLabel("本次框选截图")
                .accessibilityIdentifier("ocr.preview")
        } else {
            VStack(spacing: 6) {
                Image(systemName: "viewfinder")
                    .font(.system(size: 18, weight: .medium))
                Text("等待框选截图")
                    .font(.system(size: 10.5, weight: .medium))
            }
            .foregroundStyle(theme.text.weak.color)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("ocr.preview-empty-state")
        }
    }

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            OCRTextView(
                text: $model.text,
                textColor: theme.text.primary.nsColor,
                insertionPointColor: theme.interactiveAccent.nsColor,
                allowsVerticalScrolling: allowsEditorScrolling,
                onContentHeightChange: updateTextContentHeight
            )
            .padding(.horizontal, OCRWorkspaceMetrics.editorHorizontalPadding)
            .padding(.vertical, OCRWorkspaceMetrics.editorVerticalPadding)

            if !model.hasText {
                Text(model.emptyMessage)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(theme.text.weak.color)
                    .padding(.horizontal, 17)
                    .padding(.top, 7)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("ocr.empty-state")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ocr.text-section")
    }

    private func updateTextContentHeight(_ height: CGFloat) {
        let heightIncludingOuterPadding = height
            + OCRWorkspaceMetrics.editorVerticalPadding * 2
        guard abs(naturalTextHeight - heightIncludingOuterPadding) > 0.5 else { return }
        naturalTextHeight = heightIncludingOuterPadding
    }

    private var actionToolbar: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 8)

            TextWorkspaceToolbarButton(
                assetName: "MaterialTranslate",
                tooltip: "翻译文字",
                accessibilityLabel: "翻译识别文字",
                theme: theme,
                usesPrimaryForeground: theme.id == .graphite,
                size: 28,
                iconSize: 17,
                action: onTranslate
            )
            .accessibilityIdentifier("ocr.translate")
            .disabled(model.translationRequest == nil)
            .opacity(model.translationRequest == nil ? 0.36 : actionControlOpacity)

            TextWorkspaceToolbarButton(
                assetName: "MaterialCleaningServices",
                tooltip: "清空文字",
                accessibilityLabel: "清空识别文字",
                theme: theme,
                usesPrimaryForeground: theme.id == .graphite,
                size: 28,
                iconSize: 17,
                action: model.clear
            )
            .accessibilityIdentifier("ocr.clear")
            .disabled(!model.hasText)
            .opacity(model.hasText ? actionControlOpacity : 0.36)

            TextWorkspaceToolbarButton(
                assetName: "MaterialRefresh",
                tooltip: "重新框选截图",
                accessibilityLabel: "重新框选截图并识别文字",
                theme: theme,
                usesPrimaryForeground: theme.id == .graphite,
                size: 28,
                iconSize: 17,
                action: onCapture
            )
            .accessibilityIdentifier("ocr.capture")
            .opacity(actionControlOpacity)

            OCRCopyButton(
                isEnabled: model.hasText,
                theme: theme,
                action: model.copy
            )
            .padding(.leading, 2)
            .accessibilityIdentifier("ocr.copy")
        }
        .padding(.horizontal, 16)
    }

    private func togglePinned() {
        isPinned.toggle()
        onPinChange(isPinned)
    }
}

/// 文字识别编辑区保留 AppKit 原生文本 responder chain，因此 Command-C/V/A、
/// 撤销、选择和输入法行为不受影响。它同时上报排版后的自然高度：普通长文本先
/// 拉高窗口，只有编辑区达到 283pt（窗口 486pt）且内容仍溢出时才创建滚动条。
private struct OCRTextView: NSViewRepresentable {
    @Binding var text: String
    let textColor: NSColor
    let insertionPointColor: NSColor
    let allowsVerticalScrolling: Bool
    let onContentHeightChange: (CGFloat) -> Void

    private let accessibilityIdentifier = "ocr.text-editor"

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.contentView.drawsBackground = false
        // 短文本首帧明确不创建系统 scroller，避免右侧闪出空滑块。
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.postsFrameChangedNotifications = true
        scrollView.verticalScrollElasticity = .automatic
        scrollView.horizontalScrollElasticity = .none

        let textView = NSTextView(frame: .zero)
        textView.delegate = context.coordinator
        textView.string = text
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        // 14pt 外边距 + 3pt 文本内缩与原 TextEditor 的 17pt 起始基线一致。
        textView.textContainerInset = NSSize(width: 3, height: 4)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: max(1, scrollView.contentSize.width - 6),
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.minSize = NSSize(width: 0, height: scrollView.contentSize.height)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.setAccessibilityLabel("识别文字编辑区")
        textView.setAccessibilityIdentifier(accessibilityIdentifier)

        scrollView.documentView = textView
        context.coordinator.attach(scrollView: scrollView, textView: textView)
        applyAppearance(to: textView)
        context.coordinator.scheduleLayoutUpdate()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        context.coordinator.parent = self
        textView.setAccessibilityLabel("识别文字编辑区")
        textView.setAccessibilityIdentifier(accessibilityIdentifier)

        if textView.string != text {
            let selectedRange = textView.selectedRange()
            textView.string = text
            let safeLocation = min(selectedRange.location, text.utf16.count)
            textView.setSelectedRange(NSRange(location: safeLocation, length: 0))
        }

        applyAppearance(to: textView)
        context.coordinator.scheduleLayoutUpdate()
    }

    private func applyAppearance(to textView: NSTextView) {
        let font = NSFont(name: "Helvetica Neue", size: 14)
            ?? .systemFont(ofSize: 14, weight: .regular)
        textView.font = font
        textView.textColor = textColor
        textView.insertionPointColor = insertionPointColor
        textView.selectedTextAttributes = [
            .backgroundColor: insertionPointColor.withAlphaComponent(0.24),
            .foregroundColor: textColor
        ]

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byWordWrapping
        textView.defaultParagraphStyle = paragraphStyle
        textView.typingAttributes = [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: paragraphStyle
        ]
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: OCRTextView
        private weak var scrollView: NSScrollView?
        private weak var textView: NSTextView?
        private var pendingLayoutUpdate = false
        private var lastReportedContentHeight: CGFloat?

        init(parent: OCRTextView) {
            self.parent = parent
        }

        func attach(scrollView: NSScrollView, textView: NSTextView) {
            self.scrollView = scrollView
            self.textView = textView
            scrollView.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(viewBoundsDidChange),
                name: NSView.boundsDidChangeNotification,
                object: scrollView.contentView
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(viewFrameDidChange),
                name: NSView.frameDidChangeNotification,
                object: scrollView
            )
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            if parent.text != textView.string {
                parent.text = textView.string
            }
            scheduleLayoutUpdate()
        }

        func scheduleLayoutUpdate() {
            guard !pendingLayoutUpdate else { return }
            pendingLayoutUpdate = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.pendingLayoutUpdate = false
                self.updateDocumentLayout()
            }
        }

        @objc private func viewBoundsDidChange() {
            scheduleLayoutUpdate()
        }

        @objc private func viewFrameDidChange() {
            scheduleLayoutUpdate()
        }

        private func updateDocumentLayout() {
            guard let scrollView, let textView, let textContainer = textView.textContainer,
                  let layoutManager = textView.layoutManager else { return }

            scrollView.layoutSubtreeIfNeeded()
            let viewportSize = scrollView.contentView.bounds.size
            guard viewportSize.width > 0, viewportSize.height > 0 else {
                scheduleLayoutUpdate()
                return
            }

            let usableWidth = max(
                1,
                viewportSize.width - textView.textContainerInset.width * 2
            )
            textContainer.containerSize = NSSize(
                width: usableWidth,
                height: CGFloat.greatestFiniteMagnitude
            )
            layoutManager.ensureLayout(for: textContainer)
            let usedRect = layoutManager.usedRect(for: textContainer)
            let naturalHeight = ceil(
                usedRect.height + textView.textContainerInset.height * 2 + 1
            )
            if lastReportedContentHeight.map({ abs($0 - naturalHeight) > 0.5 }) ?? true {
                lastReportedContentHeight = naturalHeight
                parent.onContentHeightChange(naturalHeight)
            }

            let desiredHeight = max(viewportSize.height, naturalHeight)
            let desiredSize = NSSize(width: viewportSize.width, height: desiredHeight)
            if textView.frame.size != desiredSize {
                textView.setFrameSize(desiredSize)
            }

            // 窗口会先跟随普通长文本增高。只有自然高度已经超过 486pt
            // 窗口对应的编辑区上限后，才允许创建系统滚动条；否则在首帧
            // 较矮的 viewport 中提前创建 scroller，会留下右侧常驻的小方块。
            let hasOverflow = parent.allowsVerticalScrolling
                && naturalHeight > viewportSize.height + 0.5
            if hasOverflow {
                if !scrollView.hasVerticalScroller {
                    scrollView.hasVerticalScroller = true
                }
                if let verticalScroller = scrollView.verticalScroller {
                    verticalScroller.setAccessibilityIdentifier("ocr.text-editor.scrollbar")
                    verticalScroller.setAccessibilityLabel("识别文字滚动条")
                    verticalScroller.isHidden = false
                }
            } else {
                scrollView.verticalScroller?.isHidden = true
                if scrollView.hasVerticalScroller {
                    scrollView.hasVerticalScroller = false
                }
            }
            scrollView.horizontalScroller?.isHidden = true
        }
    }
}

private struct OCRCopyConfirmationToast: View {
    let theme: ThemeDefinition

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(Color.black.opacity(0.9))
                .frame(width: 19, height: 19)
                .background {
                    Circle()
                        .fill(theme.text.success.color)
                        .brightness(theme.id == .graphite ? -0.025 : 0)
                }

            Text("拷贝成功")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.text.success.color)
        }
        .offset(x: -4, y: -0.5)
        .frame(width: 122, height: 40)
        .background(Color.black, in: Capsule())
        .shadow(color: .black.opacity(0.24), radius: 8, y: 3)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("拷贝成功")
    }
}

private struct OCRCopyButton: View {
    let isEnabled: Bool
    let theme: ThemeDefinition
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Text("拷贝")
                    .font(.system(size: 11.5, weight: .semibold))
                Image("MaterialArrowDropDown")
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .frame(width: 14, height: 9)
            }
            .foregroundStyle(theme.text.primary.color.opacity(foregroundOpacity))
            .frame(width: 56, height: 28)
            .background(
                backgroundColor,
                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(ThemePressButtonStyle(theme: theme, reduceMotion: reduceMotion))
        .disabled(!isEnabled)
        .onHover { isHovering = $0 }
        .animation(
            reduceMotion ? nil : .easeOut(duration: theme.motion.duration),
            value: isHovering
        )
        .help("复制识别文字")
        .accessibilityLabel("复制识别文字")
    }

    private var backgroundColor: Color {
        if !isEnabled {
            return theme.shortcut.fill.color.opacity(theme.id == .graphite ? 0.34 : 0.52)
        }
        if theme.id == .graphite {
            return isHovering
                ? theme.card.hoverFill.color.opacity(0.72)
                : theme.shortcut.fill.color.opacity(0.46)
        }
        return isHovering
            ? theme.card.hoverFill.color.opacity(0.94)
            : theme.shortcut.fill.color.opacity(0.84)
    }

    private var foregroundOpacity: Double {
        guard isEnabled else { return theme.id == .graphite ? 0.30 : 0.42 }
        guard theme.id == .graphite else { return 0.86 }
        return isHovering ? 0.82 : 0.53
    }
}

/// 固定的 OCR 界面验收图片，不读取屏幕，也不触碰系统剪贴板。
@MainActor
enum OCRFixturePreview {
    static func makeImageData() -> Data {
        // 参考截图中的选区来自 1× 内容并显示在 Retina 窗口里，因此这里按
        // 247 × 104 的逻辑尺寸生成夹具，让 SwiftUI 的高质量插值自然得到同样
        // 的轻微柔化效果；生产截图仍按原始分辨率展示，不会被主动模糊。
        let image = NSImage(size: NSSize(width: 247, height: 104), flipped: false) { bounds in
            NSColor(srgbRed: 52 / 255, green: 52 / 255, blue: 66 / 255, alpha: 1).setFill()
            bounds.fill()

            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 28, weight: .regular),
                .foregroundColor: NSColor(
                    srgbRed: 205 / 255,
                    green: 214 / 255,
                    blue: 244 / 255,
                    alpha: 1
                )
            ]
            ("pple Root CA" as NSString).draw(
                at: NSPoint(x: -2, y: 35),
                withAttributes: attributes
            )
            ("ier=8YLX494879" as NSString).draw(
                at: NSPoint(x: -2, y: -4.5),
                withAttributes: attributes
            )
            return true
        }
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return Data()
        }
        return pngData
    }
}
