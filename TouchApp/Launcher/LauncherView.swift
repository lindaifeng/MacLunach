import SwiftUI

struct LauncherView: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ObservedObject var searchCoordinator: SearchCoordinator

    private var palette: ThemePalette { .palette(for: themeStore.theme) }

    var body: some View {
        ZStack {
            GlassBackground(
                theme: themeStore.theme,
                reduceTransparency: reduceTransparency || CommandLine.arguments.contains("--reduce-transparency")
            )
            palette.tint

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 29, weight: .semibold))
                        .foregroundStyle(.linearGradient(colors: [palette.primaryText, palette.accent], startPoint: .top, endPoint: .bottom))
                    Text("触达")
                        .font(.system(size: 28, weight: .bold))
                    Text("心之所想，一触即达")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(palette.secondaryText)
                    Spacer()
                    Button { themeStore.cycle() } label: { Image(systemName: "paintpalette") }
                        .buttonStyle(.plain)
                        .accessibilityLabel("切换主题")
                        .accessibilityIdentifier("theme.switch")
                    Divider().frame(height: 26)
                    Button {
                        NotificationCenter.default.post(name: .openTouchSettings, object: nil)
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("打开设置")
                        .accessibilityIdentifier("launcher.settings")
                }
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(palette.primaryText)
                .padding(.horizontal, 48)
                .padding(.top, 36)

                SearchBarView(
                    mode: $searchCoordinator.mode,
                    query: $searchCoordinator.query,
                    palette: palette
                )
                .frame(width: 760)
                .padding(.top, 70)

                if searchCoordinator.query.isEmpty {
                    FeatureGridView(palette: palette)
                        .padding(.top, 54)
                        .transition(.opacity)
                } else {
                    SearchResultsView(coordinator: searchCoordinator, palette: palette)
                        .frame(width: 760)
                        .padding(.top, 18)
                        .transition(.opacity)
                }

                Spacer()
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 32, style: .continuous).stroke(palette.border, lineWidth: 1))
        .padding(1)
        .animation(.easeInOut(duration: 0.08), value: searchCoordinator.query.isEmpty)
        .onAppear(perform: finishPerformanceIntervalAfterRender)
        .onReceive(NotificationCenter.default.publisher(for: .touchLauncherWillDisplay)) { _ in
            finishPerformanceIntervalAfterRender()
        }
    }

    private func finishPerformanceIntervalAfterRender() {
        DispatchQueue.main.async {
            LaunchPerformanceRecorder.shared.endAfterRenderedFrame()
        }
    }
}
