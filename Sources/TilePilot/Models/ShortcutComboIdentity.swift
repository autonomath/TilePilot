import Foundation

/// An identity for conflict checks, without changing the user's skhd spelling.
enum ShortcutComboIdentity {
    static func normalized(_ combo: String) -> String {
        let text = combo
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s*\\+\\s*", with: " + ", options: .regularExpression)
            .replacingOccurrences(of: "\\s*-\\s*", with: " - ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let separator = text.firstIndex(of: "-") else { return text }
        let left = String(text[..<separator]).trimmingCharacters(in: .whitespaces)
        let key = String(text[text.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return text }

        // Modal shortcuts are a separate scope. Keep that scope intact while
        // treating the order of modifiers in the binding itself as irrelevant.
        let modeEnd = left.lastIndex(of: "<")
        let mode = modeEnd.map { String(left[...$0]).trimmingCharacters(in: .whitespaces) + " " } ?? ""
        let modifierText = modeEnd.map { String(left[left.index(after: $0)...]) } ?? left
        let modifiers = modifierText.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !modifiers.isEmpty, modifiers.allSatisfy({ modifierExpansion[$0] != nil }) else { return text }

        var expanded = Set(modifiers.flatMap { modifierExpansion[$0] ?? [] })
        // These skhd literals already add Fn during parsing. An explicit Fn
        // modifier does not create a different binding for the same literal.
        if implicitFunctionKeys.contains(key) { expanded.remove("fn") }
        let ordered = modifierOrder.filter { expanded.contains($0) }
        if ordered.isEmpty { return mode + key }
        return mode + ordered.joined(separator: " + ") + " - " + key
    }

    private static let modifierOrder = [
        "ctrl", "lctrl", "rctrl", "shift", "lshift", "rshift",
        "alt", "lalt", "ralt", "cmd", "lcmd", "rcmd", "fn",
    ]

    private static let modifierExpansion: [String: [String]] = {
        var result = Dictionary(uniqueKeysWithValues: modifierOrder.map { ($0, [$0]) })
        result["hyper"] = ["ctrl", "shift", "alt", "cmd"]
        result["meh"] = ["ctrl", "shift", "alt"]
        return result
    }()

    private static let implicitFunctionKeys: Set<String> = Set([
        "delete", "home", "end", "pageup", "pagedown", "insert",
        "left", "right", "up", "down",
    ] + (1...20).map { "f\($0)" })
}
