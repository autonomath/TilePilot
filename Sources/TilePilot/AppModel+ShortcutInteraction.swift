import Foundation

@MainActor
extension AppModel {
func displayShortcutCombo(_ entry: ShortcutEntry) -> String {
    let display = parseShortcutComboDisplay(entry.combo)
    if display.symbols == display.words || display.symbols.isEmpty {
        return display.words
    }
    return "\(display.symbols)  \(display.words)"
}

func displayShortcutComboWords(_ entry: ShortcutEntry) -> String {
    cachedShortcutComboWordsByStableKey[entry.stableKey] ?? parseShortcutComboDisplay(entry.combo).words
}

func displayShortcutComboSymbols(_ entry: ShortcutEntry) -> String {
    parseShortcutComboDisplay(entry.combo).symbols
}

func displayShortcutComboSymbolsSpaced(_ entry: ShortcutEntry) -> String {
    cachedShortcutComboSymbolsSpacedByStableKey[entry.stableKey] ?? parseShortcutComboDisplay(entry.combo).symbolsSpaced
}

func displayShortcutComboSymbols(from combo: String) -> String {
    parseShortcutComboDisplay(combo).symbols
}

func displayShortcutComboWords(from combo: String) -> String {
    parseShortcutComboDisplay(combo).words
}

func displayShortcutPrimaryKey(_ entry: ShortcutEntry) -> String {
    let trimmed = entry.combo.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "?" }
    let separatorIndex = trimmed.lastIndex(of: "-")
    let keyPartRaw = separatorIndex.map { String(trimmed[trimmed.index(after: $0)...]) } ?? trimmed
    let keyTokens = keyPartRaw
        .split(whereSeparator: \.isWhitespace)
        .map(String.init)
        .filter { !$0.isEmpty }
    let firstToken = (keyTokens.isEmpty ? [keyPartRaw.trimmingCharacters(in: .whitespacesAndNewlines)] : keyTokens).first?.lowercased() ?? ""
    return displayPrimaryKeyToken(lower: firstToken)
}

var pinnedShortcutEntries: [ShortcutEntry] {
    cachedPinnedShortcutEntries
}

func buildPinnedShortcutEntries(orderRank: [String: Int]) -> [ShortcutEntry] {
    var byKey: [String: ShortcutEntry] = [:]
    for entry in shortcutEntries {
        byKey[entry.stableKey] = entry
    }
    let fallbackRank = Dictionary(uniqueKeysWithValues: pinnedShortcutKeys.enumerated().map { ($0.element, $0.offset) })
    return pinnedShortcutKeys.compactMap { byKey[$0] }.sorted { lhs, rhs in
        let lhsOrder = orderRank[flatOrderID(for: lhs)] ?? Int.max
        let rhsOrder = orderRank[flatOrderID(for: rhs)] ?? Int.max
        if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
        let lhsFallback = fallbackRank[lhs.stableKey] ?? Int.max
        let rhsFallback = fallbackRank[rhs.stableKey] ?? Int.max
        if lhsFallback != rhsFallback { return lhsFallback < rhsFallback }
        return lhs.sourceLine < rhs.sourceLine
    }
}

var pinnedDirectionalGroups: [DirectionalShortcutGroup] {
    let fallbackRank = Dictionary(uniqueKeysWithValues: pinnedDirectionalGroupIDs.enumerated().map { ($0.element, $0.offset) })
    let orderRank = flatShortcutsOrderRankByID()
    return pinnedDirectionalGroupIDs
        .compactMap(DirectionalShortcutGroup.init(rawValue:))
        .sorted { lhs, rhs in
            let lhsOrder = orderRank[flatOrderID(for: lhs)] ?? Int.max
            let rhsOrder = orderRank[flatOrderID(for: rhs)] ?? Int.max
            if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
            let lhsFallback = fallbackRank[lhs.rawValue] ?? Int.max
            let rhsFallback = fallbackRank[rhs.rawValue] ?? Int.max
            return lhsFallback < rhsFallback
        }
}

var pinnedDirectionalGroupBindings: [(group: DirectionalShortcutGroup, bindings: [DirectionalShortcutBinding])] {
    cachedPinnedDirectionalGroupBindings
}

