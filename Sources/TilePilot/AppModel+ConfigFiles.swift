import Foundation

@MainActor
extension AppModel {
    var editableFileLineCount: Int {
        max(1, editableFileDraft.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count)
    }

    var selectedEditableFile: EditableConfigFile? {
        cachedSelectedEditableFile
    }

    var isEditableFileDraftDirty: Bool {
        editableFileDraft != editableFileOriginal
    }

    func refreshEditableFiles() async {
        guard !isRefreshingEditableFiles else { return }
        isRefreshingEditableFiles = true
        defer { isRefreshingEditableFiles = false }

        let discovered = await configFilesService.discoverFiles(shortcuts: shortcutEntries)
        editableFiles = discovered

        if let target = consumeRequestedFileEditorTarget() {
            await openEditableFile(path: target.path, line: target.line)
            return
        }

        if let selected = selectedEditableFilePath, discovered.contains(where: { $0.path == selected }) {
            if selectedEditableFilePath == nil || !isEditableFileDraftDirty {
                await loadEditableFile(path: selected, line: nil)
            }
        } else if let first = discovered.first {
            await loadEditableFile(path: first.path, line: nil)
        }
    }

    func handlePendingFileEditorTargetIfNeeded() async {
        guard let target = consumeRequestedFileEditorTarget() else { return }
        await openEditableFile(path: target.path, line: target.line)
    }

    func openEditableFile(path: String, line: Int?) async {
        if !editableFiles.contains(where: { $0.path == path }) {
            let dynamic = EditableConfigFile(
                path: path,
                displayName: URL(fileURLWithPath: path).lastPathComponent,
                kind: inferredEditableFileKind(for: path),
                exists: FileManager.default.fileExists(atPath: path),
                isDiscovered: true
            )
            editableFiles.append(dynamic)
            editableFiles.sort { lhs, rhs in
                editableFileSortRank(lhs) < editableFileSortRank(rhs) ||
                    (editableFileSortRank(lhs) == editableFileSortRank(rhs) && lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending)
            }
        }
        await loadEditableFile(path: path, line: line)
    }

    func loadEditableFile(path: String, line: Int?) async {
        guard !isLoadingEditableFile else { return }
        isLoadingEditableFile = true
        defer { isLoadingEditableFile = false }

        do {
            let state = try await configFilesService.loadDocument(path: path)
            selectedEditableFilePath = state.file.path
            selectedEditableFileBackups = state.backups
            selectedEditableFileExists = state.file.exists
            selectedEditableFileKind = state.file.kind
            editableFileDraft = state.content
            editableFileOriginal = state.content
            editableFileJumpTargetLine = line
            filesLastErrorMessage = nil
            if let line {
                filesLastActionMessage = "Editing \(state.file.displayName) at line \(line)."
            }
            editableFiles = editableFiles.map { $0.path == state.file.path ? state.file : $0 }
        } catch {
            filesLastErrorMessage = "Failed to load file: \(error.localizedDescription)"
            filesLastActionMessage = nil
        }
    }

    func updateEditableFileDraft(_ newValue: String) {
        editableFileDraft = newValue
    }

    func consumeEditableFileJumpTargetLine() -> Int? {
        defer { editableFileJumpTargetLine = nil }
        return editableFileJumpTargetLine
    }

