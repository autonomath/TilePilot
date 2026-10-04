import Foundation

@MainActor
extension AppModel {
    func refreshConfig() async {
        guard !isRefreshingConfig else { return }
        isRefreshingConfig = true
        defer { isRefreshingConfig = false }

        do {
            let state = try await configService.loadConfigDocument()
            applyConfigDocumentState(state, preserveUserDraftIfDirty: false)
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = "Failed to load config: \(error.localizedDescription)"
            lastActionMessage = nil
        }
    }

    func refreshWindowBehaviorConfig() async {
        guard !isRefreshingYabaiConfig else { return }
        isRefreshingYabaiConfig = true
        defer { isRefreshingYabaiConfig = false }
        do {
            let state = try await yabaiRulesConfigService.loadConfigDocument()
            applyYabaiConfigDocumentState(state)
        } catch {
            lastErrorMessage = "Failed to load yabairc settings: \(error.localizedDescription)"
            lastActionMessage = nil
        }
    }

    func resetManagedConfigDraft() {
        managedConfigDraft = originalManagedConfigSection
        recomputeConfigDiffPreview()
        lastActionMessage = "Reverted draft to the last loaded managed section."
        lastErrorMessage = nil
    }

    func saveManagedConfigSection() {
        guard !isSavingConfig else { return }
        isSavingConfig = true
        let draft = managedConfigDraft

        Task { [weak self] in
            guard let self else { return }
            defer { Task { @MainActor in self.isSavingConfig = false } }
            do {
                let result = try await self.configService.saveManagedSection(body: draft)
                let reloaded = try await self.configService.loadConfigDocument()
                await MainActor.run {
                    self.applyConfigDocumentState(reloaded, preserveUserDraftIfDirty: false)
                    let mode = result.wasInsert ? "Inserted" : "Updated"
                    self.lastActionMessage = "\(mode) TilePilot managed section in skhdrc."
                    self.lastErrorMessage = nil
                }

                await self.refreshShortcuts()
                await self.runBestEffortSkhdRestart(afterConfigChange: true)
            } catch {
                await MainActor.run {
                    self.lastErrorMessage = "Config save failed: \(error.localizedDescription)"
                    self.lastActionMessage = nil
                }
            }
        }
    }

    func restoreLatestConfigBackup() {
        guard let backup = configBackups.first else {
            lastErrorMessage = "No backups available."
            lastActionMessage = nil
            return
        }
        restoreConfigBackup(backup)
    }

    func restoreConfigBackup(_ backup: ConfigBackupInfo) {
        guard !isRestoringConfig else { return }
        isRestoringConfig = true

        Task { [weak self] in
            guard let self else { return }
            defer { Task { @MainActor in self.isRestoringConfig = false } }
            do {
                _ = try await self.configService.restoreBackup(path: backup.path)
                let reloaded = try await self.configService.loadConfigDocument()
                await MainActor.run {
                    self.applyConfigDocumentState(reloaded, preserveUserDraftIfDirty: false)
                    self.lastActionMessage = "Restored backup: \(URL(fileURLWithPath: backup.path).lastPathComponent)"
                    self.lastErrorMessage = nil
                }

                await self.refreshShortcuts()
                await self.runBestEffortSkhdRestart(afterConfigChange: true)
            } catch {
                await MainActor.run {
                    self.lastErrorMessage = "Restore failed: \(error.localizedDescription)"
                    self.lastActionMessage = nil
                }
            }
        }
    }

    func resetWindowBehaviorDraft() {
        windowBehaviorAutoSaveTask?.cancel()
        windowBehaviorAutoSaveTask = nil
        windowBehaviorPolicyDraft = originalWindowBehaviorPolicy
        syncStagedAppRuleListsFromDraft(preservePendingChanges: false)
        recomputeYabaiConfigDiffPreview()
        lastActionMessage = "Reverted Window Behavior draft."
        lastErrorMessage = nil
    }

    func saveWindowBehaviorPolicy() {
        saveWindowBehaviorPolicy(reason: .manual())
    }

    func enableManualTilingMode() {
        windowBehaviorPolicyDraft.manualTilingModeEnabled = true
        recomputeYabaiConfigDiffPreview()
        saveWindowBehaviorPolicy()
    }