func buildPinnedDirectionalGroupBindings(orderRank: [String: Int]) -> [(group: DirectionalShortcutGroup, bindings: [DirectionalShortcutBinding])] {
    let fallbackRank = Dictionary(uniqueKeysWithValues: pinnedDirectionalGroupIDs.enumerated().map { ($0.element, $0.offset) })
    let groups = pinnedDirectionalGroupIDs
        .compactMap(DirectionalShortcutGroup.init(rawValue:))
        .sorted { lhs, rhs in
            let lhsOrder = orderRank[flatOrderID(for: lhs)] ?? Int.max
            let rhsOrder = orderRank[flatOrderID(for: rhs)] ?? Int.max
            if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
            let lhsFallback = fallbackRank[lhs.rawValue] ?? Int.max
            let rhsFallback = fallbackRank[rhs.rawValue] ?? Int.max
            return lhsFallback < rhsFallback
        }

    return groups.map { group in
        (group: group, bindings: directionalShortcutBindings(for: group))
    }
}

var pinnedShortcutContextItems: [PinnedShortcutContextItem] {
    cachedPinnedShortcutContextItems
}

func buildPinnedShortcutContextItems(
    orderRank: [String: Int],
    pinnedFeatureRows: [FeatureControlRow],
    pinnedDirectionalBindings: [(group: DirectionalShortcutGroup, bindings: [DirectionalShortcutBinding])],
    pinnedEntries: [ShortcutEntry]
) -> [PinnedShortcutContextItem] {
    var items: [PinnedShortcutContextItem] = []

    items.append(contentsOf: pinnedFeatureRows.map(PinnedShortcutContextItem.feature))
    items.append(contentsOf: pinnedDirectionalBindings.map { PinnedShortcutContextItem.directional(group: $0.group, bindings: $0.bindings) })

    let nonFeaturePinnedShortcuts = pinnedEntries.filter { entry in
        if featureControlRow(forShortcutEntry: entry)?.featureID != nil {
            return false
        }
        return !(isScriptingAdditionDesktopShortcut(entry) && !canRunScriptingAdditionDesktopActions)
    }
    items.append(contentsOf: nonFeaturePinnedShortcuts.map(PinnedShortcutContextItem.shortcut))

    return items.sorted { lhs, rhs in
        let lhsRank = orderRank[pinnedContextOrderID(lhs)] ?? Int.max
        let rhsRank = orderRank[pinnedContextOrderID(rhs)] ?? Int.max
        if lhsRank != rhsRank { return lhsRank < rhsRank }
        return pinnedContextOrderID(lhs) < pinnedContextOrderID(rhs)
    }
}

func isShortcutPinned(_ entry: ShortcutEntry) -> Bool {
    if let featureID = featureDefinition(for: entry)?.id {
        return isFeaturePinned(featureID)
    }
    return pinnedShortcutKeys.contains(entry.stableKey)
}

func isDirectionalGroupPinned(_ group: DirectionalShortcutGroup) -> Bool {
    pinnedDirectionalGroupIDs.contains(group.rawValue)
}

func isShortcutSelected(_ entry: ShortcutEntry) -> Bool {
    selectedShortcutStableKey == entry.stableKey
}

func selectShortcut(_ entry: ShortcutEntry) {
    selectedShortcutStableKey = entry.stableKey
}

func toggleShortcutPinned(_ entry: ShortcutEntry) {
    selectShortcut(entry)
    if let featureID = featureDefinition(for: entry)?.id {
        toggleFeaturePinned(featureID)
        return
    }
    if isShortcutPinned(entry) {
        pinnedShortcutKeys.removeAll { $0 == entry.stableKey }
        lastActionMessage = "Removed shortcut from right-click menu."
    } else {
        pinnedShortcutKeys.append(entry.stableKey)
        pinnedShortcutKeys = Array(NSOrderedSet(array: pinnedShortcutKeys)) as? [String] ?? pinnedShortcutKeys
        lastActionMessage = "Pinned shortcut to right-click menu."
    }
    persistPinnedShortcutKeys()
    rebuildShortcutPresentationCaches()
    lastErrorMessage = nil
}

func toggleDirectionalGroupPinned(_ group: DirectionalShortcutGroup) {
    if isDirectionalGroupPinned(group) {
        pinnedDirectionalGroupIDs.removeAll { $0 == group.rawValue }
        lastActionMessage = "Removed \(group.menuTitle) from right-click menu."
    } else {
        pinnedDirectionalGroupIDs.append(group.rawValue)
        pinnedDirectionalGroupIDs = Array(NSOrderedSet(array: pinnedDirectionalGroupIDs)) as? [String] ?? pinnedDirectionalGroupIDs
        lastActionMessage = "Pinned \(group.menuTitle) to right-click menu."
    }
    persistPinnedDirectionalGroupIDs()
    rebuildShortcutPresentationCaches()
    lastErrorMessage = nil
}

func runShortcut(_ entry: ShortcutEntry) {
    selectShortcut(entry)
    runShortcutCommand(entry.command, shortcutLabel: "\(entry.combo) - \(shortcutExplanation(entry))")
}

