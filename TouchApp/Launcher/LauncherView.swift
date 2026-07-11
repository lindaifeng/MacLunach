import SwiftUI

struct LauncherView: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var mode: SearchMode = .applications
    @State private var query = ""

    private var palette: ThemePalette { .palette(for: themeStore.theme) }

    var body: some View {
        ZStack {
            GlassBackground(
                theme: themeStore.theme,
                reduceTransparency: reduceTransparency || CommandLine.arguments.contains("--reduce-transparency")
            )
            palette.tint

            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(.linearGradient(colors: [palette.primaryText, palette.accent], startPoint: .top, endPoint: .bottom))
                    Text("触达")
                        .font(.system(size: 32, weight: .bold))
                    Text("心之所想，一触即达")
                        .font(.system(size: 18, weight: .medium))
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
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(palette.primaryText)
                .padding(.horizontal, 58)
                .padding(.top, 46)

                SearchBarView(mode: $mode, query: $query, palette: palette)
                .padding(.top, 104)
                .padding(.horizontal, 190)

                FeatureGridView(palette: palette)
                .padding(.top, 100)

                Spacer()
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 36))
        .overlay(RoundedRectangle(cornerRadius: 36).stroke(palette.border, lineWidth: 1))
        .padding(1)
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
