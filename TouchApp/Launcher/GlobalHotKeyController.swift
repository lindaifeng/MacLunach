import Carbon
import TouchCore
import TouchFeatureAPI

@MainActor
final class GlobalHotKeyController {
    private var eventHandler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?
    private var onPress: (@MainActor () -> Void)?

    func start(shortcut: KeyboardShortcut, onPress: @escaping @MainActor () -> Void) throws {
        stop()

        let value = try HotKeyMapping.carbonValue(for: shortcut)
        self.onPress = onPress

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            Self.handleHotKey,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
        guard installStatus == noErr else {
            throw NSError(domain: "Touch.GlobalHotKey", code: Int(installStatus))
        }

        let identifier = EventHotKeyID(signature: OSType(0x544F5543), id: 1)
        let registerStatus = RegisterEventHotKey(value.keyCode, value.modifiers, identifier, GetApplicationEventTarget(), 0, &hotKey)
        guard registerStatus == noErr else {
            stop()
            throw NSError(domain: "Touch.GlobalHotKey", code: Int(registerStatus))
        }
    }

    func stop() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        hotKey = nil
        eventHandler = nil
        onPress = nil
    }

    private static let handleHotKey: EventHandlerUPP = { _, _, userData in
        guard let userData else { return noErr }
        let controller = Unmanaged<GlobalHotKeyController>.fromOpaque(userData).takeUnretainedValue()
        Task { @MainActor in
            controller.onPress?()
        }
        return noErr
    }
}
