import Foundation

struct ConfigDocumentState: Sendable {
    let filePath: String
    let fileExists: Bool
    let fullContent: String
    let managedSectionBody: String
    let hasManagedSection: Bool
    let backups: [ConfigBackupInfo]
}

struct ConfigSaveResult: Sendable {
    let filePath: String
    let backups: [ConfigBackupInfo]
    let previousBackup: ConfigBackupInfo?
    let wasInsert: Bool
    let updatedContent: String
}

struct ConfigRestoreResult: Sendable {
    let filePath: String
    let backups: [ConfigBackupInfo]
    let restoredBackup: ConfigBackupInfo
    let preRestoreBackup: ConfigBackupInfo?
}

enum ConfigServiceError: LocalizedError {
    case invalidManagedSection(String)
    case malformedManagedMarkers
    case backupNotFound
    case backupReadFailed(String)
    case io(String)

    var errorDescription: String? {
        switch self {
        case .invalidManagedSection(let message):
            return message
        case .malformedManagedMarkers:
            return "Found only one TilePilot managed marker, or markers are out of order."
        case .backupNotFound:
            return "Selected backup file no longer exists."
        case .backupReadFailed(let message):
            return "Could not read backup: \(message)"
        case .io(let message):
            return message
        }
    }
}

final class ConfigService: @unchecked Sendable {
    let beginMarker = "# >>> TILEPILOT MANAGED BEGIN"
    let endMarker = "# <<< TILEPILOT MANAGED END"