    func disableManualTilingMode() {
        windowBehaviorPolicyDraft.manualTilingModeEnabled = false
        recomputeYabaiConfigDiffPreview()
        saveWindowBehaviorPolicy()
    }

    func setHoverFocusMode(_ mode: HoverFocusMode) {
        windowBehaviorPolicyDraft.hoverFocusMode = mode
        recomputeYabaiConfigDiffPreview()
        saveWindowBehaviorPolicy()
    }

    func setMouseFollowsFocusEnabled(_ enabled: Bool) {
        windowBehaviorPolicyDraft.mouseFollowsFocusEnabled = enabled
        recomputeYabaiConfigDiffPreview()
        saveWindowBehaviorPolicy()
    }

    func updateManualTilingModeDraft(_ enabled: Bool) {
        windowBehaviorPolicyDraft.manualTilingModeEnabled = enabled
        recomputeYabaiConfigDiffPreview()
        scheduleDebouncedWindowBehaviorSave(reason: "manual-tiling")
    }

    func updateHoverFocusModeDraft(_ mode: HoverFocusMode) {
        windowBehaviorPolicyDraft.hoverFocusMode = mode
        recomputeYabaiConfigDiffPreview()
        scheduleDebouncedWindowBehaviorSave(reason: "hover-focus")
    }

    func updateMouseFollowsFocusDraft(_ enabled: Bool) {
        windowBehaviorPolicyDraft.mouseFollowsFocusEnabled = enabled
        recomputeYabaiConfigDiffPreview()
        scheduleDebouncedWindowBehaviorSave(reason: "mouse-follows-focus")
    }

    func updateOuterPaddingDraft(_ value: Int) {
        windowBehaviorPolicyDraft.outerPadding = clampedGlobalSpacingValue(value)
        recomputeYabaiConfigDiffPreview()
        scheduleDebouncedWindowBehaviorSave(reason: "outer-padding")
    }

    func updateWindowGapDraft(_ value: Int) {
        windowBehaviorPolicyDraft.windowGap = clampedGlobalSpacingValue(value)
        recomputeYabaiConfigDiffPreview()
        scheduleDebouncedWindowBehaviorSave(reason: "window-gap")
    }

    func updateMouseModifierDraft(_ value: MouseModifierKey) {
        windowBehaviorPolicyDraft.mouseModifier = value
        recomputeYabaiConfigDiffPreview()
        scheduleDebouncedWindowBehaviorSave(reason: "mouse-modifier")
    }

    func updateMouseAction1Draft(_ value: MouseDragAction) {
        windowBehaviorPolicyDraft.mouseAction1 = value
        recomputeYabaiConfigDiffPreview()
        scheduleDebouncedWindowBehaviorSave(reason: "mouse-action1")
    }

    func updateMouseAction2Draft(_ value: MouseDragAction) {
        windowBehaviorPolicyDraft.mouseAction2 = value
        recomputeYabaiConfigDiffPreview()
        scheduleDebouncedWindowBehaviorSave(reason: "mouse-action2")
    }

    func updateMouseDropActionDraft(_ value: MouseDropAction) {
        windowBehaviorPolicyDraft.mouseDropAction = value
        recomputeYabaiConfigDiffPreview()
        scheduleDebouncedWindowBehaviorSave(reason: "mouse-drop-action")
    }

    func disableHoverFocus() {
        windowBehaviorPolicyDraft.hoverFocusMode = .off
        recomputeYabaiConfigDiffPreview()
        saveWindowBehaviorPolicy()
    }

    func disableMouseFollowsFocus() {
        windowBehaviorPolicyDraft.mouseFollowsFocusEnabled = false
        recomputeYabaiConfigDiffPreview()
        saveWindowBehaviorPolicy()
    }

    func addStagedNeverTileApp(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        stagedAlwaysTileApps = removeAppName(trimmed, from: stagedAlwaysTileApps)
        stagedNeverTileApps = addingAppName(trimmed, to: stagedNeverTileApps)
    }

    func removeStagedNeverTileApp(_ name: String) {
        stagedNeverTileApps = removeAppName(name, from: stagedNeverTileApps)
    }