func runPinnedShortcut(stableKey: String) {
    guard let entry = shortcutEntries.first(where: { $0.stableKey == stableKey }) else {
        lastErrorMessage = "Pinned shortcut is no longer in skhdrc. Open Shortcuts to refresh or unpin it."
        lastActionMessage = nil
        return
    }
    if let featureID = featureDefinition(for: entry)?.id {
        runFeatureControl(featureID, source: .statusMenu)
        return
    }
    runShortcut(entry)
}

func directionalShortcutBindings(for group: DirectionalShortcutGroup) -> [DirectionalShortcutBinding] {
    shortcutEntries.compactMap { entry in
        guard let binding = directionalShortcutBinding(for: entry), binding.group == group else { return nil }
        return binding
    }
    .sorted { lhs, rhs in
        if lhs.direction.sortRank != rhs.direction.sortRank { return lhs.direction.sortRank < rhs.direction.sortRank }
        return lhs.entry.sourceLine < rhs.entry.sourceLine
    }
}

func parseShortcutComboDisplay(_ combo: String) -> (symbols: String, symbolsSpaced: String, words: String) {
    let trimmed = combo.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return ("", "", combo) }

    let separatorIndex = trimmed.lastIndex(of: "-")
    let modifiersPart = separatorIndex.map { String(trimmed[..<$0]) } ?? ""
    let keyPartRaw = separatorIndex.map { String(trimmed[trimmed.index(after: $0)...]) } ?? trimmed

    let modifierTokens = modifiersPart
        .split(separator: "+")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

    let keyTokens = keyPartRaw
        .split(whereSeparator: \.isWhitespace)
        .map(String.init)
        .filter { !$0.isEmpty }

    var modifierWords: [String] = []
    var modifierSymbols: [String] = []
    for token in modifierTokens {
        let lower = token.lowercased()
        switch lower {
        case "alt":
            modifierWords.append("Option")
            modifierSymbols.append("⌥")
        case "cmd":
            modifierWords.append("Command")
            modifierSymbols.append("⌘")
        case "ctrl":
            modifierWords.append("Control")
            modifierSymbols.append("⌃")
        case "shift":
            modifierWords.append("Shift")
            modifierSymbols.append("⇧")
        case "fn":
            modifierWords.append("Fn")
            modifierSymbols.append("fn")
        default:
            modifierWords.append(token)
            modifierSymbols.append(token)
        }
    }

    let keyWordTokens = (keyTokens.isEmpty ? [keyPartRaw.trimmingCharacters(in: .whitespacesAndNewlines)] : keyTokens).filter { !$0.isEmpty }
    let keyWords = keyWordTokens.map { displayKeyWord(lower: $0.lowercased(), original: $0) }
    let keySymbols = keyWordTokens.map { displayKeySymbol(lower: $0.lowercased(), original: $0) }

    let words = (modifierWords + keyWords).joined(separator: " + ")
    let keySymbolPart = keySymbols.joined(separator: keySymbols.count > 1 ? " " : "")
    let symbolTokens = modifierSymbols + (keySymbolPart.isEmpty ? [] : [keySymbolPart])
    let symbols = symbolTokens.joined()
    let symbolsSpaced = symbolTokens.joined(separator: " ")
    return (symbols, symbolsSpaced, words.isEmpty ? combo : words)
}

private func displayKeyWord(lower: String, original: String) -> String {
    switch lower {
    case "return", "enter": return "Return"
    case "escape", "esc": return "Escape"
    case "space": return "Space"
    case "tab": return "Tab"
    case "left": return "Left Arrow"
    case "right": return "Right Arrow"
    case "up": return "Up Arrow"
    case "down": return "Down Arrow"
    case "grave", "backtick": return "` / ~"
    case "0x32": return "` / ~"
    default:
        if original.count == 1 { return original.uppercased() }
        return original
    }
}

private func displayKeySymbol(lower: String, original: String) -> String {
    switch lower {
    case "return", "enter": return "↩"
    case "escape", "esc": return "⎋"
    case "space": return "␣"
    case "tab": return "⇥"
    case "left": return "←"
    case "right": return "→"
    case "up": return "↑"
    case "down": return "↓"
    case "grave", "backtick": return "~"
    case "0x32": return "~"
    default:
        if original.count == 1 { return original.uppercased() }
        return original
    }
}

private func displayPrimaryKeyToken(lower: String) -> String {
    switch lower {
    case "0x32", "grave", "backtick":
        return "~"
    case "left":
        return "←"
    case "right":
        return "→"
    case "up":
        return "↑"
    case "down":
        return "↓"
    case "space":
        return "Space"
    default:
        return lower.isEmpty ? "?" : lower.uppercased()
    }
}
}
