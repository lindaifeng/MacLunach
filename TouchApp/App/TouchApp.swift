import SwiftUI

@main
struct TouchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsRootView()
                .environmentObject(FeatureAreaStore.shared)
                .frame(minWidth: 760, minHeight: 540)
        }
    }
}