    func addStagedAlwaysTileApp(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        stagedNeverTileApps = removeAppName(trimmed, from: stagedNeverTileApps)
        stagedAlwaysTileApps = addingAppName(trimmed, to: stagedAlwaysTileApps)
    }

    func removeStagedAlwaysTileApp(_ name: String) {
        stagedAlwaysTileApps = removeAppName(name, from: stagedAlwaysTileApps)
    }

    func discardStagedAppRuleListChanges() {
        syncStagedAppRuleListsFromDraft(preservePendingChanges: false)
        lastActionMessage = "Discarded app rule list edits."
        lastErrorMessage = nil
    }

    func applyStagedAppRuleListChanges() {
        guard isAppRuleListApplyRequired else { return }
        guard !isSavingYabaiConfig else { return }
        isApplyingStagedAppRules = true
        windowBehaviorPolicyDraft.neverTileApps = canonicalizeAppRuleList(stagedNeverTileApps)
        windowBehaviorPolicyDraft.alwaysTileApps = canonicalizeAppRuleList(stagedAlwaysTileApps)
        recomputeYabaiConfigDiffPreview()
        saveWindowBehaviorPolicy(reason: .manual())
    }

    func appTilingBehavior(for appName: String) -> AppTilingBehavior {
        let key = normalizedAppRuleKey(appName)
        return cachedAppTilingBehaviorByNormalizedName[key] ?? .useDefault
    }

    func appForegroundPolicy(for appName: String) -> AppForegroundPolicy {
        let key = normalizedAppRuleKey(appName)
        if let exact = cachedAppForegroundPolicyByExactNormalizedName[key] {
            return exact
        }
        if let legacy = cachedAppForegroundPolicyByLegacyNormalizedName[legacyTruncatedAppRuleKey(for: key)] {
            return legacy
        }
        return .useDefault
    }

    func setAppForegroundPolicy(_ policy: AppForegroundPolicy, for appName: String) {
        let key = normalizedAppRuleKey(appName)
        guard !key.isEmpty else { return }
        let legacyKey = legacyTruncatedAppRuleKey(for: key)
        if policy == .useDefault {
            appForegroundPolicyByName.removeValue(forKey: key)
            appForegroundPolicyByName.removeValue(forKey: legacyKey)
        } else {
            appForegroundPolicyByName[key] = policy
            appForegroundPolicyByName.removeValue(forKey: legacyKey)
        }
        persistAppForegroundPolicies()
        let displayName = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        if policy == .useDefault {
            lastActionMessage = "Keep-on-top behavior for \(displayName) reset to default."
        } else {
            lastActionMessage = "\(displayName) will stay on top when floating."
            bringFlaggedFloatingWindowsToFrontCurrentDesktop()
        }
        lastErrorMessage = nil
    }

    func toggleKeepFrontWhenFloating(for appName: String) {
        let next: AppForegroundPolicy = appForegroundPolicy(for: appName) == .keepFrontWhenFloating ? .useDefault : .keepFrontWhenFloating
        setAppForegroundPolicy(next, for: appName)
        if next == .keepFrontWhenFloating {
            bringFlaggedFloatingWindowsToFrontCurrentDesktop()
        }
    }

    func toggleNeverAutoTile(for appName: String) {
        let trimmed = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let next: AppTilingBehavior = appTilingBehavior(for: trimmed) == .neverTile ? .useDefault : .neverTile
        setNeverAutoTileEnabled(next == .neverTile, for: trimmed)
    }

    func setNeverAutoTileEnabled(_ enabled: Bool, for appName: String) {
        let trimmed = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let next: AppTilingBehavior = enabled ? .neverTile : .useDefault
        setAppTilingBehavior(next, for: trimmed, autosave: false)

        let message = enabled
            ? "\(trimmed) will stay out of tiled layouts."
            : "\(trimmed) now uses the default tiling behavior."

        saveWindowBehaviorPolicy(reason: .manual(message: message))
    }

