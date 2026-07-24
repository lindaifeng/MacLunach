import AppKit
import SwiftUI

struct GlassBackground: NSViewRepresentable {
    let theme: ThemeDefinition
    let reduceTransparency: Bool
    let themeColorOpacity: Double

    init(
        theme: ThemeDefinition,
        reduceTransparency: Bool,
        themeColorOpacity: Double = 1
    ) {
        self.theme = theme
        self.reduceTransparency = reduceTransparency
        self.themeColorOpacity = themeColorOpacity
    }

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = true
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = reduceTransparency ? .windowBackground : material
        view.alphaValue = reduceTransparency
            ? 1
            : theme.panel.effectOpacity * themeColorOpacity
    }

    private var material: NSVisualEffectView.Material {
        switch theme.panel.material {
        case .underWindowBackground: .underWindowBackground
        case .popover: .popover
        case .hudWindow: .hudWindow
        case .sidebar: .sidebar
        }
    }
}

struct PanelThemeBackground: View {
    let theme: ThemeDefinition
    let reduceTransparency: Bool
    let themeColorOpacity: Double

    init(
        theme: ThemeDefinition,
        reduceTransparency: Bool,
        themeColorOpacity: Double = 1
    ) {
        self.theme = theme
        self.reduceTransparency = reduceTransparency
        self.themeColorOpacity = themeColorOpacity
    }

    var body: some View {
        ZStack {
            if reduceTransparency {
                theme.panel.fallback.color
            } else {
                theme.panel.gradient.gradient.opacity(themeColorOpacity)
                theme.panel.tint.color.opacity(themeColorOpacity)
            }

            RadialGradient(
                colors: [theme.panel.reflection.color, .clear],
                center: .topTrailing,
                startRadius: 0,
                endRadius: 420
            )
            .opacity(reduceTransparency ? 1 : themeColorOpacity)
        }
        .allowsHitTesting(false)
    }
}

struct FeatureWorkspaceBackground: View {
    let theme: ThemeDefinition
    let reduceTransparency: Bool
    let themeColorOpacity: Double

    var body: some View {
        ZStack {
            GlassBackground(
                theme: theme,
                reduceTransparency: reduceTransparency,
                themeColorOpacity: themeColorOpacity
            )
            PanelThemeBackground(
                theme: theme,
                reduceTransparency: reduceTransparency,
                themeColorOpacity: themeColorOpacity
            )
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// 翻译与文字识别共用的文字工作台背景。
///
/// 参考工作台的主体不是从亮灰过渡到近黑，而是稳定在约 `#424242` 的
/// 中性石墨表面。这里仍从石墨主题的面板令牌取色，再用极轻的中性遮罩
/// 把明度收敛到参考范围；不为翻译或 OCR 另起一套硬编码颜色。其他主题
/// 仍完全沿用各自的材质与颜色令牌。
struct TextWorkflowWorkspaceBackground: View {
    let theme: ThemeDefinition
    let reduceTransparency: Bool
    let themeColorOpacity: Double

    var body: some View {
        ZStack {
            if theme.id == .graphite {
                // 使用主题 fallback 而不是另一套固定 RGB 值。默认 #484848
                // 经 5.5%–7.5% 的中性遮罩后约为 #444444–#434343，既贴近
                // 参考图，也消除旧渐变在窗口底部突然变暗、发蓝的问题。
                theme.panel.fallback.color
                    .opacity(reduceTransparency ? 1 : themeColorOpacity)
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.055), location: 0),
                        .init(color: .black.opacity(0.065), location: 0.52),
                        .init(color: .black.opacity(0.075), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .opacity(reduceTransparency ? 1 : themeColorOpacity)

                // 仅保留几乎不可察觉的主题反射，维持窗口层次，同时避免
                // 把右上角重新抬成与参考图不同的亮灰或冷蓝。
                RadialGradient(
                    colors: [theme.panel.reflection.color, .clear],
                    center: .topTrailing,
                    startRadius: 0,
                    endRadius: 420
                )
                .opacity(reduceTransparency ? 0 : 0.18 * themeColorOpacity)
            } else {
                FeatureWorkspaceBackground(
                    theme: theme,
                    reduceTransparency: reduceTransparency,
                    themeColorOpacity: themeColorOpacity
                )
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension ThemeDefinition {
    var preferredColorScheme: ColorScheme? {
        switch id {
        case .night, .graphite:
            return .dark
        case .day:
            return .light
        case .defaultGlass:
            return nil
        }
    }
}

@MainActor
func installWindowTopDragRegion(
    in window: NSWindow,
    height: CGFloat = 28,
    leadingInset: CGFloat = 0,
    trailingInset: CGFloat = 0
) {
    guard let contentView = window.contentView else { return }
    let dragRegion = WindowTopDragRegion(frame: .zero)
    dragRegion.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(dragRegion, positioned: .above, relativeTo: nil)
    NSLayoutConstraint.activate([
        dragRegion.leadingAnchor.constraint(
            equalTo: contentView.leadingAnchor,
            constant: leadingInset
        ),
        dragRegion.trailingAnchor.constraint(
            equalTo: contentView.trailingAnchor,
            constant: -trailingInset
        ),
        dragRegion.topAnchor.constraint(equalTo: contentView.topAnchor),
        dragRegion.heightAnchor.constraint(equalToConstant: height)
    ])
}

private final class WindowTopDragRegion: NSView {
    override var acceptsFirstResponder: Bool { false }
    override var mouseDownCanMoveWindow: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .openHand)
    }
}
