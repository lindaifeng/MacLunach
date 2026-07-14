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
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "文字识别"
        panel.identifier = NSUserInterfaceItemIdentifier("screenshot.recognition.\(artifact.id.uuidString)")
        panel.setAccessibilityLabel("文字识别结果")
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.minSize = CGSize(width: 440, height: 360)
        panel.contentViewController = NSHostingController(
            rootView: ScreenshotRecognitionResultView(model: model)
        )
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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .padding(20)
        .frame(minWidth: 440, minHeight: 360)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "text.viewfinder")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text("文字与二维码识别")
                    .font(.title3.weight(.semibold))
                Text(model.isRetrying ? "正在重新识别…" : summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.isRetrying {
                ProgressView().controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.presentation {
        case let .failure(message):
            ContentUnavailableView(
                "识别失败",
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .result(result):
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    recognizedText(result)
                    if !result.barcodes.isEmpty {
                        barcodeList(result.barcodes)
                    }
                    if result.fullText.isEmpty, result.barcodes.isEmpty {
                        ContentUnavailableView(
                            "未识别到内容",
                            systemImage: "text.magnifyingglass",
                            description: Text("可以查看原图后调整选区，或重新识别。")
                        )
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func recognizedText(_ result: ScreenshotRecognitionResult) -> some View {
        if !result.fullText.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("识别文字", systemImage: "text.alignleft")
                        .font(.headline)
                    Spacer()
                    Button("复制文字") { model.onCopy(result.fullText) }
                        .accessibilityIdentifier("screenshot.recognition.copyText")
                }
                Text(result.fullText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private func barcodeList(_ barcodes: [ScreenshotRecognizedBarcode]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("二维码（\(barcodes.count)）", systemImage: "qrcode.viewfinder")
                .font(.headline)
            ForEach(barcodes) { barcode in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: safeURL(for: barcode) == nil ? "qrcode" : "link")
                        .foregroundStyle(.secondary)
                    Text(barcode.payload)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let url = safeURL(for: barcode) {
                        Button("打开链接") { model.onOpenURL(url) }
                            .accessibilityIdentifier("screenshot.recognition.openURL")
                    } else {
                        Button("复制内容") { model.onCopy(barcode.payload) }
                            .accessibilityIdentifier("screenshot.recognition.copyBarcode")
                    }
                }
                .padding(10)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func safeURL(for barcode: ScreenshotRecognizedBarcode) -> URL? {
        // 不信任跨进程载荷中序列化的 safeURL，打开前始终根据原始内容重新校验。
        ScreenshotRecognizedBarcode.validatedURL(from: barcode.payload)
    }

    private var footer: some View {
        HStack {
            Button("查看原图") { model.onOpenOriginal(model.artifact) }
                .accessibilityIdentifier("screenshot.recognition.openOriginal")
            Button("重新识别") { model.retry() }
                .disabled(model.isRetrying)
                .accessibilityIdentifier("screenshot.recognition.retry")
            Spacer()
            Button("完成") { model.onClose() }
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
}
