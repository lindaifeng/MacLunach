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
        HStack(spacing: 0) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 21, weight: .medium))
                .frame(width: 28)
                .padding(.trailing, 14)

            HStack(alignment: .center, spacing: 6) {
                modeButton(.applications)
                modeButton(.files)
            }
            .frame(height: 60, alignment: .center)

            Text("Tab 切换")
                .font(.system(size: 11, weight: .medium))
                .tracking(0.2)
                .foregroundStyle(.white.opacity(0.56))
                .fixedSize()
                .padding(.leading, 10)
                .accessibilityIdentifier("search.hint.tab")

            Divider()
                .frame(height: 22)
                .padding(.horizontal, 16)

            SearchQueryField(text: $query)
                .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28)
        }
        .padding(.horizontal, 20)
        .frame(height: 60)
        .background(palette.cardFill, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(palette.border, lineWidth: 1)
        }
    }

    private func modeButton(_ item: SearchMode) -> some View {
        Button {
            mode = item
        } label: {
            Text(item.rawValue)
                .font(.system(size: 15, weight: mode == item ? .semibold : .medium))
                .foregroundStyle(mode == item ? palette.primaryText : palette.secondaryText)
                .frame(width: 38, height: 30, alignment: .center)
                .contentShape(Rectangle())
        }
            .buttonStyle(.plain)
            .accessibilityIdentifier(item == .applications ? "search.mode.application" : "search.mode.file")
            .accessibilityAddTraits(mode == item ? .isSelected : [])
    }
}