    func loadConfigDocument() async throws -> ConfigDocumentState {
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

    func saveManagedSection(body: String) async throws -> ConfigSaveResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    continuation.resume(returning: try self.saveManagedSectionSync(body: body))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func restoreBackup(path: String) async throws -> ConfigRestoreResult {
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
        if oldLines == newLines {
            return "No changes."
        }

        var output: [String] = []
        output.append("--- current managed section")
        output.append("+++ proposed managed section")
        let diff = newLines.difference(from: oldLines)
        for change in diff {
            switch change {
            case .remove(_, let element, _):
                output.append("- \(element)")
            case .insert(_, let element, _):
                output.append("+ \(element)")
            }
        }
        return output.joined(separator: "\n")
    }

    func defaultManagedSectionBody() -> String {
        DefaultShortcutProfile.managedSkhdSectionBody()
    }

    private func loadConfigDocumentSync() throws -> ConfigDocumentState {
        let path = skhdrcPath()
        let fileExists = FileManager.default.fileExists(atPath: path)
        let content = fileExists ? (try readTextFile(path: path)) : ""
        let extracted = try extractManagedSection(from: content)
        let backups = listBackups()

        return ConfigDocumentState(
            filePath: path,
            fileExists: fileExists,
            fullContent: content,
            managedSectionBody: extracted?.body ?? defaultManagedSectionBody(),
            hasManagedSection: extracted != nil,
            backups: backups
        )
    }

    private func saveManagedSectionSync(body: String) throws -> ConfigSaveResult {
        try validateManagedSectionBody(body)

        let state = try loadConfigDocumentSync()
        let updatedContent = try applyManagedSection(body: body, to: state.fullContent)
        let path = state.filePath

        try ensureParentDirectoryExists(forFile: path)

        let previousBackup: ConfigBackupInfo?
        if state.fileExists {
            previousBackup = try createBackup(for: path)
        } else {
            previousBackup = nil
        }

        do {
            try writeAtomically(updatedContent, to: path)
        } catch {
            if let backup = previousBackup {
                _ = try? restoreFileFromBackup(backupPath: backup.path, destinationPath: path)
            }
            throw ConfigServiceError.io("Failed to write skhd config: \(error.localizedDescription)")
        }

        let backups = listBackups()
        return ConfigSaveResult(
            filePath: path,
            backups: backups,
            previousBackup: previousBackup,
            wasInsert: !state.hasManagedSection,
            updatedContent: updatedContent
        )
    }

    private func restoreBackupSync(path backupPath: String) throws -> ConfigRestoreResult {
        let fm = FileManager.default
        guard fm.fileExists(atPath: backupPath) else {
            throw ConfigServiceError.backupNotFound
        }

        let destination = skhdrcPath()
        try ensureParentDirectoryExists(forFile: destination)

        let preRestoreBackup: ConfigBackupInfo?
        if fm.fileExists(atPath: destination) {
            preRestoreBackup = try createBackup(for: destination)
        } else {
            preRestoreBackup = nil
        }

        let restored = try backupInfo(for: backupPath)
        do {
            _ = try restoreFileFromBackup(backupPath: backupPath, destinationPath: destination)
        } catch {
            throw ConfigServiceError.io("Failed to restore backup: \(error.localizedDescription)")
        }

        return ConfigRestoreResult(
            filePath: destination,
            backups: listBackups(),
            restoredBackup: restored,
            preRestoreBackup: preRestoreBackup
        )
    }

    private func extractManagedSection(from content: String) throws -> (body: String, range: Range<String.Index>)? {
        guard let beginRange = content.range(of: beginMarker) else {
            if content.range(of: endMarker) != nil { throw ConfigServiceError.malformedManagedMarkers }
            return nil
        }
        guard let endRange = content.range(of: endMarker), beginRange.lowerBound < endRange.lowerBound else {
            throw ConfigServiceError.malformedManagedMarkers
        }

        let lineStart = content[..<beginRange.lowerBound].lastIndex(of: "\n").map { content.index(after: $0) } ?? content.startIndex
        let lineEnd: String.Index
        if let newlineAfterEnd = content[endRange.upperBound...].firstIndex(of: "\n") {
            lineEnd = content.index(after: newlineAfterEnd)
        } else {
            lineEnd = content.endIndex
        }

        let managedRange = lineStart..<lineEnd
        let innerStart = beginRange.upperBound
        let innerEnd = endRange.lowerBound
        let rawInner = String(content[innerStart..<innerEnd])

        var body = rawInner
        if body.hasPrefix("\n") { body.removeFirst() }
        if body.hasSuffix("\n") { body.removeLast() }

        return (body, managedRange)
    }

    private func applyManagedSection(body: String, to original: String) throws -> String {
        let normalizedBlock = renderManagedBlock(body: body)

        if let extracted = try extractManagedSection(from: original) {
            var updated = original
            updated.replaceSubrange(extracted.range, with: normalizedBlock)
            return updated
        }

        if original.isEmpty {
            return normalizedBlock
        }

        var updated = original
        if !updated.hasSuffix("\n") {
            updated.append("\n")
        }
        updated.append("\n")
        updated.append(normalizedBlock)
        return updated
    }

    private func renderManagedBlock(body: String) -> String {
        let trimmedBody = body.trimmingCharacters(in: .newlines)
        return """
        \(beginMarker)
        \(trimmedBody)
        \(endMarker)

        """
    }

    private func validateManagedSectionBody(_ body: String) throws {
        if body.contains(beginMarker) || body.contains(endMarker) {
            throw ConfigServiceError.invalidManagedSection("Managed section body cannot contain TilePilot marker lines.")
        }

        let lines = body.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        for (index, subseq) in lines.enumerated() {
            let line = String(subseq).trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("::") || line.hasPrefix(".") { continue }
            guard line.contains(":") else {
                throw ConfigServiceError.invalidManagedSection("Line \(index + 1) in managed section looks invalid (missing `:` separator).")
            }
        }
    }

    private func createBackup(for sourcePath: String) throws -> ConfigBackupInfo {
        let backupDir = backupsDirectoryPath()
        try FileManager.default.createDirectory(atPath: backupDir, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "skhdrc-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(6)).bak"
        let dest = (backupDir as NSString).appendingPathComponent(name)

        do {
            try FileManager.default.copyItem(atPath: sourcePath, toPath: dest)
        } catch {
            throw ConfigServiceError.io("Failed to create backup: \(error.localizedDescription)")
        }

        return try backupInfo(for: dest)
    }

    private func restoreFileFromBackup(backupPath: String, destinationPath: String) throws -> Void {
        let content = try readTextFile(path: backupPath)
        try writeAtomically(content, to: destinationPath)
    }

    private func listBackups() -> [ConfigBackupInfo] {
        let backupDir = backupsDirectoryPath()
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: backupDir),
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return urls.compactMap { url in
            try? backupInfo(for: url.path)
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    private func backupInfo(for path: String) throws -> ConfigBackupInfo {
        let url = URL(fileURLWithPath: path)
        let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return ConfigBackupInfo(
            id: UUID(),
            path: path,
            createdAt: values.contentModificationDate ?? Date.distantPast,
            sizeBytes: Int64(values.fileSize ?? 0)
        )
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
            throw ConfigServiceError.io("Failed to create config directory: \(error.localizedDescription)")
        }
    }

    private func readTextFile(path: String) throws -> String {
        do {
            return try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            throw ConfigServiceError.io("Failed to read file: \(error.localizedDescription)")
        }
    }

    private func skhdrcPath() -> String {
        NSString(string: "~/.config/skhd/skhdrc").expandingTildeInPath
    }

    private func backupsDirectoryPath() -> String {
        NSString(string: "~/.config/tilepilot/backups/skhdrc").expandingTildeInPath
    }
}
