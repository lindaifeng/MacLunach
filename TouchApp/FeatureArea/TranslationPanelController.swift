import AppKit
import NaturalLanguage
import Security
import SwiftUI
import TouchFeatureAPI
@preconcurrency import Translation
import TranslationFeature

private enum TranslationWorkspaceMetrics {
    static let compactWindowHeight: CGFloat = 232
    static let sourceTextMinimumHeight: CGFloat = 40
    static let targetTextMinimumHeight: CGFloat = 26
    static let textMaximumHeight: CGFloat = 160
    static let sourceFooterHeight: CGFloat = 24
    static let targetHeaderHeight: CGFloat = 24
    static let languagePackPromptHeight: CGFloat = 32
    static let languagePackPromptTopSpacing: CGFloat = 2
    static let languagePackContentHeight = languagePackPromptHeight
        + languagePackPromptTopSpacing

    // 顶部安全区 28 + 标题 32 + 原文复制栏 24 + 语言栏上间距 5
    // + 语言栏 40 + 译文区上间距 6 + 提供方栏 24 + 底部留白 7。
    static let nonTextWindowHeight: CGFloat = 166
    static let maximumWindowHeight = nonTextWindowHeight + textMaximumHeight * 2
}

@MainActor
final class TranslationPanelController: NSObject, NSWindowDelegate {
    // 参考图来自 Retina 2× 截图：1120 × 464 像素对应 AppKit 的
    // 560 × 232 点。窗口尺寸必须使用点，否则在截图中会被放大为两倍。
    private static let defaultWindowSize = NSSize(
        width: 560,
        height: TranslationWorkspaceMetrics.compactWindowHeight
    )
    private static let minimumWindowSize = NSSize(
        width: 520,
        height: TranslationWorkspaceMetrics.compactWindowHeight
    )

    private let panel: TranslationPanel
    private let model = TranslationWorkspaceModel()
    private let screenshotCoordinator: any WorkspaceTextCapturing
    private let onClose: () -> Void
    private var isPinned = false

