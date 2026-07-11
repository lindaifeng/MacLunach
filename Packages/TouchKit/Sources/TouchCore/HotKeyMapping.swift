import Carbon
import TouchFeatureAPI

public struct CarbonHotKeyValue: Equatable, Sendable {
    public let keyCode: UInt32
    public let modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

public enum HotKeyMappingError: Error, Equatable {
    case unsupportedKey(String)
}

public enum HotKeyMapping {
    public static func carbonValue(for shortcut: KeyboardShortcut) throws -> CarbonHotKeyValue {
        let keyCode: UInt32
        switch shortcut.key {
        case "space": keyCode = 49
        case "a": keyCode = 0
        case "b": keyCode = 11
        case "c": keyCode = 8
        case "d": keyCode = 2
        case "e": keyCode = 14
        case "f": keyCode = 3
        case "g": keyCode = 5
        case "h": keyCode = 4
        case "i": keyCode = 34
        case "j": keyCode = 38
        case "k": keyCode = 40
        case "l": keyCode = 37
        case "m": keyCode = 46
        case "n": keyCode = 45
        case "o": keyCode = 31
        case "p": keyCode = 35
        case "q": keyCode = 12
        case "r": keyCode = 15
        case "s": keyCode = 1
        case "t": keyCode = 17
        case "u": keyCode = 32
        case "v": keyCode = 9
        case "w": keyCode = 13
        case "x": keyCode = 7
        case "y": keyCode = 16
        case "z": keyCode = 6
        case "0": keyCode = 29
        case "1": keyCode = 18
        case "2": keyCode = 19
        case "3": keyCode = 20
        case "4": keyCode = 21
        case "5": keyCode = 23
        case "6": keyCode = 22
        case "7": keyCode = 26
        case "8": keyCode = 28
        case "9": keyCode = 25
        default: throw HotKeyMappingError.unsupportedKey(shortcut.key)
        }

        var modifiers: UInt32 = 0
        if shortcut.modifiers.contains(.command) { modifiers |= UInt32(cmdKey) }
        if shortcut.modifiers.contains(.option) { modifiers |= UInt32(optionKey) }
        if shortcut.modifiers.contains(.control) { modifiers |= UInt32(controlKey) }
        if shortcut.modifiers.contains(.shift) { modifiers |= UInt32(shiftKey) }
        return .init(keyCode: keyCode, modifiers: modifiers)
    }
}
