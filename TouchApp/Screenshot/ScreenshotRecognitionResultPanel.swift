import AppKit
import ScreenshotFeature
import SwiftUI

@MainActor
enum ScreenshotRecognitionPresentation: Equatable {
    case result(ScreenshotRecognitionResult)
    case failure(message: String)
}

@MainActor
protocol ScreenshotRecognitionPresenting: AnyObject {
    typealias RetryAction = @MainActor () async throws -> ScreenshotRecognitionResult

    func present(
        artifact: ScreenshotArtifact,
        presentation: ScreenshotRecognitionPresentation,
        retry: @escaping RetryAction
    )
    func dismiss()
}

enum ScreenshotRecognitionErrorMessage {
    static func text(for error: Error) -> String {
        guard let error = error as? ScreenshotFeatureError else {
            if let error = error as? LocalizedError, let description = error.errorDescription {
                return description
            }
            return String(describing: error)
        }
        switch error {
        case let .recognitionFailed(message), let .serviceFailed(message), let .storageFailed(message):
            return message
        case .permissionDenied:
            return "没有屏幕录制权限"
        case .cancelled:
            return "识别已取消"
        case .serviceTimedOut:
            return "识别服务响应超时"
        case .serviceInterrupted:
            return "识别服务连接已中断"
        case .targetUnavailable:
            return "原截图不可用"
        default:
            return "识别暂时不可用（\(String(describing: error))）"
        }
    }
}

@MainActor
final class ScreenshotRecognitionResultPanel: ScreenshotRecognitionPresenting {
    typealias PathsProvider = () throws -> ScreenshotFeaturePaths

    private let pathsProvider: PathsProvider
    private var controllers: [UUID: ScreenshotRecognitionWindowController] = [:]

    init(pathsProvider: @escaping PathsProvider = { try ScreenshotFeaturePaths.applicationSupport() }) {
        self.pathsProvider = pathsProvider
    }

    func present(
        artifact: ScreenshotArtifact,
        presentation: ScreenshotRecognitionPresentation,
        retry: @escaping RetryAction
    ) {
        if let controller = controllers[artifact.id] {
            controller.update(presentation: presentation, retry: retry)
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
            return
        }

        let controller = ScreenshotRecognitionWindowController(
            artifact: artifact,
            presentation: presentation,
            retry: retry,
            onCopy: Self.copyToPasteboard,
            onOpenURL: Self.confirmAndOpen,
            onOpenOriginal: { [pathsProvider] artifact in
                do {
                    let url = try pathsProvider().resolve(relativePath: artifact.relativePath)
                    guard FileManager.default.fileExists(atPath: url.path) else {
                        throw ScreenshotRecognitionPanelError.originalImageMissing
                    }
                    NSWorkspace.shared.open(url)
                } catch {
                    Self.showError(message: "无法查看原图：\(error.localizedDescription)")
                }
            }
        )
        controller.onClose = { [weak self] artifactID in
            self?.controllers.removeValue(forKey: artifactID)
        }
        controllers[artifact.id] = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func dismiss() {
        let current = Array(controllers.values)
        controllers.removeAll()
        current.forEach { $0.close() }
    }

    private static func copyToPasteboard(_ value: String) {
        guard !value.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }

    private static func confirmAndOpen(_ url: URL) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "是否打开二维码链接？"
        alert.informativeText = url.absoluteString
        alert.addButton(withTitle: "打开")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard NSWorkspace.shared.open(url) else {
            showError(message: "无法打开这个链接。")
            return
        }
    }

    private static func showError(message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "文字识别"
        alert.informativeText = message
        alert.addButton(withTitle: "知道了")
        alert.runModal()
    }
}

private enum ScreenshotRecognitionPanelError: LocalizedError {
    case originalImageMissing

    var errorDescription: String? {
        switch self {
        case .originalImageMissing:
            "截图文件已经不存在"
        }
    }
}

@MainActor
private final class ScreenshotRecognitionPanelModel: ObservableObject {
    @Published private(set) var presentation: ScreenshotRecognitionPresentation
    @Published private(set) var isRetrying = false

    let artifact: ScreenshotArtifact
    var onCopy: (String) -> Void
    var onOpenURL: (URL) -> Void
    var onOpenOriginal: (ScreenshotArtifact) -> Void
    var onClose: () -> Void
    private var retryAction: ScreenshotRecognitionPresenting.RetryAction

