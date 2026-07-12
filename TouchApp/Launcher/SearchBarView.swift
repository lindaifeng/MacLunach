import SwiftUI

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

            SearchQueryField(text: $query)
                .frame(maxWidth: .infinity, minHeight: 24)
        }
        .padding(.horizontal, 22)
        .frame(height: 64)
        .background(palette.cardFill, in: Capsule())
        .overlay(Capsule().stroke(palette.border, lineWidth: 1))
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
