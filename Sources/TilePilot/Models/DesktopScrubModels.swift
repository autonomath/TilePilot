import AppKit
import Foundation

enum DesktopScrubModifier: String, Codable, CaseIterable, Sendable, Hashable, Identifiable {
    case shift
    case control
    case option
    case command

    static let defaultSelection: [DesktopScrubModifier] = [.shift, .control, .option]
    static let minimumSelectionCount = 2

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .shift: return "Shift"
        case .control: return "Control"
        case .option: return "Option"
        case .command: return "Command"
        }
    }

    var symbol: String {
        switch self {
        case .shift: return "⇧"
        case .control: return "⌃"
        case .option: return "⌥"
        case .command: return "⌘"
        }
    }

    var chipLabel: String {
        "\(symbol) \(displayName)"
    }

    var modifierFlag: NSEvent.ModifierFlags {
        switch self {
        case .shift: return .shift
        case .control: return .control
        case .option: return .option
        case .command: return .command
        }
    }

    static func normalize(_ modifiers: [DesktopScrubModifier]) -> [DesktopScrubModifier] {
        allCases.filter { modifiers.contains($0) }
    }

    static func loadFromUserDefaults(rawValues: [String]?) -> [DesktopScrubModifier] {
        let parsed = normalize((rawValues ?? []).compactMap(Self.init(rawValue:)))
        return parsed.count >= minimumSelectionCount ? parsed : defaultSelection
    }

    static func flags(for modifiers: [DesktopScrubModifier]) -> NSEvent.ModifierFlags {
        normalize(modifiers).reduce(into: NSEvent.ModifierFlags()) { result, modifier in
            result.insert(modifier.modifierFlag)
        }
    }

    static func from(flags: NSEvent.ModifierFlags) -> [DesktopScrubModifier] {
        allCases.filter { flags.contains($0.modifierFlag) }
    }

    static func symbolsText(for modifiers: [DesktopScrubModifier]) -> String {
        let normalized = normalize(modifiers)
        guard !normalized.isEmpty else { return "None" }
        return normalized.map(\.symbol).joined(separator: " ")
    }

    static func wordsText(for modifiers: [DesktopScrubModifier]) -> String {
        let normalized = normalize(modifiers)
        guard !normalized.isEmpty else { return "no trigger keys" }
        return normalized.map(\.displayName).joined(separator: " + ")
    }
}

enum DesktopScrubCharacterKey: String, Codable, CaseIterable, Sendable, Hashable, Identifiable {
    case none
    case a, b, c, d, e, f, g, h, i, j, k, l, m
    case n, o, p, q, r, s, t, u, v, w, x, y, z
    case zero, one, two, three, four, five, six, seven, eight, nine

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return "None"
        case .zero: return "0"
        case .one: return "1"
        case .two: return "2"
        case .three: return "3"
        case .four: return "4"
        case .five: return "5"
        case .six: return "6"
        case .seven: return "7"
        case .eight: return "8"
        case .nine: return "9"
        default: return rawValue.uppercased()
        }
    }

    var keyDisplayText: String {
        displayName
    }

    var keyCode: Int64? {
        switch self {
        case .none: return nil
        case .a: return 0
        case .b: return 11
        case .c: return 8
        case .d: return 2
        case .e: return 14
        case .f: return 3
        case .g: return 5
        case .h: return 4
        case .i: return 34
        case .j: return 38
        case .k: return 40
        case .l: return 37
        case .m: return 46
        case .n: return 45
        case .o: return 31
        case .p: return 35
        case .q: return 12
        case .r: return 15
        case .s: return 1
        case .t: return 17
        case .u: return 32
        case .v: return 9
        case .w: return 13
        case .x: return 7
        case .y: return 16
        case .z: return 6
        case .zero: return 29
        case .one: return 18
        case .two: return 19
        case .three: return 20
        case .four: return 21
        case .five: return 23
        case .six: return 22
        case .seven: return 26
        case .eight: return 28
        case .nine: return 25
        }
    }

    static func from(keyCode: Int64) -> DesktopScrubCharacterKey? {
        switch keyCode {
        case 0: return .a
        case 11: return .b
        case 8: return .c
        case 2: return .d
        case 14: return .e
        case 3: return .f
        case 5: return .g
        case 4: return .h
        case 34: return .i
        case 38: return .j
        case 40: return .k
        case 37: return .l
        case 46: return .m
        case 45: return .n
        case 31: return .o
        case 35: return .p
        case 12: return .q
        case 15: return .r
        case 1: return .s
        case 17: return .t
        case 32: return .u
        case 9: return .v
        case 13: return .w
        case 7: return .x
        case 16: return .y
        case 6: return .z
        case 29: return .zero
        case 18: return .one
        case 19: return .two
        case 20: return .three
        case 21: return .four
        case 23: return .five
        case 22: return .six
        case 26: return .seven
        case 28: return .eight
        case 25: return .nine
        default: return nil
        }
    }

    static func from(eventCharacters: String?) -> DesktopScrubCharacterKey? {
        guard let normalized = eventCharacters?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              normalized.count == 1 else {
            return nil
        }

        switch normalized {
        case "a": return .a
        case "b": return .b
        case "c": return .c
        case "d": return .d
        case "e": return .e
        case "f": return .f
        case "g": return .g
        case "h": return .h
        case "i": return .i
        case "j": return .j
        case "k": return .k
        case "l": return .l
        case "m": return .m
        case "n": return .n
        case "o": return .o
        case "p": return .p
        case "q": return .q
        case "r": return .r
        case "s": return .s
        case "t": return .t
        case "u": return .u
        case "v": return .v
        case "w": return .w
        case "x": return .x
        case "y": return .y
        case "z": return .z
        case "0": return .zero
        case "1": return .one
        case "2": return .two
        case "3": return .three
        case "4": return .four
        case "5": return .five
        case "6": return .six
        case "7": return .seven
        case "8": return .eight
        case "9": return .nine
        default: return nil
        }
    }
}