    init(
        artifact: ScreenshotArtifact,
        presentation: ScreenshotRecognitionPresentation,
        retry: @escaping ScreenshotRecognitionPresenting.RetryAction,
        onCopy: @escaping (String) -> Void,
        onOpenURL: @escaping (URL) -> Void,
        onOpenOriginal: @escaping (ScreenshotArtifact) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.artifact = artifact
        self.presentation = presentation
        retryAction = retry
        self.onCopy = onCopy
        self.onOpenURL = onOpenURL
        self.onOpenOriginal = onOpenOriginal
        self.onClose = onClose
    }

    func update(
        presentation: ScreenshotRecognitionPresentation,
        retry: @escaping ScreenshotRecognitionPresenting.RetryAction
    ) {
        self.presentation = presentation
        retryAction = retry
        isRetrying = false
    }

    func retry() {
        guard !isRetrying else { return }
        isRetrying = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                presentation = .result(try await retryAction())
            } catch is CancellationError {
                presentation = .failure(message: "识别已取消")
            } catch let error as ScreenshotFeatureError where error == .cancelled {
                presentation = .failure(message: "识别已取消")
            } catch {
                presentation = .failure(message: ScreenshotRecognitionErrorMessage.text(for: error))
            }
            isRetrying = false
        }
    }

}

@MainActor
private final class ScreenshotRecognitionWindowController: NSWindowController, NSWindowDelegate {
    let artifactID: UUID
    var onClose: ((UUID) -> Void)?
    private let model: ScreenshotRecognitionPanelModel

    init(
        artifact: ScreenshotArtifact,
        presentation: ScreenshotRecognitionPresentation,
        retry: @escaping ScreenshotRecognitionPresenting.RetryAction,
        onCopy: @escaping (String) -> Void,
        onOpenURL: @escaping (URL) -> Void,
        onOpenOriginal: @escaping (ScreenshotArtifact) -> Void
    ) {
        artifactID = artifact.id
        model = ScreenshotRecognitionPanelModel(
            artifact: artifact,
            presentation: presentation,
            retry: retry,
            onCopy: onCopy,
            onOpenURL: onOpenURL,
            onOpenOriginal: onOpenOriginal,
            onClose: {}
        )

        let panel = ScreenshotRecognitionNSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 560, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = ""
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.identifier = NSUserInterfaceItemIdentifier("screenshot.recognition.\(artifact.id.uuidString)")
        panel.setAccessibilityLabel("文字识别结果")
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.minSize = CGSize(width: 440, height: 360)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = false
        panel.contentViewController = NSHostingController(
            rootView: ScreenshotRecognitionResultView(model: model)
        )
        installWindowTopDragRegion(in: panel)
        panel.center()

        super.init(window: panel)
        panel.delegate = self
        model.onClose = { [weak panel] in panel?.close() }
    }

    required init?(coder: NSCoder) {
        nil
    }

    func update(
        presentation: ScreenshotRecognitionPresentation,
        retry: @escaping ScreenshotRecognitionPresenting.RetryAction
    ) {
        model.update(presentation: presentation, retry: retry)
    }

    func windowWillClose(_ notification: Notification) {
        onClose?(artifactID)
    }
}

private final class ScreenshotRecognitionNSPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private struct ScreenshotRecognitionResultView: View {
    @ObservedObject var model: ScreenshotRecognitionPanelModel

