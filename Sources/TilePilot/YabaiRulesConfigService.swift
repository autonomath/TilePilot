import Foundation

enum YabaiRulesConfigServiceError: LocalizedError {
    case malformedManagedMarkers
    case backupNotFound
    case io(String)

    var errorDescription: String? {
        switch self {
        case .malformedManagedMarkers:
            return "Found only one TilePilot yabai-config marker, or markers are out of order."
        case .backupNotFound:
            return "Selected backup file no longer exists."
        case .io(let message):
            return message
        }
    }
}

final class YabaiRulesConfigService: @unchecked Sendable {
    let beginMarker = "# >>> TILEPILOT YABAI CONFIG BEGIN"
    let endMarker = "# <<< TILEPILOT YABAI CONFIG END"
    private let runtimeConfigKeys = [
        "focus_follows_mouse",
        "mouse_follows_focus",
        "mouse_modifier",
        "mouse_action1",
        "mouse_action2",
        "mouse_drop_action",
        "top_padding",
        "bottom_padding",
        "left_padding",
        "right_padding",
        "window_gap",
    ]

    func loadConfigDocument() async throws -> YabaiConfigDocumentState {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    continuation.resume(returning: try self.loadConfigDocumentSync())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func saveWindowBehaviorPolicy(_ policy: ManagedWindowBehaviorPolicy) async throws -> YabaiConfigSaveResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    continuation.resume(returning: try self.saveWindowBehaviorPolicySync(policy))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func restoreBackup(path: String) async throws -> YabaiConfigRestoreResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    continuation.resume(returning: try self.restoreBackupSync(path: path))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func buildManagedSectionDiff(original: String, proposed: String) -> String {
        let oldLines = original.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        let newLines = proposed.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        if oldLines == newLines { return "No changes." }

        var output: [String] = ["--- current managed section", "+++ proposed managed section"]
        let diff = newLines.difference(from: oldLines)
        for change in diff {
            switch change {
            case .remove(_, let element, _): output.append("- \(element)")
            case .insert(_, let element, _): output.append("+ \(element)")
            }
        }
        return output.joined(separator: "\n")
    }

    func renderManagedBody(for policy: ManagedWindowBehaviorPolicy) -> String {
        var lines: [String] = []
        lines.append("# Managed by TilePilot. Unknown lines outside this block are preserved.")
        lines.append("yabai -m config layout \(policy.manualTilingModeEnabled ? "float" : "bsp")")
        lines.append("yabai -m config focus_follows_mouse \(policy.hoverFocusMode.rawValue)")
        lines.append("yabai -m config mouse_follows_focus \(policy.mouseFollowsFocusEnabled ? "on" : "off")")
        lines.append("yabai -m config mouse_modifier \(policy.mouseModifier.rawValue)")
        lines.append("yabai -m config mouse_action1 \(policy.mouseAction1.rawValue)")
        lines.append("yabai -m config mouse_action2 \(policy.mouseAction2.rawValue)")
        lines.append("yabai -m config mouse_drop_action \(policy.mouseDropAction.rawValue)")
        lines.append("yabai -m config top_padding \(policy.outerPadding)")
        lines.append("yabai -m config bottom_padding \(policy.outerPadding)")
        lines.append("yabai -m config left_padding \(policy.outerPadding)")
        lines.append("yabai -m config right_padding \(policy.outerPadding)")
        lines.append("yabai -m config window_gap \(policy.windowGap)")

        for app in policy.alwaysTileApps.map(normalizeAppName).filter({ !$0.isEmpty }).sorted() {
            let label = ruleLabel(prefix: "tp_always", appName: app)
            lines.append("yabai -m rule --add label=\(label) app=\"\(escapeRegex(app))\" manage=on")
        }
        for app in policy.neverTileApps.map(normalizeAppName).filter({ !$0.isEmpty }).sorted() {
            let label = ruleLabel(prefix: "tp_never", appName: app)
            lines.append("yabai -m rule --add label=\(label) app=\"\(escapeRegex(app))\" manage=off")
        }
        if policy.manualTilingModeEnabled {
            lines.append("yabai -m rule --add label=tp_manual_tiling_default app=\".*\" manage=off")
        }
        return lines.joined(separator: "\n")
    }

    func runtimeRuleCommands(previous: ManagedWindowBehaviorPolicy, current: ManagedWindowBehaviorPolicy) -> [ShellCommand] {
        var commands: [ShellCommand] = []

        let previousLabels = ruleLabels(for: previous)
        let currentLabels = ruleLabels(for: current)
        for label in Array(previousLabels.union(currentLabels)).sorted() {
            commands.append(yabaiCommand(["-m", "rule", "--remove", "label=\(label)"], timeout: 1.5))
        }

        for app in current.alwaysTileApps.map(normalizeAppName).filter({ !$0.isEmpty }).sorted() {
            commands.append(
                yabaiCommand([
                    "-m", "rule", "--add",
                    "label=\(ruleLabel(prefix: "tp_always", appName: app))",
                    "app=\(escapeRegex(app))",
                    "manage=on",
                ], timeout: 1.5)
            )
        }
        for app in current.neverTileApps.map(normalizeAppName).filter({ !$0.isEmpty }).sorted() {
            commands.append(
                yabaiCommand([
                    "-m", "rule", "--add",
                    "label=\(ruleLabel(prefix: "tp_never", appName: app))",
                    "app=\(escapeRegex(app))",
                    "manage=off",
                ], timeout: 1.5)
            )
        }
        if current.manualTilingModeEnabled {
            commands.append(
                yabaiCommand([
                    "-m", "rule", "--add",
                    "label=tp_manual_tiling_default",
                    "app=.*",
                    "manage=off",
                ], timeout: 1.5)
            )
        }
        return commands
    }

    func parsePolicy(fromManagedBody body: String) -> ManagedWindowBehaviorPolicy {
        let managed = parseManagedPolicyComponents(from: body)
        let runtimeFallback = runtimeConfigAssignments(missingKeys: managed.missingRuntimeKeys)
        return resolvePolicy(managed: managed, fileFallback: .empty, runtimeFallback: runtimeFallback)
    }

    private func loadConfigDocumentSync() throws -> YabaiConfigDocumentState {
        let path = yabaircPath()
        let fileExists = FileManager.default.fileExists(atPath: path)
        let content = fileExists ? (try readTextFile(path: path)) : ""
        let extracted = try extractManagedSection(from: content)
        let managedBody = extracted?.body ?? ""
        let managed = parseManagedPolicyComponents(from: managedBody)
        let fileFallback = parseConfigAssignments(from: content)
        let runtimeFallback = runtimeConfigAssignments(missingKeys: managed.missingRuntimeKeys(in: fileFallback))
        let resolvedPolicy = resolvePolicy(managed: managed, fileFallback: fileFallback, runtimeFallback: runtimeFallback)
        let displayedManagedBody = extracted?.body ?? renderManagedBody(for: resolvedPolicy)
        return YabaiConfigDocumentState(
            filePath: path,
            fileExists: fileExists,
            fullContent: content,
            managedSectionBody: displayedManagedBody,
            hasManagedSection: extracted != nil,
            backups: listBackups(),
            policy: resolvedPolicy
        )
    }

    private func saveWindowBehaviorPolicySync(_ policy: ManagedWindowBehaviorPolicy) throws -> YabaiConfigSaveResult {
        let state = try loadConfigDocumentSync()
        let body = renderManagedBody(for: policy)
        let updated = try applyManagedSection(body: body, to: state.fullContent)
        let path = state.filePath
        try ensureParentDirectoryExists(forFile: path)

        let previousBackup: ConfigBackupInfo?
        if state.fileExists {
            previousBackup = try createBackup(for: path)
        } else {
            previousBackup = nil
        }

        do {
            try writeAtomically(updated, to: path)
        } catch {
            throw YabaiRulesConfigServiceError.io("Failed to write yabairc: \(error.localizedDescription)")
        }

        return YabaiConfigSaveResult(
            filePath: path,
            backups: listBackups(),
            previousBackup: previousBackup,
            wasInsert: !state.hasManagedSection
        )
    }

    private func restoreBackupSync(path backupPath: String) throws -> YabaiConfigRestoreResult {
        let fm = FileManager.default
        guard fm.fileExists(atPath: backupPath) else { throw YabaiRulesConfigServiceError.backupNotFound }
        let destination = yabaircPath()
        try ensureParentDirectoryExists(forFile: destination)

        let preRestoreBackup: ConfigBackupInfo?
        if fm.fileExists(atPath: destination) {
            preRestoreBackup = try createBackup(for: destination)
        } else {
            preRestoreBackup = nil
        }

        let restored = try backupInfo(for: backupPath)
        do {
            let content = try readTextFile(path: backupPath)
            try writeAtomically(content, to: destination)
        } catch {
            throw YabaiRulesConfigServiceError.io("Failed to restore backup: \(error.localizedDescription)")
        }

        return YabaiConfigRestoreResult(
            filePath: destination,
            backups: listBackups(),
            restoredBackup: restored,
            preRestoreBackup: preRestoreBackup
        )
    }

    private func applyManagedSection(body: String, to original: String) throws -> String {
        let normalizedBlock = renderManagedBlock(body: body)
        if let extracted = try extractManagedSection(from: original) {
            var updated = original
            updated.replaceSubrange(extracted.range, with: normalizedBlock)
            return updated
        }
        if original.isEmpty { return normalizedBlock }
        var updated = original
        if !updated.hasSuffix("\n") { updated.append("\n") }
        updated.append("\n")
        updated.append(normalizedBlock)
        return updated
    }

    private func extractManagedSection(from content: String) throws -> (body: String, range: Range<String.Index>)? {
        guard let beginRange = content.range(of: beginMarker) else {
            if content.range(of: endMarker) != nil { throw YabaiRulesConfigServiceError.malformedManagedMarkers }
            return nil
        }
        guard let endRange = content.range(of: endMarker), beginRange.lowerBound < endRange.lowerBound else {
            throw YabaiRulesConfigServiceError.malformedManagedMarkers
        }

        let lineStart = content[..<beginRange.lowerBound].lastIndex(of: "\n").map { content.index(after: $0) } ?? content.startIndex
        let lineEnd: String.Index = content[endRange.upperBound...].firstIndex(of: "\n").map { content.index(after: $0) } ?? content.endIndex
        let managedRange = lineStart..<lineEnd
        var body = String(content[beginRange.upperBound..<endRange.lowerBound])
        if body.hasPrefix("\n") { body.removeFirst() }
        if body.hasSuffix("\n") { body.removeLast() }
        return (body, managedRange)
    }

    private func renderManagedBlock(body: String) -> String {
        let trimmedBody = body.trimmingCharacters(in: .newlines)
        return """
        \(beginMarker)
        \(trimmedBody)
        \(endMarker)

        """
    }

    private func parseAppPattern(fromRuleLine line: String) -> String? {
        guard let appRange = line.range(of: #"app=""#) else { return nil }
        let start = appRange.upperBound
        guard let end = line[start...].firstIndex(of: "\"") else { return nil }
        return unescapeRegex(String(line[start..<end]))
    }

    private func normalizeAppName(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func resolvePolicy(
        managed: ParsedManagedPolicy,
        fileFallback: ParsedConfigAssignments,
        runtimeFallback: ParsedConfigAssignments
    ) -> ManagedWindowBehaviorPolicy {
        var policy = ManagedWindowBehaviorPolicy.default
        policy.manualTilingModeEnabled = managed.manualTilingModeEnabled
        policy.neverTileApps = Array(Set(managed.neverTileApps)).sorted()
        policy.alwaysTileApps = Array(Set(managed.alwaysTileApps)).sorted()
        policy.hoverFocusMode = managed.hoverFocusMode
            ?? fileFallback.hoverFocusMode
            ?? runtimeFallback.hoverFocusMode
            ?? policy.hoverFocusMode
        policy.mouseFollowsFocusEnabled = managed.mouseFollowsFocusEnabled
            ?? fileFallback.mouseFollowsFocusEnabled
            ?? runtimeFallback.mouseFollowsFocusEnabled
            ?? policy.mouseFollowsFocusEnabled
        policy.outerPadding = managed.outerPadding
            ?? fileFallback.outerPadding
            ?? runtimeFallback.outerPadding
            ?? policy.outerPadding
        policy.windowGap = managed.windowGap
            ?? fileFallback.windowGap
            ?? runtimeFallback.windowGap
            ?? policy.windowGap
        policy.mouseModifier = managed.mouseModifier
            ?? fileFallback.mouseModifier
            ?? runtimeFallback.mouseModifier
            ?? policy.mouseModifier
        policy.mouseAction1 = managed.mouseAction1
            ?? fileFallback.mouseAction1
            ?? runtimeFallback.mouseAction1
            ?? policy.mouseAction1
        policy.mouseAction2 = managed.mouseAction2
            ?? fileFallback.mouseAction2
            ?? runtimeFallback.mouseAction2
            ?? policy.mouseAction2
        policy.mouseDropAction = managed.mouseDropAction
            ?? fileFallback.mouseDropAction
            ?? runtimeFallback.mouseDropAction
            ?? policy.mouseDropAction
        return policy
    }

    private func parseManagedPolicyComponents(from body: String) -> ParsedManagedPolicy {
        var managed = ParsedManagedPolicy()
        let lines = body.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            if let assignment = parseConfigAssignment(from: trimmed) {
                managed.apply(key: assignment.key, rawValue: assignment.value)
                continue
            }

            if trimmed.contains(#"rule --add label=tp_manual_tiling_default app=".*" manage=off"#) ||
               trimmed.contains(#"rule --add app=".*" manage=off"#) {
                managed.manualTilingModeEnabled = true
                continue
            }

            guard trimmed.contains("rule --add"), let app = parseAppPattern(fromRuleLine: trimmed) else { continue }
            if trimmed.contains("manage=off") {
                if app != ".*" { managed.neverTileApps.append(app) }
            } else if trimmed.contains("manage=on") {
                managed.alwaysTileApps.append(app)
            }
        }
        return managed
    }

    private func parseConfigAssignments(from content: String) -> ParsedConfigAssignments {
        var assignments = ParsedConfigAssignments.empty
        let lines = content.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let assignment = parseConfigAssignment(from: trimmed) else { continue }
            assignments.apply(key: assignment.key, rawValue: assignment.value)
        }
        return assignments
    }

    private func parseConfigAssignment(from trimmedLine: String) -> (key: String, value: String)? {
        guard !trimmedLine.isEmpty, !trimmedLine.hasPrefix("#") else { return nil }
        guard let configRange = trimmedLine.range(of: "config ") else { return nil }
        let remainder = trimmedLine[configRange.upperBound...]
        let parts = remainder.split(maxSplits: 2, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
        guard parts.count >= 2 else { return nil }
        let key = String(parts[0])
        let value = sanitizedConfigValue(String(parts[1]))
        return (key, value)
    }

    private func sanitizedConfigValue(_ raw: String) -> String {
        raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"';"))
    }

    private func runtimeConfigAssignments(missingKeys: Set<String>) -> ParsedConfigAssignments {
        guard !missingKeys.isEmpty else { return .empty }
        var assignments = ParsedConfigAssignments.empty
        for key in runtimeConfigKeys where missingKeys.contains(key) {
            guard let rawValue = runtimeConfigValue(for: key) else { continue }
            assignments.apply(key: key, rawValue: rawValue)
        }
        return assignments
    }

    private func runtimeConfigValue(for key: String) -> String? {
        let command = yabaiCommand(["-m", "config", key], timeout: 1.0)
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        process.environment = ManagedHelperService.shared.environmentWithManagedHelpers()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return nil
        }

        let deadline = Date().addingTimeInterval(command.timeout)
        while process.isRunning {
            if Date() >= deadline {
                process.terminate()
                Thread.sleep(forTimeInterval: 0.05)
                if process.isRunning {
                    process.interrupt()
                }
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }

        if process.isRunning {
            process.waitUntilExit()
        }

        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0, stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func ruleLabels(for policy: ManagedWindowBehaviorPolicy) -> Set<String> {
        var labels = Set<String>()
        for app in policy.alwaysTileApps {
            let trimmed = normalizeAppName(app)
            if !trimmed.isEmpty { labels.insert(ruleLabel(prefix: "tp_always", appName: trimmed)) }
        }
        for app in policy.neverTileApps {
            let trimmed = normalizeAppName(app)
            if !trimmed.isEmpty { labels.insert(ruleLabel(prefix: "tp_never", appName: trimmed)) }
        }
        if policy.manualTilingModeEnabled {
            labels.insert("tp_manual_tiling_default")
        }
        return labels
    }

    private func escapeRegex(_ string: String) -> String {
        NSRegularExpression.escapedPattern(for: string)
    }

    private func unescapeRegex(_ string: String) -> String {
        string.replacingOccurrences(of: #"\"#, with: "")
    }

    private func ruleLabel(prefix: String, appName: String) -> String {
        let lower = appName.lowercased()
        let sanitized = lower.map { ch -> Character in
            if ch.isLetter || ch.isNumber { return ch }
            return "_"
        }
        var slug = String(sanitized)
        while slug.contains("__") {
            slug = slug.replacingOccurrences(of: "__", with: "_")
        }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        if slug.isEmpty { slug = "app" }
        return "\(prefix)_\(slug.prefix(24))_\(shortHash(lower))"
    }

    private func shortHash(_ input: String) -> String {
        var hash: UInt64 = 1469598103934665603
        for byte in input.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return String(hash, radix: 16).prefix(8).description
    }

    private func createBackup(for sourcePath: String) throws -> ConfigBackupInfo {
        let backupDir = backupsDirectoryPath()
        try FileManager.default.createDirectory(atPath: backupDir, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "yabairc-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(6)).bak"
        let dest = (backupDir as NSString).appendingPathComponent(name)
        do {
            try FileManager.default.copyItem(atPath: sourcePath, toPath: dest)
        } catch {
            throw YabaiRulesConfigServiceError.io("Failed to create backup: \(error.localizedDescription)")
        }
        return try backupInfo(for: dest)
    }

    private func listBackups() -> [ConfigBackupInfo] {
        let backupDir = backupsDirectoryPath()
        guard let urls = try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: backupDir), includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        return urls.compactMap { try? backupInfo(for: $0.path) }.sorted { $0.createdAt > $1.createdAt }
    }

    private func backupInfo(for path: String) throws -> ConfigBackupInfo {
        let url = URL(fileURLWithPath: path)
        let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return ConfigBackupInfo(id: UUID(), path: path, createdAt: values.contentModificationDate ?? .distantPast, sizeBytes: Int64(values.fileSize ?? 0))
    }

    private func writeAtomically(_ content: String, to path: String) throws {
        let destinationURL = URL(fileURLWithPath: path)
        let tempURL = destinationURL.deletingLastPathComponent().appendingPathComponent(".\(destinationURL.lastPathComponent).tmp-\(UUID().uuidString)")
        do {
            try content.write(to: tempURL, atomically: true, encoding: .utf8)
            if FileManager.default.fileExists(atPath: path) {
                _ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: tempURL)
            } else {
                try FileManager.default.moveItem(at: tempURL, to: destinationURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
    }

    private func ensureParentDirectoryExists(forFile path: String) throws {
        let dir = (path as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        } catch {
            throw YabaiRulesConfigServiceError.io("Failed to create config directory: \(error.localizedDescription)")
        }
    }

    private func readTextFile(path: String) throws -> String {
        do {
            return try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            throw YabaiRulesConfigServiceError.io("Failed to read file: \(error.localizedDescription)")
        }
    }

    private func yabaircPath() -> String {
        NSString(string: "~/.config/yabai/yabairc").expandingTildeInPath
    }

    private func backupsDirectoryPath() -> String {
        NSString(string: "~/.config/tilepilot/backups/yabairc").expandingTildeInPath
    }
}

private struct ParsedManagedPolicy {
    var hoverFocusMode: HoverFocusMode?
    var mouseFollowsFocusEnabled: Bool?
    var outerPadding: Int?
    var windowGap: Int?
    var mouseModifier: MouseModifierKey?
    var mouseAction1: MouseDragAction?
    var mouseAction2: MouseDragAction?
    var mouseDropAction: MouseDropAction?
    var manualTilingModeEnabled = false
    var neverTileApps: [String] = []
    var alwaysTileApps: [String] = []

    var missingRuntimeKeys: Set<String> {
        missingRuntimeKeys(in: .empty)
    }

    func missingRuntimeKeys(in fileFallback: ParsedConfigAssignments) -> Set<String> {
        var missing = Set<String>()
        if hoverFocusMode == nil, fileFallback.hoverFocusMode == nil { missing.insert("focus_follows_mouse") }
        if mouseFollowsFocusEnabled == nil, fileFallback.mouseFollowsFocusEnabled == nil { missing.insert("mouse_follows_focus") }
        if mouseModifier == nil, fileFallback.mouseModifier == nil { missing.insert("mouse_modifier") }
        if mouseAction1 == nil, fileFallback.mouseAction1 == nil { missing.insert("mouse_action1") }
        if mouseAction2 == nil, fileFallback.mouseAction2 == nil { missing.insert("mouse_action2") }
        if mouseDropAction == nil, fileFallback.mouseDropAction == nil { missing.insert("mouse_drop_action") }
        if outerPadding == nil, fileFallback.outerPadding == nil {
            missing.formUnion(["top_padding", "bottom_padding", "left_padding", "right_padding"])
        }
        if windowGap == nil, fileFallback.windowGap == nil { missing.insert("window_gap") }
        return missing
    }

    mutating func apply(key: String, rawValue: String) {
        switch key {
        case "focus_follows_mouse":
            hoverFocusMode = HoverFocusMode(rawValue: rawValue)
        case "mouse_follows_focus":
            mouseFollowsFocusEnabled = Self.parseBool(rawValue)
        case "mouse_modifier":
            mouseModifier = MouseModifierKey(rawValue: rawValue)
        case "mouse_action1":
            mouseAction1 = MouseDragAction(rawValue: rawValue)
        case "mouse_action2":
            mouseAction2 = MouseDragAction(rawValue: rawValue)
        case "mouse_drop_action":
            mouseDropAction = MouseDropAction(rawValue: rawValue)
        case "top_padding", "bottom_padding", "left_padding", "right_padding":
            if let value = Int(rawValue) {
                outerPadding = value
            }
        case "window_gap":
            if let value = Int(rawValue) {
                windowGap = value
            }
        default:
            break
        }
    }

    private static func parseBool(_ rawValue: String) -> Bool? {
        switch rawValue.lowercased() {
        case "on", "true", "1":
            return true
        case "off", "false", "0":
            return false
        default:
            return nil
        }
    }
}

private struct ParsedConfigAssignments {
    var hoverFocusMode: HoverFocusMode?
    var mouseFollowsFocusEnabled: Bool?
    var mouseModifier: MouseModifierKey?
    var mouseAction1: MouseDragAction?
    var mouseAction2: MouseDragAction?
    var mouseDropAction: MouseDropAction?
    var topPadding: Int?
    var bottomPadding: Int?
    var leftPadding: Int?
    var rightPadding: Int?
    var windowGap: Int?

    static let empty = ParsedConfigAssignments()

    var outerPadding: Int? {
        let values = [topPadding, bottomPadding, leftPadding, rightPadding].compactMap { $0 }
        guard !values.isEmpty else { return nil }
        if values.count == 4, Set(values).count == 1 {
            return values[0]
        }
        return topPadding ?? bottomPadding ?? leftPadding ?? rightPadding
    }

    mutating func apply(key: String, rawValue: String) {
        switch key {
        case "focus_follows_mouse":
            hoverFocusMode = HoverFocusMode(rawValue: rawValue)
        case "mouse_follows_focus":
            mouseFollowsFocusEnabled = Self.parseBool(rawValue)
        case "mouse_modifier":
            mouseModifier = MouseModifierKey(rawValue: rawValue)
        case "mouse_action1":
            mouseAction1 = MouseDragAction(rawValue: rawValue)
        case "mouse_action2":
            mouseAction2 = MouseDragAction(rawValue: rawValue)
        case "mouse_drop_action":
            mouseDropAction = MouseDropAction(rawValue: rawValue)
        case "top_padding":
            topPadding = Int(rawValue)
        case "bottom_padding":
            bottomPadding = Int(rawValue)
        case "left_padding":
            leftPadding = Int(rawValue)
        case "right_padding":
            rightPadding = Int(rawValue)
        case "window_gap":
            windowGap = Int(rawValue)
        default:
            break
        }
    }

    private static func parseBool(_ rawValue: String) -> Bool? {
        switch rawValue.lowercased() {
        case "on", "true", "1":
            return true
        case "off", "false", "0":
            return false
        default:
            return nil
        }
    }
}
