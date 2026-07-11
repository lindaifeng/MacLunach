import Testing
@testable import TouchFeatureAPI

@Test func manifestIdentityIsStable() {
    let manifest = FeatureManifest(
        id: "me.touch.finder",
        name: "打开访达",
        summary: "打开 Finder",
        symbolName: "face.smiling",
        defaultOrder: 0,
        defaultShortcut: .init(modifiers: [.command], key: "1")
    )

    #expect(manifest.id == "me.touch.finder")
    #expect(manifest.defaultShortcut.displayValue == "⌘1")
}

@Test func stateDescribesAvailability() {
    #expect(FeatureState.available.isSelectable)
    #expect(!FeatureState.disabled.isSelectable)
    #expect(!FeatureState.failed(message: "服务异常").isSelectable)
}
