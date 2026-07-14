import AppKit
import ScreenshotFeature

enum CaptureCountdownTimeline {
    static func seconds(for delay: ScreenshotCaptureDelay) -> [Int] {
        guard delay.rawValue > 0 else { return [] }
        return Array(stride(from: delay.rawValue, through: 1, by: -1))
    }
}

@MainActor
protocol ScreenshotCaptureCountdownPresenting: AnyObject, Sendable {
    func wait(for delay: ScreenshotCaptureDelay) async throws
    func cancel()
}

/// 延时截图期间显示的轻量 HUD。
///
/// 选区层已经关闭后才显示倒计时；倒计时结束先关闭面板，再请求 XPC 立即捕获，
/// 避免 HUD 自身进入最终截图。等待使用结构化并发，Esc/停用插件取消时不会阻塞主线程。
@MainActor
final class CaptureCountdownPanel: ScreenshotCaptureCountdownPresenting {
    typealias Sleep = @Sendable (Duration) async throws -> Void

    private let sleep: Sleep
    private var panel: NSPanel?
    private var label: NSTextField?
    private var activeTask: Task<Void, any Error>?
    private var keyMonitor: Any?

    init(sleep: @escaping Sleep = { try await Task.sleep(for: $0) }) {
        self.sleep = sleep
    }

    func wait(for delay: ScreenshotCaptureDelay) async throws {
        let values = CaptureCountdownTimeline.seconds(for: delay)
        guard !values.isEmpty else { return }

        cancel()
        showPanel(initialValue: values[0])

        let sleep = self.sleep
        let task = Task { @MainActor [weak self] in
            for value in values {
                try Task.checkCancellation()
                self?.update(value)
                try await sleep(.seconds(1))
            }
        }
        activeTask = task

        do {
            try await task.value
            finish()
        } catch {
            finish()
            throw error
        }
    }

    func cancel() {
        activeTask?.cancel()
        activeTask = nil
        closePanel()
    }

    private func showPanel(initialValue: Int) {
        let size = CGSize(width: 196, height: 116)
        let screenFrame = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 800, height: 600)
        let origin = CGPoint(
            x: screenFrame.midX - size.width / 2,
            y: screenFrame.midY - size.height / 2
        )
        let panel = CaptureCountdownNSPanel(
            contentRect: CGRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.identifier = NSUserInterfaceItemIdentifier("screenshot.capture.countdown")
        panel.setAccessibilityIdentifier("screenshot.capture.countdown")
        panel.setAccessibilityLabel("延时截图倒计时")
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true

        let effect = NSVisualEffectView(frame: CGRect(origin: .zero, size: size))
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 18
        effect.layer?.masksToBounds = true

        let label = NSTextField(labelWithString: String(initialValue))
        label.identifier = NSUserInterfaceItemIdentifier("screenshot.capture.countdown.value")
        label.setAccessibilityIdentifier("screenshot.capture.countdown.value")
        label.setAccessibilityLabel("剩余秒数")
        label.font = .monospacedDigitSystemFont(ofSize: 58, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(label)

        let hint = NSTextField(labelWithString: "按 Esc 取消")
        hint.font = .systemFont(ofSize: 12, weight: .medium)
        hint.textColor = .secondaryLabelColor
        hint.alignment = .center
        hint.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(hint)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: effect.centerXAnchor),
            label.topAnchor.constraint(equalTo: effect.topAnchor, constant: 12),
            hint.centerXAnchor.constraint(equalTo: effect.centerXAnchor),
            hint.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -11)
        ])

        panel.contentView = effect
        self.panel = panel
        self.label = label
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            Task { @MainActor [weak self] in self?.cancel() }
            return nil
        }
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    private func update(_ value: Int) {
        label?.stringValue = String(value)
        label?.setAccessibilityValue("剩余 \(value) 秒")
    }

    private func finish() {
        activeTask = nil
        closePanel()
    }

    private func closePanel() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        panel?.orderOut(nil)
        panel = nil
        label = nil
    }
}

private final class CaptureCountdownNSPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
