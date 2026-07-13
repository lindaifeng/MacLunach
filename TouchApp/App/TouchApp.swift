import SwiftUI

@main
struct TouchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsRootView(searchEnvironment: appDelegate.searchEnvironment)
                .environmentObject(appDelegate.featureStore)
                .environmentObject(appDelegate.screenshotEnvironment)
                .frame(minWidth: 760, minHeight: 540)
        }
    }
}
