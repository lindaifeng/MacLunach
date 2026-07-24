import SwiftUI

struct LauncherView: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("launcher.feature-layout.v1") private var featureLayoutRawValue = LauncherFeatureLayout.cards.rawValue
    @ObservedObject var searchCoordinator: SearchCoordinator

    private var theme: ThemeDefinition {
        ThemeRegistry.shared.definition(for: themeStore.theme)
    }

    private var transparencyIsReduced: Bool {
        reduceTransparency || CommandLine.arguments.contains("--reduce-transparency")
    }

    var body: some View {
        ZStack {
            GlassBackground(
                theme: theme,
                reduceTransparency: transparencyIsReduced,
                themeColorOpacity: themeStore.themeColorOpacity
            )
            PanelThemeBackground(
                theme: theme,
                reduceTransparency: transparencyIsReduced,
                themeColorOpacity: themeStore.themeColorOpacity
            )

            VStack(spacing: 0) {
                ZStack {
                    // 仅由顶部空白区域接收鼠标按下；按钮和品牌文字仍保留原有交互。
                    WindowDragHandle()
                        .accessibilityHidden(true)

                    Color.clear
                        .contentShape(Rectangle())
                        .allowsHitTesting(false)
                        .accessibilityElement()
                        .accessibilityLabel("启动器标题拖动区域")
                        .accessibilityIdentifier("launcher.drag-handle")

                    HStack(spacing: 12) {
                        BrandLogoView(size: 34)
                            .shadow(color: theme.accent.color.opacity(0.10), radius: 4, y: 2)
                        HStack(alignment: .lastTextBaseline, spacing: 20) {
                            Text("一念")
                                .font(.custom("PingFangSC-Semibold", fixedSize: 29))
                                .foregroundStyle(theme.icon.brandGradient.gradient)
                            Text("所想即现")
                                .font(.custom("PingFangSC-Medium", fixedSize: 12.5))
                                .tracking(1.1)
                                .foregroundStyle(theme.text.secondary.color)
                        }
                        Spacer()
                        Button { themeStore.cycle() } label: {
                            Image(systemName: "paintpalette")
                                .themeIconControl(theme)
                        }
                            .buttonStyle(ThemePressButtonStyle(theme: theme, reduceMotion: reduceMotion))
                            .accessibilityLabel("切换主题")
                            .accessibilityIdentifier("theme.switch")
                        Divider()
                            .overlay(theme.panel.edgeBorder.color)
                            .frame(height: 26)
                        Button {
                            NotificationCenter.default.post(name: .openTouchSettings, object: nil)
                        } label: {
                            Image(systemName: "gearshape")
                                .themeIconControl(theme)
                        }
                        .buttonStyle(ThemePressButtonStyle(theme: theme, reduceMotion: reduceMotion))
                        .accessibilityLabel("打开设置")
                        .accessibilityIdentifier("launcher.settings")
                    }
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(theme.icon.neutral.color)
                    .padding(.horizontal, 58)
                    .padding(.top, 22)
                }
                // AppKit 拖动手柄没有固有尺寸；限定为原始标题高度，防止它在 VStack 中撑开。
                .frame(height: 62, alignment: .bottom)

                SearchBarView(
                    mode: $searchCoordinator.mode,
                    query: $searchCoordinator.query,
                    isFocused: $searchCoordinator.isSearchFieldFocused,
                    diagnostics: searchCoordinator.diagnostics,
                    theme: theme
                )
                .frame(width: 860)
                .padding(.top, 32)

                if searchCoordinator.query.isEmpty {
                    Group {
                        if featureLayout == .cards {
                            FeatureGridView(theme: theme)
                                .padding(.top, 28)
                        } else {
                            FeatureKeyboardView(theme: theme)
                                .padding(.top, 24)
                        }
                    }
                        .id(featureLayout)
                        .transition(.opacity)
                } else {
                    SearchResultsView(coordinator: searchCoordinator, theme: theme)
                        .frame(width: 860)
                        .padding(.top, 16)
                        .transition(.opacity)
                }

                Spacer()

                if searchCoordinator.query.isEmpty {
                    LauncherLayoutSwitcher(selection: featureLayoutBinding, theme: theme)
                        .padding(.bottom, 14)
                        .transition(.opacity)
                }
            }
        }
        .clipShape(panelShape)
        .overlay(panelShape.stroke(theme.panel.edgeBorder.color, lineWidth: 1))
        .overlay(panelShape.stroke(theme.panel.highlight.color, lineWidth: 1).padding(1))
        .shadow(
            color: theme.panel.shadow.color.color,
            radius: theme.panel.shadow.radius,
            x: theme.panel.shadow.x,
            y: theme.panel.shadow.y
        )
        .padding(1)
        .animation(.easeInOut(duration: 0.08), value: searchCoordinator.query.isEmpty)
        .onAppear(perform: finishPerformanceIntervalAfterRender)
        .onReceive(NotificationCenter.default.publisher(for: .touchLauncherWillDisplay)) { _ in
            finishPerformanceIntervalAfterRender()
        }
    }

    private var panelShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: theme.panel.cornerRadius, style: .continuous)
    }

    private var featureLayout: LauncherFeatureLayout {
        LauncherFeatureLayout(rawValue: featureLayoutRawValue) ?? .cards
    }

    private var featureLayoutBinding: Binding<LauncherFeatureLayout> {
        Binding(
            get: { featureLayout },
            set: { featureLayoutRawValue = $0.rawValue }
        )
    }

    private func finishPerformanceIntervalAfterRender() {
        DispatchQueue.main.async {
            LaunchPerformanceRecorder.shared.endAfterRenderedFrame()
        }
    }
}
