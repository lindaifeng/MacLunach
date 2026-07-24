import SwiftUI

enum TouchSettingsSection: String, CaseIterable, Identifiable {
    case general
    case search
    case featureArea
    case appearance
    case permissions
    case update
    case privacy
    case about

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "通用"
        case .search: "搜索"
        case .featureArea: "功能区"
        case .appearance: "外观"
        case .permissions: "权限"
        case .update: "更新"
        case .privacy: "隐私与存储"
        case .about: "关于一念"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .search: "magnifyingglass"
        case .featureArea: "square.grid.2x2"
        case .appearance: "paintpalette"
        case .permissions: "checkmark.shield"
        case .update: "arrow.triangle.2.circlepath"
        case .privacy: "externaldrive"
        case .about: "info.circle"
        }
    }

    var accessibilityIdentifier: String {
        "settings.\(rawValue.replacingOccurrences(of: "A", with: "-a").lowercased())"
    }
}

struct TouchSettingsDestination {
    let section: TouchSettingsSection
    let featureID: String?

    init(section: TouchSettingsSection, featureID: String? = nil) {
        self.section = section
        self.featureID = featureID
    }
}

@MainActor
final class SettingsNavigationModel: ObservableObject {
    @Published var section: TouchSettingsSection
    @Published var featureID: String?

    init(section: TouchSettingsSection = .general, featureID: String? = nil) {
        self.section = section
        self.featureID = featureID
    }

    func navigate(to destination: TouchSettingsDestination) {
        section = destination.section
        featureID = destination.featureID
    }
}

struct SettingsRootView: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ObservedObject var searchEnvironment: SearchEnvironment
    @ObservedObject var navigation: SettingsNavigationModel

    init(
        searchEnvironment: SearchEnvironment,
        navigation: SettingsNavigationModel = SettingsNavigationModel()
    ) {
        self.searchEnvironment = searchEnvironment
        self.navigation = navigation
    }

    private var theme: ThemeDefinition {
        ThemeRegistry.shared.definition(for: themeStore.theme)
    }

    var body: some View {
        ZStack {
            GlassBackground(
                theme: theme,
                reduceTransparency: reduceTransparency,
                themeColorOpacity: themeStore.themeColorOpacity
            )
            PanelThemeBackground(
                theme: theme,
                reduceTransparency: reduceTransparency,
                themeColorOpacity: themeStore.themeColorOpacity
            )

            HStack(spacing: 0) {
                sidebar
                    .frame(width: 196)
                SettingsDivider(theme: theme)
                    .frame(width: 1)
                ScrollView {
                    settingsDetail
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 30)
                        .padding(.vertical, 26)
                }
                .id("\(navigation.section.rawValue):\(navigation.featureID ?? "root")")
                .scrollIndicators(.hidden)
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .tint(theme.accent.color)
        .preferredColorScheme(settingsColorScheme)
    }

    private var settingsColorScheme: ColorScheme? {
        switch themeStore.theme {
        case .night, .graphite:
            return .dark
        case .day:
            return .light
        case .defaultGlass:
            return nil
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                WindowDragHandle()
                    .accessibilityHidden(true)
                HStack(spacing: 8) {
                    BrandLogoView(size: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("一念")
                            .font(.custom("PingFangSC-Semibold", fixedSize: 17))
                            .foregroundStyle(theme.icon.brandGradient.gradient)
                        Text("偏好设置")
                            .font(.custom("PingFangSC-Medium", fixedSize: 10.5))
                            .foregroundStyle(theme.text.secondary.color)
                    }
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 27)
            }
            .frame(height: 84)
            .accessibilityIdentifier("settings.drag-handle")

            VStack(spacing: 3) {
                ForEach(TouchSettingsSection.allCases) { item in
                    sidebarItem(item)
                }
            }
            .padding(.horizontal, 10)

            Spacer()
        }
        .background(theme.panel.tint.color.opacity(0.22 * themeStore.themeColorOpacity))
    }

    private func sidebarItem(_ item: TouchSettingsSection) -> some View {
        let isSelected = navigation.section == item
        return Button {
            navigation.section = item
            navigation.featureID = nil
        } label: {
            HStack(spacing: 10) {
                Image(systemName: item.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 17)
                Text(item.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                Spacer()
            }
            .foregroundStyle(isSelected ? theme.accent.color : theme.text.secondary.color)
            .padding(.horizontal, 11)
            .frame(maxWidth: .infinity, minHeight: 35, maxHeight: 35, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                isSelected ? theme.accent.color.opacity(0.13) : .clear,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay(alignment: .leading) {
                if isSelected {
                    Capsule()
                        .fill(theme.accent.color)
                        .frame(width: 2, height: 18)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .buttonStyle(.plain)
        .accessibilityIdentifier(item.accessibilityIdentifier)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var settingsDetail: some View {
        if navigation.section == .search {
            FileIndexSettingsView(environment: searchEnvironment, theme: theme)
        } else if navigation.section == .featureArea {
            if let featureID = navigation.featureID {
                FeatureDetailSettingsView(
                    featureID: featureID,
                    theme: theme,
                    onBack: {
                        navigation.featureID = nil
                    },
                    onOpenPermissions: {
                        navigation.navigate(to: TouchSettingsDestination(section: .permissions))
                    }
                )
            } else {
                FeatureAreaSettingsView(theme: theme) { featureID in
                    navigation.featureID = featureID
                }
            }
        } else {
            GeneralSettingsView(section: navigation.section, theme: theme)
        }
    }
}
