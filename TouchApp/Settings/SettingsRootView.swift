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
        case .about: "关于触达"
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
    @ObservedObject var searchEnvironment: SearchEnvironment
    @ObservedObject var navigation: SettingsNavigationModel

    init(
        searchEnvironment: SearchEnvironment,
        navigation: SettingsNavigationModel = SettingsNavigationModel()
    ) {
        self.searchEnvironment = searchEnvironment
        self.navigation = navigation
    }

    var body: some View {
        NavigationSplitView {
            List {
                ForEach(TouchSettingsSection.allCases) { item in
                    Button {
                        navigation.section = item
                        navigation.featureID = nil
                    } label: {
                        Label(item.title, systemImage: item.symbol)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 5)
                    .accessibilityIdentifier(item.accessibilityIdentifier)
                }
            }
            .navigationTitle("触达设置")
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 230)
        } detail: {
            settingsDetail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private var settingsDetail: some View {
        if navigation.section == .search {
            FileIndexSettingsView(environment: searchEnvironment)
        } else if navigation.section == .featureArea {
            if let featureID = navigation.featureID {
                FeatureDetailSettingsView(featureID: featureID) {
                    navigation.featureID = nil
                }
            } else {
                FeatureAreaSettingsView { featureID in
                    navigation.featureID = featureID
                }
            }
        } else {
            GeneralSettingsView(section: navigation.section)
        }
    }
}