    init(
        screenshotCoordinator: any WorkspaceTextCapturing,
        themeStore: ThemeStore,
        onClose: @escaping () -> Void
    ) {
        self.screenshotCoordinator = screenshotCoordinator
        self.onClose = onClose
        panel = TranslationPanel(
            contentRect: NSRect(origin: .zero, size: Self.defaultWindowSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        panel.title = "截图翻译"
        panel.identifier = NSUserInterfaceItemIdentifier("translation.window")
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = false
        panel.level = .normal
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.minSize = Self.minimumWindowSize
        let hostingView = NSHostingView(
            rootView: TranslationWorkspaceView(
                model: model,
                onCapture: { [weak self] in self?.captureText() },
                onPinChange: { [weak self] isPinned in self?.setPinned(isPinned) },
                onPreferredHeightChange: { [weak self] height in
                    self?.resizePanel(toPreferredHeight: height)
                }
            )
            .environmentObject(themeStore)
        )
        hostingView.sizingOptions = []
        panel.contentView = hostingView
        // NSHostingView 会先采用 SwiftUI 的理想高度；必须在挂载根视图后重新锁定
        // 初始外框，才能保证参考布局要求的 560 × 232 点（Retina 2× 下为
        // 1120 × 464 像素），而不是被文本编辑器撑高。
        panel.setFrame(
            NSRect(origin: panel.frame.origin, size: Self.defaultWindowSize),
            display: false
        )
        installWindowTopDragRegion(in: panel)
    }

    func show(request: TextTranslationRequest? = nil) {
        if let request {
            model.accept(request)
            model.beginTranslation()
            presentPanel()
            return
        }

        captureInitialText()
    }

    func showFixture(
        sourceText: String,
        translatedText: String,
        recognizedLanguageCode: String = "zh-Hans"
    ) {
        model.accept(.init(
            text: sourceText,
            source: .screenCapture,
            recognizedLanguageCode: recognizedLanguageCode
        ))
        model.finishTranslation(translatedText)
        presentPanel()
    }

    func showLanguagePackFixture(
        sourceText: String,
        recognizedLanguageCode: String = "zh-Hans"
    ) {
        model.accept(.init(
            text: sourceText,
            source: .screenCapture,
            recognizedLanguageCode: recognizedLanguageCode
        ))
        model.showLanguagePackPromptFixture()
        presentPanel()
    }

    var isPanelVisible: Bool { panel.isVisible }

    func windowWillClose(_ notification: Notification) {
        screenshotCoordinator.cancelWorkspaceTextCapture()
        onClose()
    }
    func windowDidResignKey(_ notification: Notification) {
        dismissFeaturePanelAfterResigningKey(panel, keepsVisible: isPinned)
    }

    private func presentPanel() {
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func captureInitialText() {
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await screenshotCoordinator.captureTextForWorkspace()
                model.accept(.init(
                    text: result.text,
                    source: .screenCapture,
                    recognizedLanguageCode: result.recognizedLanguageCode
                ))
                model.beginTranslation()
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
                model.accept(.init(text: result.text, source: .screenCapture, recognizedLanguageCode: result.recognizedLanguageCode))
                model.beginTranslation()
            } catch {
                model.captureFailed(error)
            }
            presentPanel()
        }
    }

    private func setPinned(_ isPinned: Bool) {
        self.isPinned = isPinned
        panel.isFloatingPanel = isPinned
        panel.level = isPinned ? .statusBar : .normal
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = isPinned
            ? [.canJoinAllSpaces, .fullScreenAuxiliary]
            : []
        panel.makeKeyAndOrderFront(nil)
    }

    private func resizePanel(toPreferredHeight preferredHeight: CGFloat) {
        let compactHeight = Self.defaultWindowSize.height
        let visibleFrame = (panel.screen ?? NSScreen.main)?.visibleFrame
        let screenMaximumHeight = visibleFrame.map {
            max(compactHeight, $0.height - 32)
        } ?? TranslationWorkspaceMetrics.maximumWindowHeight
        let maximumHeight = min(
            TranslationWorkspaceMetrics.maximumWindowHeight,
            screenMaximumHeight
        )
        let targetHeight = min(max(preferredHeight, compactHeight), maximumHeight)
        guard abs(panel.frame.height - targetHeight) > 0.5 else { return }

        // 保持标题栏位置稳定，优先向下展开；靠近屏幕边缘时再把窗口整体
        // 向上收进可用区域，避免长文本把窗口底部推到 Dock 后面。
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
}

private final class TranslationPanel: NSPanel { override var canBecomeKey: Bool { true } }

private struct TranslationSessionRequest: Equatable, Sendable {
    let id: UUID
    let text: String
    let sourceLanguageCode: String?
    let targetLanguageCode: String
    let allowsLanguagePackDownload: Bool
}

private struct TranslationLanguagePackPrompt: Equatable, Sendable {
    let title: String
    let message: String
    let actionTitle: String
}

@MainActor
private final class TranslationWorkspaceModel: ObservableObject {
    enum StatusKind {
        case ready
        case loading
        case success
        case error
        case languagePack

        var accessibilityIdentifier: String {
            switch self {
            case .ready: "translation.status.ready"
            case .loading: "translation.status.loading"
            case .success: "translation.status.success"
            case .error: "translation.status.error"
            case .languagePack: "translation.status.language-pack"
            }
        }
    }

    enum SourceChoice: String, CaseIterable, Identifiable { case automatic = "自动识别"; case chinese = "中文"; case english = "English"; case japanese = "日本語"; var id: String { rawValue }
        var languageCode: String? { switch self { case .automatic: nil; case .chinese: "zh-Hans"; case .english: "en"; case .japanese: "ja" } }
    }
    enum TargetChoice: String, CaseIterable, Identifiable { case english = "English"; case chinese = "中文"; case japanese = "日本語"; case korean = "한국어"; case french = "Français"; case german = "Deutsch"; case spanish = "Español"; var id: String { rawValue }
        var languageCode: String { switch self { case .english: "en"; case .chinese: "zh-Hans"; case .japanese: "ja"; case .korean: "ko"; case .french: "fr"; case .german: "de"; case .spanish: "es" } }
    }

    @Published var sourceText = ""
    @Published private(set) var translatedText = ""
    @Published var sourceChoice: SourceChoice = .automatic
    @Published var targetChoice: TargetChoice = .english
    @Published private(set) var isTranslating = false
    @Published private(set) var statusMessage: String?
    @Published private(set) var statusKind: StatusKind = .ready
    @Published private(set) var sessionRequest: TranslationSessionRequest?
    @Published private(set) var recognizedLanguageCode: String?
    @Published private(set) var languagePackPrompt: TranslationLanguagePackPrompt?
    @Published private(set) var copyConfirmation: String?
    private var copyFeedbackTask: Task<Void, Never>?
    /// `LanguageAvailability.Status.supported` 表示语言对受支持，但当前设备还没有
    /// 安装对应的本机语言包。把请求暂存起来，而不是继续挂在 translationTask 上，
    /// 可以让提示状态稳定显示，同时保证点击“下载语言包”后才重新创建系统会话。
    private var pendingLanguagePackRequest: TranslationSessionRequest?

    var isSupportedSystem: Bool { ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 15 }
    var hasSourceText: Bool { !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var hasTranslatedText: Bool { !translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var canBeginTranslation: Bool {
        isSupportedSystem
            && !isTranslating
            && hasSourceText
            && resolvedSourceLanguageCode != targetChoice.languageCode
    }

    var targetEmptyMessage: String {
        if isTranslating {
            return statusMessage ?? "正在使用系统语言包翻译，请稍候…"
        }
        if languagePackPrompt != nil { return "确认语言包后，译文会显示在这里。" }
        if case .error = statusKind, let statusMessage { return statusMessage }
        if !isSupportedSystem { return "需要 macOS 15 才能使用系统离线翻译。" }
        if !hasSourceText { return "输入原文，或点击截图按钮框选需要翻译的文字。" }
        return "译文会在翻译完成后显示在这里。"
    }

    var sourceLanguageDisplayName: String {
        guard sourceChoice == .automatic else { return sourceChoice.rawValue }
        guard let recognizedLanguageCode else { return sourceChoice.rawValue }

        let languageName = switch normalizedLanguageCode(recognizedLanguageCode) {
        case "zh", "zh-hans": "中文简体"
        case "zh-hant": "中文繁體"
        case "en": "English"
        case "ja": "日本語"
        case "ko": "한국어"
        case "fr": "Français"
        case "de": "Deutsch"
        case "es": "Español"
        default: "自动识别"
        }
        return languageName == "自动识别" ? languageName : "自动：\(languageName)"
    }

    func accept(_ request: TextTranslationRequest) {
        sourceText = request.text
        recognizedLanguageCode = request.recognizedLanguageCode
        sourceChoice = .automatic
        if normalizedLanguageCode(request.recognizedLanguageCode) == "en" {
            targetChoice = .chinese
        } else {
            targetChoice = .english
        }
        translatedText = ""
        languagePackPrompt = nil
        copyConfirmation = nil
        pendingLanguagePackRequest = nil
        sessionRequest = nil
        isTranslating = false
        statusMessage = request.source == .ocrWorkspace
            ? "已接收文字识别校对内容"
            : "已接收截图识别文字"
        statusKind = .ready
    }

    func captureFailed(_ error: Error) {
        statusMessage = error.localizedDescription
        statusKind = .error
    }

    func beginTranslation() {
        guard isSupportedSystem else {
            statusMessage = "需要 macOS 15 才能使用系统离线翻译"
            statusKind = .error
            return
        }
        let text = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            statusMessage = "请先输入或截图识别原文"
            statusKind = .error
            return
        }
        guard let sourceLanguageCode = resolvedSourceLanguageCode ?? detectSourceLanguageCode(in: text) else {
            statusMessage = "未能识别原文语言，请在原文语言中手动选择后重试"
            statusKind = .error
            return
        }
        if sourceChoice == .automatic, recognizedLanguageCode == nil {
            recognizedLanguageCode = sourceLanguageCode
        }
        guard sourceLanguageCode != targetChoice.languageCode else {
            statusMessage = "原文和目标语言相同"
            statusKind = .error
            return
        }
        statusMessage = "正在准备系统语言包…"
        statusKind = .loading
        translatedText = ""
        isTranslating = true
        languagePackPrompt = nil
        pendingLanguagePackRequest = nil
        sessionRequest = .init(
            id: UUID(),
            text: text,
            // OCR 已经给出语言时，自动识别仍保持“自动：English”的展示，
            // 但把可靠的识别结果传给 Translation，避免短文本再次识别失败。
            sourceLanguageCode: sourceLanguageCode,
            targetLanguageCode: targetChoice.languageCode,
            allowsLanguagePackDownload: false
        )
    }

    func finishTranslation(_ text: String) {
        translatedText = text
        statusMessage = "已使用 macOS 系统离线翻译"
        statusKind = .success
        isTranslating = false
        languagePackPrompt = nil
        sessionRequest = nil
        pendingLanguagePackRequest = nil
    }

    func failTranslation(message: String) {
        statusMessage = message
        statusKind = .error
        isTranslating = false
        languagePackPrompt = nil
        sessionRequest = nil
        pendingLanguagePackRequest = nil
    }

    func requestLanguagePackDownload() {
        guard let request = sessionRequest else { return }
        showLanguagePackPrompt(
            for: request,
            title: "系统语言包未安装",
            message: "当前语言组合受支持，下载后即可使用 macOS 离线翻译。"
        )
    }

    func showLanguagePackPrompt(
        for request: TranslationSessionRequest,
        title: String,
        message: String,
        actionTitle: String = "下载语言包"
    ) {
        // 只保留不允许下载的原始请求。用户点击按钮后会重新创建一个新的
        // TranslationSession.Configuration，让系统有机会弹出并完成语言包下载。
        pendingLanguagePackRequest = request
        sessionRequest = nil
        isTranslating = false
        statusMessage = message
        statusKind = .languagePack
        languagePackPrompt = .init(title: title, message: message, actionTitle: actionTitle)
    }

    func showLanguagePackPromptFixture() {
        isTranslating = false
        pendingLanguagePackRequest = .init(
            id: UUID(),
            text: sourceText.trimmingCharacters(in: .whitespacesAndNewlines),
            sourceLanguageCode: resolvedSourceLanguageCode,
            targetLanguageCode: targetChoice.languageCode,
            allowsLanguagePackDownload: false
        )
        sessionRequest = nil
        statusMessage = "当前语言组合受支持，但本机语言包尚未安装"
        statusKind = .languagePack
        languagePackPrompt = .init(
            title: "系统语言包未安装",
            message: "当前语言组合受支持，下载后即可使用 macOS 离线翻译。",
            actionTitle: "下载语言包"
        )
    }

    /// `prepareTranslation()` 在语言包已进入系统后台下载时会直接返回，
    /// 但并不表示语言包已经可翻译。此时不能继续挂起 `translate`，否则面板
    /// 会只显示“正在下载”且没有恢复入口。
    func showLanguagePackDownloading(for request: TranslationSessionRequest) {
        showLanguagePackPrompt(
            for: request,
            title: "语言包尚未就绪",
            message: "macOS 仍在下载或等待下载；请检查网络后点“重新检查”。",
            actionTitle: "重新检查"
        )
    }

    func confirmLanguagePackDownload() {
        guard let request = pendingLanguagePackRequest else { return }
        pendingLanguagePackRequest = nil
        languagePackPrompt = nil
        isTranslating = true
        statusMessage = "正在等待 macOS 确认或下载语言包…"
        statusKind = .loading
        sessionRequest = .init(
            id: UUID(),
            text: request.text,
            sourceLanguageCode: request.sourceLanguageCode,
            targetLanguageCode: request.targetLanguageCode,
            allowsLanguagePackDownload: true
        )
    }

    func cancelLanguagePackDownload() {
        languagePackPrompt = nil
        isTranslating = false
        sessionRequest = nil
        pendingLanguagePackRequest = nil
        statusMessage = "已暂不下载语言包"
        statusKind = .ready
    }

    func isCurrentTranslationRequest(_ request: TranslationSessionRequest) -> Bool {
        sessionRequest?.id == request.id
    }

    func markPreparingInstalledLanguagePack() {
        isTranslating = true
        statusMessage = "正在使用已安装的系统语言包翻译…"
        statusKind = .loading
    }

    func copyTranslation() {
        copy(translatedText, successMessage: "译文已复制")
    }

    func copySource() {
        copy(sourceText, successMessage: "原文已复制")
    }

    func swapLanguages() {
        let originalLanguageCode = sourceChoice.languageCode ?? recognizedLanguageCode
        guard let originalLanguageCode,
              let swappedTarget = targetChoice(for: originalLanguageCode),
              let swappedSource = sourceChoice(for: targetChoice.languageCode) else {
            statusMessage = "尚未识别出可交换的原文语言"
            statusKind = .error
            return
        }

        sourceChoice = swappedSource
        targetChoice = swappedTarget
        if !translatedText.isEmpty {
            let previousSource = sourceText
            sourceText = translatedText
            translatedText = previousSource
        }
        statusMessage = "已交换原文与目标语言"
        statusKind = .ready
    }

    var detectedLanguageLabel: String? {
        guard sourceChoice == .automatic, let recognizedLanguageCode else { return nil }
        return switch normalizedLanguageCode(recognizedLanguageCode) {
        case "zh-hans", "zh-hant", "zh": "已识别：中文"
        case "en": "已识别：English"
        case "ja": "已识别：日本語"
        case "ko": "已识别：한국어"
        case "fr": "已识别：Français"
        case "de": "已识别：Deutsch"
        case "es": "已识别：Español"
        default: "已自动识别原文语言"
        }
    }

    private func copy(_ text: String, successMessage: String) {
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        showCopyConfirmation(successMessage)
    }

    private func showCopyConfirmation(_ message: String) {
        copyFeedbackTask?.cancel()
        copyConfirmation = message
        copyFeedbackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled else { return }
            self?.copyConfirmation = nil
        }
    }

    private func sourceChoice(for languageCode: String) -> SourceChoice? {
        switch normalizedLanguageCode(languageCode) {
        case "zh", "zh-hans", "zh-hant": .chinese
        case "en": .english
        case "ja": .japanese
        default: nil
        }
    }

    private func targetChoice(for languageCode: String) -> TargetChoice? {
        switch normalizedLanguageCode(languageCode) {
        case "zh", "zh-hans", "zh-hant": .chinese
        case "en": .english
        case "ja": .japanese
        case "ko": .korean
        case "fr": .french
        case "de": .german
        case "es": .spanish
        default: nil
        }
    }

    private func normalizedLanguageCode(_ languageCode: String?) -> String? {
        languageCode?.lowercased().replacingOccurrences(of: "_", with: "-")
    }

    /// 返回当前可以交给 Translation 的源语言代码。
    ///
    /// 自动识别并不等于完全没有语言信息：截图 OCR 通常已经返回了识别结果。
    /// 复用这个结果可以避免 `status(for:text:)` 在短句、符号或 OCR 噪声较多时
    /// 抛出 `unableToIdentifyLanguage`，同时仍然保留界面上的自动识别语义。
    private var resolvedSourceLanguageCode: String? {
        if let explicit = sourceChoice.languageCode {
            return explicit
        }

        guard let normalized = normalizedLanguageCode(recognizedLanguageCode) else {
            return nil
        }

        return switch normalized {
        case "zh", "zh-hans", "zh-hans-cn": "zh-Hans"
        case "zh-hant", "zh-hant-tw": "zh-Hant"
        case "en", "en-us", "en-gb": "en"
        case "ja", "ja-jp": "ja"
        case "ko", "ko-kr": "ko"
        case "fr", "fr-fr": "fr"
        case "de", "de-de": "de"
        case "es", "es-es": "es"
        default: nil
        }
    }

    /// Apple Translation 对短文本的自动识别并不总能获得源语言，且没有源
    /// 语言时 `prepareTranslation()` 不会弹出语言包确认。先用本机
    /// NaturalLanguage 识别，确保“下载语言包”始终能走系统确认流程。
    private func detectSourceLanguageCode(in text: String) -> String? {
        guard let language = NLLanguageRecognizer.dominantLanguage(for: text) else {
            return nil
        }

        return switch normalizedLanguageCode(language.rawValue) {
        case "zh", "zh-hans", "zh-hans-cn": "zh-Hans"
        case "zh-hant", "zh-hant-tw": "zh-Hant"
        case "en", "en-us", "en-gb": "en"
        case "ja", "ja-jp": "ja"
        case "ko", "ko-kr": "ko"
        case "fr", "fr-fr": "fr"
        case "de", "de-de": "de"
        case "es", "es-es": "es"
        default: nil
        }
    }
}

private struct TranslationWorkspaceView: View {
    @ObservedObject var model: TranslationWorkspaceModel
    let onCapture: () -> Void
    let onPinChange: (Bool) -> Void
    let onPreferredHeightChange: (CGFloat) -> Void

    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var isPinned = false
    @State private var sourceNaturalTextHeight = TranslationWorkspaceMetrics.sourceTextMinimumHeight
    @State private var targetNaturalTextHeight = TranslationWorkspaceMetrics.targetTextMinimumHeight

    private var theme: ThemeDefinition {
        ThemeRegistry.shared.definition(for: themeStore.theme)
    }

    private var secondaryControlOpacity: Double {
        theme.id == .graphite ? 0.75 : 1
    }

    private var sourceTextHeight: CGFloat {
        adaptiveTextHeight(
            sourceNaturalTextHeight,
            minimum: TranslationWorkspaceMetrics.sourceTextMinimumHeight
        )
    }

    private var targetTextHeight: CGFloat {
        guard model.languagePackPrompt == nil else {
            return TranslationWorkspaceMetrics.languagePackContentHeight
        }
        return adaptiveTextHeight(
            targetNaturalTextHeight,
            minimum: TranslationWorkspaceMetrics.targetTextMinimumHeight
        )
    }

    private var preferredWindowHeight: CGFloat {
        TranslationWorkspaceMetrics.nonTextWindowHeight
            + sourceTextHeight
            + targetTextHeight
    }

    var body: some View {
        TranslationTaskHost(model: model) {
            ZStack {
                TextWorkflowWorkspaceBackground(
                    theme: theme,
                    reduceTransparency: reduceTransparency,
                    themeColorOpacity: themeStore.themeColorOpacity
                )

                VStack(spacing: 0) {
                    Color.clear.frame(height: 28)
                    header
                    workspace
                }

                if let confirmation = model.copyConfirmation {
                    ThemeStatusToast(
                        title: confirmation,
                        detail: "内容已写入剪贴板",
                        systemName: "checkmark",
                        theme: theme
                    )
                    .accessibilityIdentifier("translation.copy-toast")
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.92).combined(with: .opacity))
                    .zIndex(20)
                }
            }
            .ignoresSafeArea(.container, edges: .top)
            .preferredColorScheme(theme.preferredColorScheme)
            .tint(theme.accent.color)
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
            .onChange(of: model.languagePackPrompt) { _, prompt in
                if prompt != nil {
                    targetNaturalTextHeight = TranslationWorkspaceMetrics.targetTextMinimumHeight
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 7) {
            Text("截图翻译")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(theme.text.primary.color)
                .accessibilityIdentifier("translation.title")

            Spacer(minLength: 12)

            TextWorkspaceToolbarButton(
                systemName: "viewfinder",
                tooltip: "重新框选截图",
                accessibilityLabel: "重新框选截图",
                theme: theme,
                size: 28,
                action: onCapture
            )
            .accessibilityIdentifier("translation.capture")
            .opacity(secondaryControlOpacity)

            TextWorkspaceToolbarButton(
                systemName: "arrow.triangle.2.circlepath",
                tooltip: "重新翻译",
                accessibilityLabel: "重新翻译",
                theme: theme,
                size: 28,
                action: model.beginTranslation
            )
            .disabled(!model.canBeginTranslation)
            .opacity(model.canBeginTranslation ? 1 : 0.38)
            .opacity(secondaryControlOpacity)
            .accessibilityIdentifier("translation.translate")

            TextWorkspaceToolbarButton(
                systemName: isPinned ? "pin.fill" : "pin",
                tooltip: isPinned ? "取消置顶" : "置顶窗口",
                accessibilityLabel: isPinned ? "取消置顶" : "置顶截图翻译",
                theme: theme,
                isSelected: isPinned,
                size: 28,
                action: togglePinned
            )
            .accessibilityIdentifier("translation.pin")
            .accessibilityValue(isPinned ? "已置顶" : "未置顶")
            .opacity(isPinned ? 1 : secondaryControlOpacity)
        }
        .padding(.horizontal, 16)
        .frame(height: 32)
    }

    private var workspace: some View {
        VStack(spacing: 0) {
            sourceSection
                .frame(
                    height: sourceTextHeight + TranslationWorkspaceMetrics.sourceFooterHeight
                )

            languageControls
                .padding(.top, 5)

            targetSection
                .frame(
                    height: targetTextHeight + TranslationWorkspaceMetrics.targetHeaderHeight
                )
                .padding(.top, 6)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("translation.canvas")
        .padding(.horizontal, 16)
        .padding(.bottom, 7)
        .frame(maxHeight: .infinity)
        .animation(
            reduceMotion ? nil : .easeOut(duration: theme.motion.duration),
            value: model.languagePackPrompt
        )
    }

    private var sourceSection: some View {
        VStack(spacing: 0) {
            textArea(
                text: $model.sourceText,
                isEditable: true,
                textIdentifier: "translation.source-text",
                emptyMessage: "输入需要翻译的原文，或重新框选截图。",
                emptyIdentifier: "translation.source-empty-state",
                onContentHeightChange: updateSourceContentHeight
            )

            HStack(spacing: 0) {
                Spacer(minLength: 0)
                copyButton(
                    systemName: "doc.on.doc",
                    tooltip: "复制原文",
                    accessibilityLabel: "复制原文",
                    identifier: "translation.copy-source",
                    isEnabled: model.hasSourceText,
                    action: model.copySource
                )
                // 24pt 命中区保持完整；额外 2pt 只用于让图标中心与标题栏
                // 28pt 工具按钮共用右侧基线，视觉上不再忽左忽右。
                .padding(.trailing, 2)
            }
            .frame(height: 24)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("translation.source-section")
    }

    private var languageControls: some View {
        HStack(spacing: 8) {
            languagePicker(
                title: "原文语言",
                displayName: model.sourceLanguageDisplayName,
                selection: $model.sourceChoice,
                identifier: "translation.source-language"
            )

            TextWorkspaceToolbarButton(
                systemName: "arrow.left.arrow.right",
                tooltip: "交换语言",
                accessibilityLabel: "交换原文与目标语言",
                theme: theme,
                usesPrimaryForeground: true,
                size: 28,
                action: model.swapLanguages
            )
            .accessibilityIdentifier("translation.swap")

            languagePicker(
                title: "目标语言",
                displayName: model.targetChoice.rawValue,
                selection: $model.targetChoice,
                identifier: "translation.target-language"
            )
        }
        .frame(height: 40)
        .accessibilityElement(children: .contain)
    }

    private var targetSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Label("Apple 翻译", systemImage: "translate")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(theme.text.secondary.color.opacity(secondaryControlOpacity))
                    .accessibilityIdentifier("translation.provider")

                Spacer(minLength: 8)

                copyButton(
                    systemName: "doc.on.doc",
                    tooltip: "复制译文",
                    accessibilityLabel: "复制译文",
                    identifier: "translation.copy-target",
                    isEnabled: model.hasTranslatedText,
                    action: model.copyTranslation
                )
                .padding(.trailing, 2)
            }
            .frame(height: 24)

            if let prompt = model.languagePackPrompt {
                languagePackPrompt(prompt)
                    .padding(
                        .top,
                        TranslationWorkspaceMetrics.languagePackPromptTopSpacing
                    )
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            } else {
                textArea(
                    text: Binding(get: { model.translatedText }, set: { _ in }),
                    isEditable: false,
                    textIdentifier: "translation.target-text",
                    emptyMessage: model.targetEmptyMessage,
                    emptyIdentifier: "translation.target-empty-state",
                    onContentHeightChange: updateTargetContentHeight
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("translation.target-section")
    }

    private func languagePackPrompt(_ prompt: TranslationLanguagePackPrompt) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(theme.accent.color)
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 0) {
                Text(prompt.title)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(theme.text.primary.color)
                    .lineLimit(1)
                    .accessibilityIdentifier("translation.language-pack-title")
                Text(prompt.message)
                    .font(.system(size: 8.5, weight: .regular))
                    .foregroundStyle(theme.text.secondary.color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                    .accessibilityLabel(prompt.message)
                    .accessibilityIdentifier("translation.language-pack-message")
            }
            .layoutPriority(1)

            Spacer(minLength: 4)

            Button(action: model.confirmLanguagePackDownload) {
                Label(prompt.actionTitle, systemImage: "arrow.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 6)
                    .frame(height: 20)
                    .background(theme.accent.color, in: Capsule())
                    .contentShape(Capsule())
            }
            .frame(minWidth: 74)
            .buttonStyle(ThemePressButtonStyle(theme: theme, reduceMotion: reduceMotion))
            .help("由 macOS 管理语言包；后台下载完成后可在此重新检查")
            .accessibilityIdentifier("translation.download-language-pack")

            TextWorkspaceToolbarButton(
                systemName: "xmark",
                tooltip: "暂不下载语言包",
                accessibilityLabel: "暂不下载语言包",
                theme: theme,
                size: 20,
                iconSize: 8,
                action: model.cancelLanguagePackDownload
            )
            .accessibilityIdentifier("translation.cancel-language-pack")
        }
        .padding(.leading, 6)
        .padding(.trailing, 3)
        // 参考图中的提示条约 32pt。20pt 下载按钮上下各保留约 6pt，
        // 同时让语言包状态单独把窗口拉高，不挤压底部 7pt 安全留白。
        .frame(height: TranslationWorkspaceMetrics.languagePackPromptHeight)
        .background(
            theme.accent.color.opacity(reduceTransparency ? 0.16 : 0.10),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("translation.language-pack-prompt")
    }

    private func languagePicker<T: Hashable & CaseIterable & RawRepresentable>(
        title: String,
        displayName: String,
        selection: Binding<T>,
        identifier: String
    ) -> some View where T.RawValue == String {
        TranslationLanguagePicker(
            title: title,
            displayName: displayName,
            selection: selection,
            identifier: identifier,
            theme: theme,
            reduceTransparency: reduceTransparency
        )
    }

    private func textArea(
        text: Binding<String>,
        isEditable: Bool,
        textIdentifier: String,
        emptyMessage: String,
        emptyIdentifier: String,
        onContentHeightChange: @escaping (CGFloat) -> Void
    ) -> some View {
        ZStack(alignment: .topLeading) {
            TranslationTextView(
                text: text,
                isEditable: isEditable,
                accessibilityLabel: isEditable ? "原文编辑区" : "译文",
                accessibilityIdentifier: textIdentifier,
                textColor: theme.text.primary.nsColor,
                insertionPointColor: theme.accent.nsColor,
                onContentHeightChange: onContentHeightChange
            )

            if text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(emptyMessage)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(theme.text.weak.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 7)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier(emptyIdentifier)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func adaptiveTextHeight(_ height: CGFloat, minimum: CGFloat) -> CGFloat {
        min(
            max(ceil(height), minimum),
            TranslationWorkspaceMetrics.textMaximumHeight
        )
    }

    private func updateSourceContentHeight(_ height: CGFloat) {
        guard abs(sourceNaturalTextHeight - height) > 0.5 else { return }
        sourceNaturalTextHeight = height
    }

    private func updateTargetContentHeight(_ height: CGFloat) {
        guard abs(targetNaturalTextHeight - height) > 0.5 else { return }
        targetNaturalTextHeight = height
    }

    private func copyButton(
        systemName: String,
        tooltip: String,
        accessibilityLabel: String,
        identifier: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        TextWorkspaceToolbarButton(
            systemName: systemName,
            tooltip: tooltip,
            accessibilityLabel: accessibilityLabel,
            theme: theme,
            size: 24,
            action: action
        )
        .disabled(!isEnabled)
        .opacity(isEnabled ? secondaryControlOpacity : secondaryControlOpacity * 0.34)
        .accessibilityIdentifier(identifier)
    }

    private func togglePinned() {
        isPinned.toggle()
        onPinChange(isPinned)
    }
}

/// 截图翻译的原文和译文编辑区。
///
/// SwiftUI 的 `TextEditor` 在紧凑的翻译面板中会带出系统默认的背景、内缩和
/// 滚动条样式，因此这里使用一个透明的 AppKit 文本视图，只保留原生文本编辑
/// responder chain（Command-C/V/A、选择和复制）以及可访问性能力。滚动条使用
/// overlay + autohide；短文本会明确隐藏垂直 scroller，长文本仍然可以正常滚动。
private struct TranslationTextView: NSViewRepresentable {
    @Binding var text: String
    let isEditable: Bool
    let accessibilityLabel: String
    let accessibilityIdentifier: String
    let textColor: NSColor
    let insertionPointColor: NSColor
    let onContentHeightChange: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        // 初始先关闭；布局完成后只有在文档确实溢出时才启用垂直滚动条。
        // 这样短文本首帧也不会在右侧闪出一条空滑块。
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
        textView.allowsUndo = isEditable
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainerInset = NSSize(width: 0, height: 4)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: max(1, scrollView.contentSize.width),
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.minSize = NSSize(width: 0, height: scrollView.contentSize.height)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.setAccessibilityLabel(accessibilityLabel)
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
        textView.isEditable = isEditable
        textView.allowsUndo = isEditable
        textView.setAccessibilityLabel(accessibilityLabel)
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
        textView.font = .systemFont(ofSize: 12.5, weight: .regular)
        textView.textColor = textColor
        textView.insertionPointColor = insertionPointColor
        textView.selectedTextAttributes = [
            .backgroundColor: insertionPointColor.withAlphaComponent(0.24),
            .foregroundColor: textColor
        ]

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 2
        paragraphStyle.lineBreakMode = .byWordWrapping
        textView.defaultParagraphStyle = paragraphStyle
        textView.typingAttributes = [
            .font: textView.font as Any,
            .foregroundColor: textColor,
            .paragraphStyle: paragraphStyle
        ]
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: TranslationTextView
        private weak var scrollView: NSScrollView?
        private weak var textView: NSTextView?
        private var pendingLayoutUpdate = false
        private var lastReportedContentHeight: CGFloat?

        init(parent: TranslationTextView) {
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
            guard parent.isEditable, let textView else { return }
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

            textView.textContainer?.containerSize = NSSize(
                width: viewportSize.width,
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

            let hasOverflow = naturalHeight > viewportSize.height + 0.5
            // Overlay scrollers 不占用文本宽度；短文本直接移除垂直 scroller，
            // 长文本才恢复它。仅设置 isHidden 不足以避免 AppKit 在首次布局
            // 或窗口调整大小时留下一个空的右侧滑块。
            if scrollView.hasVerticalScroller != hasOverflow {
                scrollView.hasVerticalScroller = hasOverflow
            }
            if let verticalScroller = scrollView.verticalScroller {
                verticalScroller.setAccessibilityIdentifier(
                    "\(parent.accessibilityIdentifier).scrollbar"
                )
                verticalScroller.setAccessibilityLabel(
                    parent.isEditable ? "原文滚动条" : "译文滚动条"
                )
                verticalScroller.isHidden = !hasOverflow
            }
            scrollView.horizontalScroller?.isHidden = true
        }
    }
}

private struct TranslationLanguagePicker<Choice>: View
where Choice: Hashable & CaseIterable & RawRepresentable, Choice.RawValue == String {
    let title: String
    let displayName: String
    @Binding var selection: Choice
    let identifier: String
    let theme: ThemeDefinition
    let reduceTransparency: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPresented = false
    @State private var isHovering = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 8) {
                Text(displayName)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(theme.text.primary.color)
                    .lineLimit(1)

                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(theme.text.primary.color)
                    .rotationEffect(.degrees(isPresented ? 180 : 0))
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, minHeight: 40, maxHeight: 40)
            .background(
                pickerBackground,
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(pickerBorder, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(ThemePressButtonStyle(theme: theme, reduceMotion: reduceMotion))
        .onHover { isHovering = $0 }
        .animation(
            reduceMotion ? nil : .easeOut(duration: theme.motion.duration),
            value: isHovering
        )
        .animation(
            reduceMotion ? nil : .easeOut(duration: theme.motion.duration),
            value: isPresented
        )
        .popover(
            isPresented: $isPresented,
            attachmentAnchor: .rect(.bounds),
            arrowEdge: .bottom
        ) {
            languageOptions
                .presentationBackground(.clear)
                .preferredColorScheme(theme.preferredColorScheme)
        }
        .accessibilityLabel("\(title)，\(displayName)")
        .accessibilityValue(displayName)
        .accessibilityIdentifier(identifier)
    }

    private var pickerBackground: Color {
        if isPresented {
            return theme.card.selectedFill.color.opacity(reduceTransparency ? 1 : 0.94)
        }
        if isHovering {
            return theme.card.hoverFill.color.opacity(reduceTransparency ? 1 : 0.9)
        }
        // #5A5A5A 以 82% 覆盖 #424242 后约为 #565656，与参考语言栏一致。
        return theme.search.fill.color.opacity(reduceTransparency ? 1 : 0.82)
    }

    private var pickerBorder: Color {
        if isPresented {
            return theme.accent.color.opacity(0.28)
        }
        if isHovering {
            return theme.panel.highlight.color.opacity(0.14)
        }
        // 参考语言栏默认没有可见描边，只依赖灰阶差建立层级。
        return theme.id == .graphite
            ? .clear
            : theme.panel.highlight.color.opacity(0.16)
    }

    private var languageOptions: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(theme.text.weak.color)
                .padding(.horizontal, 8)
                .padding(.bottom, 2)

            ForEach(Array(Choice.allCases), id: \.self) { option in
                TranslationLanguageOption(
                    title: option.rawValue,
                    isSelected: option == selection,
                    theme: theme
                ) {
                    selection = option
                    isPresented = false
                }
            }
        }
        .padding(7)
        .frame(width: 190)
        .background(
            theme.tooltip.fill.color.opacity(reduceTransparency ? 1 : 0.98),
            in: RoundedRectangle(cornerRadius: 13, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(theme.panel.highlight.color.opacity(0.2), lineWidth: 1)
        }
        .shadow(color: theme.tooltip.shadow.color, radius: 12, y: 6)
        .padding(7)
    }
}

private struct TranslationLanguageOption: View {
    let title: String
    let isSelected: Bool
    let theme: ThemeDefinition
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(theme.text.primary.color)

                Spacer(minLength: 12)

                Image(systemName: "checkmark")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(theme.accent.color)
                    .opacity(isSelected ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(
                optionBackground,
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(ThemePressButtonStyle(theme: theme, reduceMotion: reduceMotion))
        .onHover { isHovering = $0 }
        .animation(
            reduceMotion ? nil : .easeOut(duration: theme.motion.duration),
            value: isHovering
        )
        .accessibilityLabel(title)
        .accessibilityValue(isSelected ? "已选择" : "")
    }

    private var optionBackground: Color {
        if isSelected {
            return theme.accent.color.opacity(0.15)
        }
        if isHovering {
            return theme.card.hoverFill.color.opacity(0.82)
        }
        return .clear
    }
}

private struct TranslationTaskHost<Content: View>: View {
    @ObservedObject var model: TranslationWorkspaceModel
    @ViewBuilder let content: () -> Content

    var body: some View {
        if #available(macOS 15, *) {
            AvailableTranslationTaskHost(model: model, content: content)
        } else {
            content()
        }
    }
}

@available(macOS 15, *)
private struct AvailableTranslationTaskHost<Content: View>: View {
    @ObservedObject var model: TranslationWorkspaceModel
    @ViewBuilder let content: () -> Content
    @State private var configuration: TranslationSession.Configuration?

    var body: some View {
        content()
            .translationTask(configuration) { session in
                guard let request = model.sessionRequest else { return }
                await translate(request, using: session)
            }
            .onAppear(perform: refreshConfiguration)
            .onChange(of: model.sessionRequest) { _, _ in
                refreshConfiguration()
            }

    }

    private func translate(_ request: TranslationSessionRequest, using session: TranslationSession) async {
        do {
            let availability = try await availability(for: request)
            // 配置变化或用户点击“暂不下载”后，旧的 translationTask 可能还会
            // 收到一次回调；旧任务不得覆盖当前界面状态。
            guard model.isCurrentTranslationRequest(request) else { return }
            switch availability {
            case .installed:
                model.markPreparingInstalledLanguagePack()
            case .supported:
                guard request.allowsLanguagePackDownload else {
                    model.requestLanguagePackDownload()
                    return
                }
            case .unsupported:
                model.failTranslation(message: await unsupportedMessage(for: request))
                return
            @unknown default:
                model.failTranslation(message: "无法确认当前语言包状态，请稍后重试")
                return
            }

            guard !request.allowsLanguagePackDownload || hasApplicationIdentifierEntitlement else {
                model.failTranslation(
                    message: "当前调试构建缺少系统翻译所需的应用身份签名。请先在 Xcode 登录开发者账号，再重新构建。"
                )
                return
            }

            // `prepareTranslation()` 会一直等待系统确认或语言包下载。在代理、
            // MobileAsset 或网络异常时，系统调用可能长期不返回。用独立看门狗
            // 恢复成“重新检查”，避免整个翻译面板无限显示加载状态。
            let preparationWatchdog = Task { @MainActor in
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled,
                      model.isCurrentTranslationRequest(request) else {
                    return
                }
                model.showLanguagePackDownloading(for: request)
            }
            defer { preparationWatchdog.cancel() }

            // 已明确原文语言时先准备语言对；自动检测时直接翻译，
            // 由系统根据原文完成识别并在用户确认后下载所需语言包。
            try await session.prepareTranslation()
            guard model.isCurrentTranslationRequest(request) else { return }
            // macOS 15 的 TranslationSession 没有公开下载进度或 `isReady`。
            // 重新查询 LanguageAvailability：若系统已将下载转入后台，则停止
            // 当前翻译请求并恢复“重新检查”入口，绝不能无限等待 translate。
            let postPreparationAvailability = try await self.availability(for: request)
            guard postPreparationAvailability == .installed else {
                guard model.isCurrentTranslationRequest(request) else { return }
                model.showLanguagePackDownloading(for: request)
                return
            }
            let response = try await session.translate(request.text)
            guard model.isCurrentTranslationRequest(request) else { return }
            model.finishTranslation(response.targetText)
        } catch is CancellationError {
            // 取消通常来自语言包提示切换、窗口关闭或用户重新发起翻译；
            // 这些情况已经由模型更新状态，不再闪回成错误文案。
            guard model.isCurrentTranslationRequest(request) else { return }
            model.failTranslation(message: "翻译已取消")
        } catch TranslationError.unsupportedSourceLanguage {
            failIfCurrent(request, message: "macOS 不支持当前原文语言，请重新识别或手动选择原文语言")
        } catch TranslationError.unsupportedTargetLanguage {
            failIfCurrent(request, message: "macOS 不支持当前目标语言，请更换目标语言")
        } catch TranslationError.unsupportedLanguagePairing {
            failIfCurrent(request, message: "macOS 不支持当前语言组合，请更换目标语言")
        } catch TranslationError.unableToIdentifyLanguage {
            failIfCurrent(request, message: "未能识别原文语言，请在左侧手动选择原文语言")
        } catch TranslationError.nothingToTranslate {
            failIfCurrent(request, message: "没有可翻译的文字")
        } catch TranslationError.internalError {
            // 系统在语言包下载失败、Translation 服务短暂异常时都可能抛出
            // internalError。先重新查询状态，若仍是 supported，就保留可恢复
            // 的下载入口，而不是误报成“语言不可用”。
            if await showLanguagePackPromptIfNeeded(for: request) {
                return
            }
            failIfCurrent(request, message: "系统翻译服务暂时不可用，请稍后重试")
        } catch {
            guard model.isCurrentTranslationRequest(request) else { return }

            // `prepareTranslation()` 在少数系统状态下只返回泛化错误，
            // 但语言包状态已经变成 `.supported`。再次查询可以把“可恢复的
            // 未安装/下载失败”与真正的系统服务错误区分开，避免用户看到
            // 没有行动入口的“语言不可用”。
            if await showLanguagePackPromptIfNeeded(for: request) {
                return
            }

            let nsError = error as NSError
            NSLog(
                "[Translation] request failed domain=%@ code=%ld source=%@ target=%@ description=%@",
                nsError.domain,
                nsError.code,
                request.sourceLanguageCode ?? "auto",
                request.targetLanguageCode,
                nsError.localizedDescription
            )
            model.failTranslation(message: "系统翻译服务暂时不可用，请稍后重试")
        }
    }

    private func failIfCurrent(_ request: TranslationSessionRequest, message: String) {
        guard model.isCurrentTranslationRequest(request) else { return }
        model.failTranslation(message: message)
    }

    /// 将 Translation 的泛化错误重新映射为可操作的语言包提示。
    ///
    /// Apple Translation 的 `.supported` 不是“不支持”，而是“语言对支持，
    /// 但本机还没有对应离线模型”。下载失败后 `prepareTranslation()` 有时只
    /// 抛出 `internalError`，因此必须再次查询 `LanguageAvailability`，否则用户
    /// 会看到没有下载按钮的笼统错误。
    private func showLanguagePackPromptIfNeeded(
        for request: TranslationSessionRequest
    ) async -> Bool {
        guard model.isCurrentTranslationRequest(request),
              let currentAvailability = try? await availability(for: request),
              currentAvailability == .supported else {
            return false
        }

        let title = request.allowsLanguagePackDownload
            ? "语言包下载未完成"
            : "系统语言包未安装"
        let message = request.allowsLanguagePackDownload
            ? "系统没有完成语言包下载，请检查网络后重试。"
            : "当前语言组合受支持，但本机尚未下载对应的离线语言包。"
        model.showLanguagePackPrompt(
            for: request,
            title: title,
            message: message,
            actionTitle: request.allowsLanguagePackDownload ? "重新检查" : "下载语言包"
        )
        return true
    }

    private func unsupportedMessage(for request: TranslationSessionRequest) async -> String {
        guard let sourceLanguageCode = request.sourceLanguageCode else {
            return "macOS 不支持当前语言组合，请更换目标语言"
        }

        let supportedLanguages = await LanguageAvailability().supportedLanguages
        if !isSupportedLanguage(sourceLanguageCode, in: supportedLanguages) {
            return "macOS 不支持当前原文语言，请重新识别或手动选择原文语言"
        }
        if !isSupportedLanguage(request.targetLanguageCode, in: supportedLanguages) {
            return "macOS 不支持当前目标语言，请更换目标语言"
        }
        return "macOS 不支持当前语言组合，请更换目标语言"
    }

    private func isSupportedLanguage(
        _ languageCode: String,
        in supportedLanguages: [Locale.Language]
    ) -> Bool {
        let requested = normalizedLanguageCode(languageCode)
        let requestedBase = requested.split(separator: "-").first.map(String.init)
        return supportedLanguages.contains { language in
            guard let availableCode = language.languageCode?.identifier else { return false }
            let normalized = normalizedLanguageCode(availableCode)
            let availableBase = normalized.split(separator: "-").first.map(String.init)
            return normalized == requested || availableBase == requestedBase
        }
    }

    private func normalizedLanguageCode(_ code: String) -> String {
        code.lowercased().replacingOccurrences(of: "_", with: "-")
    }

    private var hasApplicationIdentifierEntitlement: Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(
                  task,
                  "com.apple.application-identifier" as CFString,
                  nil
              ) as? String else {
            return false
        }
        return !value.isEmpty
    }

    private func availability(
        for request: TranslationSessionRequest
    ) async throws -> LanguageAvailability.Status {
        let checker = LanguageAvailability()
        let target = Locale.Language(identifier: request.targetLanguageCode)
        if let sourceLanguageCode = request.sourceLanguageCode {
            return await checker.status(
                from: Locale.Language(identifier: sourceLanguageCode),
                to: target
            )
        }
        return try await checker.status(for: request.text, to: target)
    }

    private func refreshConfiguration() {
        guard let request = model.sessionRequest else {
            configuration = nil
            return
        }

        let source = request.sourceLanguageCode.map(Locale.Language.init(identifier:))
        let target = Locale.Language(identifier: request.targetLanguageCode)
        if var current = configuration,
           current.source == source,
           current.target == target {
            current.invalidate()
            configuration = current
        } else {
            configuration = .init(source: source, target: target)
        }
    }
}
