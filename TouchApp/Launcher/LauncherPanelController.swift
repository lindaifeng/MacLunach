import AppKit
import SwiftUI

@MainActor
final class LauncherPanelController: NSObject {
    /// 以 macOS Retina 2x 坐标呈现 2160 × 1120 px 的设计画布。
    static let contentSize = NSSize(width: 1_080, height: 560)

    private let panel: LauncherPanel
    private let themeStore: ThemeStore
    private let searchCoordinator: SearchCoordinator
    private let featureStore: FeatureAreaStore

    init(
        searchEnvironment: SearchEnvironment,
        featureStore: FeatureAreaStore,
        screenshotEnvironment: ScreenshotEnvironment,
        themeStore: ThemeStore
    ) {
        self.themeStore = themeStore
        self.featureStore = featureStore
        searchCoordinator = SearchCoordinator(
            environment: searchEnvironment,
            actionSearch: { [weak featureStore] query in
                featureStore?.searchLauncherActions(query: query) ?? []
            },
            actionActivation: { [weak featureStore] result in
                featureStore?.performLauncherSearchResult(result)
            }
        )
        panel = LauncherPanel(
            contentRect: NSRect(origin: .zero, size: Self.contentSize),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()
        panel.isFloatingPanel = true
        // 启动器与普通功能区保持同一层级，由当前点击/Key Window 决定谁显示在最前。
        panel.level = .floating
        // UI 测试宿主会在启动后短暂取得焦点；此时不应让待测面板立即消失。
        panel.hidesOnDeactivate = !Self.isRunningUITests
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = false
        panel.isRestorable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.searchKeyHandler = { [weak self] event in
            self?.handleSearchKey(event) ?? false
        }
        panel.outsideSearchClickHandler = { [weak self] in
            self?.searchCoordinator.exitActionSearch()
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
        searchCoordinator.prepareForPresentation()
        centerPanelOnActiveScreen()
        NSApp.activate()
        NotificationCenter.default.post(name: .touchLauncherWillDisplay, object: nil)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(nil)
        panel.orderFrontRegardless()
    }

    private func centerPanelOnActiveScreen() {
        let mouseLocation = NSEvent.mouseLocation
        let targetScreen = NSScreen.screens.first { $0.frame.contains(mouseLocation) }
            ?? panel.screen
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let targetScreen else { return }

        panel.setFrameOrigin(Self.centeredOrigin(panelSize: panel.frame.size, in: targetScreen.frame))
    }

    static func centeredOrigin(panelSize: NSSize, in screenFrame: NSRect) -> NSPoint {
        NSPoint(
            x: screenFrame.midX - panelSize.width / 2,
            y: screenFrame.midY - panelSize.height / 2
        )
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
            searchCoordinator.advanceMode()
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
            return performFeatureIfMapped(event)
        }
    }

    private func performFeatureIfMapped(_ event: NSEvent) -> Bool {
        guard searchCoordinator.mode == .actions,
              !(panel.firstResponder is any NSTextInputClient),
              searchCoordinator.query.isEmpty,
              !event.isARepeat,
              event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
              let characters = event.charactersIgnoringModifiers,
              let character = characters.first,
              !character.isWhitespace else { return false }

        let key = String(character).lowercased()
        guard featureStore.hasLauncherAssignment(for: key) else { return false }

        Task { await featureStore.performLauncherKey(key) }
        return true
    }

    private static var isRunningUITests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
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