    func saveSelectedEditableFile() {
        guard let path = selectedEditableFilePath, !isSavingEditableFile else { return }
        isSavingEditableFile = true
        let content = editableFileDraft
        let kind = selectedEditableFileKind

        Task { [weak self] in
            guard let self else { return }
            defer { Task { @MainActor in self.isSavingEditableFile = false } }
            do {
                let result = try await self.configFilesService.saveFile(path: path, content: content)
                await MainActor.run {
                    self.selectedEditableFileBackups = result.backups
                    self.selectedEditableFileExists = true
                    self.selectedEditableFileKind = result.file.kind
                    self.editableFileOriginal = content
                    self.editableFiles = self.editableFiles.map { $0.path == path ? result.file : $0 }
                    self.filesLastActionMessage = "Saved \(result.file.displayName)."
                    self.filesLastErrorMessage = nil
                    if kind == .script {
                        self.scriptHeaderDescriptionCache[path] = nil
                    }
                }

                if kind == .skhdrc {
                    await self.runBestEffortSkhdRestartAfterRawFileSave()
                }
                if kind == .skhdrc {
                    await self.refreshShortcuts()
                } else if kind == .yabairc {
                    await self.refreshWindowBehaviorConfig()
                    await self.refreshDoctor()
                    await self.refreshLiveState()
                }
            } catch {
                await MainActor.run {
                    self.filesLastErrorMessage = "Save failed: \(error.localizedDescription)"
                    self.filesLastActionMessage = nil
                }
            }
        }
    }

    func revertSelectedEditableFileDraft() {
        editableFileDraft = editableFileOriginal
        filesLastActionMessage = "Discarded unsaved edits."
        filesLastErrorMessage = nil
    }

    func restoreSelectedEditableFileBackup(_ backup: ConfigBackupInfo? = nil) {
        guard let path = selectedEditableFilePath else { return }
        guard !isRestoringEditableFile else { return }
        guard let backupToRestore = backup ?? selectedEditableFileBackups.first else {
            filesLastErrorMessage = "No backups available for this file."
            filesLastActionMessage = nil
            return
        }

        isRestoringEditableFile = true
        let kind = selectedEditableFileKind
        Task { [weak self] in
            guard let self else { return }
            defer { Task { @MainActor in self.isRestoringEditableFile = false } }
            do {
                _ = try await self.configFilesService.restoreBackup(filePath: path, backupPath: backupToRestore.path)
                let reloaded = try await self.configFilesService.loadDocument(path: path)
                await MainActor.run {
                    self.selectedEditableFileBackups = reloaded.backups
                    self.selectedEditableFileExists = reloaded.file.exists
                    self.selectedEditableFileKind = reloaded.file.kind
                    self.editableFileDraft = reloaded.content
                    self.editableFileOriginal = reloaded.content
                    self.editableFiles = self.editableFiles.map { $0.path == path ? reloaded.file : $0 }
                    self.filesLastActionMessage = "Restored backup: \(URL(fileURLWithPath: backupToRestore.path).lastPathComponent)"
                    self.filesLastErrorMessage = nil
                    if kind == .script {
                        self.scriptHeaderDescriptionCache[path] = nil
                    }
                }
                if kind == .skhdrc {
                    await self.runBestEffortSkhdRestartAfterRawFileSave()
                    await self.refreshShortcuts()
                } else if kind == .yabairc {
                    await self.refreshWindowBehaviorConfig()
                    await self.refreshDoctor()
                    await self.refreshLiveState()
                }
            } catch {
                await MainActor.run {
                    self.filesLastErrorMessage = "Restore failed: \(error.localizedDescription)"
                    self.filesLastActionMessage = nil
                }
            }
        }
    }

    func revealSelectedEditableFileInFinder() {
        guard let path = selectedEditableFilePath else { return }
        configFilesService.revealInFinder(path: path)
        filesLastActionMessage = "Revealed file in Finder."
        filesLastErrorMessage = nil
    }

    func restartYabaiAfterRawFileEdit() {
        guard selectedEditableFileKind == .yabairc else { return }
        runSupportCommand(
            yabaiCommand(["--restart-service"], timeout: 2.0),
            successMessage: "Requested yabai service restart."
        )
    }

    func rebuildSelectedEditableFileCache() {
        guard let path = selectedEditableFilePath else {
            cachedSelectedEditableFile = nil
            return
        }

        if let discovered = editableFiles.first(where: { $0.path == path }) {
            cachedSelectedEditableFile = discovered
            return
        }

        cachedSelectedEditableFile = EditableConfigFile(
            path: path,
            displayName: URL(fileURLWithPath: path).lastPathComponent,
            kind: selectedEditableFileKind,
            exists: selectedEditableFileExists,
            isDiscovered: true
        )
    }
}
