import Foundation

@MainActor
extension AppModel {
    var releaseDefaultsResetButtonTitle: String {
        "Restore All Default Settings"
    }

    func ensureReleaseDefaultsInitializedIfNeeded() async {
        updateReleaseDefaultsStatus()
        guard !hasAttemptedReleaseDefaultsInitialization else { return }
        hasAttemptedReleaseDefaultsInitialization = true

        let profile = releaseDefaultsService.currentProfile()
        do {
            try releaseDefaultsService.writeProfileSnapshotToDisk(profile)
        } catch {
            // Snapshot file is informational. Keep runtime defaults flow alive.
        }

        let defaults = UserDefaults.standard
        let initialized = defaults.bool(forKey: AppModel.releaseDefaultsInitializedDefaultsKey)
        if !initialized {
            let hasLegacyFootprint = await detectLegacySettingsFootprint()
            if hasLegacyFootprint {
                defaults.set(true, forKey: AppModel.releaseDefaultsInitializedDefaultsKey)
                defaults.set(profile.profileVersion, forKey: AppModel.releaseDefaultsSeenVersionDefaultsKey)
                updateReleaseDefaultsStatus(currentProfile: profile)
                return
            }
            _ = await applyReleaseDefaultsProfile(profile, mode: .firstInstall)
            updateReleaseDefaultsStatus(currentProfile: profile)
            return
        }

        defaults.set(profile.profileVersion, forKey: AppModel.releaseDefaultsSeenVersionDefaultsKey)
        updateReleaseDefaultsStatus(currentProfile: profile)
    }

    func resetToReleaseDefaults() {
        Task { [weak self] in
            guard let self else { return }
            let profile = self.releaseDefaultsService.currentProfile()
            do {
                try self.releaseDefaultsService.writeProfileSnapshotToDisk(profile)
            } catch {
                // Keep reset flow running even if snapshot write fails.
            }
            _ = await self.applyReleaseDefaultsProfile(profile, mode: .manualReset)
            self.updateReleaseDefaultsStatus(currentProfile: profile)
        }
    }

