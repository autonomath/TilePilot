import AppKit
import Foundation

enum ConfigFilesServiceError: LocalizedError {
    case fileNotFound(String)
    case io(String)
    case backupNotFound

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "File not found: \(path)"
        case .io(let message):
            return message
        case .backupNotFound:
            return "Selected backup file no longer exists."
        }
    }
}

final class ConfigFilesService: @unchecked Sendable {
    func discoverFiles(shortcuts: [ShortcutEntry]) async -> [EditableConfigFile] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: self.discoverFilesSync(shortcuts: shortcuts))
            }
        }
    }

    func loadDocument(path: String) async throws -> EditableFileDocumentState {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    continuation.resume(returning: try self.loadDocumentSync(path: path))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func saveFile(path: String, content: String) async throws -> EditableFileSaveResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    continuation.resume(returning: try self.saveFileSync(path: path, content: content))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func restoreBackup(filePath: String, backupPath: String) async throws -> EditableFileRestoreResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    continuation.resume(returning: try self.restoreBackupSync(filePath: filePath, backupPath: backupPath))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func revealInFinder(path: String) {
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func discoverFilesSync(shortcuts: [ShortcutEntry]) -> [EditableConfigFile] {
        let fm = FileManager.default
        let corePaths = [yabaircPath(), skhdrcPath()]
        var paths: [String] = corePaths
        var seen = Set(corePaths)

        let yabaiScriptsDir = NSString(string: "~/.config/yabai/scripts").expandingTildeInPath
        if let urls = try? fm.contentsOfDirectory(
            at: URL(fileURLWithPath: yabaiScriptsDir),
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for url in urls where url.pathExtension.lowercased() == "sh" {
                let path = url.path
                if seen.insert(path).inserted { paths.append(path) }
            }
        }

        for shortcut in shortcuts {
            if let path = referencedPath(from: shortcut.command) {
                if seen.insert(path).inserted { paths.append(path) }
            }
        }

        let coreFiles = corePaths.map { buildFile(path: $0, isDiscovered: false) }
        let discovered = paths
            .filter { !corePaths.contains($0) }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map { buildFile(path: $0, isDiscovered: true) }

        return coreFiles + discovered
    }

    private func loadDocumentSync(path: String) throws -> EditableFileDocumentState {
        let file = buildFile(path: path, isDiscovered: !isCorePath(path))
        let content: String
        if file.exists {
            do {
                content = try String(contentsOfFile: path, encoding: .utf8)
            } catch {
                throw ConfigFilesServiceError.io("Failed to read file: \(error.localizedDescription)")
            }
        } else {
            content = ""
        }
        return EditableFileDocumentState(
            file: file,
            content: content,
            backups: listBackups(for: path)
        )
    }

    private func saveFileSync(path: String, content: String) throws -> EditableFileSaveResult {
        let fm = FileManager.default
        let existed = fm.fileExists(atPath: path)
        let previousBackup: ConfigBackupInfo?
        if existed {
            previousBackup = try createBackup(for: path)
        } else {
            previousBackup = nil
        }

        do {
            try ensureParentDirectoryExists(forFile: path)
            try writeAtomically(content, to: path)
        } catch {
            if let previousBackup {
                _ = try? restoreFileFromBackup(backupPath: previousBackup.path, destinationPath: path)
            }
            throw ConfigFilesServiceError.io("Failed to write file: \(error.localizedDescription)")
        }

        return EditableFileSaveResult(
            file: buildFile(path: path, isDiscovered: !isCorePath(path)),
            backups: listBackups(for: path),
            previousBackup: previousBackup
        )
    }

    private func restoreBackupSync(filePath: String, backupPath: String) throws -> EditableFileRestoreResult {
        let fm = FileManager.default
        guard fm.fileExists(atPath: backupPath) else { throw ConfigFilesServiceError.backupNotFound }
        try ensureParentDirectoryExists(forFile: filePath)

        let preRestoreBackup: ConfigBackupInfo?
        if fm.fileExists(atPath: filePath) {
            preRestoreBackup = try createBackup(for: filePath)
        } else {
            preRestoreBackup = nil
        }

        let restoredBackup = try backupInfo(for: backupPath)
        do {
            _ = try restoreFileFromBackup(backupPath: backupPath, destinationPath: filePath)
        } catch {
            throw ConfigFilesServiceError.io("Failed to restore backup: \(error.localizedDescription)")
        }

        return EditableFileRestoreResult(
            file: buildFile(path: filePath, isDiscovered: !isCorePath(filePath)),
            backups: listBackups(for: filePath),
            restoredBackup: restoredBackup,
            preRestoreBackup: preRestoreBackup
        )
    }

    private func buildFile(path: String, isDiscovered: Bool) -> EditableConfigFile {
        let expanded = NSString(string: path).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        return EditableConfigFile(
            path: expanded,
            displayName: url.lastPathComponent.isEmpty ? expanded : url.lastPathComponent,
            kind: kind(for: expanded),
            exists: FileManager.default.fileExists(atPath: expanded),
            isDiscovered: isDiscovered
        )
    }

    private func kind(for path: String) -> EditableFileKind {
        if path == yabaircPath() { return .yabairc }
        if path == skhdrcPath() { return .skhdrc }
        if URL(fileURLWithPath: path).pathExtension.lowercased() == "sh" { return .script }
        return .other
    }

    private func isCorePath(_ path: String) -> Bool {
        let expanded = NSString(string: path).expandingTildeInPath
        return expanded == yabaircPath() || expanded == skhdrcPath()
    }

    private func referencedPath(from command: String) -> String? {
        let tokens = command.split(whereSeparator: \.isWhitespace)
        guard let first = tokens.first else { return nil }
        let token = String(first)

        if token.hasPrefix("~/") {
            return NSString(string: token).expandingTildeInPath
        }
        if token.hasPrefix("/") {
            return token
        }
        if token.hasPrefix("./") {
            let base = NSString(string: "~/.config/skhd").expandingTildeInPath
            return (base as NSString).appendingPathComponent(String(token.dropFirst(2)))
        }
        return nil
    }

    private func listBackups(for filePath: String) -> [ConfigBackupInfo] {
        let dir = backupsDirectoryPath(for: filePath)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: dir),
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return urls.compactMap { try? backupInfo(for: $0.path) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private func createBackup(for sourcePath: String) throws -> ConfigBackupInfo {
        let backupDir = backupsDirectoryPath(for: sourcePath)
        try FileManager.default.createDirectory(atPath: backupDir, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"

        let fileName = URL(fileURLWithPath: sourcePath).lastPathComponent
        let name = "\(fileName)-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(6)).bak"
        let destination = (backupDir as NSString).appendingPathComponent(name)

        do {
            try FileManager.default.copyItem(atPath: sourcePath, toPath: destination)
        } catch {
            throw ConfigFilesServiceError.io("Failed to create backup: \(error.localizedDescription)")
        }
        return try backupInfo(for: destination)
    }

    private func restoreFileFromBackup(backupPath: String, destinationPath: String) throws {
        let content = try String(contentsOfFile: backupPath, encoding: .utf8)
        try writeAtomically(content, to: destinationPath)
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
        let tempURL = destinationURL.deletingLastPathComponent()
            .appendingPathComponent(".\(destinationURL.lastPathComponent).tmp-\(UUID().uuidString)")
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
            throw ConfigFilesServiceError.io("Failed to create directory: \(error.localizedDescription)")
        }
    }

    private func backupsDirectoryPath(for filePath: String) -> String {
        let root = NSString(string: "~/.config/tilepilot/backups/files").expandingTildeInPath
        let safe = backupKey(for: filePath)
        return (root as NSString).appendingPathComponent(safe)
    }

    private func backupKey(for path: String) -> String {
        let expanded = NSString(string: path).expandingTildeInPath
        let base = URL(fileURLWithPath: expanded).lastPathComponent.replacingOccurrences(of: " ", with: "_")
        var hash: UInt64 = 5381
        for byte in expanded.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(byte)
        }
        return "\(base)-\(String(hash, radix: 16))"
    }

    private func yabaircPath() -> String {
        NSString(string: "~/.config/yabai/yabairc").expandingTildeInPath
    }

    private func skhdrcPath() -> String {
        NSString(string: "~/.config/skhd/skhdrc").expandingTildeInPath
    }
}
