import AppKit
import SwiftUI

@MainActor
final class LauncherPanelController: NSObject {
    private let panel: LauncherPanel
    private let themeStore = ThemeStore()
    private let searchCoordinator: SearchCoordinator

    init(
        searchEnvironment: SearchEnvironment,
        featureStore: FeatureAreaStore,
        screenshotEnvironment: ScreenshotEnvironment
    ) {
        searchCoordinator = SearchCoordinator(environment: searchEnvironment)
        panel = LauncherPanel(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 500),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isRestorable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.searchKeyHandler = { [weak self] event in
            self?.handleSearchKey(event) ?? false
        }
        panel.contentView = NSHostingView(
            rootView: LauncherView(searchCoordinator: searchCoordinator)
                .environmentObject(themeStore)
                .environmentObject(featureStore)
                .environmentObject(screenshotEnvironment)
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(dismissLauncher),
            name: .dismissTouchLauncher,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func dismissLauncher() {
        hide()
    }

    var isVisible: Bool { panel.isVisible }

    func show() {
        LaunchPerformanceRecorder.shared.begin()
        present()
    }

    private func present() {
        panel.center()
        NSApp.activate()
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


    private func handleSearchKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 48:
            searchCoordinator.toggleMode()
            return true
        case 53:
            if searchCoordinator.clearOrDismiss() == .dismiss { hide() }
            return true
        case 125:
            searchCoordinator.moveSelection(by: 1)
            return true
        case 126:
            searchCoordinator.moveSelection(by: -1)
            return true
        case 36, 76:
            searchCoordinator.activateSelected(commandModifier: event.modifierFlags.contains(.command))
            return true
        case 49 where searchCoordinator.canPreviewSelectedResult:
            searchCoordinator.previewSelected()
            return true
        default:
            return false
        }
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

extension LauncherPanelController: ScreenshotLauncherPresenting {
    var isLauncherVisible: Bool {
        isVisible
    }

    func hideLauncher() {
        hide()
    }

    func showLauncher() {
        show()
    }
}