    private let accent = Color(red: 0.13, green: 0.52, blue: 0.96)
    private let panelBackground = Color(nsColor: NSColor(
        calibratedRed: 0.075,
        green: 0.085,
        blue: 0.105,
        alpha: 0.98
    ))

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 18)
                .padding(.vertical, 15)
            separator
            content
                .padding(18)
            separator
            footer
                .padding(.horizontal, 18)
                .padding(.vertical, 13)
        }
        .frame(minWidth: 440, minHeight: 360)
        .background(panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        }
        .padding(8)
        .background(Color.clear)
        .ignoresSafeArea(.container, edges: .top)
    }

    private var header: some View {
        HStack(spacing: 11) {
            Image(systemName: "text.viewfinder")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(accent.gradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text("文字与二维码识别")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                Text(model.isRetrying ? "正在重新识别…" : summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.54))
            }
            Spacer()
            if model.isRetrying {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white.opacity(0.75))
            }
        }
        .padding(.leading, 58)
    }

    @ViewBuilder
    private var content: some View {
        switch model.presentation {
        case let .failure(message):
            stateView(
                title: "识别失败",
                message: message,
                symbol: "exclamationmark.triangle.fill",
                color: .orange
            )
        case let .result(result):
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    recognizedText(result)
                    if !result.barcodes.isEmpty {
                        barcodeList(result.barcodes)
                    }
                    if result.fullText.isEmpty, result.barcodes.isEmpty {
                        stateView(
                            title: "未识别到内容",
                            message: "可以查看原图后调整选区，或重新识别。",
                            symbol: "text.magnifyingglass",
                            color: accent
                        )
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    @ViewBuilder
    private func recognizedText(_ result: ScreenshotRecognitionResult) -> some View {
        if !result.fullText.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    sectionTitle("识别文字", symbol: "text.alignleft")
                    Spacer()
                    RecognitionActionButton(title: "复制", symbol: "doc.on.doc") {
                        model.onCopy(result.fullText)
                    }
                        .accessibilityIdentifier("screenshot.recognition.copyText")
                }
                Text(result.fullText)
                    .textSelection(.enabled)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.88))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .stroke(Color.white.opacity(0.07), lineWidth: 1)
                    }
            }
        }
    }

    private func barcodeList(_ barcodes: [ScreenshotRecognizedBarcode]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("二维码（\(barcodes.count)）", symbol: "qrcode.viewfinder")
            ForEach(barcodes) { barcode in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: safeURL(for: barcode) == nil ? "qrcode" : "link")
                        .foregroundStyle(accent)
                    Text(barcode.payload)
                        .textSelection(.enabled)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.82))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let url = safeURL(for: barcode) {
                        RecognitionActionButton(title: "打开", symbol: "arrow.up.right") {
                            model.onOpenURL(url)
                        }
                            .accessibilityIdentifier("screenshot.recognition.openURL")
                    } else {
                        RecognitionActionButton(title: "复制", symbol: "doc.on.doc") {
                            model.onCopy(barcode.payload)
                        }
                            .accessibilityIdentifier("screenshot.recognition.copyBarcode")
                    }
                }
                .padding(12)
                .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }

    private func safeURL(for barcode: ScreenshotRecognizedBarcode) -> URL? {
        // 不信任跨进程载荷中序列化的 safeURL，打开前始终根据原始内容重新校验。
        ScreenshotRecognizedBarcode.validatedURL(from: barcode.payload)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            RecognitionActionButton(title: "查看原图", symbol: "photo") {
                model.onOpenOriginal(model.artifact)
            }
                .accessibilityIdentifier("screenshot.recognition.openOriginal")
            RecognitionActionButton(title: "重新识别", symbol: "arrow.clockwise") {
                model.retry()
            }
                .disabled(model.isRetrying)
                .accessibilityIdentifier("screenshot.recognition.retry")
            Spacer()
            RecognitionActionButton(title: "完成", symbol: "checkmark", isPrimary: true) {
                model.onClose()
            }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("screenshot.recognition.done")
        }
    }

    private var summary: String {
        switch model.presentation {
        case .failure:
            "原图已保留，可重新识别"
        case let .result(result):
            "\(result.textBlocks.count) 段文字 · \(result.barcodes.count) 个二维码"
        }
    }

    private var separator: some View {
        Rectangle()
            .fill(Color.white.opacity(0.075))
            .frame(height: 1)
    }

    private func sectionTitle(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white.opacity(0.72))
    }

    private func iconButton(
        symbol: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.70))
                .frame(width: 28, height: 28)
                .background(Color.white.opacity(0.06), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func stateView(
        title: String,
        message: String,
        symbol: String,
        color: Color
    ) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(color)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.52))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }
}

private struct RecognitionActionButton: View {
    let title: String
    let symbol: String
    var isPrimary = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isPrimary ? Color.white : Color.white.opacity(0.76))
                .padding(.horizontal, 11)
                .frame(height: 30)
                .background(
                    isPrimary
                        ? Color(red: 0.13, green: 0.52, blue: 0.96)
                        : Color.white.opacity(0.065),
                    in: Capsule()
                )
                .overlay {
                    if !isPrimary {
                        Capsule().stroke(Color.white.opacity(0.08), lineWidth: 1)
                    }
                }
        }
        .buttonStyle(.plain)
    }
}
