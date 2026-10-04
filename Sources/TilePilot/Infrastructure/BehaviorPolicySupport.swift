import Foundation

func normalizedAppRuleKey(_ appName: String) -> String {
    appName
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: #"[\u200E\u200F\u202A-\u202E\u2066-\u2069]"#, with: "", options: .regularExpression)
        .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
        .lowercased()
}

func legacyTruncatedAppRuleKey(for normalizedKey: String) -> String {
    guard normalizedKey.count > 1 else { return normalizedKey }
    return String(normalizedKey.dropFirst())
}

func canonicalizeAppRuleList(_ values: [String]) -> [String] {
    var byNormalizedKey: [String: String] = [:]
    for raw in values {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { continue }
        let key = normalizedAppRuleKey(trimmed)
        guard !key.isEmpty else { continue }
        if byNormalizedKey[key] == nil {
            byNormalizedKey[key] = trimmed
        }
    }
    return byNormalizedKey.values.sorted { lhs, rhs in
        lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
    }
}

func addingAppName(_ name: String, to values: [String]) -> [String] {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return canonicalizeAppRuleList(values) }
    let key = normalizedAppRuleKey(trimmed)
    guard !key.isEmpty else { return canonicalizeAppRuleList(values) }
    if values.contains(where: { normalizedAppRuleKey($0) == key }) {
        return canonicalizeAppRuleList(values)
    }
    return canonicalizeAppRuleList(values + [trimmed])
}

func removeAppName(_ name: String, from values: [String]) -> [String] {
    let key = normalizedAppRuleKey(name)
    guard !key.isEmpty else { return canonicalizeAppRuleList(values) }
    let filtered = values.filter { normalizedAppRuleKey($0) != key }
    return canonicalizeAppRuleList(filtered)
}

func parseExternalYabaiAppBehaviors(
    from fullContent: String,
    beginMarker: String,
    endMarker: String
) -> [String: AppTilingBehavior] {
    var map: [String: AppTilingBehavior] = [:]
    var inManagedBlock = false

    for rawLine in fullContent.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init) {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if line == beginMarker {
            inManagedBlock = true
            continue
        }
        if line == endMarker {
            inManagedBlock = false
            continue
        }
        if inManagedBlock || line.isEmpty || line.hasPrefix("#") { continue }
        guard line.contains("rule --add") else { continue }

        let behavior: AppTilingBehavior?
        if line.contains("manage=off") {
            behavior = .neverTile
        } else if line.contains("manage=on") {
            behavior = .alwaysTile
        } else {
            behavior = nil
        }
        guard let behavior else { continue }
        guard let appPattern = parseAppPattern(fromRuleLine: line) else { continue }

        for app in expandExternalAppPattern(appPattern) {
            let key = normalizedAppRuleKey(app)
            guard !key.isEmpty else { continue }
            map[key] = behavior
        }
    }
    return map
}

func inferredEditableFileKind(for path: String) -> EditableFileKind {
    let expanded = NSString(string: path).expandingTildeInPath
    if expanded == NSString(string: "~/.config/yabai/yabairc").expandingTildeInPath { return .yabairc }
    if expanded == NSString(string: "~/.config/skhd/skhdrc").expandingTildeInPath { return .skhdrc }
    if URL(fileURLWithPath: expanded).pathExtension.lowercased() == "sh" { return .script }
    return .other
}

func editableFileSortRank(_ file: EditableConfigFile) -> Int {
    switch file.kind {
    case .yabairc: return 0
    case .skhdrc: return 1
    case .script: return 2
    case .other: return 3
    }
}

private func parseAppPattern(fromRuleLine line: String) -> String? {
    guard let range = line.range(of: #"app=""#) else { return nil }
    let start = range.upperBound
    guard let end = line[start...].firstIndex(of: "\"") else { return nil }
    return String(line[start..<end])
}

private func expandExternalAppPattern(_ pattern: String) -> [String] {
    let unescaped = pattern.replacingOccurrences(of: #"\"#, with: "")
    if unescaped == ".*" { return [] }

    if let exact = unwrapAnchoredExactPattern(unescaped) {
        return [exact]
    }

    if let group = unwrapAnchoredAlternationPattern(unescaped) {
        return group
    }

    if !looksRegexLike(unescaped) {
        return [unescaped]
    }
    return []
}

private func unwrapAnchoredExactPattern(_ pattern: String) -> String? {
    guard pattern.hasPrefix("^"), pattern.hasSuffix("$") else { return nil }
    let core = String(pattern.dropFirst().dropLast())
    guard !core.isEmpty, !looksRegexLike(core) else { return nil }
    return core
}

private func unwrapAnchoredAlternationPattern(_ pattern: String) -> [String]? {
    guard pattern.hasPrefix("^("), pattern.hasSuffix(")$") else { return nil }
    let core = String(pattern.dropFirst(2).dropLast(2))
    let parts = core.split(separator: "|").map(String.init)
    guard !parts.isEmpty else { return nil }
    var apps: [String] = []
    for part in parts {
        let name = part.replacingOccurrences(of: #"\"#, with: "")
        guard !name.isEmpty, !looksRegexLike(name) else { return nil }
        apps.append(name)
    }
    return apps
}

private func looksRegexLike(_ value: String) -> Bool {
    let regexMeta = CharacterSet(charactersIn: "[](){}.*+?|^$")
    return value.rangeOfCharacter(from: regexMeta) != nil
}