    func setAppTilingBehavior(_ behavior: AppTilingBehavior, for appName: String, autosave: Bool = true) {
        let trimmed = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let key = normalizedAppRuleKey(trimmed)
        guard !key.isEmpty else { return }

        windowBehaviorPolicyDraft.neverTileApps = windowBehaviorPolicyDraft.neverTileApps.filter { normalizedAppRuleKey($0) != key }
        windowBehaviorPolicyDraft.alwaysTileApps = windowBehaviorPolicyDraft.alwaysTileApps.filter { normalizedAppRuleKey($0) != key }

        switch behavior {
        case .useDefault:
            break
        case .neverTile:
            windowBehaviorPolicyDraft.neverTileApps.append(trimmed)
            windowBehaviorPolicyDraft.neverTileApps = canonicalizeAppRuleList(windowBehaviorPolicyDraft.neverTileApps)
        case .alwaysTile:
            windowBehaviorPolicyDraft.alwaysTileApps.append(trimmed)
            windowBehaviorPolicyDraft.alwaysTileApps = canonicalizeAppRuleList(windowBehaviorPolicyDraft.alwaysTileApps)
        }
        recomputeYabaiConfigDiffPreview()
        if autosave {
            scheduleDebouncedWindowBehaviorSave(reason: "app-behavior")
        }
    }

    func toggleAppDefaultTilingBehavior(for appName: String) {
        let trimmed = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let currentDefault = appTilingBehavior(for: trimmed)
        let next: AppTilingBehavior
        switch currentDefault {
        case .neverTile:
            next = .alwaysTile
        case .alwaysTile:
            next = .neverTile
        case .useDefault:
            next = windowBehaviorPolicyDraft.manualTilingModeEnabled ? .alwaysTile : .neverTile
        }
        setAppTilingBehavior(next, for: trimmed, autosave: false)
        saveWindowBehaviorPolicy()
    }

    func alwaysTileConflictDesktopIndex(for appName: String) -> Int? {
        guard appTilingBehavior(for: appName) == .alwaysTile else { return nil }
        guard let snapshot = liveStateSnapshot, snapshot.source == .yabai, !snapshot.degraded else { return nil }
        guard let activeSpace = activeSpaceIndex(in: snapshot) else { return nil }
        guard desktopTilingEnabled(spaceIndex: activeSpace) == false else { return nil }
        return activeSpace
    }

    var isManagedConfigDraftDirty: Bool {
        managedConfigDraft != originalManagedConfigSection
    }

    func recomputeConfigDiffPreview() {
        configDiffPreviewText = configService.buildManagedSectionDiff(
            original: originalManagedConfigSection,
            proposed: managedConfigDraft
        )
    }

    private enum WindowBehaviorSaveReason {
        case manual(message: String? = nil)
        case autosave
    }

    private func saveWindowBehaviorPolicy(reason: WindowBehaviorSaveReason) {
        guard !isSavingYabaiConfig else { return }
        guard isWindowBehaviorDraftDirty else {
            if isApplyingStagedAppRules {
                isApplyingStagedAppRules = false
                syncStagedAppRuleListsFromDraft(preservePendingChanges: false)
            }
            return
        }
        isSavingYabaiConfig = true
        let draft = windowBehaviorPolicyDraft
        let previousPolicy = originalWindowBehaviorPolicy
        let wasApplyingStagedRules = isApplyingStagedAppRules

        Task { [weak self] in
            guard let self else { return }
            defer { Task { @MainActor in self.isSavingYabaiConfig = false } }
            do {
                _ = try await self.yabaiRulesConfigService.saveWindowBehaviorPolicy(draft)
                let reloaded = try await self.yabaiRulesConfigService.loadConfigDocument()
                await MainActor.run {
                    self.applyYabaiConfigDocumentState(reloaded, preserveDraftIfDirty: false)
                    if wasApplyingStagedRules {
                        self.lastActionMessage = "App rule list changes applied."
                        self.windowBehaviorAutosaveActionMessage = nil
                        self.windowBehaviorAutosaveErrorMessage = nil
                    } else if case let .manual(message) = reason {
                        self.lastActionMessage = message ?? "Window behavior saved to yabairc."
                        self.windowBehaviorAutosaveActionMessage = nil
                        self.windowBehaviorAutosaveErrorMessage = nil
                    } else {
                        self.lastActionMessage = nil
                        self.windowBehaviorAutosaveActionMessage = "Behavior changes saved."
                        self.windowBehaviorAutosaveErrorMessage = nil
                    }
                    self.lastErrorMessage = nil
                    if wasApplyingStagedRules {
                        self.isApplyingStagedAppRules = false
                        self.syncStagedAppRuleListsFromDraft(preservePendingChanges: false)
                    }
                }
                await self.applyWindowBehaviorRuntime(previous: previousPolicy, current: draft)
            } catch {
                await MainActor.run {
                    self.lastErrorMessage = "Saving yabairc settings failed: \(error.localizedDescription)"
                    self.lastActionMessage = nil
                    if case .autosave = reason, !wasApplyingStagedRules {
                        self.windowBehaviorAutosaveErrorMessage = "Could not save behavior changes. Try again."
                        self.windowBehaviorAutosaveActionMessage = nil
                    }
                    if wasApplyingStagedRules {
                        self.isApplyingStagedAppRules = false
                    }
                }
            }
        }
    }

