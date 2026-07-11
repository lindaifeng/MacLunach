import SwiftUI
import TouchFeatureAPI
import FinderFeature
import ScreenshotFeature
import SuperRightFeature

struct LauncherView: View {
    private let plugins: [any FeaturePlugin] = [
        FinderFeaturePlugin(),
        ScreenshotFeaturePlugin(),
        SuperRightFeaturePlugin()
    ]

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.10, green: 0.16, blue: 0.29), Color(red: 0.28, green: 0.35, blue: 0.56)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(.linearGradient(colors: [.white, .indigo], startPoint: .top, endPoint: .bottom))
                    Text("触达")
                        .font(.system(size: 32, weight: .bold))
                    Text("心之所想，一触即达")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.white.opacity(0.65))
                    Spacer()
                    Image(systemName: "paintpalette")
                    Divider().frame(height: 26)
                    Image(systemName: "gearshape")
                }
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 58)
                .padding(.top, 46)

                HStack(spacing: 14) {
                    Image(systemName: "magnifyingglass")
                    Text("应用")
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.indigo.opacity(0.8), in: Capsule())
                    Text("文件").foregroundStyle(.white.opacity(0.7))
                    Text("Tab 切换").foregroundStyle(.white.opacity(0.5))
                    Divider().frame(height: 22)
                    Text("搜索应用、文件、动作")
                        .foregroundStyle(.white.opacity(0.55))
                    Spacer()
                }
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 24)
                .frame(height: 64)
                .background(.white.opacity(0.14), in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.26), lineWidth: 1))
                .padding(.top, 104)
                .padding(.horizontal, 190)

                HStack(spacing: 24) {
                    ForEach(plugins, id: \.manifest.id) { plugin in
                        Button {
                            Task { _ = try? await plugin.perform() }
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: plugin.manifest.symbolName)
                                    .font(.system(size: 27, weight: .medium))
                                    .frame(width: 40)
                                Text(plugin.manifest.name)
                                    .font(.system(size: 19, weight: .semibold))
                                Spacer()
                                Text(plugin.manifest.defaultShortcut.displayValue)
                                    .font(.system(size: 15, weight: .medium, design: .monospaced))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(.white.opacity(0.11), in: RoundedRectangle(cornerRadius: 8))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 22)
                            .frame(width: 260, height: 86)
                            .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 20))
                            .overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.26), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 100)

                Spacer()
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 36))
        .overlay(RoundedRectangle(cornerRadius: 36).stroke(.white.opacity(0.45), lineWidth: 1))
        .padding(1)
        .accessibilityIdentifier("launcher.root")
    }
}
