import SwiftUI

enum SearchMode: String, CaseIterable {
    case actions = "动作"
    case applications = "应用"
    case files = "文件"
}

struct SearchBarView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var mode: SearchMode
    @Binding var query: String
    @Binding var isFocused: Bool
    @ObservedObject var diagnostics: SearchDiagnostics
    let theme: ThemeDefinition

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 21, weight: .medium))
                .frame(width: 28)
                .padding(.trailing, 14)

            HStack(alignment: .center, spacing: 6) {
                modeButton(.actions)
                modeButton(.applications)
                modeButton(.files)
            }
            .frame(height: 60, alignment: .center)

            Divider()
                .frame(height: 22)
                .padding(.horizontal, 16)

            SearchQueryField(
                text: $query,
                isFocused: $isFocused,
                textColor: theme.text.secondary.nsColor,
                placeholderColor: theme.search.placeholder.nsColor,
                placeholder: mode == .actions ? "搜索动作" : "搜索应用、文件"
            )
                .frame(maxWidth: .infinity, minHeight: 30, maxHeight: 30)
                .contentShape(Rectangle())
                .simultaneousGesture(
                    TapGesture().onEnded {
                        isFocused = true
                    }
                )

            HStack(spacing: 12) {
                if mode == .files, diagnostics.isActivelyIndexing {
                    SearchIndexProgressIndicator(
                        progress: diagnostics.indexingProgress ?? 0,
                        rootName: diagnostics.indexingRootName,
                        theme: theme
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }

                Text("Tab 切换")
                    .font(.system(size: 11, weight: .medium))
                    .tracking(0.2)
                    .foregroundStyle(theme.text.weak.color)
                    .fixedSize()
                    .accessibilityIdentifier("search.hint.tab")
            }
            .padding(.leading, 16)
        }
        .padding(.horizontal, 20)
        .frame(height: 60)
        .foregroundStyle(theme.text.secondary.color)
        .background(theme.search.fill.color, in: searchShape)
        .shadow(
            color: theme.search.shadow.color.color,
            radius: theme.search.shadow.radius,
            x: theme.search.shadow.x,
            y: theme.search.shadow.y
        )
        .overlay {
            searchShape
                .stroke(isFocused ? theme.search.focusedBorder.color : theme.search.border.color, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .overlay {
            if isFocused {
                searchShape.stroke(theme.search.focusRing.color, lineWidth: 4)
                    .padding(-3)
                    .allowsHitTesting(false)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: theme.motion.duration), value: isFocused)
    }

    private func modeButton(_ item: SearchMode) -> some View {
        Button {
            mode = item
            isFocused = item != .actions
        } label: {
            Text(item.rawValue)
                .font(.system(size: 15, weight: mode == item ? .semibold : .medium))
                .foregroundStyle(mode == item ? theme.accent.color : theme.text.secondary.color)
                .frame(width: 38, height: 30, alignment: .center)
                .contentShape(Rectangle())
        }
            .buttonStyle(.plain)
            .accessibilityIdentifier(accessibilityIdentifier(for: item))
            .accessibilityAddTraits(mode == item ? .isSelected : [])
            .overlay(alignment: .bottom) {
                if mode == item {
                    Capsule()
                        .fill(theme.accent.color)
                        .frame(width: 26, height: 2)
                        .allowsHitTesting(false)
                }
            }
    }

    private func accessibilityIdentifier(for item: SearchMode) -> String {
        switch item {
        case .actions: "search.mode.action"
        case .applications: "search.mode.application"
        case .files: "search.mode.file"
        }
    }

    private var searchShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: theme.search.cornerRadius, style: .continuous)
    }
}

private struct SearchIndexProgressIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rotation = Angle.zero

    let progress: Double
    let rootName: String?
    let theme: ThemeDefinition

    var body: some View {
        HStack(spacing: 7) {
            ZStack {
                Circle()
                    .stroke(theme.text.weak.color.opacity(0.28), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: max(0.06, min(progress, 1)))
                    .stroke(
                        theme.accent.color,
                        style: StrokeStyle(lineWidth: 2, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))

                Circle()
                    .stroke(theme.text.weak.color.opacity(0.18), lineWidth: 1.5)
                    .frame(width: 9, height: 9)
                Circle()
                    .trim(from: 0.06, to: 0.36)
                    .stroke(
                        theme.auxiliaryAccent.color,
                        style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
                    )
                    .frame(width: 9, height: 9)
                    .rotationEffect(rotation)
            }
            .frame(width: 18, height: 18)

            Text("\(Int((min(max(progress, 0), 1) * 100).rounded()))%")
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(theme.text.secondary.color)
                .frame(minWidth: 29, alignment: .trailing)
        }
        .help(rootName.map { "正在检索“\($0)”" } ?? "正在检索文件")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("文件检索进度")
        .accessibilityValue("\(Int((min(max(progress, 0), 1) * 100).rounded()))%")
        .accessibilityIdentifier("search.index-progress")
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                rotation = .degrees(360)
            }
        }
    }
}
