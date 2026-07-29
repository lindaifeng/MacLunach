import AppKit
import SuperRightFeature
import SwiftUI

@MainActor
final class MoveConflictWindowController: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private let themeStore: ThemeStore
    private let onResolve: (MoveConflictRequest, MoveConflictResolution) -> Void
    private let onCancel: (MoveConflictRequest) -> Void
    private var request: MoveConflictRequest?
    private var isDismissing = false

    init(
        themeStore: ThemeStore,
        onResolve: @escaping (MoveConflictRequest, MoveConflictResolution) -> Void,
        onCancel: @escaping (MoveConflictRequest) -> Void
    ) {
        self.themeStore = themeStore
        self.onResolve = onResolve
        self.onCancel = onCancel
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 330),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.contentMinSize = NSSize(width: 420, height: 300)
        panel.contentMaxSize = NSSize(width: 520, height: 390)
    }

    func show(_ request: MoveConflictRequest, errorMessage: String? = nil) {
        self.request = request
        isDismissing = false
        panel.contentView = NSHostingView(
            rootView: MoveConflictWindowView(
                request: request,
                errorMessage: errorMessage,
                onResolve: { [weak self] resolution in
                    guard let self, let request = self.request else { return }
                    self.onResolve(request, resolution)
                },
                onCancel: { [weak self] in
                    self?.cancelCurrentRequest()
                }
            )
            .environmentObject(themeStore)
        )
        panel.center()
        // 仅在 Finder 报告冲突时前置，正常剪切和无冲突移动完全不激活主应用。
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        isDismissing = true
        request = nil
        panel.orderOut(nil)
    }

    func isPresentingConflict(id: UUID) -> Bool {
        request?.id == id && panel.isVisible
    }

    func windowWillClose(_ notification: Notification) {
        guard !isDismissing else { return }
        cancelCurrentRequest()
    }

    private func cancelCurrentRequest() {
        guard let request else { return }
        isDismissing = true
        self.request = nil
        panel.orderOut(nil)
        onCancel(request)
    }
}

private struct MoveConflictWindowView: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    let request: MoveConflictRequest
    let errorMessage: String?
    let onResolve: (MoveConflictResolution) -> Void
    let onCancel: () -> Void

    private var theme: ThemeDefinition { ThemeRegistry.shared.definition(for: themeStore.theme) }

    var body: some View {
        ZStack {
            PanelThemeBackground(
                theme: theme,
                reduceTransparency: reduceTransparency,
                themeColorOpacity: 0.98
            )

            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 13) {
                    Image(systemName: "arrow.left.arrow.right.circle.fill")
                        .font(.system(size: 29, weight: .medium))
                        .foregroundStyle(theme.accent.color)
                        .frame(width: 42, height: 42)
                        .background(theme.accent.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("发现同名项目")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(theme.text.primary.color)
                        Text("目标文件夹中已有同名文件，尚未移动任何项目。")
                            .font(.system(size: 12.5))
                            .foregroundStyle(theme.text.secondary.color)
                    }
                    Spacer(minLength: 0)
                }

                VStack(alignment: .leading, spacing: 7) {
                    ForEach(request.conflicts.prefix(2), id: \.sourceURL) { conflict in
                        HStack(spacing: 8) {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(theme.text.secondary.color)
                            Text(conflict.sourceURL.lastPathComponent)
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(theme.text.primary.color)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                        }
                    }
                    if request.conflicts.count > 2 {
                        Text("另有 \(request.conflicts.count - 2) 个同名项目")
                            .font(.system(size: 11.5))
                            .foregroundStyle(theme.text.weak.color)
                    }
                }
                .padding(12)
                .background(theme.card.fill.color.opacity(0.82), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(theme.card.border.color, lineWidth: 1)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.text.failure.color)
                }

                Spacer(minLength: 0)

                HStack(spacing: 9) {
                    decisionButton("取消", foreground: theme.text.secondary.color, fill: theme.card.fill.color) {
                        onCancel()
                    }
                    decisionButton("跳过冲突项", foreground: theme.text.primary.color, fill: theme.card.hoverFill.color) {
                        onResolve(.skipConflicts)
                    }
                    decisionButton("保留两者", foreground: .white, fill: theme.accent.color) {
                        onResolve(.keepBoth)
                    }
                }
            }
            .padding(24)
        }
        .clipShape(RoundedRectangle(cornerRadius: theme.panel.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: theme.panel.cornerRadius, style: .continuous)
                .stroke(theme.panel.edgeBorder.color, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("移动冲突处理")
    }

    private func decisionButton(
        _ title: String,
        foreground: Color,
        fill: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(foreground)
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .background(fill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(theme.card.border.color.opacity(0.75), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}