    func restoreYabaiConfigBackup(_ backup: ConfigBackupInfo) {
        guard !isRestoringYabaiConfig else { return }
        isRestoringYabaiConfig = true
        Task { [weak self] in
            guard let self else { return }
            defer { Task { @MainActor in self.isRestoringYabaiConfig = false } }
            do {
                _ = try await self.yabaiRulesConfigService.restoreBackup(path: backup.path)
                let reloaded = try await self.yabaiRulesConfigService.loadConfigDocument()
                await MainActor.run {
                    self.applyYabaiConfigDocumentState(reloaded, preserveDraftIfDirty: false)
                    self.lastActionMessage = "Restored yabairc backup: \(URL(fileURLWithPath: backup.path).lastPathComponent)"
                    self.lastErrorMessage = nil
                }
                await self.applyWindowBehaviorRuntime(previous: self.originalWindowBehaviorPolicy, current: reloaded.policy)
            } catch {
                await MainActor.run {
                    self.lastErrorMessage = "Restore yabairc backup failed: \(error.localizedDescription)"
                    self.lastActionMessage = nil
                }
            }
        }
    }

    private func applyConfigDocumentState(_ state: ConfigDocumentState, preserveUserDraftIfDirty: Bool) {
        let wasDirty = isManagedConfigDraftDirty
        configFilePath = state.filePath
        configFileExists = state.fileExists
        configHasManagedSection = state.hasManagedSection
        configBackups = state.backups
        loadedFullConfigContent = state.fullContent
        originalManagedConfigSection = state.managedSectionBody

        if !(preserveUserDraftIfDirty && wasDirty) {
            managedConfigDraft = state.managedSectionBody
        }
        recomputeConfigDiffPreview()
    }

    private func applyYabaiConfigDocumentState(_ state: YabaiConfigDocumentState, preserveDraftIfDirty: Bool = true) {
        yabaiConfigFilePath = state.filePath
        yabaiConfigFileExists = state.fileExists
        yabaiConfigHasManagedSection = state.hasManagedSection
        yabaiConfigBackups = state.backups
        externalYabaiAppBehaviorByName = parseExternalYabaiAppBehaviors(
            from: state.fullContent,
            beginMarker: yabaiRulesConfigService.beginMarker,
            endMarker: yabaiRulesConfigService.endMarker
        )
        let wasDirty = isWindowBehaviorDraftDirty
        originalWindowBehaviorPolicy = state.policy
        originalYabaiManagedConfigSection = state.managedSectionBody
        if !(preserveDraftIfDirty && wasDirty) {
            windowBehaviorPolicyDraft = state.policy
        }
        syncStagedAppRuleListsFromDraft(preservePendingChanges: true)
        recomputeYabaiConfigDiffPreview()
    }

    private func recomputeYabaiConfigDiffPreview() {
        let proposed = yabaiRulesConfigService.renderManagedBody(for: windowBehaviorPolicyDraft)
        yabaiConfigDiffPreviewText = yabaiRulesConfigService.buildManagedSectionDiff(
            original: originalYabaiManagedConfigSection,
            proposed: proposed
        )
    }

