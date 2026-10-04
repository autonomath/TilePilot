import Foundation

struct ShortcutLoadResult: Sendable {
    let entries: [ShortcutEntry]
    let filePath: String
    let issues: [String]
}

final class SkhdShortcutService: @unchecked Sendable {
    func loadShortcuts() async -> ShortcutLoadResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: self.loadShortcutsSync())
            }
        }
    }

    private func loadShortcutsSync() -> ShortcutLoadResult {
        let path = NSString(string: "~/.config/skhd/skhdrc").expandingTildeInPath
        var issues: [String] = []

        guard FileManager.default.fileExists(atPath: path) else {
            return ShortcutLoadResult(
                entries: [],
                filePath: path,
                issues: ["skhd config not found at \(path)"]
            )
        }

        let raw: String
        do {
            raw = try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            return ShortcutLoadResult(
                entries: [],
                filePath: path,
                issues: ["Unable to read skhdrc: \(error.localizedDescription)"]
            )
        }

        let lines = raw.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        var entries: [ShortcutEntry] = []

        for (index, lineSubseq) in lines.enumerated() {
            let lineNumber = index + 1
            let line = String(lineSubseq)

            if let entry = parseLine(line, lineNumber: lineNumber, filePath: path) {
                entries.append(entry)
            } else if shouldCountAsMalformed(line) {
                issues.append("Line \(lineNumber): could not parse shortcut entry")
            }
        }

        return ShortcutLoadResult(entries: entries, filePath: path, issues: Array(issues.prefix(50)))
    }

    private func parseLine(_ line: String, lineNumber: Int, filePath: String) -> ShortcutEntry? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.hasPrefix("#") { return nil }

        // skhd mode declarations and directives are not shortcut entries.
        if trimmed.hasPrefix("::") || trimmed.hasPrefix(".") {
            return nil
        }

        guard let colonIndex = firstShortcutSeparator(in: line) else { return nil }

        let lhs = String(line[..<colonIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        let rhsStart = line.index(after: colonIndex)
        let rhs = String(line[rhsStart...]).trimmingCharacters(in: .whitespacesAndNewlines)

        guard !lhs.isEmpty, !rhs.isEmpty else { return nil }
        if lhs.contains("=") && !lhs.contains("+") && !lhs.contains("-") && !lhs.contains("cmd") {
            // Heuristic: likely not a keybinding line.
            return nil
        }

        let command = stripTrailingComment(rhs)
        let warning = helperPathWarning(for: command)

        return ShortcutEntry(
            id: UUID(),
            combo: lhs,
            command: command,
            category: categorize(command: command),
            sourceLine: lineNumber,
            sourceFile: filePath,
            warning: warning
        )
    }

    private func firstShortcutSeparator(in line: String) -> String.Index? {
        var inSingleQuote = false
        var inDoubleQuote = false
        var escaped = false

        for index in line.indices {
            let ch = line[index]

            if escaped {
                escaped = false
                continue
            }
            if ch == "\\" {
                escaped = true
                continue
            }
            if ch == "'" && !inDoubleQuote {
                inSingleQuote.toggle()
                continue
            }
            if ch == "\"" && !inSingleQuote {
                inDoubleQuote.toggle()
                continue
            }
            if ch == ":" && !inSingleQuote && !inDoubleQuote {
                return index
            }
        }
        return nil
    }

    private func stripTrailingComment(_ rhs: String) -> String {
        var inSingleQuote = false
        var inDoubleQuote = false
        var escaped = false

        for index in rhs.indices {
            let ch = rhs[index]
            if escaped {
                escaped = false
                continue
            }
            if ch == "\\" {
                escaped = true
                continue
            }
            if ch == "'" && !inDoubleQuote {
                inSingleQuote.toggle()
                continue
            }
            if ch == "\"" && !inSingleQuote {
                inDoubleQuote.toggle()
                continue
            }
            if ch == "#" && !inSingleQuote && !inDoubleQuote {
                let before = String(rhs[..<index]).trimmingCharacters(in: .whitespacesAndNewlines)
                return before.isEmpty ? rhs : before
            }
        }

        return rhs.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func categorize(command: String) -> String {
        let c = command.lowercased()
        if c.contains("yabai -m space") { return "Spaces" }
        if c.contains("yabai -m window") { return "Windows" }
        if c.contains("yabai -m display") { return "Displays" }
        if c.contains("skhd -k") { return "Macros" }
        if c.hasPrefix("open ") || c.contains(" open ") { return "Apps" }
        if c.contains("osascript") { return "Automation" }
        return "Other"
    }

    private func helperPathWarning(for command: String) -> String? {
        let tokens = command.split(whereSeparator: \.isWhitespace)
        guard let first = tokens.first else { return nil }
        let token = String(first)

        let candidate: String?
        if token.hasPrefix("~/") {
            candidate = NSString(string: token).expandingTildeInPath
        } else if token.hasPrefix("/") {
            candidate = token
        } else if token.hasPrefix("./") {
            candidate = NSString(string: "~/.config/skhd").expandingTildeInPath + "/" + token.dropFirst(2)
        } else {
            candidate = nil
        }

        guard let path = candidate else { return nil }
        if FileManager.default.fileExists(atPath: path) { return nil }
        return "Referenced path not found: \(path)"
    }

    private func shouldCountAsMalformed(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix("::") || trimmed.hasPrefix(".") {
            return false
        }
        // Lines that look like intended bindings but lack a parseable separator.
        return trimmed.contains("cmd") || trimmed.contains("alt") || trimmed.contains("shift") || trimmed.contains("ctrl")
    }
}
