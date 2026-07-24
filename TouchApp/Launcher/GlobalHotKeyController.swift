import Carbon
import Foundation
import TouchCore
import TouchFeatureAPI

enum LauncherShortcutPreferences {
    static let defaultShortcut = KeyboardShortcut(modifiers: [.option], key: "space")
    private static let storageKey = "launcher.global-shortcut.v1"

    static func load(defaults: UserDefaults = .standard) -> KeyboardShortcut {
        guard let data = defaults.data(forKey: storageKey),
              let shortcut = try? JSONDecoder().decode(KeyboardShortcut.self, from: data),
              shortcut.modifiers.count == 1,
              !shortcut.key.isEmpty else {
            return defaultShortcut
        }
        return shortcut
    }

    static func save(_ shortcut: KeyboardShortcut, defaults: UserDefaults = .standard) {
        guard shortcut.modifiers.count == 1,
              !shortcut.key.isEmpty,
              let data = try? JSONEncoder().encode(shortcut) else { return }
        defaults.set(data, forKey: storageKey)
        NotificationCenter.default.post(name: .launcherShortcutDidChange, object: shortcut)
    }
}

extension Notification.Name {
    static let launcherShortcutDidChange = Notification.Name("me.touch.launcher-shortcut-did-change")
}

@MainActor
final class GlobalHotKeyController {
    private static let hotKeySignature = OSType(0x544F5543)
    private let identifier: UInt32
    private var eventHandler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?
    private var onPress: (@MainActor () -> Void)?

    init(identifier: UInt32 = 1) {
        self.identifier = identifier
    }

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

        let hotKeyIdentifier = EventHotKeyID(signature: Self.hotKeySignature, id: identifier)
        let registerStatus = RegisterEventHotKey(value.keyCode, value.modifiers, hotKeyIdentifier, GetApplicationEventTarget(), 0, &hotKey)
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

    private static let handleHotKey: EventHandlerUPP = { _, event, userData in
        guard let userData else { return noErr }
        let controller = Unmanaged<GlobalHotKeyController>.fromOpaque(userData).takeUnretainedValue()

        // Every controller listens for the same kEventHotKeyPressed event
        // class on the application target. Read the event's identifier before
        // dispatching so pressing one shortcut cannot trigger all actions.
        var hotKeyIdentifier = EventHotKeyID()
        let parameterStatus = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyIdentifier
        )
        guard parameterStatus == noErr,
              hotKeyIdentifier.signature == GlobalHotKeyController.hotKeySignature,
              hotKeyIdentifier.id == controller.identifier else {
            // Other controllers listen on the same target. Let the event
            // continue through the handler chain until its owner sees it.
            return OSStatus(eventNotHandledErr)
        }

        Task { @MainActor in
            controller.onPress?()
        }
        return noErr
    }
}