    private func scheduleDebouncedWindowBehaviorSave(reason _: String) {
        windowBehaviorAutoSaveTask?.cancel()
        windowBehaviorAutoSaveTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: self.windowBehaviorAutoSaveDelayNanoseconds)
            } catch {
                return
            }
            if Task.isCancelled { return }
            await MainActor.run {
                guard self.isWindowBehaviorDraftDirty else { return }
                if self.isSavingYabaiConfig || self.isRestoringYabaiConfig {
                    self.scheduleDebouncedWindowBehaviorSave(reason: "retry-after-busy")
                    return
                }
                self.saveWindowBehaviorPolicy(reason: .autosave)
            }
        }
    }

    private func syncStagedAppRuleListsFromDraft(preservePendingChanges: Bool) {
        let shouldPreserve = preservePendingChanges && hasInitializedStagedAppRuleLists && isAppRuleListApplyRequired
        guard !shouldPreserve else { return }
        stagedNeverTileApps = canonicalizeAppRuleList(windowBehaviorPolicyDraft.neverTileApps)
        stagedAlwaysTileApps = canonicalizeAppRuleList(windowBehaviorPolicyDraft.alwaysTileApps)
        hasInitializedStagedAppRuleLists = true
    }

    func persistAppForegroundPolicies() {
        let raw = appForegroundPolicyByName.mapValues(\.rawValue)
        UserDefaults.standard.set(raw, forKey: AppModel.appForegroundPolicyByNameDefaultsKey)
    }

    func rebuildAppBehaviorLookupCaches() {
        var tilingByKey = externalYabaiAppBehaviorByName
        for appName in windowBehaviorPolicyDraft.alwaysTileApps {
            let key = normalizedAppRuleKey(appName)
            guard !key.isEmpty else { continue }
            tilingByKey[key] = .alwaysTile
        }
        for appName in windowBehaviorPolicyDraft.neverTileApps {
            let key = normalizedAppRuleKey(appName)
            guard !key.isEmpty else { continue }
            tilingByKey[key] = .neverTile
        }
        cachedAppTilingBehaviorByNormalizedName = tilingByKey

        var exactForegroundPolicies: [String: AppForegroundPolicy] = [:]
        var legacyForegroundPolicies: [String: AppForegroundPolicy] = [:]
        for (rawKey, policy) in appForegroundPolicyByName {
            let normalizedKey = normalizedAppRuleKey(rawKey)
            guard !normalizedKey.isEmpty else { continue }
            exactForegroundPolicies[normalizedKey] = policy
            legacyForegroundPolicies[legacyTruncatedAppRuleKey(for: normalizedKey)] = policy
        }
        cachedAppForegroundPolicyByExactNormalizedName = exactForegroundPolicies
        cachedAppForegroundPolicyByLegacyNormalizedName = legacyForegroundPolicies
    }

    func applyWindowBehaviorRuntime(previous: ManagedWindowBehaviorPolicy, current: ManagedWindowBehaviorPolicy) async {
        var configApplyFailed = false
        let configCommands: [ShellCommand] = [
            yabaiCommand(["-m", "config", "layout", current.manualTilingModeEnabled ? "float" : "bsp"], timeout: 1.5),
            yabaiCommand(["-m", "config", "focus_follows_mouse", current.hoverFocusMode.rawValue], timeout: 1.5),
            yabaiCommand(["-m", "config", "mouse_follows_focus", current.mouseFollowsFocusEnabled ? "on" : "off"], timeout: 1.5),
            yabaiCommand(["-m", "config", "mouse_modifier", current.mouseModifier.rawValue], timeout: 1.5),
            yabaiCommand(["-m", "config", "mouse_action1", current.mouseAction1.rawValue], timeout: 1.5),
            yabaiCommand(["-m", "config", "mouse_action2", current.mouseAction2.rawValue], timeout: 1.5),
            yabaiCommand(["-m", "config", "mouse_drop_action", current.mouseDropAction.rawValue], timeout: 1.5),
            yabaiCommand(["-m", "config", "top_padding", String(current.outerPadding)], timeout: 1.5),
            yabaiCommand(["-m", "config", "bottom_padding", String(current.outerPadding)], timeout: 1.5),
            yabaiCommand(["-m", "config", "left_padding", String(current.outerPadding)], timeout: 1.5),
            yabaiCommand(["-m", "config", "right_padding", String(current.outerPadding)], timeout: 1.5),
            yabaiCommand(["-m", "config", "window_gap", String(current.windowGap)], timeout: 1.5),
        ]
        for command in configCommands {
            let result = await doctorService.runSupportCommand(command)
            if !result.isSuccess {
                configApplyFailed = true
            }
            await MainActor.run {
                self.appendCommandLog(from: result)
                if !result.isSuccess {
                    self.lastActionMessage = "Saved settings, but runtime apply may require restarting yabai."
                }
            }
        }

        let ruleCommands = yabaiRulesConfigService.runtimeRuleCommands(previous: previous, current: current)
        var ruleApplyFailed = false
        for command in ruleCommands {
            let result = await doctorService.runSupportCommand(command)
            await MainActor.run {
                self.appendCommandLog(from: result)
            }
            if !result.isSuccess {
                ruleApplyFailed = true
            }
        }

        let allNeverTiled = Set(current.neverTileApps)
        if !allNeverTiled.isEmpty {
            await floatOpenWindowsForApps(allNeverTiled)
        }
        let alwaysTileConflict = firstAlwaysTileDesktopConflict(for: Set(current.alwaysTileApps))

        await MainActor.run {
            let baseMessage: String?
            if current.manualTilingModeEnabled {
                if !ruleApplyFailed && !configApplyFailed {
                    baseMessage = "Manual Tiling Mode enabled. Existing windows stay as-is; new windows should stop auto-tiling."
                } else if self.lastErrorMessage == nil {
                    self.lastErrorMessage = "Saved settings, but some live yabai rules did not apply. Restart yabai if behavior looks wrong."
                    baseMessage = nil
                } else {
                    baseMessage = nil
                }
            } else {
                if !ruleApplyFailed && !configApplyFailed {
                    baseMessage = "Window behavior updated."
                } else if self.lastErrorMessage == nil {
                    self.lastErrorMessage = "Saved settings, but some runtime updates did not apply. Restart yabai if behavior looks wrong."
                    baseMessage = nil
                } else {
                    baseMessage = nil
                }
            }

            if let baseMessage {
                if let conflict = alwaysTileConflict {
                    self.lastActionMessage = "\(baseMessage) Desktop tiling is off on Desktop \(conflict.desktop); enable it to tile \(conflict.app) there."
                } else {
                    self.lastActionMessage = baseMessage
                }
                self.lastErrorMessage = nil
            }
        }
        await refreshLiveState()
        await refreshDoctor()
        await refreshWindowBehaviorConfig()
    }

    private func floatOpenWindowsForApps(_ appNames: Set<String>) async {
        let names = Set(appNames.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        guard !names.isEmpty else { return }
        let openWindows = liveStateSnapshot?.windows ?? []
        for window in openWindows where names.contains(window.app) && !window.floating {
            let result = await doctorService.runSupportCommand(
                yabaiCommand(["-m", "window", String(window.id), "--toggle", "float"], timeout: 1.5)
            )
            await MainActor.run {
                self.appendCommandLog(from: result)
            }
            if result.isSuccess {
                await bringWindowToFront(windowID: window.id)
            }
        }
    }

    private func firstAlwaysTileDesktopConflict(for appNames: Set<String>) -> (app: String, desktop: Int)? {
        let names = Set(appNames.map { normalizedAppRuleKey($0) }.filter { !$0.isEmpty })
        guard !names.isEmpty else { return nil }
        guard let snapshot = liveStateSnapshot else { return nil }

        for window in snapshot.windows where !window.isHidden && !window.isMinimized {
            let appKey = normalizedAppRuleKey(window.app)
            guard names.contains(appKey) else { continue }
            guard let layout = snapshot.spaces.first(where: { $0.index == window.space })?.layout?.lowercased() else { continue }
            if layout == "float" {
                return (app: window.app, desktop: window.space)
            }
        }
        return nil
    }

    private func clampedGlobalSpacingValue(_ value: Int) -> Int {
        min(max(value, 0), 100)
    }
}
