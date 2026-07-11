import Testing
import TouchFeatureAPI
@testable import TouchCore

@Test func optionSpaceMapsToCarbonValues() throws {
    let value = try HotKeyMapping.carbonValue(for: .init(modifiers: [.option], key: "space"))

    #expect(value.keyCode == 49)
    #expect(value.modifiers != 0)
}

@Test func unsupportedKeyIsRejected() {
    #expect(throws: HotKeyMappingError.unsupportedKey("💡")) {
        try HotKeyMapping.carbonValue(for: .init(modifiers: [.option], key: "💡"))
    }
}
