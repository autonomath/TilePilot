import AppKit
import CoreGraphics
import Foundation

/// The four shortcut modifiers. Caps Lock and Fn never change which key a layer matches.
struct KeyboardLayerModifiers: OptionSet, Codable, Hashable, Sendable {
    let rawValue: UInt8

    init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    static let control = KeyboardLayerModifiers(rawValue: 1 << 0)
    static let option = KeyboardLayerModifiers(rawValue: 1 << 1)
    static let shift = KeyboardLayerModifiers(rawValue: 1 << 2)
    static let command = KeyboardLayerModifiers(rawValue: 1 << 3)
    static let hyper: KeyboardLayerModifiers = [.control, .option, .shift, .command]

    /// Each modifier with its event flag, symbol, and name, in macOS order: ⌃⌥⇧⌘.
    private static let table: [(modifier: KeyboardLayerModifiers, flag: CGEventFlags, symbol: String, word: String)] = [
        (.control, .maskControl, "⌃", "Control"),
        (.option, .maskAlternate, "⌥", "Option"),
        (.shift, .maskShift, "⇧", "Shift"),
        (.command, .maskCommand, "⌘", "Command"),
    ]

    init(_ flags: CGEventFlags) {
        self.init(Self.table.filter { flags.contains($0.flag) }.map(\.modifier))
    }

    /// NSEvent uses the same bits as CGEventFlags for these four modifiers.
    init(_ flags: NSEvent.ModifierFlags) {
        self.init(CGEventFlags(rawValue: UInt64(flags.rawValue)))
    }

    private var entries: [(modifier: KeyboardLayerModifiers, flag: CGEventFlags, symbol: String, word: String)] {
        Self.table.filter { contains($0.modifier) }
    }

    var cgEventFlags: CGEventFlags { CGEventFlags(entries.map(\.flag)) }
    var symbols: String { entries.map(\.symbol).joined() }
    var words: [String] { entries.map(\.word) }
}

/// A physical key plus the exact modifiers held with it.
struct KeyboardLayerChord: Codable, Hashable, Sendable {
    var keyCode: UInt16
    var modifiers: KeyboardLayerModifiers = []
}

/// A key recorded for a layer, with the label shown for it.
struct KeyboardLayerKey: Codable, Hashable, Sendable {
    var keyCode: UInt16
    var modifiers: KeyboardLayerModifiers
    var keyLabel: String

    var chord: KeyboardLayerChord { KeyboardLayerChord(keyCode: keyCode, modifiers: modifiers) }
    var symbols: String { modifiers.symbols + keyLabel }
    var spelledOut: String { (modifiers.words + [keyLabel]).joined(separator: " + ") }

    static func label(keyCode: UInt16, characters: String?) -> String {
        if let name = namedKeys[keyCode] { return name }
        if let characters, characters.count == 1,
           let scalar = characters.unicodeScalars.first,
           !CharacterSet.controlCharacters.contains(scalar),
           !CharacterSet.whitespacesAndNewlines.contains(scalar) {
            let label = characters.uppercased()
            return keypadKeyCodes.contains(keyCode) ? "Keypad \(label)" : label
        }
        return "Key \(keyCode)"
    }

    private static let modifierKeyCodes: Set<UInt16> = Set(54...63)
    private static let keypadKeyCodes: Set<UInt16> = [65, 67, 69, 75, 78, 81, 82, 83, 84, 85, 86, 87, 88, 89, 91, 92]
    private static let namedKeys: [UInt16: String] = [
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 71: "⌧", 76: "⌤", 117: "⌦",
        115: "↖", 119: "↘", 116: "⇞", 121: "⇟", 123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
    ]
}

extension KeyboardLayerKey {
    /// Returns nil for modifier keys, which can't be a layer key or a shortcut on their own.
    init?(keyCode: UInt16, modifiers: KeyboardLayerModifiers, characters: String?) {
        guard keyCode < 128, !Self.modifierKeyCodes.contains(keyCode) else { return nil }
        self.init(keyCode: keyCode, modifiers: modifiers, keyLabel: Self.label(keyCode: keyCode, characters: characters))
    }
}

struct KeyboardLayerApp: Codable, Hashable, Sendable {
    var bundleID: String?
    var name: String
    var path: String
}

extension KeyboardLayerApp {
    init(url: URL) {
        var name = FileManager.default.displayName(atPath: url.path)
        if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
        self.init(bundleID: Bundle(url: url)?.bundleIdentifier, name: name, path: url.path)
    }
}

enum KeyboardLayerAction: Codable, Hashable, Sendable {
    /// A TilePilot feature from the Actions & Shortcuts catalog. The title is kept for display
    /// after the feature (a template or Work Set) is deleted.
    case feature(id: String, title: String)
    case openApp(KeyboardLayerApp)
    case sendShortcut(KeyboardLayerKey)
    /// An entry in `KeyboardLayerActionCatalog`, such as Snap Left Half or Volume Up. The title is
    /// kept for display if a later version drops the entry.
    case builtIn(id: String, title: String)
    /// A block of text, pasted into the front app.
    case typeText(String)
    case openURL(String)
    /// A file or folder.
    case openPath(String)
    /// A shortcut from Apple's Shortcuts app, by name.
    case runAppleShortcut(name: String)
    /// A shell command, typed in or taken from skhdrc (which supplies the title).
    case runCommand(command: String, title: String?)
}

