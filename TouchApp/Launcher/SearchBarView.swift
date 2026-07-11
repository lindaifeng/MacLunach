import SwiftUI

extension Notification.Name {
    static let toggleTouchSearchMode = Notification.Name("me.touch.toggle-search-mode")
}

enum SearchMode: String, CaseIterable {
    case applications = "应用"
    case files = "文件"
}

struct SearchBarView: View {
    @Binding var mode: SearchMode
    @Binding var query: String
    let palette: ThemePalette

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 23, weight: .medium))

            modeButton(.applications)
            modeButton(.files)

            Text("Tab 切换")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(palette.secondaryText)
                .padding(.leading, 4)

            Divider().frame(height: 22)

            TextField("搜索应用、文件、动作", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(palette.primaryText)
                .accessibilityIdentifier("search.query")
        }
        .padding(.horizontal, 22)
        .frame(height: 64)
        .background(palette.cardFill, in: Capsule())
        .overlay(Capsule().stroke(palette.border, lineWidth: 1))
        .onKeyPress(.tab) {
            mode = mode == .applications ? .files : .applications
            return .handled
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleTouchSearchMode)) { _ in
            mode = mode == .applications ? .files : .applications
        }
    }

    private func modeButton(_ item: SearchMode) -> some View {
        Button(item.rawValue) { mode = item }
            .buttonStyle(.plain)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(palette.primaryText)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(mode == item ? palette.accent.opacity(0.82) : .clear, in: Capsule())
            .accessibilityIdentifier(item == .applications ? "search.mode.application" : "search.mode.file")
            .accessibilityAddTraits(mode == item ? .isSelected : [])
    }
}
