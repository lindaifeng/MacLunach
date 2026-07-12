import AppKit
import SwiftUI

@MainActor
final class LauncherPanelController {
    private let panel: LauncherPanel
    private let themeStore = ThemeStore()

    init() {
        panel = LauncherPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 620),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(
            rootView: LauncherView()
                .environmentObject(themeStore)
                .environmentObject(FeatureAreaStore.shared)
        )
    }

    var isVisible: Bool { panel.isVisible }

    func show() {
        LaunchPerformanceRecorder.shared.begin()
        present()
    }

    private func present() {
        panel.center()
        NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        NotificationCenter.default.post(name: .touchLauncherWillDisplay, object: nil)
    }

    func hide() {
        panel.orderOut(nil)
    }

    func toggle() {
        panel.isVisible ? hide() : show()
    }

    func runPerformanceMeasurement(samples: Int, outputURL: URL) async {
        var durations: [Double] = []
        durations.reserveCapacity(samples)

        for _ in 0..<samples {
            hide()
            await Task.yield()
            let duration = await withCheckedContinuation { continuation in
                LaunchPerformanceRecorder.shared.begin { milliseconds in
                    continuation.resume(returning: milliseconds)
                }
                present()
            }
            durations.append(duration)
        }

        let output = durations.map { String(format: "%.3f", $0) }.joined(separator: "\n") + "\n"
        try? output.write(to: outputURL, atomically: true, encoding: .utf8)
        hide()
        NSApp.terminate(nil)
    }
}