struct KeyboardLayerBinding: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var key: KeyboardLayerKey?
    var action: KeyboardLayerAction?
    /// What the key is for, in the user's words. Optional so older saved layers still decode.
    var note: String?

    private enum CodingKeys: String, CodingKey {
        case id, key, action, note
    }
}

extension KeyboardLayerBinding {
    /// An action this build doesn't know, saved by a newer one, reads as no action instead of
    /// failing every saved layer.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            key: try container.decodeIfPresent(KeyboardLayerKey.self, forKey: .key),
            action: try? container.decodeIfPresent(KeyboardLayerAction.self, forKey: .action),
            note: try container.decodeIfPresent(String.self, forKey: .note)
        )
    }
}

enum KeyboardLayerTrigger: String, Codable, CaseIterable, Identifiable, Sendable {
    case tab
    case capsLock
    case grave
    case backslash
    case rightClick

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tab: return "Tab"
        case .capsLock: return "Caps Lock"
        case .grave: return "` Backtick"
        case .backslash: return "\\ Backslash"
        case .rightClick: return "Right Click"
        }
    }

    var symbol: String {
        switch self {
        case .tab: return "⇥"
        case .capsLock: return "⇪"
        case .grave: return "`"
        case .backslash: return "\\"
        case .rightClick: return "🖱"
        }
    }

    /// The key code the event tap sees. TilePilot remaps Caps Lock to F18 while a Caps Lock
    /// layer is on, because macOS never reports Caps Lock as a normal key press. The right mouse
    /// button has no key code, so the tap reports it as a stand-in.
    var eventKeyCode: UInt16 {
        switch self {
        case .tab: return 48
        case .capsLock: return 79
        case .grave: return 50
        case .backslash: return 42
        case .rightClick: return KeyboardLayerEngine.rightMouseButton
        }
    }

    /// Tapping Caps Lock toggles Caps Lock; the other triggers type themselves.
    var tapsCapsLock: Bool { self == .capsLock }

    /// The same key alone in skhd syntax, for spotting skhd bindings that compete for it. skhd
    /// can't bind mouse buttons.
    var skhdCombo: String? {
        switch self {
        case .tab: return "tab"
        case .capsLock: return "f18"
        case .grave: return "0x32"
        case .backslash: return "0x2A"
        case .rightClick: return nil
        }
    }
}

enum KeyboardLayerUnboundKeys: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Keys without a binding type as usual.
    case typeNormally
    /// Keys without a binding become ⌃⌥⇧⌘ + key, like a Hyper Key.
    case sendHyper

    var id: String { rawValue }
}

/// Holding the trigger turns the layer's keys into actions.
struct KeyboardLayer: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var isEnabled = false
    var trigger: KeyboardLayerTrigger
    var unboundKeys: KeyboardLayerUnboundKeys = .typeNormally
    var bindings: [KeyboardLayerBinding] = []

    var sendsHyperForUnboundKeys: Bool { unboundKeys == .sendHyper }

    /// A Hyper layer works with no keys listed, and so does a Right Click layer, whose unlisted
    /// keys open their settings; otherwise at least one binding needs a key (other than the
    /// trigger) and an action.
    var isUsable: Bool {
        trigger == .rightClick || sendsHyperForUnboundKeys || bindings.contains { binding in
            guard let key = binding.key, binding.action != nil else { return false }
            return key.keyCode != trigger.eventKeyCode
        }
    }
}

enum KeyboardLayerPlanner {
    /// The layers that intercept keys right now: turned on, with at least one finished key, and
    /// one per trigger. A Caps Lock layer also needs Caps Lock to be free.
    static func activeLayers(_ layers: [KeyboardLayer], capsLockAvailable: Bool) -> [KeyboardLayerEngine.Layer] {
        var usedTriggers: Set<KeyboardLayerTrigger> = []
        var result: [KeyboardLayerEngine.Layer] = []
        for layer in layers where layer.isEnabled && layer.isUsable {
            guard usedTriggers.insert(layer.trigger).inserted else { continue }
            if layer.trigger == .capsLock && !capsLockAvailable { continue }
            var bindings: [KeyboardLayerChord: KeyboardLayerAction] = [:]
            var keysLeftAlone: Set<KeyboardLayerChord> = []
            for binding in layer.bindings {
                guard let key = binding.key, key.keyCode != layer.trigger.eventKeyCode,
                      bindings[key.chord] == nil else { continue }
                if let action = binding.action { bindings[key.chord] = action } else { keysLeftAlone.insert(key.chord) }
            }
            result.append(KeyboardLayerEngine.Layer(
                id: layer.id,
                triggerKeyCode: layer.trigger.eventKeyCode,
                tapsCapsLock: layer.trigger.tapsCapsLock,
                sendsHyperForUnboundKeys: layer.sendsHyperForUnboundKeys,
                bindings: bindings,
                keysLeftAlone: keysLeftAlone
            ))
        }
        return result
    }

    /// Why a layer can't be turned on, or nil when it can.
    static func enableBlockReason(
        for layer: KeyboardLayer,
        in layers: [KeyboardLayer],
        capsLockOwner: CapsLockOwner?
    ) -> String? {
        if layers.contains(where: { $0.id != layer.id && $0.isEnabled && $0.trigger == layer.trigger }) {
            return "Another layer already uses \(layer.trigger.title). Turn it off or choose another trigger."
        }
        if layer.trigger == .capsLock, let capsLockOwner {
            return capsLockOwner.explanation
        }
        return nil
    }
}
