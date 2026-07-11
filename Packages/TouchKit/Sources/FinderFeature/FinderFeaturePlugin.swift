import AppKit
import TouchFeatureAPI

public struct FinderFeaturePlugin: FeaturePlugin {
    public init() {}

    public let manifest = FeatureManifest(
        id: "me.touch.finder",
        name: "打开访达",
        summary: "打开 Finder",
        symbolName: "face.smiling",
        defaultOrder: 0,
        defaultShortcut: .init(modifiers: [.command], key: "1")
    )

    public func initialState() async -> FeatureState { .available }

    public func perform() async throws -> FeatureActionResult {
        _ = await MainActor.run {
            NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory()))
        }
        return .completed
    }
}
