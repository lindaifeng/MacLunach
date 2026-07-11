import AppKit
import SwiftUI
import TouchCore

struct GlassBackground: NSViewRepresentable {
    let theme: TouchTheme
    let reduceTransparency: Bool

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = true
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = reduceTransparency ? .windowBackground : material
    }

    private var material: NSVisualEffectView.Material {
        switch theme {
        case .crystal: .underWindowBackground
        case .obsidian: .hudWindow
        case .amber: .sidebar
        }
    }
}