    private func detectLegacySettingsFootprint() async -> Bool {
        if releaseDefaultsService.hasLegacyUserDefaultsFootprint() {
            return true
        }
        if let state = try? await configService.loadConfigDocument() {
            if state.hasManagedSection {
                return true
            }
            if state.fileExists && !state.fullContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return true
            }
        }
        if let state = try? await yabaiRulesConfigService.loadConfigDocument() {
            if state.hasManagedSection {
                return true
            }
            if state.fileExists && !state.fullContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return true
            }
        }
        if !(await ManagedHelperService.shared.detectExistingExternalHelpers()).isEmpty {
            return true
        }
        return false
    }

    private func applyReleaseDefaultsProfile(_ profile: ReleaseDefaultsProfile, mode: ReleaseDefaultsApplyMode) async -> Bool {
        if isSavingConfig || isSavingYabaiConfig || isRestoringConfig || isRestoringYabaiConfig {
            lastErrorMessage = "Please wait for current save/restore operations to finish."
            lastActionMessage = nil
            return false
        }

        let previousPolicy = (try? await yabaiRulesConfigService.loadConfigDocument())?.policy ?? originalWindowBehaviorPolicy

        do {
            _ = try await configService.saveManagedSection(body: profile.configState.managedSkhdSectionBody)
        } catch {
            lastErrorMessage = "Applying release defaults failed while saving skhdrc: \(error.localizedDescription)"
            lastActionMessage = nil
            return false
        }

        do {
            _ = try await yabaiRulesConfigService.saveWindowBehaviorPolicy(profile.configState.windowBehaviorPolicy)
        } catch {
            lastErrorMessage = "Applying release defaults failed while saving yabairc: \(error.localizedDescription)"
            lastActionMessage = nil
            return false
        }

        applyReleaseDefaultsUserState(profile.userState)

        let defaults = UserDefaults.standard
        defaults.set(true, forKey: AppModel.releaseDefaultsInitializedDefaultsKey)
        defaults.set(profile.profileVersion, forKey: AppModel.releaseDefaultsAppliedVersionDefaultsKey)
        defaults.set(profile.profileVersion, forKey: AppModel.releaseDefaultsSeenVersionDefaultsKey)

        await runBestEffortSkhdRestart(afterConfigChange: false)
        if canRunYabaiRuntimeCommands {
            await applyWindowBehaviorRuntime(previous: previousPolicy, current: profile.configState.windowBehaviorPolicy)
        } else {
            await refreshWindowBehaviorConfig()
        }
        await refreshConfig()
        await refreshShortcuts()
        await refreshLiveState()
        await refreshDoctor()
        await refreshBootstrapSetup()

        switch mode {
        case .firstInstall:
            lastActionMessage = "Applied release defaults \(profile.profileVersion) on first launch."
        case .manualReset:
            lastActionMessage = "Applied release defaults \(profile.profileVersion)."
        }
        lastErrorMessage = nil
        return true
    }

    private func applyReleaseDefaultsUserState(_ state: ReleaseDefaultsUserState) {
        pinnedFeatureControlIDs = Array(NSOrderedSet(array: state.pinnedFeatureControlIDs)) as? [String] ?? state.pinnedFeatureControlIDs
        pinnedDirectionalGroupIDs = Array(NSOrderedSet(array: state.pinnedDirectionalGroupIDs)) as? [String] ?? state.pinnedDirectionalGroupIDs
        shortcutsCustomOrderIDs = Array(NSOrderedSet(array: state.shortcutsCustomOrderIDs)) as? [String] ?? state.shortcutsCustomOrderIDs
        windowLayoutTemplates = state.windowLayoutTemplates
        workSets = state.workSets
        activeWorkSetIDsByScope = state.activeWorkSetIDsByScope
        pinnedShortcutKeys = []
        persistPinnedFeatureControlIDs()
        persistPinnedDirectionalGroupIDs()
        persistPinnedShortcutKeys()
        persistShortcutsCustomOrderIDs()
        persistWindowLayoutTemplates()
        persistWorkSets()

        showWindowBadgeOverlay = state.showWindowBadgeOverlay
        UserDefaults.standard.set(showWindowBadgeOverlay, forKey: AppModel.showWindowBadgeOverlayDefaultsKey)
        showWindowOutlineOverlay = state.showWindowOutlineOverlay
        UserDefaults.standard.set(showWindowOutlineOverlay, forKey: AppModel.showWindowOutlineOverlayDefaultsKey)
        windowOutlineOverlayBaseWidth = state.windowOutlineOverlayBaseWidth
        UserDefaults.standard.set(windowOutlineOverlayBaseWidth, forKey: AppModel.windowOutlineOverlayBaseWidthDefaultsKey)
        tiledOverlayAccentColor = state.tiledOverlayAccentColor
        UserDefaults.standard.set(state.tiledOverlayAccentColor.userDefaultsArray, forKey: AppModel.tiledOverlayAccentColorDefaultsKey)
        floatingOverlayAccentColor = state.floatingOverlayAccentColor
        UserDefaults.standard.set(state.floatingOverlayAccentColor.userDefaultsArray, forKey: AppModel.floatingOverlayAccentColorDefaultsKey)
        desktopScrubEnabled = state.desktopScrubEnabled
        desktopScrubTriggerModifiers = DesktopScrubModifier.normalize(state.desktopScrubTriggerModifiers)
        desktopScrubTriggerCharacter = state.desktopScrubTriggerCharacter
        desktopScrubSensitivity = state.desktopScrubSensitivity
        desktopScrubInvertDirection = state.desktopScrubInvertDirection
        persistDesktopScrubSettings()
        refreshDesktopScrubConfiguration()
        raiseOnFloatToggleEnabled = state.raiseOnFloatToggleEnabled
        UserDefaults.standard.set(raiseOnFloatToggleEnabled, forKey: AppModel.raiseOnFloatToggleDefaultsKey)
        performancePreset = state.performanceSettings.preset
        performanceForegroundPollingSeconds = state.performanceSettings.foregroundPollingSeconds
        performanceBackgroundPollingSeconds = state.performanceSettings.backgroundPollingSeconds
        performanceKeepOnTopEnforcementSeconds = state.performanceSettings.keepOnTopEnforcementSeconds
        miniMapHoverTitlesEnabled = state.performanceSettings.miniMapHoverTitlesEnabled
        hideMinimizedHelperWindowsInMaps = state.performanceSettings.hideMinimizedHelperWindowsInMaps
        performanceFastLiveRefreshEnabled = state.performanceSettings.fastLiveRefreshEnabled
        keepOnTopEnforcementEnabled = state.performanceSettings.keepOnTopEnforcementEnabled
        persistPerformanceSettings()

        appForegroundPolicyByName = state.appForegroundPolicyByName
        persistAppForegroundPolicies()
        reconcileShortcutsCustomOrderIDsToCurrentItems()
        refreshWindowBadges()
    }

    private func updateReleaseDefaultsStatus(currentProfile: ReleaseDefaultsProfile? = nil) {
        let profile = currentProfile ?? releaseDefaultsService.currentProfile()
        let defaults = UserDefaults.standard
        if let applied = defaults.string(forKey: AppModel.releaseDefaultsAppliedVersionDefaultsKey) {
            if applied == profile.profileVersion {
                releaseDefaultsStatus = .upToDate(version: profile.profileVersion)
            } else {
                releaseDefaultsStatus = .updateAvailable(currentVersion: profile.profileVersion, lastAppliedVersion: applied)
            }
        } else {
            releaseDefaultsStatus = .neverApplied(currentVersion: profile.profileVersion)
        }
    }
}
