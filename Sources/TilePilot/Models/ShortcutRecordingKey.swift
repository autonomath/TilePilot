import AppKit

enum ShortcutRecordingKey {
    static func combo(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, unmodifiedCharacters: String?) -> String? {
        // Modifier-only events are not shortcuts. Other physical keys can always
        // use skhd's hexadecimal syntax, including keypad and non-US keys.
        guard keyCode < 128, !(54...63).contains(keyCode) else { return nil }
        let literal = literalKeys[keyCode]
        let token = literal ?? characterToken(keyCode: keyCode, characters: unmodifiedCharacters)
            ?? String(format: "0x%02X", keyCode)

        var names: [String] = []
        if modifiers.contains(.control) { names.append("ctrl") }
        if modifiers.contains(.shift) { names.append("shift") }
        if modifiers.contains(.option) { names.append("alt") }
        if modifiers.contains(.command) { names.append("cmd") }
        // skhd adds Fn implicitly to navigation and F-key literals.
        if modifiers.contains(.function), !implicitFunctionKeys.contains(keyCode) { names.append("fn") }
        return names.isEmpty ? token : "\(names.joined(separator: " + ")) - \(token)"
    }

    static func cancelsRecording(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        keyCode == 53 && modifiers.intersection([.control, .shift, .option, .command, .function]).isEmpty
    }

    private static func characterToken(keyCode: UInt16, characters: String?) -> String? {
        // skhd resolves character bindings through the current keyboard layout,
        // but excludes the keypad and accepts only one-byte characters.
        guard printableKeyCodes.contains(keyCode), let characters, characters.utf8.count == 1 else { return nil }
        let token = characters.lowercased()
        // Punctuation is grammar in skhd (or an unknown token), never a
        // character key. Hex digits also need uppercase A–F in its tokenizer.
        guard "abcdefghijklmnopqrstuvwxyz0123456789".contains(token) else { return nil }
        return token
    }

    private static let printableKeyCodes: Set<UInt16> = Set(0...50).subtracting([36, 48, 49])
    private static let literalKeys: [UInt16: String] = [
        36: "return", 48: "tab", 49: "space", 51: "backspace", 53: "escape",
        64: "f17", 79: "f18", 80: "f19", 90: "f20",
        96: "f5", 97: "f6", 98: "f7", 99: "f3", 100: "f8", 101: "f9", 103: "f11",
        105: "f13", 106: "f16", 107: "f14", 109: "f10", 111: "f12", 113: "f15",
        114: "insert", 115: "home", 116: "pageup", 117: "delete", 118: "f4", 119: "end",
        120: "f2", 121: "pagedown", 122: "f1", 123: "left", 124: "right", 125: "down", 126: "up",
    ]
    private static let implicitFunctionKeys = Set(literalKeys.keys).subtracting([36, 48, 49, 51, 53])
}
