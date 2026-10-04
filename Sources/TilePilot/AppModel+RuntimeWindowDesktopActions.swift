import AppKit
import ApplicationServices
import Foundation

private enum MegamapDesktopSwitchCapturePolicy {
    case none
    case incremental
}

private enum VisibleWindowsLayoutOperation {
    case floatAll
    case tileAll
    case gridFloating
    case rebuildTileLayout
}

private struct TemplateApplyRunResult {
    let assignedCount: Int
    let emptyConstrainedSlotCount: Int
    let extraWindowCount: Int
    let limitedCount: Int
    let failedCount: Int
    let errorMessage: String?
}

private struct WorkSetLaunchMissingAppsResult {
    var launched: Int = 0
    var noWindow: Int = 0
    var failed: Int = 0
}

private struct RecentWindowTilerDesktopState {
    let spaceIndex: Int
    let display: DisplayState?
    let windows: [WindowState]
    let primaryWindowIDs: Set<Int>
    let tilingEnabledBySpaceIndex: [Int: Bool]
    let targetOptions: [RecentWindowTilerTargetOption]
}

private struct RecentWindowTilerAccessibilityInfo {
    let title: String
    let canMoveAndResize: Bool
    let isSupportedForPicker: Bool
}

private struct RecentWindowTilerTemplateApplyResult {
    let assignedCount: Int
    let ignoredSelectedCount: Int
    let emptyConstrainedSlotCount: Int
    let missingAssignedCount: Int
    let updated: Int
    let failed: Int
    let primaryFocused: Bool
}

private struct RuntimeLayoutWindow: Decodable {
    struct Frame: Decodable {
        let x: Double
        let y: Double
        let w: Double
        let h: Double
    }

    let id: Int
    let frame: Frame
    let isFloating: Bool
    let isVisible: Bool
    let isMinimized: Bool
    let isHidden: Bool
    let isNativeFullscreen: Bool
    let splitType: String

    var frameX: Double { frame.x }
    var frameY: Double { frame.y }
    var frameW: Double { frame.w }
    var frameH: Double { frame.h }

    private enum CodingKeys: String, CodingKey {
        case id
        case frame
        case isFloating = "is-floating"
        case isVisible = "is-visible"
        case isMinimized = "is-minimized"
        case isHidden = "is-hidden"
        case isNativeFullscreen = "is-native-fullscreen"
        case splitType = "split-type"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        frame = try container.decode(Frame.self, forKey: .frame)
        isFloating = try container.decodeIfPresent(Bool.self, forKey: .isFloating) ?? false
        isVisible = try container.decodeIfPresent(Bool.self, forKey: .isVisible) ?? false
        isMinimized = try container.decodeIfPresent(Bool.self, forKey: .isMinimized) ?? false
        isHidden = try container.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false
        isNativeFullscreen = try container.decodeIfPresent(Bool.self, forKey: .isNativeFullscreen) ?? false
        splitType = try container.decodeIfPresent(String.self, forKey: .splitType) ?? ""
    }
}

@MainActor
extension AppModel {
    func applyWindowLayoutTemplate(templateID: UUID) {
        Task { [weak self] in
            await self?.applyWindowLayoutTemplateInternal(templateID: templateID)
        }
    }

    func activateWorkSet(workSetID: UUID) {
        let previousTask = workSetActivationTask
        previousTask?.cancel()
        workSetActivationRequestID += 1
        let requestID = workSetActivationRequestID
        workSetActivationTask = Task { [weak self] in
            _ = await previousTask?.result
            guard let self else { return }
            guard self.workSetActivationRequestID == requestID else { return }
            await self.activateWorkSetInternal(workSetID: workSetID, requestID: requestID)
            await MainActor.run {
                if self.workSetActivationRequestID == requestID {
                    self.workSetActivationTask = nil
                }
            }
        }
    }

    func cycleWorkSetsCurrentDesktop() {
        guard let nextWorkSet = nextWorkSetForCurrentDesktopCycle() else {
            lastErrorMessage = cycleWorkSetsDisabledReason() ?? "No Work Sets are available on this desktop."
            lastActionMessage = nil
            return
        }
        activateWorkSet(workSetID: nextWorkSet.id)
    }

    func bringFloatingWindowsToFrontCurrentDesktop() {
        Task { [weak self] in
            guard let self else { return }
            await self.bringFloatingWindowsToFrontCurrentDesktop(
                flaggedOnly: false,
                reason: .manualAll,
                bypassCooldown: true
            )
        }
    }

    func bringFlaggedFloatingWindowsToFrontCurrentDesktop(reason: String = "manual") {
        Task { [weak self] in
            guard let self else { return }
            let internalReason: FloatingBringReason = reason == "auto" ? .autoTransition : .manualFlagged
            await self.bringFloatingWindowsToFrontCurrentDesktop(
                flaggedOnly: true,
                reason: internalReason,
                bypassCooldown: internalReason != .autoTransition
            )
        }
    }

    func tileFocusedWindowNow() {
        guard let focused = focusedWindowState else {
            lastErrorMessage = "No focused window detected."
            lastActionMessage = nil
            return
        }
        setWindowFloating(windowID: focused.id, shouldFloat: false, bringToFrontOnFloat: true)
    }

    func floatFocusedWindowNow() {
        guard let focused = focusedWindowState else {
            lastErrorMessage = "No focused window detected."
            lastActionMessage = nil
            return
        }
        setWindowFloating(windowID: focused.id, shouldFloat: true, bringToFrontOnFloat: true)
    }

    func toggleFocusedWindowTiling() {
        guard let focused = focusedWindowState else {
            lastErrorMessage = "No focused window detected."
            lastActionMessage = nil
            return
        }
        toggleWindowFloating(windowID: focused.id, bringToFrontOnFloat: true)
    }

    func setVisibleWindowsFloatingCurrentDesktop() {
        Task { [weak self] in
            await self?.applyVisibleWindowsLayoutOperation(.floatAll)
        }
    }

    func setVisibleWindowsTiledCurrentDesktop() {
        Task { [weak self] in
            await self?.applyVisibleWindowsLayoutOperation(.tileAll)
        }
    }

    func applyFloatingGridToCurrentDesktop() {
        Task { [weak self] in
            await self?.applyVisibleWindowsLayoutOperation(.gridFloating)
        }
    }

    func rebuildTileLayoutCurrentDesktop() {
        Task { [weak self] in
            await self?.applyVisibleWindowsLayoutOperation(.rebuildTileLayout)
        }
    }

    func focusWindow(windowID: Int) {
        guard let window = focusableWindow(windowID: windowID) else { return }
        Task { [weak self] in
            guard let self else { return }
            let focused = await self.focusWindowWithRestore(windowID: windowID, knownWindow: window)
            guard focused else {
                return
            }
            await MainActor.run {
                self.lastActionMessage = "Focused \(window.app)."
                self.lastErrorMessage = nil
            }
            self.scheduleMegamapDestinationCaptureIfNeeded(
                spaceIndex: window.space,
                delayMilliseconds: 420,
                minimumAgeSeconds: 0.0
            )
            await self.refreshLiveState()
        }
    }

    func focusWindow(windowID: Int, desktopIndex: Int) {
        guard let window = focusableWindow(windowID: windowID) else { return }
        Task { [weak self] in
            guard let self else { return }

            if let currentSpace = await self.queryCurrentFocusedSpaceIndex(),
               currentSpace != desktopIndex {
                let switched = await self.focusDesktopInternal(
                    index: desktopIndex,
                    updateMessages: false,
                    megamapCapturePolicy: .incremental
                )
                guard switched else {
                    await MainActor.run {
                        self.lastErrorMessage = "Could not switch to Desktop \(desktopIndex)."
                        self.lastActionMessage = nil
                    }
                    return
                }
                try? await Task.sleep(for: .milliseconds(180))
            }

            let focused = await self.focusWindowWithRestore(windowID: windowID, knownWindow: window)
            guard focused else {
                return
            }

            await MainActor.run {
                self.lastActionMessage = "Focused \(window.app)."
                self.lastErrorMessage = nil
            }
            self.scheduleMegamapDestinationCaptureIfNeeded(
                spaceIndex: desktopIndex,
                delayMilliseconds: 420,
                minimumAgeSeconds: 0.0
            )
            await self.refreshLiveState()
        }
    }

    func focusDesktop(index: Int) {
        Task { [weak self] in
            guard let self else { return }
            let switched = await self.focusDesktopInternal(
                index: index,
                updateMessages: true,
                megamapCapturePolicy: .incremental
            )
            guard switched else { return }
            await self.refreshLiveState()
        }
    }

    func desktopTilingEnabled(spaceIndex: Int) -> Bool? {
        guard let snapshot = liveStateSnapshot, snapshot.source == .yabai, !snapshot.degraded else { return nil }
        let layout = snapshot.spaces.first(where: { $0.index == spaceIndex })?.layout
        return tilingEnabled(forSpaceLayout: layout)
    }

    private func tilingEnabled(forSpaceLayout layout: String?) -> Bool? {
        guard let layout = layout?.lowercased() else { return nil }
        if layout == "float" { return false }
        if layout == "bsp" || layout == "stack" { return true }
        return nil
    }

    func desktopTilingDisabledReason(spaceIndex: Int) -> String? {
        guard canRunYabaiRuntimeCommands else {
            return yabaiRuntimeControlDisabledReason ?? "Desktop controls are unavailable."
        }
        guard let snapshot = liveStateSnapshot, snapshot.source == .yabai, !snapshot.degraded else {
            return "Desktop layout data is unavailable right now."
        }
        guard snapshot.spaces.contains(where: { $0.index == spaceIndex }) else {
            return "Desktop \(spaceIndex) is not currently available."
        }
        return nil
    }

    func persistDesktopTilingPreferences() {
        let raw = Dictionary(
            uniqueKeysWithValues: desktopTilingPreferencesBySpaceIndex.map { (String($0.key), $0.value) }
        )
        UserDefaults.standard.set(raw, forKey: AppModel.desktopTilingPreferencesDefaultsKey)
    }

    func seedAllFloatingDesktopTilingPreferencesIfEmpty(using snapshot: LiveStateSnapshot) {
        guard desktopTilingPreferencesBySpaceIndex.isEmpty else { return }
        guard snapshot.source == .yabai, !snapshot.degraded else { return }

        var preferences: [Int: Bool] = [:]
        for space in snapshot.spaces {
            guard let layout = space.layout?.lowercased() else { continue }
            guard layout == "float" else { return }
            preferences[space.index] = false
        }
        guard !preferences.isEmpty else { return }
        desktopTilingPreferencesBySpaceIndex = preferences
        persistDesktopTilingPreferences()
    }

    func applyPersistedDesktopTilingPreferencesIfNeeded(using snapshot: LiveStateSnapshot) async {
        guard !desktopTilingPreferencesBySpaceIndex.isEmpty else { return }
        guard canRunYabaiRuntimeCommands, snapshot.source == .yabai, !snapshot.degraded else { return }
        guard !isApplyingPersistedDesktopTilingPreferences else { return }

        let mismatches = snapshot.spaces.compactMap { space -> (spaceIndex: Int, enabled: Bool, currentLayout: String)? in
            guard let desired = desktopTilingPreferencesBySpaceIndex[space.index],
                  let layout = space.layout?.lowercased() else { return nil }
            let current: Bool?
            if layout == "float" {
                current = false
            } else if layout == "bsp" || layout == "stack" {
                current = true
            } else {
                current = nil
            }
            guard current != nil, current != desired else { return nil }
            return (space.index, desired, layout)
        }
        guard !mismatches.isEmpty else {
            lastDesktopTilingPreferenceApplySignature = nil
            return
        }

        let signature = mismatches
            .map { "\($0.spaceIndex)=\($0.enabled ? "on" : "off") from \($0.currentLayout)" }
            .sorted()
            .joined(separator: "|")
        let now = Date()
        if signature == lastDesktopTilingPreferenceApplySignature,
           let lastAttempt = lastDesktopTilingPreferenceApplyAttemptAt,
           now.timeIntervalSince(lastAttempt) < 10 {
            return
        }
        lastDesktopTilingPreferenceApplySignature = signature
        lastDesktopTilingPreferenceApplyAttemptAt = now

        isApplyingPersistedDesktopTilingPreferences = true
        defer { isApplyingPersistedDesktopTilingPreferences = false }

        for mismatch in mismatches {
            let targetLayout = mismatch.enabled ? "bsp" : "float"
            let result = await doctorService.runSupportCommand(
                yabaiCommand(["-m", "space", String(mismatch.spaceIndex), "--layout", targetLayout], timeout: 1.5)
            )
            appendCommandLog(from: result)
        }
    }

    func setDesktopTilingEnabled(spaceIndex: Int, enabled: Bool) {
        if let reason = desktopTilingDisabledReason(spaceIndex: spaceIndex) {
            lastErrorMessage = reason
            lastActionMessage = nil
            return
        }
        if let current = desktopTilingEnabled(spaceIndex: spaceIndex), current == enabled {
            desktopTilingPreferencesBySpaceIndex[spaceIndex] = enabled
            persistDesktopTilingPreferences()
            lastActionMessage = enabled ? "Desktop \(spaceIndex) tiling is already on." : "Desktop \(spaceIndex) tiling is already off."
            lastErrorMessage = nil
            return
        }

        Task { [weak self] in
            guard let self else { return }
            let targetLayout = enabled ? "bsp" : "float"
            let result = await self.doctorService.runSupportCommand(
                yabaiCommand(["-m", "space", String(spaceIndex), "--layout", targetLayout], timeout: 1.5)
            )
            await MainActor.run {
                self.appendCommandLog(from: result)
                if result.isSuccess {
                    self.desktopTilingPreferencesBySpaceIndex[spaceIndex] = enabled
                    self.persistDesktopTilingPreferences()
                    self.lastActionMessage = enabled ? "Desktop \(spaceIndex) tiling enabled." : "Desktop \(spaceIndex) tiling disabled."
                    self.lastErrorMessage = nil
                } else {
                    self.lastErrorMessage = enabled
                        ? "Failed to enable tiling on Desktop \(spaceIndex)."
                        : "Failed to disable tiling on Desktop \(spaceIndex)."
                    self.lastActionMessage = nil
                }
            }
            guard result.isSuccess else { return }
            await self.refreshLiveState()
            await self.refreshDoctor()
        }
    }

    func setAllDesktopTilingEnabled(enabled: Bool) {
        guard canRunYabaiRuntimeCommands else {
            lastErrorMessage = yabaiRuntimeControlDisabledReason ?? "Desktop controls are unavailable."
            lastActionMessage = nil
            return
        }
        guard let snapshot = liveStateSnapshot, snapshot.source == .yabai, !snapshot.degraded else {
            lastErrorMessage = "Desktop layout data is unavailable right now."
            lastActionMessage = nil
            return
        }
        let targetSpaces = snapshot.spaces.map(\.index).sorted()
        guard !targetSpaces.isEmpty else {
            lastErrorMessage = "No desktops available."
            lastActionMessage = nil
            return
        }

        Task { [weak self] in
            guard let self else { return }
            let targetLayout = enabled ? "bsp" : "float"
            var successCount = 0
            var successfulSpaces: [Int] = []
            for spaceIndex in targetSpaces {
                let result = await self.doctorService.runSupportCommand(
                    yabaiCommand(["-m", "space", String(spaceIndex), "--layout", targetLayout], timeout: 1.5)
                )
                await MainActor.run {
                    self.appendCommandLog(from: result)
                }
                if result.isSuccess {
                    successCount += 1
                    successfulSpaces.append(spaceIndex)
                }
            }
            await MainActor.run {
                for spaceIndex in successfulSpaces {
                    self.desktopTilingPreferencesBySpaceIndex[spaceIndex] = enabled
                }
                if !successfulSpaces.isEmpty {
                    self.persistDesktopTilingPreferences()
                }
                if successCount == targetSpaces.count {
                    self.lastActionMessage = enabled ? "Enabled tiling on all desktops." : "Disabled tiling on all desktops."
                    self.lastErrorMessage = nil
                } else {
                    self.lastActionMessage = enabled
                        ? "Enabled tiling on \(successCount)/\(targetSpaces.count) desktops."
                        : "Disabled tiling on \(successCount)/\(targetSpaces.count) desktops."
                    self.lastErrorMessage = "Some desktops could not be updated."
                }
            }
            await self.refreshLiveState()
            await self.refreshDoctor()
        }
    }

    func toggleWindowFloating(windowID: Int, bringToFrontOnFloat: Bool = false) {
        guard let window = runtimeControllableWindow(windowID: windowID) else { return }
        setWindowFloating(windowID: windowID, shouldFloat: !window.floating, bringToFrontOnFloat: bringToFrontOnFloat)
    }

    func setWindowFloating(windowID: Int, shouldFloat: Bool, bringToFrontOnFloat: Bool = false) {
        guard let window = runtimeControllableWindow(windowID: windowID) else { return }
        if window.floating == shouldFloat {
            lastActionMessage = shouldFloat ? "\(window.app) is already floating." : "\(window.app) is already tiled."
            lastErrorMessage = nil
            return
        }

        Task { [weak self] in
            guard let self else { return }
            let toggle = await self.doctorService.runSupportCommand(
                yabaiCommand(["-m", "window", String(windowID), "--toggle", "float"], timeout: 1.5)
            )
            await MainActor.run {
                self.appendCommandLog(from: toggle)
            }

            let toggled: Bool
            if toggle.isSuccess {
                toggled = true
            } else if window.supportsFocusedFloatToggleFallback {
                toggled = await self.setWindowFloatingUsingFocusedFallback(
                    window: window
                )
            } else {
                await MainActor.run {
                    self.lastErrorMessage = shouldFloat ? "Failed to set window to floating." : "Failed to set window to tiled."
                    self.lastActionMessage = nil
                }
                return
            }

            guard toggled else {
                await MainActor.run {
                    self.lastErrorMessage = shouldFloat ? "Failed to set window to floating." : "Failed to set window to tiled."
                    self.lastActionMessage = nil
                }
                return
            }

            let foregroundPolicyEnabled = self.appForegroundPolicy(for: window.app) == .keepFrontWhenFloating
            if shouldFloat && (bringToFrontOnFloat || self.raiseOnFloatToggleEnabled || foregroundPolicyEnabled) {
                let shouldAllowFocusFallback = bringToFrontOnFloat || self.raiseOnFloatToggleEnabled
                _ = await self.raiseWindowOnly(
                    windowID: windowID,
                    targetSpace: window.space,
                    bypassCooldown: true,
                    allowFocusFallback: shouldAllowFocusFallback
                )
            }
            if shouldFloat && foregroundPolicyEnabled {
                await self.bringFloatingWindowsToFrontCurrentDesktop(
                    flaggedOnly: true,
                    reason: .floatToggle,
                    bypassCooldown: false
                )
            }

            await MainActor.run {
                self.lastActionMessage = shouldFloat ? "Window set to floating." : "Window set to tiled."
                self.lastErrorMessage = nil
            }
            await self.refreshLiveState()
        }
    }

    private func setWindowFloatingUsingFocusedFallback(window: WindowState) async -> Bool {
        if let currentSpace = await queryCurrentFocusedSpaceIndex(),
           currentSpace != window.space {
            let switched = await focusDesktopInternal(
                index: window.space,
                updateMessages: false,
                megamapCapturePolicy: .incremental
            )
            guard switched else { return false }
            try? await Task.sleep(for: .milliseconds(180))
        }

        let focused = await focusWindowWithRestore(windowID: window.id, knownWindow: window)
        guard focused else { return false }

        let toggleFocused = await doctorService.runSupportCommand(
            yabaiCommand(["-m", "window", "--toggle", "float"], timeout: 1.5)
        )
        await MainActor.run {
            appendCommandLog(from: toggleFocused)
        }
        guard toggleFocused.isSuccess else { return false }

        return true
    }

    private func applyVisibleWindowsLayoutOperation(_ operation: VisibleWindowsLayoutOperation) async {
        guard canRunYabaiRuntimeCommands else {
            await MainActor.run {
                self.lastErrorMessage = self.yabaiRuntimeControlDisabledReason ?? "Window controls are unavailable right now."
                self.lastActionMessage = nil
            }
            return
        }

        guard var state = await currentDesktopVisibleWindowsForBulkLayout() else { return }
        let totalVisibleCount = state.windows.count
        let limitedCount = state.windows.filter { !$0.isRuntimeManageable }.count
        let neverAutoTileWindows = bulkLayoutNeverAutoTileWindows(from: state.windows)
        let tilingEligibleWindows = bulkLayoutTilingEligibleWindows(from: state.windows)

        if totalVisibleCount == 0 {
            await MainActor.run {
                self.lastErrorMessage = "No visible windows on the current desktop."
                self.lastActionMessage = nil
            }
            return
        }

        switch operation {
        case .floatAll:
            let targets = state.windows.filter { $0.isRuntimeManageable && !$0.floating }
            let result = await setFloatingStateForWindows(targets, shouldFloat: true)
            if result.updated > 0 {
                await bringFloatingWindowsToFrontCurrentDesktop(
                    flaggedOnly: false,
                    reason: .manualAll,
                    bypassCooldown: true
                )
            }
            await finishVisibleWindowsLayoutOperation(
                operation,
                totalVisibleCount: totalVisibleCount,
                updatedCount: result.updated,
                ruleExceptionCount: 0,
                limitedCount: limitedCount,
                failedCount: result.failed
            )

        case .tileAll:
            guard await runCurrentDesktopLayoutCommands([["-m", "space", "--layout", "bsp"]]) else { return }
            let floatExceptions = await setFloatingStateForWindows(
                neverAutoTileWindows.filter { $0.isRuntimeManageable && !$0.floating },
                shouldFloat: true
            )
            let result = await setFloatingStateForWindows(
                tilingEligibleWindows.filter { $0.isRuntimeManageable && $0.floating },
                shouldFloat: false
            )
            guard await runCurrentDesktopLayoutCommands([["-m", "space", "--balance"]]) else { return }
            await finishVisibleWindowsLayoutOperation(
                operation,
                totalVisibleCount: totalVisibleCount,
                updatedCount: result.updated,
                ruleExceptionCount: neverAutoTileWindows.count,
                limitedCount: limitedCount,
                failedCount: result.failed + floatExceptions.failed
            )

        case .gridFloating:
            let floatResult = await setFloatingStateForWindows(
                state.windows.filter { $0.isRuntimeManageable && !$0.floating },
                shouldFloat: true
            )
            await refreshLiveState()
            guard let refreshed = await currentDesktopVisibleWindowsForBulkLayout() else { return }
            state = refreshed
            let gridResult = await applyGridFrames(
                to: state.windows.filter { $0.isRuntimeManageable },
                display: state.display
            )
            await bringFloatingWindowsToFrontCurrentDesktop(
                flaggedOnly: false,
                reason: .manualAll,
                bypassCooldown: true
            )
            await finishVisibleWindowsLayoutOperation(
                operation,
                totalVisibleCount: totalVisibleCount,
                updatedCount: floatResult.updated + gridResult.updated,
                ruleExceptionCount: 0,
                limitedCount: limitedCount,
                failedCount: floatResult.failed + gridResult.failed
            )

        case .rebuildTileLayout:
            let floatExceptions = await setFloatingStateForWindows(
                neverAutoTileWindows.filter { $0.isRuntimeManageable && !$0.floating },
                shouldFloat: true
            )
            let rebuildResult = await rebuildBalancedTileLayout(
                spaceIndex: state.spaceIndex,
                windows: tilingEligibleWindows
            )

            await finishVisibleWindowsLayoutOperation(
                operation,
                totalVisibleCount: totalVisibleCount,
                updatedCount: rebuildResult.updated,
                ruleExceptionCount: neverAutoTileWindows.count,
                limitedCount: limitedCount,
                failedCount: rebuildResult.failed + floatExceptions.failed
            )
        }

        await refreshLiveState()
        await refreshDoctor()
    }

    func presentRecentWindowTiler() {
        acknowledgeInitialStatusIfNeeded()
        guard canRunYabaiRuntimeCommands else {
            lastErrorMessage = yabaiRuntimeControlDisabledReason ?? "Window controls are unavailable right now."
            lastActionMessage = nil
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.refreshLiveState()
            guard let state = await self.currentDesktopWindowsForRecentWindowTiler() else { return }
            let candidates = self.recentWindowTilerCandidates(
                from: state.windows,
                primaryWindowIDs: state.primaryWindowIDs,
                tilingEnabledBySpaceIndex: state.tilingEnabledBySpaceIndex
            )
            guard !candidates.isEmpty else {
                self.lastErrorMessage = "No controllable windows on the current desktop."
                self.lastActionMessage = nil
                self.recentWindowTilerState = nil
                return
            }

            let displayFrame = self.recentWindowTilerDisplayFrame(display: state.display)
            let templateOptions = self.recentWindowTilerTemplateOptions(display: state.display)
            let defaultMode = self.recentWindowTilerDefaultMode(templateOptions: templateOptions)
            let selectedTemplateID = self.recentWindowTilerDefaultTemplateID(templateOptions: templateOptions)
            let backdropEnabled = UserDefaults.standard.bool(
                forKey: AppModel.recentWindowTilerBackdropEnabledDefaultsKey
            )
            let backdropColor = self.recentWindowTilerBackdropColor()
            let prepared = self.preparedRecentWindowTilerCandidates(
                candidates,
                mode: defaultMode,
                selectedTemplateID: selectedTemplateID,
                templateOptions: templateOptions,
                displayFrame: displayFrame
            )
            self.recentWindowTilerState = RecentWindowTilerPresentationState(
                candidates: prepared.candidates,
                selectedWindowIDs: prepared.selectedWindowIDs,
                mode: defaultMode,
                backdropEnabled: backdropEnabled,
                backdropColor: backdropColor,
                targetSpaceIndex: state.spaceIndex,
                targetDisplayID: state.display?.id,
                targetOptions: state.targetOptions,
                displayAspectRatio: self.recentWindowGridAspectRatio(display: state.display),
                displayFrame: displayFrame,
                templateOptions: templateOptions,
                selectedTemplateID: selectedTemplateID,
                templateSlotWindowIDs: prepared.templateSlotWindowIDs
            )
            self.lastErrorMessage = nil
        }
    }

    func dismissRecentWindowTiler() {
        recentWindowTilerState = nil
    }

    func refreshRecentWindowTiler() {
        guard let state = recentWindowTilerState else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.refreshRecentWindowTilerSnapshot(preserving: state)
        }
    }

    func setRecentWindowTilerTargetDisplay(_ displayID: Int) {
        guard let state = recentWindowTilerState,
              let target = state.targetOptions.first(where: { $0.displayID == displayID }),
              state.targetDisplayID != target.displayID else {
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.refreshRecentWindowTilerSnapshot(
                preserving: state,
                targetSpaceIndex: target.spaceIndex,
                targetDisplayID: target.displayID,
                resetSelection: true
            )
        }
    }

    func focusRecentWindowTilerCandidate(windowID: Int) {
        focusWindow(windowID: windowID)
    }

    func closeRecentWindowTilerCandidate(windowID: Int) {
        guard let state = recentWindowTilerState,
              let candidate = state.candidates.first(where: { $0.windowID == windowID }) else {
            return
        }
        let knownWindow = (latestLiveStateSnapshot ?? liveStateSnapshot)?.windows.first(where: { $0.id == windowID })

        Task { @MainActor [weak self] in
            guard let self else { return }
            let closeRequested = await self.closeRecentWindowTilerWindow(windowID: windowID, knownWindow: knownWindow)
            guard closeRequested else {
                self.lastErrorMessage = "Could not close \(candidate.app)."
                self.lastActionMessage = nil
                return
            }

            self.removeRecentWindowTilerCandidate(windowID: windowID)
            self.lastActionMessage = "Close requested for \(candidate.app)."
            self.lastErrorMessage = nil

            try? await Task.sleep(for: .milliseconds(260))
            if let updatedState = self.recentWindowTilerState {
                await self.refreshRecentWindowTilerSnapshot(preserving: updatedState)
            }
        }
    }

    func toggleRecentWindowTilerSelection(windowID: Int) {
        guard var state = recentWindowTilerState,
              let candidate = state.candidates.first(where: { $0.windowID == windowID }),
              candidate.isSelectable(in: state.mode) else {
            return
        }
        if state.selectedWindowIDs.contains(windowID) {
            state.selectedWindowIDs.remove(windowID)
            if state.mode == .template {
                state.templateSlotWindowIDs = state.templateSlotWindowIDs.map { $0 == windowID ? nil : $0 }
            }
        } else {
            state.selectedWindowIDs.insert(windowID)
            if state.mode == .template {
                state.templateSlotWindowIDs = recentWindowTilerTemplateSlotWindowIDs(for: state)
            }
        }
        persistRecentWindowTilerPreferredSelectionCount(state.selectedCount)
        recentWindowTilerState = state
    }

    private func removeRecentWindowTilerCandidate(windowID: Int) {
        guard var state = recentWindowTilerState else { return }
        state.candidates.removeAll { $0.windowID == windowID }
        state.selectedWindowIDs.remove(windowID)
        state.templateSlotWindowIDs = state.templateSlotWindowIDs.map { $0 == windowID ? nil : $0 }
        recentWindowTilerState = state.candidates.isEmpty ? nil : state
    }

    private func refreshRecentWindowTilerSnapshot(
        preserving existingState: RecentWindowTilerPresentationState,
        targetSpaceIndex: Int? = nil,
        targetDisplayID: Int? = nil,
        resetSelection: Bool = false
    ) async {
        await refreshLiveState()
        guard let targetState = await currentDesktopWindowsForRecentWindowTiler(
            targetSpaceIndex: targetSpaceIndex ?? existingState.targetSpaceIndex,
            targetDisplayID: targetDisplayID ?? existingState.targetDisplayID
        ) else {
            return
        }

        let freshCandidates = recentWindowTilerCandidates(
            from: targetState.windows,
            primaryWindowIDs: targetState.primaryWindowIDs,
            tilingEnabledBySpaceIndex: targetState.tilingEnabledBySpaceIndex
        )
        guard !freshCandidates.isEmpty else {
            recentWindowTilerState = nil
            lastErrorMessage = "No controllable windows on this desktop."
            lastActionMessage = nil
            return
        }

        let displayFrame = recentWindowTilerDisplayFrame(display: targetState.display)
        let templateOptions = recentWindowTilerTemplateOptions(display: targetState.display)
        let mode: RecentWindowTilerMode = existingState.mode == .template && templateOptions.isEmpty ? .floatingGrid : existingState.mode
        let selectedTemplateID: UUID? = {
            guard !templateOptions.isEmpty else { return nil }
            if let existingID = existingState.selectedTemplateID,
               templateOptions.contains(where: { $0.id == existingID }) {
                return existingID
            }
            return recentWindowTilerDefaultTemplateID(templateOptions: templateOptions)
        }()

        let candidates = freshCandidates

        var selectedWindowIDs = resetSelection ? [] : existingState.selectedWindowIDs.intersection(Set(candidates.map(\.windowID)))
        selectedWindowIDs.formIntersection(Set(candidates.filter { $0.isSelectable(in: mode) }.map(\.windowID)))

        var templateSlotWindowIDs: [Int?] = []
        if mode == .template,
           let selectedTemplateID,
           let template = templateOptions.first(where: { $0.id == selectedTemplateID }) {
            let selectableIDs = Set(candidates.filter { $0.isSelectable(in: .template) }.map(\.windowID))
            let slotCount = WindowLayoutTemplate.sortedSlots(template.slots).count
            templateSlotWindowIDs = Array(existingState.templateSlotWindowIDs.prefix(slotCount)).map { windowID in
                guard let windowID,
                      selectedWindowIDs.contains(windowID),
                      selectableIDs.contains(windowID) else {
                    return nil
                }
                return windowID
            }
            if templateSlotWindowIDs.count < slotCount {
                templateSlotWindowIDs += Array(repeating: nil, count: slotCount - templateSlotWindowIDs.count)
            }
        }

        if selectedWindowIDs.isEmpty {
            let prepared = preparedRecentWindowTilerCandidates(
                candidates,
                mode: mode,
                selectedTemplateID: selectedTemplateID,
                templateOptions: templateOptions,
                displayFrame: displayFrame
            )
            selectedWindowIDs = prepared.selectedWindowIDs
            templateSlotWindowIDs = prepared.templateSlotWindowIDs
        }

        recentWindowTilerState = RecentWindowTilerPresentationState(
            candidates: candidates,
            selectedWindowIDs: selectedWindowIDs,
            mode: mode,
            backdropEnabled: existingState.backdropEnabled,
            backdropColor: existingState.backdropColor,
            targetSpaceIndex: targetState.spaceIndex,
            targetDisplayID: targetState.display?.id,
            targetOptions: targetState.targetOptions,
            displayAspectRatio: recentWindowGridAspectRatio(display: targetState.display),
            displayFrame: displayFrame,
            templateOptions: templateOptions,
            selectedTemplateID: selectedTemplateID,
            templateSlotWindowIDs: templateSlotWindowIDs
        )
        lastErrorMessage = nil
    }

    func setRecentWindowTilerMode(_ mode: RecentWindowTilerMode) {
        guard var state = recentWindowTilerState, state.mode != mode else { return }
        guard mode != .template || state.canUseTemplateMode else { return }

        state.mode = mode
        if mode == .template, let selectedTemplateID = state.selectedTemplateID {
            let prepared = preparedRecentWindowTilerCandidates(
                state.candidates,
                mode: mode,
                selectedTemplateID: selectedTemplateID,
                templateOptions: state.templateOptions,
                displayFrame: state.displayFrame
            )
            state.candidates = prepared.candidates
            state.selectedWindowIDs = prepared.selectedWindowIDs
            state.templateSlotWindowIDs = prepared.templateSlotWindowIDs
        } else {
            state.selectedWindowIDs.formIntersection(state.selectableWindowIDs(for: mode))
            state.templateSlotWindowIDs = []
        }
        persistRecentWindowTilerLastMode(mode)
        persistRecentWindowTilerPreferredSelectionCount(state.selectedCount)
        recentWindowTilerState = state
    }

    func setRecentWindowTilerBackdropEnabled(_ enabled: Bool) {
        guard var state = recentWindowTilerState, state.backdropEnabled != enabled else { return }
        state.backdropEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: AppModel.recentWindowTilerBackdropEnabledDefaultsKey)
        recentWindowTilerState = state
    }

    func setRecentWindowTilerBackdropColor(_ color: OverlayAccentColor) {
        guard var state = recentWindowTilerState, state.backdropColor != color else { return }
        state.backdropColor = color
        UserDefaults.standard.set(
            color.userDefaultsArray,
            forKey: AppModel.recentWindowTilerBackdropColorDefaultsKey
        )
        recentWindowTilerState = state
    }

    func setRecentWindowTilerTemplate(_ templateID: UUID) {
        guard var state = recentWindowTilerState,
              state.templateOptions.contains(where: { $0.id == templateID }),
              state.selectedTemplateID != templateID else {
            return
        }

        state.selectedTemplateID = templateID
        if state.mode == .template {
            let prepared = preparedRecentWindowTilerCandidates(
                state.candidates,
                mode: .template,
                selectedTemplateID: templateID,
                templateOptions: state.templateOptions,
                displayFrame: state.displayFrame
            )
            state.candidates = prepared.candidates
            state.selectedWindowIDs = prepared.selectedWindowIDs
            state.templateSlotWindowIDs = prepared.templateSlotWindowIDs
        }
        persistRecentWindowTilerLastTemplateID(templateID)
        recentWindowTilerState = state
    }

    func reorderRecentWindowTilerCandidate(draggedWindowID: Int, targetWindowID: Int) {
        guard var state = recentWindowTilerState,
              draggedWindowID != targetWindowID,
              let sourceIndex = state.candidates.firstIndex(where: { $0.windowID == draggedWindowID }),
              let targetIndex = state.candidates.firstIndex(where: { $0.windowID == targetWindowID }) else {
            return
        }

        let candidate = state.candidates.remove(at: sourceIndex)
        let insertionIndex = sourceIndex < targetIndex ? targetIndex : targetIndex
        state.candidates.insert(candidate, at: insertionIndex)
        if state.mode == .template,
           let sourceSlotIndex = state.templateSlotWindowIDs.firstIndex(where: { $0 == draggedWindowID }),
           let targetSlotIndex = state.templateSlotWindowIDs.firstIndex(where: { $0 == targetWindowID }) {
            state.templateSlotWindowIDs.swapAt(sourceSlotIndex, targetSlotIndex)
        }
        recentWindowTilerState = state
    }

    func applyRecentWindowTilerSelection() {
        guard let state = recentWindowTilerState else { return }
        applyRecentWindowTilerSelection(
            orderedWindowIDs: state.orderedEffectiveSelectedWindowIDs,
            mode: state.mode,
            backdropEnabled: state.backdropEnabled,
            backdropColor: state.backdropColor,
            templateID: state.selectedTemplateID,
            templateSlotWindowIDs: state.mode == .template ? state.templateSlotWindowIDs : [],
            targetSpaceIndex: state.targetSpaceIndex,
            targetDisplayID: state.targetDisplayID
        )
    }

    func applyRecentWindowTilerSelection(
        orderedWindowIDs: [Int],
        mode: RecentWindowTilerMode,
        backdropEnabled: Bool = false,
        backdropColor: OverlayAccentColor = .workSetBackdropDefault,
        templateID: UUID? = nil,
        templateSlotWindowIDs: [Int?] = [],
        targetSpaceIndex: Int? = nil,
        targetDisplayID: Int? = nil
    ) {
        guard !orderedWindowIDs.isEmpty else {
            lastErrorMessage = "Select at least one window."
            lastActionMessage = nil
            return
        }
        if mode == .template, templateID == nil {
            lastErrorMessage = "Choose a template first."
            lastActionMessage = nil
            return
        }

        persistRecentWindowTilerPreferredSelectionCount(orderedWindowIDs.count)
        persistRecentWindowTilerLastMode(mode)
        if let templateID {
            persistRecentWindowTilerLastTemplateID(templateID)
        }
        recentWindowTilerState = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.applyRecentWindowTilerSelectionInternal(
                orderedWindowIDs: orderedWindowIDs,
                mode: mode,
                backdropEnabled: backdropEnabled,
                backdropColor: backdropColor,
                templateID: templateID,
                templateSlotWindowIDs: templateSlotWindowIDs,
                targetSpaceIndex: targetSpaceIndex,
                targetDisplayID: targetDisplayID
            )
        }
    }

    private func recentWindowTilerCandidates(
        from windows: [WindowState],
        primaryWindowIDs: Set<Int>,
        tilingEnabledBySpaceIndex: [Int: Bool]
    ) -> [RecentWindowTilerCandidate] {
        windows
            .enumerated()
            .compactMap {
                recentWindowTilerCandidate(
                    from: $0.element,
                    frontToBackOrder: $0.offset,
                    isOnTargetDisplay: primaryWindowIDs.contains($0.element.id),
                    tilingEnabled: tilingEnabledBySpaceIndex[$0.element.space]
                )
            }
    }

    private func recentWindowTilerDisplayFrame(display: DisplayState?) -> CGRect? {
        guard let display else { return nil }
        return CGRect(
            x: display.frameX,
            y: display.frameY,
            width: display.frameW,
            height: display.frameH
        )
    }

    private func recentWindowTilerTemplateOptions(display: DisplayState?) -> [RecentWindowTilerTemplateOption] {
        guard let display else { return [] }
        return windowLayoutTemplates
            .filter {
                !$0.slots.isEmpty &&
                $0.displayShapeKey.matches(width: display.frameW, height: display.frameH)
            }
            .map {
                RecentWindowTilerTemplateOption(
                    id: $0.id,
                    name: $0.name,
                    slots: $0.slots,
                    displayShapeKey: $0.displayShapeKey
                )
            }
    }

    private func recentWindowTilerDefaultMode(
        templateOptions: [RecentWindowTilerTemplateOption]
    ) -> RecentWindowTilerMode {
        let stored = UserDefaults.standard.string(forKey: AppModel.recentWindowTilerLastModeDefaultsKey)
            .flatMap(RecentWindowTilerMode.init(rawValue:))
        guard let stored else { return .floatingGrid }
        switch stored {
        case .template where !templateOptions.isEmpty:
            return .template
        case .floatingGrid:
            return .floatingGrid
        case .autoTiled, .template:
            return .floatingGrid
        }
    }

    private func recentWindowTilerDefaultTemplateID(
        templateOptions: [RecentWindowTilerTemplateOption]
    ) -> UUID? {
        guard !templateOptions.isEmpty else { return nil }
        if let raw = UserDefaults.standard.string(forKey: AppModel.recentWindowTilerLastTemplateIDDefaultsKey),
           let id = UUID(uuidString: raw),
           templateOptions.contains(where: { $0.id == id }) {
            return id
        }
        return templateOptions.first?.id
    }

    private func persistRecentWindowTilerLastMode(_ mode: RecentWindowTilerMode) {
        let defaultMode: RecentWindowTilerMode = mode == .autoTiled ? .floatingGrid : mode
        UserDefaults.standard.set(defaultMode.rawValue, forKey: AppModel.recentWindowTilerLastModeDefaultsKey)
    }

    private func persistRecentWindowTilerLastTemplateID(_ templateID: UUID) {
        UserDefaults.standard.set(templateID.uuidString, forKey: AppModel.recentWindowTilerLastTemplateIDDefaultsKey)
    }

    private func recentWindowTilerBackdropColor() -> OverlayAccentColor {
        OverlayAccentColor.from(
            userDefaultsArray: UserDefaults.standard.array(
                forKey: AppModel.recentWindowTilerBackdropColorDefaultsKey
            ) as? [Double]
        ) ?? .workSetBackdropDefault
    }

    private func recentWindowTilerPreferredSelectionCount() -> Int {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: AppModel.recentWindowTilerPreferredSelectionCountDefaultsKey) != nil else {
            return 4
        }
        return max(1, min(defaults.integer(forKey: AppModel.recentWindowTilerPreferredSelectionCountDefaultsKey), 32))
    }

    private func persistRecentWindowTilerPreferredSelectionCount(_ count: Int) {
        guard count > 0 else { return }
        UserDefaults.standard.set(
            max(1, min(count, 32)),
            forKey: AppModel.recentWindowTilerPreferredSelectionCountDefaultsKey
        )
    }

    private func preparedRecentWindowTilerCandidates(
        _ candidates: [RecentWindowTilerCandidate],
        mode: RecentWindowTilerMode,
        selectedTemplateID: UUID?,
        templateOptions: [RecentWindowTilerTemplateOption],
        displayFrame: CGRect?
    ) -> (candidates: [RecentWindowTilerCandidate], selectedWindowIDs: Set<Int>, templateSlotWindowIDs: [Int?]) {
        if mode == .template,
           let selectedTemplateID,
           let template = templateOptions.first(where: { $0.id == selectedTemplateID }) {
            let stableCandidates = candidates.sorted {
                if $0.frontToBackOrder != $1.frontToBackOrder {
                    return $0.frontToBackOrder < $1.frontToBackOrder
                }
                return $0.windowID < $1.windowID
            }
            let templateSlotWindowIDs = RecentWindowTemplatePlanner.slotWindowIDs(
                for: template,
                candidates: stableCandidates,
                displayFrame: displayFrame
            )
            let reordered = RecentWindowTemplatePlanner.reorderedCandidates(
                for: template,
                candidates: stableCandidates,
                displayFrame: displayFrame
            )
            let selectedIDs = Set(templateSlotWindowIDs.compactMap { $0 })
            return (reordered, selectedIDs, templateSlotWindowIDs)
        }

        let preferredSelectionCount = recentWindowTilerPreferredSelectionCount()
        let selectedWindowIDs = Set(candidates
            .filter { $0.isSelectable(in: mode) }
            .prefix(preferredSelectionCount)
            .map(\.windowID)
        )
        return (candidates, selectedWindowIDs, [])
    }

    private func recentWindowTilerTemplateSlotWindowIDs(for state: RecentWindowTilerPresentationState) -> [Int?] {
        guard state.mode == .template,
              let selectedTemplateID = state.selectedTemplateID,
              let template = state.templateOptions.first(where: { $0.id == selectedTemplateID }) else {
            return []
        }
        return RecentWindowTemplatePlanner.slotWindowIDs(
            for: template,
            candidates: state.candidates.filter { state.selectedWindowIDs.contains($0.windowID) },
            displayFrame: state.displayFrame
        )
    }

    private func recentWindowTilerCandidate(
        from window: WindowState,
        frontToBackOrder: Int,
        isOnTargetDisplay: Bool,
        tilingEnabled: Bool?
    ) -> RecentWindowTilerCandidate? {
        let accessibilityInfo = recentWindowTilerAccessibilityInfo(for: window)
        let canAutoTile = window.isRuntimeManageable
        guard accessibilityInfo?.isSupportedForPicker != false else { return nil }
        let canFloatingGrid = canAutoTile || accessibilityInfo?.canMoveAndResize == true
        guard canFloatingGrid else { return nil }
        let effectiveFloating = tilingEnabled == false || window.floating

        let title = window.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? accessibilityInfo?.title ?? ""
            : window.title

        return RecentWindowTilerCandidate(
            windowID: window.id,
            pid: window.pid,
            app: window.app,
            title: title,
            focused: window.focused,
            floating: effectiveFloating,
            minimized: window.isMinimized,
            canAutoTile: canAutoTile,
            canFloatingGrid: canFloatingGrid,
            isOnTargetDisplay: isOnTargetDisplay,
            frame: CGRect(x: window.frameX, y: window.frameY, width: window.frameW, height: window.frameH),
            frontToBackOrder: frontToBackOrder
        )
    }

    private func applyRecentWindowTilerSelectionInternal(
        orderedWindowIDs: [Int],
        mode: RecentWindowTilerMode,
        backdropEnabled: Bool,
        backdropColor: OverlayAccentColor,
        templateID: UUID?,
        templateSlotWindowIDs: [Int?],
        targetSpaceIndex: Int?,
        targetDisplayID: Int?
    ) async {
        guard canRunYabaiRuntimeCommands else {
            await MainActor.run {
                self.lastErrorMessage = self.yabaiRuntimeControlDisabledReason ?? "Window controls are unavailable right now."
                self.lastActionMessage = nil
            }
            return
        }

        guard let state = await currentDesktopWindowsForRecentWindowTiler(
            targetSpaceIndex: targetSpaceIndex,
            targetDisplayID: targetDisplayID
        ) else { return }
        let candidates = recentWindowTilerCandidates(
            from: state.windows,
            primaryWindowIDs: state.primaryWindowIDs,
            tilingEnabledBySpaceIndex: state.tilingEnabledBySpaceIndex
        )
        let allowedWindowIDs = Set(candidates.filter { $0.isSelectable(in: mode) }.map(\.windowID))
        let explicitTemplateSlotWindowIDs = mode == .template && !templateSlotWindowIDs.isEmpty
            ? templateSlotWindowIDs
            : []
        let requestedWindowIDs = explicitTemplateSlotWindowIDs.isEmpty
            ? orderedWindowIDs
            : explicitTemplateSlotWindowIDs.compactMap { $0 }
        let selectedWindowIDs = requestedWindowIDs.filter { allowedWindowIDs.contains($0) }
        let windowsByID = Dictionary(uniqueKeysWithValues: state.windows.map { ($0.id, $0) })
        var selectedWindows = selectedWindowIDs.compactMap { windowsByID[$0] }
        let selectedIDs = Set(selectedWindows.map(\.id))
        let nonSelectedWindows = state.windows.filter {
            state.primaryWindowIDs.contains($0.id) &&
                $0.isRuntimeManageable &&
                !$0.isMinimized &&
                !selectedIDs.contains($0.id)
        }

        guard !selectedWindows.isEmpty || !explicitTemplateSlotWindowIDs.isEmpty else {
            await MainActor.run {
                self.lastErrorMessage = "Selected windows are no longer available on this desktop."
                self.lastActionMessage = nil
            }
            return
        }

        var movedIntoPrimaryScope = 0
        var failedMoveIntoPrimaryScope = 0
        var restoredMinimizedCount = 0
        var failedMinimizedRestoreCount = 0
        if let display = state.display {
            let primaryScope = WorkSetScopeKey(displayID: display.id, spaceIndex: state.spaceIndex)
            let outOfScopeSelectedWindows = selectedWindows.filter {
                !workSetWindowMatchesScope($0, scopeKey: primaryScope, targetDisplay: display)
            }

            if !outOfScopeSelectedWindows.isEmpty {
                let moveResult = await moveRecentWindowTilerWindowsIntoPrimaryScope(
                    outOfScopeSelectedWindows,
                    scopeKey: primaryScope,
                    display: display
                )
                movedIntoPrimaryScope = moveResult.moved
                failedMoveIntoPrimaryScope = moveResult.failed

                await refreshLiveState()
                let refreshedByID = Dictionary(
                    uniqueKeysWithValues: (latestLiveStateSnapshot ?? liveStateSnapshot)?.windows.map { ($0.id, $0) } ?? []
                )
                selectedWindows = selectedWindowIDs.compactMap { refreshedByID[$0] ?? windowsByID[$0] }
            }

            if mode == .autoTiled {
                selectedWindows = selectedWindows.filter {
                    workSetWindowMatchesScope($0, scopeKey: primaryScope, targetDisplay: display)
                }
            }
        }

        let minimizedSelectedWindows = selectedWindows.filter(\.isMinimized)
        if !minimizedSelectedWindows.isEmpty {
            let restoreResult = await restoreMinimizedRecentWindowTilerWindows(minimizedSelectedWindows)
            restoredMinimizedCount = restoreResult.restored
            failedMinimizedRestoreCount = restoreResult.failed

            await refreshLiveState()
            let refreshedByID = Dictionary(
                uniqueKeysWithValues: (latestLiveStateSnapshot ?? liveStateSnapshot)?.windows.map { ($0.id, $0) } ?? []
            )
            selectedWindows = selectedWindowIDs.compactMap { windowID in
                guard let window = refreshedByID[windowID] ?? windowsByID[windowID],
                      !window.isMinimized else {
                    return nil
                }
                return window
            }
        }

        guard !selectedWindows.isEmpty || !explicitTemplateSlotWindowIDs.isEmpty else {
            await MainActor.run {
                self.lastErrorMessage = "Selected windows could not be moved to this display."
                self.lastActionMessage = nil
            }
            return
        }

        if !backdropEnabled, let display = state.display {
            hideRecentWindowTilerBackdrop(
                for: WorkSetScopeKey(displayID: display.id, spaceIndex: state.spaceIndex)
            )
        }

        let result: (updated: Int, failed: Int, primaryFocused: Bool)
        var ignoredSelectedCount = 0
        var emptyConstrainedSlotCount = 0
        var missingAssignedCount = 0
        var appliedWindowCount = selectedWindows.count
        var appliedTemplateName: String?
        switch mode {
        case .autoTiled:
            showRecentWindowTilerBackdropIfEnabled(
                backdropEnabled,
                color: backdropColor,
                display: state.display,
                spaceIndex: state.spaceIndex,
                selectedWindows: selectedWindows
            )
            result = await applyRecentAutoTiledLayout(
                spaceIndex: state.spaceIndex,
                selectedWindows: selectedWindows,
                nonSelectedWindows: nonSelectedWindows
            )
        case .floatingGrid:
            showRecentWindowTilerBackdropIfEnabled(
                backdropEnabled,
                color: backdropColor,
                display: state.display,
                spaceIndex: state.spaceIndex,
                selectedWindows: selectedWindows
            )
            result = await applyRecentFloatingGridLayout(
                display: state.display,
                selectedWindows: selectedWindows,
                requiresBackdropClearance: backdropEnabled
            )
        case .template:
            guard let templateID,
                  let template = windowLayoutTemplate(withID: templateID) else {
                await MainActor.run {
                    self.lastErrorMessage = "Template no longer exists."
                    self.lastActionMessage = nil
                }
                return
            }
            guard let display = state.display else {
                await MainActor.run {
                    self.lastErrorMessage = "Current desktop display is unavailable."
                    self.lastActionMessage = nil
                }
                return
            }
            guard template.displayShapeKey.matches(width: display.frameW, height: display.frameH) else {
                await MainActor.run {
                    self.lastErrorMessage = "Template does not match this display shape."
                    self.lastActionMessage = nil
                }
                return
            }

            showRecentWindowTilerBackdropIfEnabled(
                backdropEnabled,
                color: backdropColor,
                display: display,
                spaceIndex: state.spaceIndex,
                selectedWindows: selectedWindows
            )
            let slots = WindowLayoutTemplate.sortedSlots(template.slots)
            appliedTemplateName = template.name
            let templateResult = await applyRecentTemplateLayout(
                template: template,
                slots: slots,
                display: display,
                selectedWindows: selectedWindows,
                templateSlotWindowIDs: explicitTemplateSlotWindowIDs,
                requestedSelectedCount: orderedWindowIDs.count,
                requiresBackdropClearance: backdropEnabled
            )
            ignoredSelectedCount = templateResult.ignoredSelectedCount
            emptyConstrainedSlotCount = templateResult.emptyConstrainedSlotCount
            missingAssignedCount = templateResult.missingAssignedCount
            appliedWindowCount = templateResult.assignedCount
            result = (
                updated: templateResult.updated,
                failed: templateResult.failed,
                primaryFocused: templateResult.primaryFocused
            )
        }

        await refreshLiveState()
        await refreshDoctor()

        await MainActor.run {
            var issues: [String] = []
            if nonSelectedWindows.count > 0, mode == .autoTiled {
                issues.append("Floated \(nonSelectedWindows.count) non-selected window(s).")
            }
            if movedIntoPrimaryScope > 0 {
                issues.append("Pulled \(movedIntoPrimaryScope) selected window(s) in from another display.")
            }
            if failedMoveIntoPrimaryScope > 0 {
                issues.append("Could not pull \(failedMoveIntoPrimaryScope) selected window(s) in from another display.")
            }
            if restoredMinimizedCount > 0 {
                issues.append("Restored \(restoredMinimizedCount) minimized window(s).")
            }
            if failedMinimizedRestoreCount > 0 {
                issues.append("Could not restore \(failedMinimizedRestoreCount) minimized window(s).")
            }
            if result.failed > 0 {
                issues.append("\(result.failed) window operation(s) failed.")
            }
            if ignoredSelectedCount > 0 {
                issues.append("Ignored \(ignoredSelectedCount) extra selected window(s).")
            }
            if emptyConstrainedSlotCount > 0 {
                issues.append("Left \(emptyConstrainedSlotCount) constrained slot(s) empty.")
            }
            if missingAssignedCount > 0 {
                issues.append("\(missingAssignedCount) assigned window(s) disappeared before apply.")
            }
            if !result.primaryFocused {
                issues.append("Could not focus the first selected window.")
            }

            switch mode {
            case .autoTiled:
                self.lastActionMessage = "Tiled \(selectedWindows.count) selected window(s)."
            case .floatingGrid:
                self.lastActionMessage = "Arranged \(selectedWindows.count) selected window(s) into a floating grid."
            case .template:
                self.lastActionMessage = "Applied \(appliedTemplateName ?? "template") to \(appliedWindowCount) selected window(s)."
            }
            self.lastErrorMessage = issues.isEmpty ? nil : issues.joined(separator: " ")
        }
    }

    private func showRecentWindowTilerBackdropIfEnabled(
        _ enabled: Bool,
        color: OverlayAccentColor,
        display: DisplayState?,
        spaceIndex: Int,
        selectedWindows: [WindowState]
    ) {
        guard enabled, let display else { return }
        showRecentWindowTilerBackdrop(
            scopeKey: WorkSetScopeKey(displayID: display.id, spaceIndex: spaceIndex),
            display: display,
            color: color,
            excluding: Set(selectedWindows.map(\.id))
        )
    }

    private func applyRecentAutoTiledLayout(
        spaceIndex: Int,
        selectedWindows: [WindowState],
        nonSelectedWindows: [WindowState]
    ) async -> (updated: Int, failed: Int, primaryFocused: Bool) {
        let selectedWindowIDs = Set(selectedWindows.map(\.id))
        let floatOthers = await setFloatingStateForWindows(
            nonSelectedWindows.filter { !$0.floating },
            shouldFloat: true
        )
        let floatLiveOthers = await floatNonSelectedRuntimeWindowsOnSpace(
            spaceIndex: spaceIndex,
            selectedWindowIDs: selectedWindowIDs
        )
        if floatOthers.updated > 0 || floatLiveOthers.updated > 0 {
            try? await Task.sleep(for: .milliseconds(35))
        }

        let rebuild = await rebuildBalancedTileLayout(
            spaceIndex: spaceIndex,
            windows: selectedWindows,
            preserveOrder: true
        )

        let primaryFocused: Bool
        if let primaryWindow = selectedWindows.first {
            primaryFocused = await focusWindowWithRestore(windowID: primaryWindow.id, knownWindow: primaryWindow)
        } else {
            primaryFocused = true
        }

        return (
            updated: floatOthers.updated + floatLiveOthers.updated + rebuild.updated,
            failed: floatOthers.failed + floatLiveOthers.failed + rebuild.failed,
            primaryFocused: primaryFocused
        )
    }

    private func applyRecentFloatingGridLayout(
        display: DisplayState?,
        selectedWindows: [WindowState],
        requiresBackdropClearance: Bool
    ) async -> (updated: Int, failed: Int, primaryFocused: Bool) {
        let floatSelected = await setFloatingStateForWindows(
            selectedWindows.filter { $0.isRuntimeManageable && !$0.floating },
            shouldFloat: true
        )
        if floatSelected.updated > 0 {
            try? await Task.sleep(for: .milliseconds(60))
            await refreshLiveState()
        }

        let refreshedByID = Dictionary(
            uniqueKeysWithValues: (latestLiveStateSnapshot ?? liveStateSnapshot)?.windows.map { ($0.id, $0) } ?? []
        )
        let refreshedSelected = selectedWindows.map { refreshedByID[$0.id] ?? $0 }
        let grid = await applyGridFramesWithAccessibilityFallback(to: refreshedSelected, display: display)
        let windowsToStack = requiresBackdropClearance
            ? refreshedSelected
            : refreshedSelected.filter(\.isRuntimeManageable)
        let stack = await stackWorkSetWindows(
            windowsToStack.reversed(),
            primaryWindowID: refreshedSelected.first?.id,
            requiresBackdropClearance: requiresBackdropClearance
        )
        let primaryFocused: Bool
        if let primaryWindow = refreshedSelected.first, !primaryWindow.isRuntimeManageable {
            primaryFocused = await focusWindowWithRestore(windowID: primaryWindow.id, knownWindow: primaryWindow)
        } else {
            primaryFocused = stack.primaryFocused
        }

        return (
            updated: floatSelected.updated + grid.updated + stack.updated,
            failed: floatSelected.failed + grid.failed + stack.failed,
            primaryFocused: primaryFocused
        )
    }

    private func applyRecentTemplateLayout(
        template: WindowLayoutTemplate,
        slots: [WindowLayoutSlot],
        display: DisplayState,
        selectedWindows: [WindowState],
        templateSlotWindowIDs: [Int?],
        requestedSelectedCount: Int,
        requiresBackdropClearance: Bool
    ) async -> RecentWindowTilerTemplateApplyResult {
        guard !selectedWindows.isEmpty || !templateSlotWindowIDs.isEmpty else {
            return RecentWindowTilerTemplateApplyResult(
                assignedCount: 0,
                ignoredSelectedCount: 0,
                emptyConstrainedSlotCount: 0,
                missingAssignedCount: 0,
                updated: 0,
                failed: 0,
                primaryFocused: true
            )
        }

        let assignment = assignExplicitRecentTemplateWindows(
            slots: slots,
            templateSlotWindowIDs: templateSlotWindowIDs,
            selectedWindows: selectedWindows
        )
        let assignedWindows = assignment.assignments.map(\.window)
        guard !assignedWindows.isEmpty else {
            return RecentWindowTilerTemplateApplyResult(
                assignedCount: 0,
                ignoredSelectedCount: max(0, requestedSelectedCount - assignment.missingAssignedCount),
                emptyConstrainedSlotCount: assignment.emptyConstrainedSlotCount,
                missingAssignedCount: assignment.missingAssignedCount,
                updated: 0,
                failed: 0,
                primaryFocused: true
            )
        }

        let floatSelected = await setFloatingStateForWindows(
            assignedWindows.filter { $0.isRuntimeManageable && !$0.floating },
            shouldFloat: true
        )
        if floatSelected.updated > 0 {
            try? await Task.sleep(for: .milliseconds(60))
            await refreshLiveState()
        }

        let refreshedByID = Dictionary(
            uniqueKeysWithValues: (latestLiveStateSnapshot ?? liveStateSnapshot)?.windows.map { ($0.id, $0) } ?? []
        )
        let assignments = assignment.assignments.map {
            (slot: $0.slot, window: refreshedByID[$0.window.id] ?? $0.window)
        }
        let frames = await applyRecentTemplateFrames(
            assignments: assignments,
            template: template,
            display: display
        )
        let stackOrder = assignments
            .sorted { lhs, rhs in
                if lhs.slot.zIndex != rhs.slot.zIndex {
                    return lhs.slot.zIndex < rhs.slot.zIndex
                }
                let geometric = WindowLayoutTemplate.sortedSlots([lhs.slot, rhs.slot])
                return geometric.first?.id == lhs.slot.id
            }
            .map(\.window)
        let stack = await stackWorkSetWindows(
            stackOrder,
            primaryWindowID: nil,
            requiresBackdropClearance: requiresBackdropClearance
        )

        return RecentWindowTilerTemplateApplyResult(
            assignedCount: assignedWindows.count,
            ignoredSelectedCount: max(0, requestedSelectedCount - assignedWindows.count - assignment.missingAssignedCount),
            emptyConstrainedSlotCount: assignment.emptyConstrainedSlotCount,
            missingAssignedCount: assignment.missingAssignedCount,
            updated: floatSelected.updated + frames.updated + stack.updated,
            failed: floatSelected.failed + frames.failed + stack.failed,
            primaryFocused: true
        )
    }

    private func assignExplicitRecentTemplateWindows(
        slots: [WindowLayoutSlot],
        templateSlotWindowIDs: [Int?],
        selectedWindows: [WindowState]
    ) -> (
        assignments: [(slot: WindowLayoutSlot, window: WindowState)],
        emptyConstrainedSlotCount: Int,
        missingAssignedCount: Int
    ) {
        let selectedWindowsByID = Dictionary(uniqueKeysWithValues: selectedWindows.map { ($0.id, $0) })
        let normalizedSlotWindowIDs = slots.indices.map { index -> Int? in
            guard templateSlotWindowIDs.indices.contains(index) else { return nil }
            return templateSlotWindowIDs[index]
        }
        var assignments: [(slot: WindowLayoutSlot, window: WindowState)] = []
        var emptyConstrainedSlotCount = 0
        var missingAssignedCount = 0

        for (index, slot) in slots.enumerated() {
            guard let windowID = normalizedSlotWindowIDs[index] else {
                if !slot.allowedApps.isEmpty {
                    emptyConstrainedSlotCount += 1
                }
                continue
            }

            guard let window = selectedWindowsByID[windowID] else {
                missingAssignedCount += 1
                if !slot.allowedApps.isEmpty {
                    emptyConstrainedSlotCount += 1
                }
                continue
            }

            guard recentTemplateSlot(slot, allows: window) else {
                emptyConstrainedSlotCount += 1
                continue
            }

            assignments.append((slot: slot, window: window))
        }

        return (
            assignments: assignments,
            emptyConstrainedSlotCount: emptyConstrainedSlotCount,
            missingAssignedCount: missingAssignedCount
        )
    }

    private func recentTemplateSlot(_ slot: WindowLayoutSlot, allows window: WindowState) -> Bool {
        guard !slot.allowedApps.isEmpty else { return true }
        let allowedKeys = Set(slot.allowedApps.map(normalizedAppRuleKey).filter { !$0.isEmpty })
        return allowedKeys.contains(normalizedAppRuleKey(window.app))
    }

    private func applyRecentTemplateFrames(
        assignments: [(slot: WindowLayoutSlot, window: WindowState)],
        template: WindowLayoutTemplate,
        display: DisplayState
    ) async -> (updated: Int, failed: Int) {
        var updated = 0
        var failed = 0

        for assignment in assignments {
            let window = assignment.window
            let normalizedFrame = fittedTemplateRect(for: assignment.slot, template: template, display: display)
            let absoluteFrame = CGRect(
                x: display.frameX + (normalizedFrame.minX * display.frameW),
                y: display.frameY + (normalizedFrame.minY * display.frameH),
                width: max(80, normalizedFrame.width * display.frameW),
                height: max(60, normalizedFrame.height * display.frameH)
            ).integral

            if window.isRuntimeManageable {
                let resizeResult = await doctorService.runSupportCommand(
                    yabaiCommand(
                        ["-m", "window", String(window.id), "--resize", "abs:\(Int(absoluteFrame.width)):\(Int(absoluteFrame.height))"],
                        timeout: 1.5
                    )
                )
                await MainActor.run {
                    appendCommandLog(from: resizeResult)
                }

                let moveResult = await doctorService.runSupportCommand(
                    yabaiCommand(
                        ["-m", "window", String(window.id), "--move", "abs:\(Int(absoluteFrame.minX)):\(Int(absoluteFrame.minY))"],
                        timeout: 1.5
                    )
                )
                await MainActor.run {
                    appendCommandLog(from: moveResult)
                }

                if resizeResult.isSuccess && moveResult.isSuccess {
                    updated += 1
                    continue
                }
            }

            if await setWindowFrameUsingAccessibility(window: window, frame: absoluteFrame) {
                updated += 1
            } else {
                failed += 1
            }
        }

        return (updated, failed)
    }

    private func applyWindowLayoutTemplateInternal(templateID: UUID) async {
        guard let template = windowLayoutTemplate(withID: templateID) else {
            await MainActor.run {
                self.lastErrorMessage = "Template no longer exists."
                self.lastActionMessage = nil
            }
            return
        }

        if let disabledReason = templateApplyDisabledReason(template) {
            await MainActor.run {
                self.lastErrorMessage = disabledReason
                self.lastActionMessage = nil
            }
            return
        }

        guard !template.slots.isEmpty else {
            await MainActor.run {
                self.lastErrorMessage = "Template has no slots yet."
                self.lastActionMessage = nil
            }
            return
        }

        guard let state = await currentDesktopVisibleWindowsForBulkLayout(template: template),
              let display = state.display else {
            return
        }

        let result = await performTemplateApply(
            template: template,
            candidateWindows: state.windows,
            display: display,
            spaceIndex: state.spaceIndex,
            requireMatchingDisplayShape: false,
            noMatchesMessage: "No windows matched this template on the current desktop."
        )

        if let errorMessage = result.errorMessage {
            await MainActor.run {
                self.lastErrorMessage = errorMessage
                self.lastActionMessage = nil
            }
            return
        }

        var issues: [String] = []
        if result.emptyConstrainedSlotCount > 0 {
            issues.append("Left \(result.emptyConstrainedSlotCount) constrained slot(s) empty.")
        }
        if result.limitedCount > 0 {
            issues.append("Skipped \(result.limitedCount) limited window(s).")
        }
        let extraCount = max(0, result.extraWindowCount)
        if extraCount > 0 {
            issues.append("Left \(extraCount) extra eligible window(s) unchanged.")
        }
        let failedCount = result.failedCount
        if failedCount > 0 {
            issues.append("\(failedCount) window(s) could not be placed.")
        }

        await MainActor.run {
            self.lastActionMessage = "Applied template \(template.name) to \(result.assignedCount) window(s)."
            self.lastErrorMessage = issues.isEmpty ? nil : issues.joined(separator: " ")
        }
        await refreshLiveState()
    }

    private func performTemplateApply(
        template: WindowLayoutTemplate,
        candidateWindows: [WindowState],
        display: DisplayState,
        spaceIndex: Int,
        requireMatchingDisplayShape: Bool,
        noMatchesMessage: String
    ) async -> TemplateApplyRunResult {
        if requireMatchingDisplayShape,
           !template.displayShapeKey.matches(width: display.frameW, height: display.frameH) {
            return TemplateApplyRunResult(
                assignedCount: 0,
                emptyConstrainedSlotCount: 0,
                extraWindowCount: 0,
                limitedCount: 0,
                failedCount: 0,
                errorMessage: "Linked template does not match this display shape."
            )
        }

        let eligibleWindows = candidateWindows.filter(\.isRuntimeManageable)
        let limitedCount = candidateWindows.filter { !$0.isRuntimeManageable }.count
        let assignment = assignTemplateWindows(
            for: template,
            from: eligibleWindows
        )
        let assignedWindows = assignment.assignments.map(\.window)

        guard !assignedWindows.isEmpty else {
            return TemplateApplyRunResult(
                assignedCount: 0,
                emptyConstrainedSlotCount: assignment.emptyConstrainedSlotCount,
                extraWindowCount: assignment.extraWindowCount,
                limitedCount: limitedCount,
                failedCount: 0,
                errorMessage: noMatchesMessage
            )
        }

        let floatResult = await setFloatingStateForWindows(
            assignedWindows.filter { !$0.floating },
            shouldFloat: true
        )
        if floatResult.updated > 0 {
            try? await Task.sleep(for: .milliseconds(120))
        }

        let frameResult = await applyTemplateFrames(
            assignments: assignment.assignments,
            template: template,
            display: display
        )
        let stackingResult = await applyTemplateStacking(
            assignments: assignment.assignments,
            spaceIndex: spaceIndex
        )

        return TemplateApplyRunResult(
            assignedCount: assignedWindows.count,
            emptyConstrainedSlotCount: assignment.emptyConstrainedSlotCount,
            extraWindowCount: assignment.extraWindowCount,
            limitedCount: limitedCount,
            failedCount: floatResult.failed + frameResult.failed + stackingResult.failed,
            errorMessage: nil
        )
    }

    private func activateWorkSetInternal(workSetID: UUID, requestID: Int) async {
        guard let workSet = workSet(withID: workSetID) else {
            await MainActor.run {
                self.lastErrorMessage = "Work Set no longer exists."
                self.lastActionMessage = nil
            }
            return
        }
        guard isCurrentWorkSetActivation(requestID) else { return }

        activeWorkSetLayoutSyncTask?.cancel()
        activeWorkSetLayoutSyncTask = nil
        pendingActiveWorkSetLayoutSync = false
        workSetActivationInProgress = true
        defer { workSetActivationInProgress = false }

        let targetScopeVisible = await prepareWorkSetActivationScope(workSet.scopeKey)
        guard isCurrentWorkSetActivation(requestID) else { return }
        guard targetScopeVisible else {
            await MainActor.run {
                self.lastErrorMessage = "Make Desktop \(workSet.scopeKey.spaceIndex) on \(workSet.sourceDisplayName) visible to activate this Work Set."
                self.lastActionMessage = nil
            }
            return
        }

        if let disabledReason = workSetActivationDisabledReason(workSet) {
            await MainActor.run {
                self.lastErrorMessage = disabledReason
                self.lastActionMessage = nil
            }
            return
        }

        guard visibleWorkSetContexts.contains(where: { $0.scopeKey == workSet.scopeKey }) else {
            await MainActor.run {
                self.lastErrorMessage = "Make Desktop \(workSet.scopeKey.spaceIndex) on \(workSet.sourceDisplayName) visible to activate this Work Set."
                self.lastActionMessage = nil
            }
            return
        }

        var restoreMinimizedResult = await restoreMinimizedWorkSetMembers(
            resolveWorkSetMembers(
                workSet.members,
                in: workSetActivationCandidateWindows(in: latestLiveStateSnapshot ?? liveStateSnapshot)
            )
        )
        guard isCurrentWorkSetActivation(requestID) else { return }
        if restoreMinimizedResult.restored > 0 {
            await refreshLiveState()
            guard isCurrentWorkSetActivation(requestID) else { return }
        }

        let launchMissingAppsResult: WorkSetLaunchMissingAppsResult
        if workSet.launchMissingApps {
            launchMissingAppsResult = await launchMissingAppsForWorkSet(workSet)
            guard isCurrentWorkSetActivation(requestID) else { return }
        } else {
            launchMissingAppsResult = WorkSetLaunchMissingAppsResult()
        }

        let globalEligibleWindows = workSetActivationCandidateWindows(in: latestLiveStateSnapshot ?? liveStateSnapshot)
        let globallyResolvedMembers = resolveWorkSetMembers(workSet.members, in: globalEligibleWindows)
        let moveResult = await moveWorkSetWindowsIntoScope(
            globallyResolvedMembers.compactMap(\.matchedWindow),
            scopeKey: workSet.scopeKey
        )
        guard isCurrentWorkSetActivation(requestID) else { return }

        if moveResult.moved > 0 {
            await refreshLiveState()
            guard isCurrentWorkSetActivation(requestID) else { return }
        }

        if moveResult.moved > 0 {
            let movedRestoreResult = await restoreMinimizedWorkSetMembers(
                resolveWorkSetMembers(
                    workSet.members,
                    in: workSetActivationCandidateWindows(in: latestLiveStateSnapshot ?? liveStateSnapshot)
                )
            )
            restoreMinimizedResult = mergeWorkSetRestoreResults(restoreMinimizedResult, movedRestoreResult)
            guard isCurrentWorkSetActivation(requestID) else { return }
            if movedRestoreResult.restored > 0 {
                await refreshLiveState()
                guard isCurrentWorkSetActivation(requestID) else { return }
            }
        }

        guard let refreshedContext = workSetContext(for: workSet.scopeKey) else {
            await MainActor.run {
                self.lastErrorMessage = "Current desktop data is unavailable right now."
                self.lastActionMessage = nil
            }
            return
        }

        let scopeWindows = workSetActivationCandidateWindows(
            in: latestLiveStateSnapshot ?? liveStateSnapshot,
            scopeKey: workSet.scopeKey
        )
        let resolvedMembers = resolveWorkSetMembers(workSet.members, in: scopeWindows)
        let manageableResolvedMembers = resolvedMembers.filter {
            guard let matchedWindow = $0.matchedWindow else { return false }
            return matchedWindow.isRuntimeManageable && !matchedWindow.isMinimized
        }
        let limitedResolvedMembers = resolvedMembers.filter { resolved in
            guard let matchedWindow = resolved.matchedWindow else { return false }
            return !matchedWindow.isRuntimeManageable
        }
        let sameAppCount = resolvedMembers.filter { $0.status == .sameApp }.count
        let missingCount = resolvedMembers.filter { $0.status == .missing }.count
        let activeWindowIDs = Set(manageableResolvedMembers.compactMap { $0.matchedWindow?.id })
        let recoveryMessages = workSetActivationRecoveryMessages(
            restoredMinimized: restoreMinimizedResult.restored,
            failedMinimizedRestore: restoreMinimizedResult.failed,
            launchResult: launchMissingAppsResult
        )

        switch workSet.layoutMode {
        case .stackOnly:
            guard !manageableResolvedMembers.isEmpty else {
                await MainActor.run {
                    let baseMessage = limitedResolvedMembers.isEmpty
                        ? "No saved windows from this Work Set are available on the current desktop."
                        : "No saved windows from this Work Set can be managed on the current desktop."
                    self.lastErrorMessage = ([baseMessage] + recoveryMessages).joined(separator: " ")
                    self.lastActionMessage = nil
                }
                return
            }

            if workSet.backdropEnabled {
                updateWorkSetBackdropPresentation(
                    for: workSet,
                    context: refreshedContext,
                    activeWindowIDs: activeWindowIDs,
                    resetDismissal: true
                )
            }

            let transitionReset = await resetWorkSetScopeForActivation(
                scopeKey: workSet.scopeKey,
                incomingWorkSetID: workSet.id,
                incomingLayoutMode: workSet.layoutMode,
                preserveBackdrop: workSet.backdropEnabled
            )
            guard isCurrentWorkSetActivation(requestID) else { return }

            if workSet.backdropEnabled {
                updateWorkSetBackdropPresentation(
                    for: workSet,
                    context: refreshedContext,
                    activeWindowIDs: activeWindowIDs,
                    resetDismissal: false
                )
            }

            let activeStackResult = await stackWorkSetWindows(
                manageableResolvedMembers.compactMap(\.matchedWindow).reversed(),
                primaryWindowID: manageableResolvedMembers.first?.matchedWindow?.id,
                requiresBackdropClearance: workSet.backdropEnabled
            )
            guard isCurrentWorkSetActivation(requestID) else { return }
            let scopeFloatCleanup: (updated: Int, failed: Int)
            if transitionReset.layoutResetAttempted && transitionReset.layoutResetSucceeded {
                scopeFloatCleanup = (0, 0)
            } else {
                scopeFloatCleanup = await normalizeWorkSetScopeToFloatingIfNeeded(scopeKey: workSet.scopeKey)
            }

            await MainActor.run {
                self.setActiveWorkSetID(workSet.id, for: workSet.scopeKey)

                var issues = recoveryMessages
                if sameAppCount > 0 {
                    issues.append("Used \(sameAppCount) same-app fallback window(s).")
                }
                if moveResult.moved > 0 {
                    issues.append("Pulled \(moveResult.moved) window(s) in from another desktop or display.")
                }
                if limitedResolvedMembers.count > 0 {
                    issues.append("Skipped \(limitedResolvedMembers.count) limited member window(s).")
                }
                if missingCount > 0 {
                    issues.append("\(missingCount) member(s) were missing.")
                }
                if transitionReset.failed > 0 {
                    issues.append("Could not fully clear \(transitionReset.failed) leftover tiled window(s).")
                }
                if transitionReset.layoutResetAttempted && !transitionReset.layoutResetSucceeded {
                    issues.append("Could not fully leave tiled desktop mode.")
                }
                let failedCount = moveResult.failed
                    + activeStackResult.failed
                    + scopeFloatCleanup.failed
                    + (activeStackResult.primaryFocused ? 0 : 1)
                if failedCount > 0 {
                    issues.append("\(failedCount) window operation(s) failed.")
                }

                self.lastActionMessage = "Activated Work Set \(workSet.name)."
                self.lastErrorMessage = issues.isEmpty ? nil : issues.joined(separator: " ")
            }

        case .tiled:
            guard !manageableResolvedMembers.isEmpty else {
                await MainActor.run {
                    let baseMessage = limitedResolvedMembers.isEmpty
                        ? "No saved windows from this Work Set are available on the current desktop."
                        : "No saved windows from this Work Set can be tiled on the current desktop."
                    self.lastErrorMessage = ([baseMessage] + recoveryMessages).joined(separator: " ")
                    self.lastActionMessage = nil
                }
                return
            }

            setActiveWorkSetID(workSet.id, for: workSet.scopeKey)

            rememberOriginalDesktopLayoutBeforeTiledWorkSetOverrideIfNeeded(
                scopeKey: workSet.scopeKey,
                snapshot: latestLiveStateSnapshot ?? liveStateSnapshot
            )

            if workSet.backdropEnabled {
                updateWorkSetBackdropPresentation(
                    for: workSet,
                    context: refreshedContext,
                    activeWindowIDs: activeWindowIDs,
                    resetDismissal: true
                )
            }

            let transitionReset = await resetWorkSetScopeForActivation(
                scopeKey: workSet.scopeKey,
                incomingWorkSetID: workSet.id,
                incomingLayoutMode: workSet.layoutMode,
                preserveBackdrop: workSet.backdropEnabled
            )
            guard isCurrentWorkSetActivation(requestID) else { return }

            if workSet.backdropEnabled {
                updateWorkSetBackdropPresentation(
                    for: workSet,
                    context: refreshedContext,
                    activeWindowIDs: activeWindowIDs,
                    resetDismissal: false
                )
            }

            let tiledResult = await applyTiledWorkSetLayout(
                scopeKey: workSet.scopeKey,
                scopeWindows: visibleWindowsForWorkSetScope(workSet.scopeKey, in: latestLiveStateSnapshot ?? liveStateSnapshot),
                activeWindows: manageableResolvedMembers.compactMap(\.matchedWindow),
                focusPrimary: true
            )
            guard isCurrentWorkSetActivation(requestID) else { return }

            await MainActor.run {
                self.setActiveWorkSetID(workSet.id, for: workSet.scopeKey)

                var issues = recoveryMessages
                if sameAppCount > 0 {
                    issues.append("Used \(sameAppCount) same-app fallback window(s).")
                }
                if moveResult.moved > 0 {
                    issues.append("Pulled \(moveResult.moved) window(s) in from another desktop or display.")
                }
                if limitedResolvedMembers.count > 0 {
                    issues.append("Skipped \(limitedResolvedMembers.count) limited member window(s).")
                }
                if missingCount > 0 {
                    issues.append("\(missingCount) member(s) were missing.")
                }
                if transitionReset.failed > 0 {
                    issues.append("Could not fully clear \(transitionReset.failed) leftover tiled window(s).")
                }
                let failedCount = moveResult.failed
                    + (transitionReset.layoutResetAttempted && !transitionReset.layoutResetSucceeded ? 1 : 0)
                    + tiledResult.failed
                    + (tiledResult.primaryFocused ? 0 : 1)
                if failedCount > 0 {
                    issues.append("\(failedCount) window operation(s) failed.")
                }

                self.lastActionMessage = "Activated Work Set \(workSet.name)."
                self.lastErrorMessage = issues.isEmpty ? nil : issues.joined(separator: " ")
            }

        case .template:
            guard let linkedTemplateID = workSet.linkedTemplateID else {
                await MainActor.run {
                    self.lastErrorMessage = "Choose a linked template for this Work Set first."
                    self.lastActionMessage = nil
                }
                return
            }
            guard let template = windowLayoutTemplate(withID: linkedTemplateID) else {
                await MainActor.run {
                    self.lastErrorMessage = "Linked template is missing."
                    self.lastActionMessage = nil
                }
                return
            }

            let transitionReset = await resetWorkSetScopeForActivation(
                scopeKey: workSet.scopeKey,
                incomingWorkSetID: workSet.id,
                incomingLayoutMode: workSet.layoutMode,
                preserveBackdrop: false
            )
            guard isCurrentWorkSetActivation(requestID) else { return }

            let templateResult = await performTemplateApply(
                template: template,
                candidateWindows: manageableResolvedMembers.compactMap(\.matchedWindow),
                display: refreshedContext.display,
                spaceIndex: refreshedContext.scopeKey.spaceIndex,
                requireMatchingDisplayShape: true,
                noMatchesMessage: "No saved windows from this Work Set matched the linked template on this desktop."
            )
            guard isCurrentWorkSetActivation(requestID) else { return }

            if let errorMessage = templateResult.errorMessage {
                await MainActor.run {
                    self.lastErrorMessage = errorMessage
                    self.lastActionMessage = nil
                }
                return
            }

            updateWorkSetBackdropPresentation(
                for: workSet,
                context: refreshedContext,
                activeWindowIDs: activeWindowIDs,
                resetDismissal: true
            )

            let primaryFocused: Bool
            if let primaryWindow = manageableResolvedMembers.first?.matchedWindow {
                primaryFocused = await focusWindowWithRestore(
                    windowID: primaryWindow.id,
                    knownWindow: primaryWindow
                )
            } else {
                primaryFocused = false
            }
            guard isCurrentWorkSetActivation(requestID) else { return }
            let scopeFloatCleanup: (updated: Int, failed: Int)
            if transitionReset.layoutResetAttempted && transitionReset.layoutResetSucceeded {
                scopeFloatCleanup = (0, 0)
            } else {
                scopeFloatCleanup = await normalizeWorkSetScopeToFloatingIfNeeded(scopeKey: workSet.scopeKey)
            }

            await MainActor.run {
                self.setActiveWorkSetID(workSet.id, for: workSet.scopeKey)

                var issues = recoveryMessages
                if sameAppCount > 0 {
                    issues.append("Used \(sameAppCount) same-app fallback window(s).")
                }
                if moveResult.moved > 0 {
                    issues.append("Pulled \(moveResult.moved) window(s) in from another desktop or display.")
                }
                if templateResult.emptyConstrainedSlotCount > 0 {
                    issues.append("Left \(templateResult.emptyConstrainedSlotCount) constrained slot(s) empty.")
                }
                if templateResult.extraWindowCount > 0 {
                    issues.append("Left \(templateResult.extraWindowCount) extra eligible window(s) unchanged.")
                }
                if templateResult.limitedCount > 0 {
                    issues.append("Skipped \(templateResult.limitedCount) limited member window(s).")
                }
                if missingCount > 0 {
                    issues.append("\(missingCount) member(s) were missing.")
                }
                if transitionReset.failed > 0 {
                    issues.append("Could not fully clear \(transitionReset.failed) leftover tiled window(s).")
                }
                if transitionReset.layoutResetAttempted && !transitionReset.layoutResetSucceeded {
                    issues.append("Could not fully leave tiled desktop mode.")
                }
                let failedCount = moveResult.failed
                    + templateResult.failedCount
                    + scopeFloatCleanup.failed
                    + (primaryFocused ? 0 : 1)
                if failedCount > 0 {
                    issues.append("\(failedCount) window operation(s) failed.")
                }

                self.lastActionMessage = "Activated Work Set \(workSet.name)."
                self.lastErrorMessage = issues.isEmpty ? nil : issues.joined(separator: " ")
            }
        }

        await refreshLiveState()
    }

    private func isCurrentWorkSetActivation(_ requestID: Int) -> Bool {
        !Task.isCancelled && workSetActivationRequestID == requestID
    }

    private func workSetActivationCandidateWindows(
        in snapshot: LiveStateSnapshot?,
        scopeKey: WorkSetScopeKey? = nil
    ) -> [WindowState] {
        guard let snapshot else { return [] }
        return snapshot.windows.filter { window in
            if let scopeKey,
               (window.space != scopeKey.spaceIndex || window.display != scopeKey.displayID) {
                return false
            }
            guard !window.isHidden,
                  window.isVisible || window.isMinimized else {
                return false
            }
            return !isBackdropSurfaceWindow(
                window,
                normalizedTitle: window.title.trimmingCharacters(in: .whitespacesAndNewlines),
                normalizedRole: window.role.trimmingCharacters(in: .whitespacesAndNewlines),
                normalizedSubrole: window.subrole.trimmingCharacters(in: .whitespacesAndNewlines),
                in: snapshot
            )
        }
        .sorted(by: workSetWindowSort)
    }

    private func restoreMinimizedWorkSetMembers(
        _ resolvedMembers: [WorkSetResolvedMember]
    ) async -> (restored: Int, failed: Int) {
        var seenWindowIDs = Set<Int>()
        let minimizedWindows = resolvedMembers.compactMap(\.matchedWindow).filter { window in
            window.isMinimized && seenWindowIDs.insert(window.id).inserted
        }
        guard !minimizedWindows.isEmpty else { return (0, 0) }

        var restored = 0
        var failed = 0
        for window in minimizedWindows {
            guard !Task.isCancelled else { break }
            if await restoreMinimizedWorkSetWindow(window) {
                restored += 1
            } else {
                failed += 1
            }
        }
        return (restored, failed)
    }

    private func mergeWorkSetRestoreResults(
        _ lhs: (restored: Int, failed: Int),
        _ rhs: (restored: Int, failed: Int)
    ) -> (restored: Int, failed: Int) {
        (lhs.restored + rhs.restored, lhs.failed + rhs.failed)
    }

    private func restoreMinimizedWorkSetWindow(_ window: WindowState) async -> Bool {
        let restore = await doctorService.runSupportCommand(
            yabaiCommand(["-m", "window", "--deminimize", String(window.id)], timeout: 1.5)
        )
        await MainActor.run {
            appendCommandLog(from: restore)
        }
        if restore.isSuccess {
            return true
        }

        guard window.hasAXReference else { return false }
        let appElement = AXUIElementCreateApplication(pid_t(window.pid))
        var windowsRef: CFTypeRef?
        let windowsResult = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
        guard windowsResult == .success,
              let windows = windowsRef as? [AXUIElement],
              let targetWindow = matchingAXWindow(for: window, in: windows) else {
            return false
        }

        let unminimized = AXUIElementSetAttributeValue(
            targetWindow,
            kAXMinimizedAttribute as CFString,
            kCFBooleanFalse
        ) == .success
        if unminimized {
            _ = AXUIElementPerformAction(targetWindow, kAXRaiseAction as CFString)
        }
        return unminimized
    }

    private func launchMissingAppsForWorkSet(_ workSet: WorkSet) async -> WorkSetLaunchMissingAppsResult {
        let candidates = workSetActivationCandidateWindows(in: latestLiveStateSnapshot ?? liveStateSnapshot)
        let resolvedMembers = resolveWorkSetMembers(workSet.members, in: candidates)
        let missingMembers = resolvedMembers.compactMap { resolved -> WorkSetMember? in
            resolved.matchedWindow == nil ? resolved.member : nil
        }
        guard !missingMembers.isEmpty else { return WorkSetLaunchMissingAppsResult() }

        var result = WorkSetLaunchMissingAppsResult()
        var launchedMembersByKey: [String: WorkSetMember] = [:]

        for member in missingMembers {
            guard !Task.isCancelled else { break }
            guard let launchKey = workSetLaunchKey(for: member),
                  launchedMembersByKey[launchKey] == nil,
                  !workSetMemberAppIsRunning(member) else {
                continue
            }

            let launched = await launchWorkSetMemberApp(member)
            if launched {
                launchedMembersByKey[launchKey] = member
                result.launched += 1
            } else {
                result.failed += 1
            }
        }

        guard !launchedMembersByKey.isEmpty else { return result }

        var unresolvedLaunchKeys = Set(launchedMembersByKey.keys)
        for attempt in 0..<16 {
            guard !Task.isCancelled else { break }
            try? await Task.sleep(for: .milliseconds(250))
            await refreshLiveState()

            let refreshedCandidates = workSetActivationCandidateWindows(in: latestLiveStateSnapshot ?? liveStateSnapshot)
            let refreshedResolvedMembers = resolveWorkSetMembers(workSet.members, in: refreshedCandidates)
            for resolved in refreshedResolvedMembers where resolved.matchedWindow != nil {
                if let launchKey = workSetLaunchKey(for: resolved.member) {
                    unresolvedLaunchKeys.remove(launchKey)
                }
            }

            if unresolvedLaunchKeys.isEmpty || attempt == 15 {
                break
            }
        }

        result.noWindow = unresolvedLaunchKeys.count
        return result
    }

    private func workSetLaunchKey(for member: WorkSetMember) -> String? {
        if let bundleIdentifier = member.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
           !bundleIdentifier.isEmpty {
            return "bundle:\(bundleIdentifier.lowercased())"
        }
        let appName = normalizedAppRuleKey(member.appName)
        return appName.isEmpty ? nil : "app:\(appName)"
    }

    private func workSetMemberAppIsRunning(_ member: WorkSetMember) -> Bool {
        if let bundleIdentifier = member.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
           !bundleIdentifier.isEmpty,
           !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty {
            return true
        }

        let appName = normalizedAppRuleKey(member.appName)
        guard !appName.isEmpty else { return false }
        return NSWorkspace.shared.runningApplications.contains { runningApp in
            normalizedAppRuleKey(runningApp.localizedName ?? "") == appName
        }
    }

    private func launchWorkSetMemberApp(_ member: WorkSetMember) async -> Bool {
        let command: ShellCommand
        if let bundleURLPath = member.bundleURLPath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !bundleURLPath.isEmpty,
           FileManager.default.fileExists(atPath: bundleURLPath) {
            command = ShellCommand("/usr/bin/open", [bundleURLPath], timeout: 3.0)
        } else if let bundleIdentifier = member.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !bundleIdentifier.isEmpty {
            command = ShellCommand("/usr/bin/open", ["-b", bundleIdentifier], timeout: 3.0)
        } else {
            let appName = member.appName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !appName.isEmpty else { return false }
            command = ShellCommand("/usr/bin/open", ["-a", appName], timeout: 3.0)
        }

        let launch = await doctorService.runSupportCommand(command)
        await MainActor.run {
            appendCommandLog(from: launch)
        }
        return launch.isSuccess
    }

    private func workSetActivationRecoveryMessages(
        restoredMinimized: Int,
        failedMinimizedRestore: Int,
        launchResult: WorkSetLaunchMissingAppsResult
    ) -> [String] {
        var messages: [String] = []
        if restoredMinimized > 0 {
            messages.append("Restored \(restoredMinimized) minimized window(s).")
        }
        if failedMinimizedRestore > 0 {
            messages.append("Could not restore \(failedMinimizedRestore) minimized window(s).")
        }
        if launchResult.launched > 0 {
            messages.append("Launched \(launchResult.launched) app(s).")
        }
        if launchResult.noWindow > 0 {
            messages.append("\(launchResult.noWindow) launched app(s) opened no window.")
        }
        if launchResult.failed > 0 {
            messages.append("\(launchResult.failed) app launch(es) failed.")
        }
        return messages
    }

    private func resetWorkSetScopeForActivation(
        scopeKey: WorkSetScopeKey,
        incomingWorkSetID: UUID,
        incomingLayoutMode: WorkSetLayoutMode,
        preserveBackdrop: Bool
    ) async -> (updated: Int, failed: Int, layoutResetAttempted: Bool, layoutResetSucceeded: Bool) {
        guard let activeID = activeWorkSetID(for: scopeKey),
              activeID != incomingWorkSetID,
              let activeWorkSet = workSet(withID: activeID),
              activeWorkSet.layoutMode == .tiled else {
            return (0, 0, false, true)
        }

        if !preserveBackdrop {
            hideWorkSetBackdrop(for: scopeKey)
        }

        if incomingLayoutMode == .tiled {
            return (0, 0, false, true)
        }

        let switchedToFloat = await runBestEffortYabaiCommand(
            ["-m", "space", String(scopeKey.spaceIndex), "--layout", "float"],
            timeout: 1.5,
            log: true
        )
        if switchedToFloat {
            savedDesktopLayoutBeforeTiledWorkSetByScope.removeValue(forKey: scopeKey)
            savedWindowFramesBeforeTiledWorkSetByScope.removeValue(forKey: scopeKey)
        }

        return (0, 0, true, switchedToFloat)
    }

    private func updateWorkSetBackdropPresentation(
        for workSet: WorkSet,
        context: WorkSetDesktopContext,
        activeWindowIDs: Set<Int>,
        resetDismissal: Bool
    ) {
        if resetDismissal {
            clearDismissedWorkSetBackdrop(for: workSet.scopeKey)
        }
        if workSet.backdropEnabled {
            let anchorWindow = workSetBackdropAnchorWindow(
                scopeKey: workSet.scopeKey,
                excluding: activeWindowIDs
            )
            showWorkSetBackdrop(for: workSet, display: context.display, anchorWindow: anchorWindow)
        } else {
            hideWorkSetBackdrop(for: workSet.scopeKey)
        }
    }

    private func visibleWindowsForWorkSetScope(
        _ scopeKey: WorkSetScopeKey,
        in snapshot: LiveStateSnapshot?
    ) -> [WindowState] {
        guard let snapshot else { return [] }
        return snapshot.windows.filter {
            $0.space == scopeKey.spaceIndex &&
            $0.isVisible &&
            !$0.isMinimized &&
            !$0.isHidden &&
            !isBackdropSurfaceWindow(
                $0,
                normalizedTitle: $0.title.trimmingCharacters(in: .whitespacesAndNewlines),
                normalizedRole: $0.role.trimmingCharacters(in: .whitespacesAndNewlines),
                normalizedSubrole: $0.subrole.trimmingCharacters(in: .whitespacesAndNewlines),
                in: snapshot
            )
        }
        .sorted(by: workSetWindowSort)
    }

    private func rememberOriginalDesktopLayoutBeforeTiledWorkSetOverrideIfNeeded(
        scopeKey: WorkSetScopeKey,
        snapshot: LiveStateSnapshot?
    ) {
        guard savedDesktopLayoutBeforeTiledWorkSetByScope[scopeKey] == nil,
              let layout = snapshot?.spaces.first(where: { $0.index == scopeKey.spaceIndex && $0.displayId == scopeKey.displayID })?.layout?.lowercased(),
              !layout.isEmpty else {
            return
        }
        savedDesktopLayoutBeforeTiledWorkSetByScope[scopeKey] = layout
        if savedWindowFramesBeforeTiledWorkSetByScope[scopeKey] == nil,
           let snapshot {
            let windows = visibleWindowsForWorkSetScope(scopeKey, in: snapshot).filter(\.isRuntimeManageable)
            savedWindowFramesBeforeTiledWorkSetByScope[scopeKey] = Dictionary(
                uniqueKeysWithValues: windows.map { ($0.id, WorkSetSavedWindowFrame(window: $0)) }
            )
        }
    }

    func restoreSavedTiledWorkSetDesktopLayoutIfNeeded(scopeKey: WorkSetScopeKey) async -> Bool {
        guard let savedLayout = savedDesktopLayoutBeforeTiledWorkSetByScope[scopeKey] else {
            return true
        }
        let restored = await runBestEffortYabaiCommand(
            ["-m", "space", String(scopeKey.spaceIndex), "--layout", savedLayout],
            timeout: 1.5,
            log: true
        )
        if restored {
            savedDesktopLayoutBeforeTiledWorkSetByScope.removeValue(forKey: scopeKey)
            savedWindowFramesBeforeTiledWorkSetByScope.removeValue(forKey: scopeKey)
        }
        return restored
    }

    private func restoreSavedWindowFramesAfterTiledWorkSetIfNeeded(
        scopeKey: WorkSetScopeKey,
        windows: [WindowState]? = nil,
        refreshAfterRestore: Bool = true
    ) async -> (updated: Int, failed: Int) {
        guard let savedFrames = savedWindowFramesBeforeTiledWorkSetByScope.removeValue(forKey: scopeKey),
              !savedFrames.isEmpty else {
            return (0, 0)
        }

        let targetWindows = (windows ?? visibleWindowsForWorkSetScope(scopeKey, in: latestLiveStateSnapshot ?? liveStateSnapshot))
            .filter(\.isRuntimeManageable)
        var updated = 0
        var failed = 0

        for window in targetWindows {
            guard !Task.isCancelled else { break }
            guard let savedFrame = savedFrames[window.id] else { continue }

            let resizeResult = await doctorService.runSupportCommand(
                yabaiCommand(
                    ["-m", "window", String(window.id), "--resize", "abs:\(Int(savedFrame.width)):\(Int(savedFrame.height))"],
                    timeout: 1.5
                )
            )
            await MainActor.run {
                appendCommandLog(from: resizeResult)
            }

            let moveResult = await doctorService.runSupportCommand(
                yabaiCommand(
                    ["-m", "window", String(window.id), "--move", "abs:\(Int(savedFrame.x)):\(Int(savedFrame.y))"],
                    timeout: 1.5
                )
            )
            await MainActor.run {
                appendCommandLog(from: moveResult)
            }

            if resizeResult.isSuccess && moveResult.isSuccess {
                updated += 1
            } else {
                failed += 1
            }
        }

        if refreshAfterRestore, updated > 0 {
            try? await Task.sleep(for: .milliseconds(60))
            await refreshLiveState()
        }

        return (updated, failed)
    }

    private func normalizeWorkSetScopeToFloatingIfNeeded(
        scopeKey: WorkSetScopeKey
    ) async -> (updated: Int, failed: Int) {
        var snapshot = latestLiveStateSnapshot ?? liveStateSnapshot
        if snapshot == nil {
            await refreshLiveState()
            snapshot = latestLiveStateSnapshot ?? liveStateSnapshot
        }
        let windows = visibleWindowsForWorkSetScope(scopeKey, in: snapshot)
            .filter { $0.isRuntimeManageable && !$0.floating }
        guard !windows.isEmpty else { return (0, 0) }

        let result = await setFloatingStateForWindows(windows, shouldFloat: true)
        if result.updated > 0 {
            try? await Task.sleep(for: .milliseconds(60))
            await refreshLiveState()
        }
        return result
    }

    private func applyTiledWorkSetLayout(
        scopeKey: WorkSetScopeKey,
        scopeWindows: [WindowState],
        activeWindows: [WindowState],
        focusPrimary: Bool
    ) async -> (updated: Int, failed: Int, primaryFocused: Bool) {
        guard !activeWindows.isEmpty else { return (0, 0, false) }

        let activeWindowIDs = Set(activeWindows.map(\.id))
        let nonMembers = scopeWindows.filter {
            !activeWindowIDs.contains($0.id) && $0.isRuntimeManageable
        }

        let floatedNonMembers = await setFloatingStateForWindows(
            nonMembers.filter { !$0.floating },
            shouldFloat: true
        )
        if floatedNonMembers.updated > 0 {
            try? await Task.sleep(for: .milliseconds(35))
        }

        let rebuildResult = await rebuildBalancedTileLayout(
            spaceIndex: scopeKey.spaceIndex,
            windows: activeWindows
        )

        let restackResult = await restackTiledWorkSetWindowsAboveBackdrop(
            activeWindows.reversed(),
            primaryWindow: focusPrimary ? activeWindows.first : nil
        )

        return (
            updated: floatedNonMembers.updated + rebuildResult.updated + restackResult.updated,
            failed: floatedNonMembers.failed + rebuildResult.failed + restackResult.failed,
            primaryFocused: restackResult.primaryFocused
        )
    }

    private func restackTiledWorkSetWindowsAboveBackdrop<S: Sequence>(
        _ windows: S,
        primaryWindow: WindowState?
    ) async -> (updated: Int, failed: Int, primaryFocused: Bool) where S.Element == WindowState {
        var updated = 0
        var failed = 0

        for window in windows {
            guard !Task.isCancelled else { break }
            let raised = await focusWorkSetStackWindow(window)
            if raised {
                updated += 1
            } else {
                failed += 1
            }
            try? await Task.sleep(for: .milliseconds(4))
        }

        let primaryFocused: Bool
        if let primaryWindow {
            primaryFocused = await focusWindowWithRestore(
                windowID: primaryWindow.id,
                knownWindow: primaryWindow
            )
        } else {
            primaryFocused = true
        }

        return (updated, failed, primaryFocused)
    }

    private func prepareWorkSetActivationScope(_ scopeKey: WorkSetScopeKey) async -> Bool {
        for attempt in 0..<6 {
            await refreshLiveState()
            if visibleWorkSetContexts.contains(where: { $0.scopeKey == scopeKey }) {
                return true
            }
            if attempt < 5 {
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        return visibleWorkSetContexts.contains(where: { $0.scopeKey == scopeKey })
    }

    private func moveWorkSetWindowsIntoScope(
        _ windows: [WindowState],
        scopeKey: WorkSetScopeKey
    ) async -> (moved: Int, failed: Int) {
        guard !windows.isEmpty else { return (0, 0) }

        var moved = 0
        var failed = 0
        let targetDisplay = workSetContext(for: scopeKey)?.display

        for window in windows {
            guard !Task.isCancelled else { break }
            guard !workSetWindowMatchesScope(window, scopeKey: scopeKey, targetDisplay: targetDisplay) else {
                continue
            }

            let movedIntoScope = await moveWindowIntoWorkSetScope(
                window: window,
                scopeKey: scopeKey,
                targetDisplay: targetDisplay
            )
            if movedIntoScope {
                moved += 1
            } else {
                failed += 1
            }
        }

        return (moved, failed)
    }

    private func moveWindowIntoWorkSetScope(
        window: WindowState,
        scopeKey: WorkSetScopeKey,
        targetDisplay: DisplayState?
    ) async -> Bool {
        let windowID = window.id
        let primaryMove = await doctorService.runSupportCommand(
            yabaiCommand(["-m", "window", String(windowID), "--space", String(scopeKey.spaceIndex)], timeout: 1.8)
        )
        await MainActor.run {
            appendCommandLog(from: primaryMove)
        }

        if primaryMove.isSuccess {
            if await workSetWindowIsInScope(windowID: windowID, scopeKey: scopeKey, targetDisplay: targetDisplay) {
                return true
            }
        }

        let displayMove = await doctorService.runSupportCommand(
            yabaiCommand(["-m", "window", String(windowID), "--display", String(scopeKey.displayID)], timeout: 1.8)
        )
        await MainActor.run {
            appendCommandLog(from: displayMove)
        }
        if displayMove.isSuccess {
            let finalizeMove = await doctorService.runSupportCommand(
                yabaiCommand(["-m", "window", String(windowID), "--space", String(scopeKey.spaceIndex)], timeout: 1.8)
            )
            await MainActor.run {
                appendCommandLog(from: finalizeMove)
            }

            if finalizeMove.isSuccess,
               await workSetWindowIsInScope(windowID: windowID, scopeKey: scopeKey, targetDisplay: targetDisplay) {
                return true
            }
        }

        guard let targetDisplay,
              window.hasAXReference,
              window.canMove else {
            return false
        }

        return await moveWindowIntoWorkSetScopeUsingAccessibility(
            window: window,
            scopeKey: scopeKey,
            targetDisplay: targetDisplay
        )
    }

    private func workSetWindowIsInScope(
        windowID: Int,
        scopeKey: WorkSetScopeKey,
        targetDisplay: DisplayState?
    ) async -> Bool {
        try? await Task.sleep(for: .milliseconds(140))
        await refreshLiveState()
        guard let snapshot = latestLiveStateSnapshot ?? liveStateSnapshot,
              let updated = snapshot.windows.first(where: { $0.id == windowID }) else {
            return false
        }
        let resolvedTargetDisplay = snapshot.displays.first(where: { $0.id == scopeKey.displayID }) ?? targetDisplay
        return workSetWindowMatchesScope(updated, scopeKey: scopeKey, targetDisplay: resolvedTargetDisplay)
    }

    private func moveWindowIntoWorkSetScopeUsingAccessibility(
        window: WindowState,
        scopeKey: WorkSetScopeKey,
        targetDisplay: DisplayState
    ) async -> Bool {
        let appPID = pid_t(window.pid)
        NSRunningApplication(processIdentifier: appPID)?.activate(options: [.activateIgnoringOtherApps])

        let appElement = AXUIElementCreateApplication(appPID)
        var windowsRef: CFTypeRef?
        let windowsResult = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
        guard windowsResult == .success,
              let windows = windowsRef as? [AXUIElement],
              !windows.isEmpty,
              let targetWindow = matchingAXWindow(for: window, in: windows) else {
            return false
        }

        if window.isMinimized || axBoolValue(targetWindow, kAXMinimizedAttribute as CFString) == true {
            _ = AXUIElementSetAttributeValue(targetWindow, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }

        var targetPoint = workSetAccessibilityTargetPoint(for: window, targetDisplay: targetDisplay)
        guard let positionValue = AXValueCreate(.cgPoint, &targetPoint) else {
            return false
        }

        let positionSet = AXUIElementSetAttributeValue(
            targetWindow,
            kAXPositionAttribute as CFString,
            positionValue
        ) == .success
        let raised = AXUIElementPerformAction(targetWindow, kAXRaiseAction as CFString) == .success

        guard positionSet || raised else {
            return false
        }

        return await workSetWindowIsInScope(
            windowID: window.id,
            scopeKey: scopeKey,
            targetDisplay: targetDisplay
        )
    }

    private func workSetAccessibilityTargetPoint(
        for window: WindowState,
        targetDisplay: DisplayState
    ) -> CGPoint {
        let snapshot = latestLiveStateSnapshot ?? liveStateSnapshot
        let sourceDisplay = snapshot?.displays.first(where: { $0.id == window.display })

        let horizontalInset = min(max(targetDisplay.frameW * 0.04, 28), 84)
        let verticalInset = min(max(targetDisplay.frameH * 0.05, 42), 108)
        let fallbackX = targetDisplay.frameX + horizontalInset
        let fallbackY = targetDisplay.frameY + verticalInset

        let desiredX: Double
        let desiredY: Double
        if let sourceDisplay {
            desiredX = targetDisplay.frameX + (window.frameX - sourceDisplay.frameX)
            desiredY = targetDisplay.frameY + (window.frameY - sourceDisplay.frameY)
        } else {
            desiredX = fallbackX
            desiredY = fallbackY
        }

        let maxX = max(fallbackX, targetDisplay.frameX + targetDisplay.frameW - max(window.frameW, 180) - horizontalInset)
        let maxY = max(fallbackY, targetDisplay.frameY + targetDisplay.frameH - max(window.frameH, 140) - verticalInset)

        return CGPoint(
            x: min(max(desiredX, fallbackX), maxX),
            y: min(max(desiredY, fallbackY), maxY)
        )
    }

    private func workSetWindowMatchesScope(
        _ window: WindowState,
        scopeKey: WorkSetScopeKey,
        targetDisplay: DisplayState?
    ) -> Bool {
        guard window.space == scopeKey.spaceIndex,
              window.display == scopeKey.displayID else {
            return false
        }
        guard let targetDisplay else {
            return true
        }
        return workSetWindowAppearsOnDisplay(window, display: targetDisplay)
    }

    private func workSetWindowAppearsOnDisplay(_ window: WindowState, display: DisplayState) -> Bool {
        let displayRect = CGRect(
            x: display.frameX,
            y: display.frameY,
            width: display.frameW,
            height: display.frameH
        )
        let windowRect = CGRect(
            x: window.frameX,
            y: window.frameY,
            width: window.frameW,
            height: window.frameH
        )
        guard !displayRect.isEmpty, !windowRect.isEmpty else {
            return false
        }

        let center = CGPoint(x: windowRect.midX, y: windowRect.midY)
        if displayRect.contains(center) {
            return true
        }

        let intersection = displayRect.intersection(windowRect)
        guard !intersection.isNull, !intersection.isEmpty else {
            return false
        }

        let windowArea = max(windowRect.width * windowRect.height, 1)
        let visibleShare = (intersection.width * intersection.height) / windowArea
        return visibleShare >= 0.35
    }

    func requestActiveWorkSetOwnedLayoutSync() {
        guard !workSetActivationInProgress else {
            return
        }
        guard let snapshot = latestLiveStateSnapshot ?? liveStateSnapshot,
              snapshot.source == .yabai,
              !snapshot.degraded else {
            return
        }
        scheduleActiveWorkSetOwnedLayoutSyncIfNeeded(using: snapshot)
    }

    private func scheduleActiveWorkSetOwnedLayoutSyncIfNeeded(using snapshot: LiveStateSnapshot) {
        guard snapshot.source == .yabai, !snapshot.degraded else { return }
        if activeWorkSetLayoutSyncTask != nil {
            pendingActiveWorkSetLayoutSync = true
            return
        }

        activeWorkSetLayoutSyncTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.syncActiveWorkSetOwnedLayoutsIfNeeded()
            self.activeWorkSetLayoutSyncTask = nil
            if self.pendingActiveWorkSetLayoutSync {
                self.pendingActiveWorkSetLayoutSync = false
                self.requestActiveWorkSetOwnedLayoutSync()
            }
        }
    }

    private func syncActiveWorkSetOwnedLayoutsIfNeeded() async {
        guard !Task.isCancelled else { return }
        guard let snapshot = latestLiveStateSnapshot ?? liveStateSnapshot,
              snapshot.source == .yabai,
              !snapshot.degraded else {
            return
        }

        let visibleContexts = visibleWorkSetContexts(in: snapshot)
        let contextsByScope = Dictionary(uniqueKeysWithValues: visibleContexts.map { ($0.scopeKey, $0) })
        let activeTiledWorkSets = workSets.filter {
            activeWorkSetID(for: $0.scopeKey) == $0.id &&
            $0.layoutMode == .tiled &&
            contextsByScope[$0.scopeKey] != nil
        }
        let activeTiledScopeIDs = Set(activeTiledWorkSets.map { $0.scopeKey.id })

        for scopeKey in savedDesktopLayoutBeforeTiledWorkSetByScope.keys.sorted(by: { $0.id < $1.id }) {
            guard !Task.isCancelled else { return }
            guard !activeTiledScopeIDs.contains(scopeKey.id),
                  contextsByScope[scopeKey] != nil else {
                continue
            }
            if await restoreSavedTiledWorkSetDesktopLayoutIfNeeded(scopeKey: scopeKey) {
                lastWorkSetOwnedLayoutSyncSignatureByScope.removeValue(forKey: scopeKey.id)
                await refreshLiveState()
            }
        }

        for workSet in activeTiledWorkSets {
            guard !Task.isCancelled else { return }
            guard let signature = workSetOwnedLayoutSyncSignature(for: workSet, snapshot: snapshot),
                  lastWorkSetOwnedLayoutSyncSignatureByScope[workSet.scopeKey.id] != signature,
                  let context = contextsByScope[workSet.scopeKey] else {
                continue
            }

            let scopeWindows = visibleWindowsForWorkSetScope(workSet.scopeKey, in: snapshot)
            let resolvedMembers = resolveWorkSetMembers(workSet.members, in: scopeWindows)
            let activeWindows = resolvedMembers.compactMap(\.matchedWindow).filter(\.isRuntimeManageable)
            guard !activeWindows.isEmpty else {
                lastWorkSetOwnedLayoutSyncSignatureByScope[workSet.scopeKey.id] = signature
                continue
            }

            rememberOriginalDesktopLayoutBeforeTiledWorkSetOverrideIfNeeded(
                scopeKey: workSet.scopeKey,
                snapshot: snapshot
            )

            let result = await applyTiledWorkSetLayout(
                scopeKey: workSet.scopeKey,
                scopeWindows: scopeWindows,
                activeWindows: activeWindows,
                focusPrimary: false
            )

            updateWorkSetBackdropPresentation(
                for: workSet,
                context: context,
                activeWindowIDs: Set(activeWindows.map(\.id)),
                resetDismissal: false
            )

            if result.updated > 0 || result.failed > 0 {
                await refreshLiveState()
            }

            let appliedSnapshot = latestLiveStateSnapshot ?? liveStateSnapshot ?? snapshot
            lastWorkSetOwnedLayoutSyncSignatureByScope[workSet.scopeKey.id] =
                workSetOwnedLayoutSyncSignature(for: workSet, snapshot: appliedSnapshot) ?? signature
        }

        lastWorkSetOwnedLayoutSyncSignatureByScope = lastWorkSetOwnedLayoutSyncSignatureByScope.filter { scopeID, _ in
            activeTiledScopeIDs.contains(scopeID)
        }
    }

    private func workSetOwnedLayoutSyncSignature(
        for workSet: WorkSet,
        snapshot: LiveStateSnapshot
    ) -> String? {
        guard snapshot.source == .yabai,
              !snapshot.degraded,
              snapshot.spaces.contains(where: { $0.index == workSet.scopeKey.spaceIndex && $0.displayId == workSet.scopeKey.displayID }) else {
            return nil
        }

        let memberSignature = workSet.members.map { member in
            [
                member.id.uuidString.lowercased(),
                normalizedAppRuleKey(member.appName),
                normalizedWorkSetSyncMetadata(member.windowTitle),
                normalizedWorkSetSyncMetadata(member.role),
                normalizedWorkSetSyncMetadata(member.subrole),
                member.lastSeenWindowID.map(String.init) ?? "",
                member.lastSeenPID.map(String.init) ?? ""
            ].joined(separator: ":")
        }
        .joined(separator: "|")

        let windowSignature = visibleWindowsForWorkSetScope(workSet.scopeKey, in: snapshot)
            .sorted { lhs, rhs in
                if lhs.id != rhs.id { return lhs.id < rhs.id }
                if lhs.space != rhs.space { return lhs.space < rhs.space }
                return lhs.display < rhs.display
            }
            .map { window in
                [
                    String(window.id),
                    String(window.space),
                    String(window.display),
                    window.floating ? "1" : "0",
                    window.isRuntimeManageable ? "1" : "0"
                ].joined(separator: ":")
            }
            .joined(separator: "|")

        let layout = snapshot.spaces.first(where: {
            $0.index == workSet.scopeKey.spaceIndex && $0.displayId == workSet.scopeKey.displayID
        })?.layout?.lowercased() ?? "unknown"

        return [
            workSet.id.uuidString.lowercased(),
            workSet.layoutMode.rawValue,
            workSet.linkedTemplateID?.uuidString.lowercased() ?? "",
            layout,
            memberSignature,
            windowSignature
        ].joined(separator: "###")
    }

    private func normalizedWorkSetSyncMetadata(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    }

    private func currentDesktopWindowsForRecentWindowTiler(
        targetSpaceIndex: Int? = nil,
        targetDisplayID: Int? = nil
    ) async -> RecentWindowTilerDesktopState? {
        var snapshot = latestLiveStateSnapshot ?? liveStateSnapshot
        if snapshot == nil || snapshot?.source != .yabai || snapshot?.degraded == true {
            await refreshLiveState()
            snapshot = latestLiveStateSnapshot ?? liveStateSnapshot
        }

        guard let snapshot,
              snapshot.source == .yabai,
              !snapshot.degraded,
              let target = recentWindowTilerTargetSpace(
                in: snapshot,
                targetSpaceIndex: targetSpaceIndex,
                targetDisplayID: targetDisplayID
              ) else {
            await MainActor.run {
                self.lastErrorMessage = "Current desktop data is unavailable right now."
                self.lastActionMessage = nil
            }
            return nil
        }

        let spaceIndex = target.space.index
        let spaceDisplay = target.display
        let primaryDisplayID = spaceDisplay?.id
        let visibleOtherSpaceIndexes = Set(snapshot.spaces
            .filter { space in
                guard space.visible, space.index != spaceIndex else { return false }
                if let primaryDisplayID {
                    return space.displayId != primaryDisplayID
                }
                return true
            }
            .map(\.index)
        )

        let primaryWindows = snapshot.windows
            .filter { window in
                guard window.space == spaceIndex else { return false }
                if let primaryDisplayID, window.display != primaryDisplayID {
                    return false
                }
                return recentWindowTilerCanUseWindow(window, in: snapshot)
            }
            .sorted(by: workSetWindowSort)
        let primaryWindowIDs = Set(primaryWindows.map(\.id))

        let secondaryWindows = snapshot.windows
            .filter { window in
                guard visibleOtherSpaceIndexes.contains(window.space),
                      !primaryWindowIDs.contains(window.id) else {
                    return false
                }
                if let primaryDisplayID, window.display == primaryDisplayID {
                    return false
                }
                return recentWindowTilerCanUseWindow(window, in: snapshot)
            }
            .sorted(by: workSetWindowSort)
        let tilingEnabledBySpaceIndex = Dictionary(uniqueKeysWithValues: snapshot.spaces.compactMap { space -> (Int, Bool)? in
            guard let enabled = tilingEnabled(forSpaceLayout: space.layout) else { return nil }
            return (space.index, enabled)
        })

        return RecentWindowTilerDesktopState(
            spaceIndex: spaceIndex,
            display: spaceDisplay,
            windows: primaryWindows + secondaryWindows,
            primaryWindowIDs: primaryWindowIDs,
            tilingEnabledBySpaceIndex: tilingEnabledBySpaceIndex,
            targetOptions: recentWindowTilerTargetOptions(in: snapshot)
        )
    }

    private func recentWindowTilerTargetOptions(in snapshot: LiveStateSnapshot) -> [RecentWindowTilerTargetOption] {
        let displaysByID = Dictionary(uniqueKeysWithValues: snapshot.displays.map { ($0.id, $0) })
        let visibleSpaces = snapshot.spaces
            .filter(\.visible)
            .compactMap { space -> RecentWindowTilerTargetOption? in
                guard let display = displaysByID[space.displayId] else { return nil }
                return RecentWindowTilerTargetOption(
                    displayID: display.id,
                    displayName: display.name,
                    spaceIndex: space.index
                )
            }

        let uniqueByDisplay = Dictionary(visibleSpaces.map { ($0.displayID, $0) }, uniquingKeysWith: { first, _ in first })
        return uniqueByDisplay.values.sorted { lhs, rhs in
            guard let lhsDisplay = displaysByID[lhs.displayID],
                  let rhsDisplay = displaysByID[rhs.displayID] else {
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
            if abs(lhsDisplay.frameY - rhsDisplay.frameY) > 8 {
                return lhsDisplay.frameY < rhsDisplay.frameY
            }
            if abs(lhsDisplay.frameX - rhsDisplay.frameX) > 8 {
                return lhsDisplay.frameX < rhsDisplay.frameX
            }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    private func recentWindowTilerTargetSpace(
        in snapshot: LiveStateSnapshot,
        targetSpaceIndex: Int?,
        targetDisplayID: Int?
    ) -> (space: SpaceState, display: DisplayState?)? {
        if let targetSpaceIndex,
           let space = snapshot.spaces.first(where: { space in
               space.index == targetSpaceIndex &&
                   targetDisplayID.map { space.displayId == $0 } ?? true
           }) {
            return (space, snapshot.displays.first(where: { $0.id == space.displayId }))
        }

        if let mouseDisplay = recentWindowTilerMouseDisplay(in: snapshot),
           let visibleSpace = snapshot.spaces.first(where: { $0.displayId == mouseDisplay.id && $0.visible })
                ?? snapshot.spaces.first(where: { $0.displayId == mouseDisplay.id && $0.focused })
                ?? snapshot.spaces.first(where: { $0.displayId == mouseDisplay.id }) {
            return (visibleSpace, mouseDisplay)
        }

        guard let activeSpaceIndex = activeSpaceIndex(in: snapshot),
              let activeSpace = snapshot.spaces.first(where: { $0.index == activeSpaceIndex }) else {
            return nil
        }
        return (activeSpace, snapshot.displays.first(where: { $0.id == activeSpace.displayId }))
    }

    private func recentWindowTilerMouseDisplay(in snapshot: LiveStateSnapshot) -> DisplayState? {
        let mouse = NSEvent.mouseLocation
        let screens = NSScreen.screens
        let matches = snapshot.displays.filter { display in
            let appKitFrame = convertRecentWindowTilerDisplayFrameToAppKit(display, screens: screens)
            return appKitFrame.contains(mouse)
        }
        if matches.count == 1 {
            return matches[0]
        }

        let best = snapshot.displays.max { lhs, rhs in
            let lhsFrame = convertRecentWindowTilerDisplayFrameToAppKit(lhs, screens: screens)
            let rhsFrame = convertRecentWindowTilerDisplayFrameToAppKit(rhs, screens: screens)
            let lhsDistance = recentWindowTilerDistanceSquared(from: mouse, to: lhsFrame)
            let rhsDistance = recentWindowTilerDistanceSquared(from: mouse, to: rhsFrame)
            return lhsDistance > rhsDistance
        }
        return best
    }

    private func convertRecentWindowTilerDisplayFrameToAppKit(_ display: DisplayState, screens: [NSScreen]) -> CGRect {
        let rect = CGRect(x: display.frameX, y: display.frameY, width: display.frameW, height: display.frameH)
        guard !screens.isEmpty else { return rect }
        let referenceMaxY = screens.first(where: { screen in
            abs(screen.frame.minX) < 0.5 && abs(screen.frame.minY) < 0.5
        })?.frame.maxY
            ?? NSScreen.main?.frame.maxY
            ?? screens.map(\.frame.maxY).min()
            ?? rect.maxY
        return CGRect(
            x: rect.origin.x,
            y: referenceMaxY - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    private func recentWindowTilerDistanceSquared(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx: CGFloat
        if point.x < rect.minX {
            dx = rect.minX - point.x
        } else if point.x > rect.maxX {
            dx = point.x - rect.maxX
        } else {
            dx = 0
        }

        let dy: CGFloat
        if point.y < rect.minY {
            dy = rect.minY - point.y
        } else if point.y > rect.maxY {
            dy = point.y - rect.maxY
        } else {
            dy = 0
        }

        return (dx * dx) + (dy * dy)
    }

    private func recentWindowTilerCanUseWindow(_ window: WindowState, in snapshot: LiveStateSnapshot) -> Bool {
        guard !window.isHidden else {
            return false
        }
        guard !isBackdropSurfaceWindow(
            window,
            normalizedTitle: window.title.trimmingCharacters(in: .whitespacesAndNewlines),
            normalizedRole: window.role.trimmingCharacters(in: .whitespacesAndNewlines),
            normalizedSubrole: window.subrole.trimmingCharacters(in: .whitespacesAndNewlines),
            in: snapshot
        ) else {
            return false
        }

        if window.isMinimized {
            return window.hasAXReference || window.isRuntimeManageable
        }

        if window.isVisible || window.hasWindowServerMatch || window.isRuntimeManageable {
            return true
        }

        return recentWindowTilerAccessibilityInfo(for: window)?.canMoveAndResize == true
    }

    private func restoreMinimizedRecentWindowTilerWindows(_ windows: [WindowState]) async -> (restored: Int, failed: Int) {
        var seenWindowIDs = Set<Int>()
        let minimizedWindows = windows.filter { window in
            window.isMinimized && seenWindowIDs.insert(window.id).inserted
        }
        guard !minimizedWindows.isEmpty else { return (0, 0) }

        var restored = 0
        var failed = 0
        for window in minimizedWindows {
            guard !Task.isCancelled else { break }
            if await restoreMinimizedWorkSetWindow(window) {
                restored += 1
            } else {
                failed += 1
            }
        }
        return (restored, failed)
    }

    private func moveRecentWindowTilerWindowsIntoPrimaryScope(
        _ windows: [WindowState],
        scopeKey: WorkSetScopeKey,
        display: DisplayState
    ) async -> (moved: Int, failed: Int) {
        var moved = 0
        var failed = 0

        for window in windows {
            guard !Task.isCancelled else { break }
            let movedIntoScope = await moveWindowIntoWorkSetScope(
                window: window,
                scopeKey: scopeKey,
                targetDisplay: display
            )
            if movedIntoScope {
                moved += 1
            } else {
                failed += 1
            }
        }

        return (moved, failed)
    }

    private func currentDesktopVisibleWindowsForBulkLayout(template: WindowLayoutTemplate? = nil) async -> (spaceIndex: Int, display: DisplayState?, windows: [WindowState])? {
        var snapshot = latestLiveStateSnapshot ?? liveStateSnapshot
        if snapshot == nil || snapshot?.source != .yabai || snapshot?.degraded == true {
            await refreshLiveState()
            snapshot = latestLiveStateSnapshot ?? liveStateSnapshot
        }

        let resolvedTarget: (space: SpaceState, display: DisplayState)?
        if let snapshot, let template {
            resolvedTarget = preferredTemplateTarget(for: template, in: snapshot)
        } else {
            resolvedTarget = nil
        }

        guard let snapshot,
              snapshot.source == .yabai,
              !snapshot.degraded,
              let spaceIndex = resolvedTarget?.space.index ?? activeSpaceIndex(in: snapshot) else {
            await MainActor.run {
                self.lastErrorMessage = "Current desktop data is unavailable right now."
                self.lastActionMessage = nil
            }
            return nil
        }

        let spaceDisplay = resolvedTarget?.display ?? snapshot.spaces.first(where: { $0.index == spaceIndex }).flatMap { space in
            snapshot.displays.first(where: { $0.id == space.displayId })
        }

        let windows = snapshot.windows.filter {
            $0.space == spaceIndex &&
            $0.isVisible &&
            !$0.isMinimized &&
            !$0.isHidden &&
            !isBackdropSurfaceWindow(
                $0,
                normalizedTitle: $0.title.trimmingCharacters(in: .whitespacesAndNewlines),
                normalizedRole: $0.role.trimmingCharacters(in: .whitespacesAndNewlines),
                normalizedSubrole: $0.subrole.trimmingCharacters(in: .whitespacesAndNewlines),
                in: snapshot
            )
        }
        .sorted { lhs, rhs in
            if abs(lhs.frameY - rhs.frameY) > 8 { return lhs.frameY < rhs.frameY }
            if abs(lhs.frameX - rhs.frameX) > 8 { return lhs.frameX < rhs.frameX }
            if lhs.focused != rhs.focused { return lhs.focused && !rhs.focused }
            return lhs.id < rhs.id
        }
        return (spaceIndex, spaceDisplay, windows)
    }

    private func bulkLayoutNeverAutoTileWindows(from windows: [WindowState]) -> [WindowState] {
        windows.filter { isNeverAutoTileEnabled(for: $0.app) }
    }

    private func bulkLayoutTilingEligibleWindows(from windows: [WindowState]) -> [WindowState] {
        windows.filter { !isNeverAutoTileEnabled(for: $0.app) }
    }

    private func runCurrentDesktopLayoutCommands(_ commands: [[String]]) async -> Bool {
        for arguments in commands {
            let result = await doctorService.runSupportCommand(
                yabaiCommand(arguments, timeout: 1.5)
            )
            await MainActor.run {
                appendCommandLog(from: result)
            }
            if !result.isSuccess {
                await MainActor.run {
                    self.lastErrorMessage = "Tile layout command failed."
                    self.lastActionMessage = nil
                }
                return false
            }
        }
        return true
    }

    private func setFloatingStateForWindows(_ windows: [WindowState], shouldFloat: Bool) async -> (updated: Int, failed: Int) {
        var updated = 0
        var failed = 0

        for window in windows {
            guard !Task.isCancelled else { break }
            let toggled = await setWindowFloatingSilently(window: window, shouldFloat: shouldFloat)
            if toggled {
                updated += 1
            } else {
                failed += 1
            }
        }

        return (updated, failed)
    }

    private func orderedTemplateCandidateWindows(from windows: [WindowState]) -> [WindowState] {
        guard let focusedIndex = windows.firstIndex(where: \.focused) else {
            return windows
        }
        var ordered = windows
        let focused = ordered.remove(at: focusedIndex)
        ordered.insert(focused, at: 0)
        return ordered
    }

    private func assignTemplateWindows(
        for template: WindowLayoutTemplate,
        from eligibleWindows: [WindowState]
    ) -> (assignments: [(slot: WindowLayoutSlot, window: WindowState)], emptyConstrainedSlotCount: Int, extraWindowCount: Int) {
        let orderedSlots = WindowLayoutTemplate.sortedSlots(template.slots)
        let constrainedSlots = orderedSlots.filter { !$0.allowedApps.isEmpty }
        let unconstrainedSlots = orderedSlots.filter(\.allowedApps.isEmpty)
        let stableWindows = eligibleWindows
        var usedWindowIDs = Set<Int>()
        var assignments: [(slot: WindowLayoutSlot, window: WindowState)] = []
        var emptyConstrainedSlotCount = 0

        for slot in constrainedSlots {
            let allowedKeys = Set(slot.allowedApps.map(normalizedAppRuleKey).filter { !$0.isEmpty })
            guard !allowedKeys.isEmpty else { continue }
            guard let match = stableWindows.first(where: { window in
                !usedWindowIDs.contains(window.id) && allowedKeys.contains(normalizedAppRuleKey(window.app))
            }) else {
                emptyConstrainedSlotCount += 1
                continue
            }
            usedWindowIDs.insert(match.id)
            assignments.append((slot: slot, window: match))
        }

        let remainingWindows = orderedTemplateCandidateWindows(
            from: stableWindows.filter { !usedWindowIDs.contains($0.id) }
        )
        var remainingIterator = remainingWindows.makeIterator()
        for slot in unconstrainedSlots {
            guard let match = remainingIterator.next() else { break }
            usedWindowIDs.insert(match.id)
            assignments.append((slot: slot, window: match))
        }

        let orderedAssignments = assignments.sorted { lhs, rhs in
            let ordered = WindowLayoutTemplate.sortedSlots([lhs.slot, rhs.slot])
            return ordered.first?.id == lhs.slot.id
        }
        return (
            assignments: orderedAssignments,
            emptyConstrainedSlotCount: emptyConstrainedSlotCount,
            extraWindowCount: max(0, stableWindows.count - orderedAssignments.count)
        )
    }

    private func applyTemplateFrames(
        assignments: [(slot: WindowLayoutSlot, window: WindowState)],
        template: WindowLayoutTemplate,
        display: DisplayState
    ) async -> (updated: Int, failed: Int) {
        guard !assignments.isEmpty else { return (0, 0) }

        var updated = 0
        var failed = 0

        for assignment in assignments {
            let window = assignment.window
            let slot = assignment.slot
            let normalizedFrame = fittedTemplateRect(for: slot, template: template, display: display)
            let absoluteFrame = CGRect(
                x: display.frameX + (normalizedFrame.minX * display.frameW),
                y: display.frameY + (normalizedFrame.minY * display.frameH),
                width: max(80, normalizedFrame.width * display.frameW),
                height: max(60, normalizedFrame.height * display.frameH)
            ).integral

            let resizeResult = await doctorService.runSupportCommand(
                yabaiCommand(
                    ["-m", "window", String(window.id), "--resize", "abs:\(Int(absoluteFrame.width)):\(Int(absoluteFrame.height))"],
                    timeout: 1.5
                )
            )
            await MainActor.run {
                appendCommandLog(from: resizeResult)
            }

            let moveResult = await doctorService.runSupportCommand(
                yabaiCommand(
                    ["-m", "window", String(window.id), "--move", "abs:\(Int(absoluteFrame.minX)):\(Int(absoluteFrame.minY))"],
                    timeout: 1.5
                )
            )
            await MainActor.run {
                appendCommandLog(from: moveResult)
            }

            if resizeResult.isSuccess && moveResult.isSuccess {
                updated += 1
            } else {
                failed += 1
            }
        }

        return (updated, failed)
    }

    private func fittedTemplateRect(
        for slot: WindowLayoutSlot,
        template: WindowLayoutTemplate,
        display: DisplayState
    ) -> CGRect {
        let sourceAspectRatio = max(template.displayShapeKey.aspectRatio, 0.1)
        let targetAspectRatio = max(display.frameW, 1) / max(display.frameH, 1)

        var scaleX = 1.0
        var scaleY = 1.0
        var offsetX = 0.0
        var offsetY = 0.0

        if targetAspectRatio > sourceAspectRatio {
            scaleX = sourceAspectRatio / targetAspectRatio
            offsetX = (1 - scaleX) / 2
        } else if targetAspectRatio < sourceAspectRatio {
            scaleY = targetAspectRatio / sourceAspectRatio
            offsetY = (1 - scaleY) / 2
        }

        let rect = slot.normalizedRect
        let fittedRect = CGRect(
            x: offsetX + (rect.minX * scaleX),
            y: offsetY + (rect.minY * scaleY),
            width: rect.width * scaleX,
            height: rect.height * scaleY
        )

        let clampedX = min(max(0, fittedRect.minX), 1)
        let clampedY = min(max(0, fittedRect.minY), 1)
        let maxWidth = max(0, 1 - clampedX)
        let maxHeight = max(0, 1 - clampedY)

        return CGRect(
            x: clampedX,
            y: clampedY,
            width: min(max(0, fittedRect.width), maxWidth),
            height: min(max(0, fittedRect.height), maxHeight)
        )
    }

    private func applyTemplateStacking(
        assignments: [(slot: WindowLayoutSlot, window: WindowState)],
        spaceIndex: Int
    ) async -> (updated: Int, failed: Int) {
        guard assignments.count > 1 else { return (0, 0) }

        let orderedAssignments = assignments.sorted { lhs, rhs in
            if lhs.slot.zIndex != rhs.slot.zIndex {
                return lhs.slot.zIndex < rhs.slot.zIndex
            }
            let geometric = WindowLayoutTemplate.sortedSlots([lhs.slot, rhs.slot])
            return geometric.first?.id == lhs.slot.id
        }

        var updated = 0
        var failed = 0

        for assignment in orderedAssignments {
            let raised = await raiseWindowOnly(
                windowID: assignment.window.id,
                targetSpace: spaceIndex,
                bypassCooldown: true,
                allowFocusFallback: false
            )
            if raised {
                updated += 1
            } else {
                failed += 1
            }
            try? await Task.sleep(for: .milliseconds(35))
        }

        return (updated, failed)
    }

    private func stackWorkSetWindows<S: Sequence>(
        _ windows: S,
        primaryWindowID: Int?,
        requiresBackdropClearance: Bool
    ) async -> (updated: Int, failed: Int, primaryFocused: Bool) where S.Element == WindowState {
        let orderedWindows = Array(windows)
        var updated = 0
        var failed = 0

        for window in orderedWindows {
            guard !Task.isCancelled else { break }
            let raised: Bool
            if requiresBackdropClearance {
                raised = window.isRuntimeManageable
                    ? await focusWorkSetStackWindow(window)
                    : raiseWindowUsingAccessibilityOnly(
                        windowID: window.id,
                        bypassCooldown: true
                    )
            } else {
                raised = raiseWindowUsingAccessibilityOnly(
                    windowID: window.id,
                    bypassCooldown: true
                )
            }
            if raised {
                updated += 1
            } else {
                failed += 1
            }
            try? await Task.sleep(for: .milliseconds(2))
        }

        let primaryFocused: Bool
        if let primaryWindowID,
           let primaryWindow = orderedWindows.first(where: { $0.id == primaryWindowID }) {
            primaryFocused = await focusWindowWithRestore(windowID: primaryWindowID, knownWindow: primaryWindow)
        } else {
            primaryFocused = true
        }

        return (updated, failed, primaryFocused)
    }

    private func focusWorkSetStackWindow(_ window: WindowState) async -> Bool {
        let focus = await doctorService.runSupportCommand(
            yabaiCommand(["-m", "window", "--focus", String(window.id)], timeout: 1.0)
        )
        await MainActor.run {
            appendCommandLog(from: focus)
        }
        if focus.isSuccess {
            return true
        }
        return raiseWindowUsingAccessibilityOnly(
            windowID: window.id,
            bypassCooldown: true
        )
    }

    private func applyGridFramesWithAccessibilityFallback(
        to windows: [WindowState],
        display: DisplayState?
    ) async -> (updated: Int, failed: Int) {
        guard !windows.isEmpty else { return (0, 0) }

        let grid = recentWindowGridDimensions(windowCount: windows.count, display: display)
        let placements = RecentWindowGridPlanner.placements(
            windowCount: windows.count,
            rows: grid.rows,
            cols: grid.cols
        )
        var updated = 0
        var failed = 0

        let frameAttempts = windows.enumerated().compactMap { index, window -> Task<(WindowState, RecentWindowGridPlacement, CGRect?, Bool), Never>? in
            guard placements.indices.contains(index) else {
                failed += 1
                return nil
            }
            let placement = placements[index]
            let exactFrame = recentWindowGridFrame(
                placement: placement,
                rows: grid.rows,
                cols: grid.cols,
                display: display
            )
            return Task { @MainActor in
                let succeeded: Bool
                if let exactFrame {
                    succeeded = await self.setWindowFrameUsingAccessibility(window: window, frame: exactFrame)
                } else {
                    succeeded = false
                }
                return (window, placement, exactFrame, succeeded)
            }
        }

        for attempt in frameAttempts {
            let (window, placement, exactFrame, axSucceeded) = await attempt.value
            if axSucceeded {
                updated += 1
                continue
            }

            if window.isRuntimeManageable {
                let result = await doctorService.runSupportCommand(
                    yabaiCommand(
                        ["-m", "window", String(window.id), "--grid", "\(grid.rows):\(grid.cols):\(placement.col):\(placement.row):\(placement.colSpan):\(placement.rowSpan)"],
                        timeout: 1.5
                    )
                )
                await MainActor.run {
                    appendCommandLog(from: result)
                }
                guard result.isSuccess else {
                    failed += 1
                    continue
                }
                if let exactFrame,
                   !(await runtimeWindowFrameMatches(windowID: window.id, frame: exactFrame)) {
                    failed += 1
                } else {
                    updated += 1
                }
                continue
            }
            failed += 1
        }

        return (updated, failed)
    }

    private func recentWindowGridDimensions(windowCount count: Int, display: DisplayState?) -> (rows: Int, cols: Int) {
        let aspectRatio = recentWindowGridAspectRatio(display: display)
        return RecentWindowGridPlanner.dimensions(windowCount: count, displayAspectRatio: aspectRatio)
    }

    private func recentWindowGridAspectRatio(display: DisplayState?) -> Double {
        guard let display, display.frameH > 1 else { return 1.6 }
        return max(display.frameW / display.frameH, 0.5)
    }

    private func recentWindowGridFrame(
        placement: RecentWindowGridPlacement,
        rows: Int,
        cols: Int,
        display: DisplayState?
    ) -> CGRect? {
        guard let display else { return nil }
        let bounds = recentWindowGridUsableFrame(for: display)
        let gap = 5.0
        let colCount = Double(max(cols, 1))
        let rowCount = Double(max(rows, 1))
        let cellWidth = (bounds.width - ((colCount - 1) * gap)) / colCount
        let cellHeight = (bounds.height - ((rowCount - 1) * gap)) / rowCount
        let frame = CGRect(
            x: bounds.minX + (Double(placement.col) * (cellWidth + gap)),
            y: bounds.minY + (Double(placement.row) * (cellHeight + gap)),
            width: max(80, cellWidth * Double(max(placement.colSpan, 1))),
            height: max(60, cellHeight * Double(max(placement.rowSpan, 1)))
        )
        return roundedRecentWindowGridFrame(frame)
    }

    private func recentWindowGridUsableFrame(for display: DisplayState) -> CGRect {
        let displayFrame = CGRect(
            x: display.frameX,
            y: display.frameY,
            width: display.frameW,
            height: display.frameH
        )
        var usableFrame = displayFrame

        let screens = NSScreen.screens
        if let screen = bestRecentWindowTilerScreen(
            for: convertRecentWindowTilerDisplayFrameToAppKit(display, screens: screens),
            screens: screens
        ) {
            let visibleFrame = convertAppKitRectToRecentWindowTilerFrame(screen.visibleFrame, screens: screens)
            let visibleIntersection = displayFrame.intersection(visibleFrame)
            if !visibleIntersection.isNull, !visibleIntersection.isEmpty {
                usableFrame = visibleIntersection
            }
        }

        // AX window placement is clamped by macOS near the top of every display. If
        // we request the raw display top, macOS moves the top row down but preserves
        // the requested height, which makes it overlap the row below.
        let minimumTopInset = 30.0
        let currentTopInset = usableFrame.minY - displayFrame.minY
        if currentTopInset < minimumTopInset {
            let insetDelta = min(minimumTopInset - currentTopInset, max(0, usableFrame.height - 80))
            usableFrame.origin.y += insetDelta
            usableFrame.size.height -= insetDelta
        }

        return usableFrame
    }

    private func bestRecentWindowTilerScreen(for appKitFrame: CGRect, screens: [NSScreen]) -> NSScreen? {
        screens.max { lhs, rhs in
            let lhsScore = recentWindowTilerIntersectionArea(lhs.frame, appKitFrame) + (lhs.frame.equalTo(appKitFrame) ? 1_000_000 : 0)
            let rhsScore = recentWindowTilerIntersectionArea(rhs.frame, appKitFrame) + (rhs.frame.equalTo(appKitFrame) ? 1_000_000 : 0)
            return lhsScore < rhsScore
        }
    }

    private func recentWindowTilerIntersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull, !intersection.isEmpty else { return 0 }
        return intersection.width * intersection.height
    }

    private func convertAppKitRectToRecentWindowTilerFrame(_ rect: CGRect, screens: [NSScreen]) -> CGRect {
        guard !screens.isEmpty else { return rect }
        let referenceMaxY = recentWindowTilerAppKitReferenceMaxY(screens: screens, fallback: rect.maxY)
        return CGRect(
            x: rect.origin.x,
            y: referenceMaxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    private func recentWindowTilerAppKitReferenceMaxY(screens: [NSScreen], fallback: CGFloat) -> CGFloat {
        screens.first(where: { screen in
            abs(screen.frame.minX) < 0.5 && abs(screen.frame.minY) < 0.5
        })?.frame.maxY
            ?? NSScreen.main?.frame.maxY
            ?? screens.map(\.frame.maxY).min()
            ?? fallback
    }

    private func roundedRecentWindowGridFrame(_ frame: CGRect) -> CGRect {
        let x = frame.minX.rounded()
        let y = frame.minY.rounded()
        let maxX = frame.maxX.rounded()
        let maxY = frame.maxY.rounded()
        return CGRect(
            x: x,
            y: y,
            width: max(80, maxX - x),
            height: max(60, maxY - y)
        )
    }

    private func applyGridFrames(
        to windows: [WindowState],
        display: DisplayState?
    ) async -> (updated: Int, failed: Int) {
        guard !windows.isEmpty else { return (0, 0) }

        let grid = recentWindowGridDimensions(windowCount: windows.count, display: display)
        let placements = RecentWindowGridPlanner.placements(
            windowCount: windows.count,
            rows: grid.rows,
            cols: grid.cols
        )

        var updated = 0
        var failed = 0

        for (index, window) in windows.enumerated() {
            guard placements.indices.contains(index) else {
                failed += 1
                continue
            }
            let placement = placements[index]
            let exactFrame = recentWindowGridFrame(
                placement: placement,
                rows: grid.rows,
                cols: grid.cols,
                display: display
            )

            if let exactFrame,
               await setWindowFrameUsingAccessibility(window: window, frame: exactFrame) {
                updated += 1
                continue
            }

            let result = await doctorService.runSupportCommand(
                yabaiCommand(
                    ["-m", "window", String(window.id), "--grid", "\(grid.rows):\(grid.cols):\(placement.col):\(placement.row):\(placement.colSpan):\(placement.rowSpan)"],
                    timeout: 1.5
                )
            )
            await MainActor.run {
                appendCommandLog(from: result)
            }

            guard result.isSuccess else {
                failed += 1
                continue
            }
            if let exactFrame,
               !(await runtimeWindowFrameMatches(windowID: window.id, frame: exactFrame)) {
                failed += 1
            } else {
                updated += 1
            }
        }

        return (updated, failed)
    }

    private func rebuildBalancedTileLayout(
        spaceIndex: Int,
        windows: [WindowState],
        preserveOrder: Bool = false
    ) async -> (updated: Int, failed: Int) {
        var packable = windows.filter { $0.isRuntimeManageable }
        if !preserveOrder {
            packable.sort { lhs, rhs in
                if abs(lhs.frameY - rhs.frameY) > 8 { return lhs.frameY < rhs.frameY }
                if abs(lhs.frameX - rhs.frameX) > 8 { return lhs.frameX < rhs.frameX }
                return lhs.id < rhs.id
            }
        }

        guard !packable.isEmpty else { return (0, 0) }

        var failedWindowIDs: Set<Int> = []
        let packableIDs = Set(packable.map(\.id))

        for window in packable {
            guard !Task.isCancelled else {
                return (0, failedWindowIDs.count)
            }
            let ensured = await ensureWindowFloatingState(window: window, shouldFloat: true)
            if !ensured {
                failedWindowIDs.insert(window.id)
            }
        }

        let layoutResult = await doctorService.runSupportCommand(
            yabaiCommand(["-m", "space", String(spaceIndex), "--layout", "bsp"], timeout: 1.5)
        )
        await MainActor.run {
            appendCommandLog(from: layoutResult)
        }
        guard layoutResult.isSuccess else { return (0, packable.count) }

        try? await Task.sleep(for: .milliseconds(25))

        let rootWindow = packable[0]
        if !(await ensureWindowFloatingState(window: rootWindow, shouldFloat: false)) {
            failedWindowIDs.insert(rootWindow.id)
        }

        try? await Task.sleep(for: .milliseconds(25))

        for window in packable.dropFirst() {
            guard !Task.isCancelled else {
                return (0, failedWindowIDs.count)
            }
            if let target = await largestManagedRetileTarget(spaceIndex: spaceIndex, allowedWindowIDs: packableIDs) {
                _ = await focusRetileWindow(target.id)
                await ensureSplitType(windowID: target.id, desired: target.frameW >= target.frameH ? "vertical" : "horizontal")
            }

            if !(await ensureWindowFloatingState(window: window, shouldFloat: false)) {
                failedWindowIDs.insert(window.id)
            }

            try? await Task.sleep(for: .milliseconds(18))
            _ = await runBestEffortYabaiCommand(["-m", "space", "--balance"], timeout: 1.0, log: false)
            try? await Task.sleep(for: .milliseconds(12))
        }

        try? await Task.sleep(for: .milliseconds(25))
        _ = await runBestEffortYabaiCommand(["-m", "space", "--balance"], timeout: 1.0, log: false)

        let finalWindows = await queryRuntimeWindowsOnSpace(spaceIndex: spaceIndex) ?? []
        let stillFloatingCount = finalWindows.filter {
            packableIDs.contains($0.id) &&
            $0.isVisible &&
            !$0.isMinimized &&
            !$0.isHidden &&
            $0.isFloating
        }.count

        return (
            updated: max(0, packable.count - stillFloatingCount),
            failed: failedWindowIDs.count + stillFloatingCount
        )
    }

    private func floatNonSelectedRuntimeWindowsOnSpace(
        spaceIndex: Int,
        selectedWindowIDs: Set<Int>
    ) async -> (updated: Int, failed: Int) {
        guard let runtimeWindows = await queryRuntimeWindowsOnSpace(spaceIndex: spaceIndex) else {
            return (0, 0)
        }

        let targets = runtimeWindows.filter {
            !selectedWindowIDs.contains($0.id) &&
                !$0.isNativeFullscreen &&
                !$0.isFloating
        }

        guard !targets.isEmpty else { return (0, 0) }

        var updated = 0
        var failed = 0
        for window in targets {
            let toggled = await runBestEffortYabaiCommand(
                ["-m", "window", String(window.id), "--toggle", "float"],
                timeout: 1.0,
                log: false
            )
            if toggled {
                updated += 1
            } else {
                failed += 1
            }
        }
        return (updated, failed)
    }

    private func setWindowFloatingSilently(window: WindowState, shouldFloat: Bool) async -> Bool {
        if let current = await queryRuntimeWindow(windowID: window.id)?.isFloating, current == shouldFloat {
            return true
        }

        return await toggleWindowFloatingSilently(window: window, shouldFloat: shouldFloat)
    }

    private func toggleWindowFloatingSilently(window: WindowState, shouldFloat: Bool) async -> Bool {
        let toggle = await doctorService.runSupportCommand(
            yabaiCommand(["-m", "window", String(window.id), "--toggle", "float"], timeout: 1.5)
        )
        await MainActor.run {
            appendCommandLog(from: toggle)
        }

        if toggle.isSuccess {
            return true
        }

        if window.supportsFocusedFloatToggleFallback {
            return await setWindowFloatingUsingFocusedFallback(window: window)
        }

        return false
    }

    private func ensureWindowFloatingState(window: WindowState, shouldFloat: Bool) async -> Bool {
        if let current = await queryRuntimeWindow(windowID: window.id)?.isFloating, current == shouldFloat {
            return true
        }

        for attempt in 0..<3 {
            _ = await toggleWindowFloatingSilently(window: window, shouldFloat: shouldFloat)
            try? await Task.sleep(for: .milliseconds(20))
            if let current = await queryRuntimeWindow(windowID: window.id)?.isFloating, current == shouldFloat {
                return true
            }
            if attempt < 2 {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }

        return await queryRuntimeWindow(windowID: window.id)?.isFloating == shouldFloat
    }

    private func ensureSplitType(windowID: Int, desired: String) async {
        guard let current = await queryRuntimeWindow(windowID: windowID)?.splitType,
              !current.isEmpty,
              current != desired else {
            return
        }

        _ = await runBestEffortYabaiCommand(
            ["-m", "window", String(windowID), "--toggle", "split"],
            timeout: 1.0,
            log: false
        )
        try? await Task.sleep(for: .milliseconds(15))
    }

    private func focusRetileWindow(_ windowID: Int) async -> Bool {
        let result = await doctorService.runSupportCommand(
            yabaiCommand(["-m", "window", "--focus", String(windowID)], timeout: 1.2)
        )
        await MainActor.run {
            appendCommandLog(from: result)
        }
        return result.isSuccess
    }

    private func largestManagedRetileTarget(spaceIndex: Int, allowedWindowIDs: Set<Int>) async -> RuntimeLayoutWindow? {
        guard let windows = await queryRuntimeWindowsOnSpace(spaceIndex: spaceIndex) else { return nil }
        return windows
            .filter {
                allowedWindowIDs.contains($0.id) &&
                $0.isVisible &&
                !$0.isMinimized &&
                !$0.isHidden &&
                !$0.isFloating &&
                !$0.isNativeFullscreen
            }
            .sorted { lhs, rhs in
                let lhsArea = lhs.frameW * lhs.frameH
                let rhsArea = rhs.frameW * rhs.frameH
                if abs(lhsArea - rhsArea) > 1 { return lhsArea > rhsArea }
                if abs(lhs.frameY - rhs.frameY) > 8 { return lhs.frameY < rhs.frameY }
                if abs(lhs.frameX - rhs.frameX) > 8 { return lhs.frameX < rhs.frameX }
                return lhs.id < rhs.id
            }
            .first
    }

    private func queryRuntimeWindowsOnSpace(spaceIndex: Int) async -> [RuntimeLayoutWindow]? {
        let result = await doctorService.runSupportCommand(
            yabaiCommand(["-m", "query", "--windows", "--space", String(spaceIndex)], timeout: 1.2)
        )
        guard result.isSuccess, let data = result.stdout.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([RuntimeLayoutWindow].self, from: data)
    }

    private func queryRuntimeWindow(windowID: Int) async -> RuntimeLayoutWindow? {
        let result = await doctorService.runSupportCommand(
            yabaiCommand(["-m", "query", "--windows", "--window", String(windowID)], timeout: 1.0)
        )
        guard result.isSuccess, let data = result.stdout.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(RuntimeLayoutWindow.self, from: data)
    }

    private func runtimeWindowFrameMatches(
        windowID: Int,
        frame: CGRect,
        tolerance: CGFloat = 8
    ) async -> Bool {
        try? await Task.sleep(for: .milliseconds(25))
        guard let window = await queryRuntimeWindow(windowID: windowID) else { return false }
        let actualFrame = CGRect(
            x: window.frameX,
            y: window.frameY,
            width: window.frameW,
            height: window.frameH
        )
        return recentWindowFrameMatches(actualFrame, frame, tolerance: tolerance)
    }

    @discardableResult
    private func runBestEffortYabaiCommand(
        _ arguments: [String],
        timeout: TimeInterval,
        log: Bool
    ) async -> Bool {
        let result = await doctorService.runSupportCommand(
            yabaiCommand(arguments, timeout: timeout)
        )
        if log {
            await MainActor.run {
                appendCommandLog(from: result)
            }
        }
        return result.isSuccess
    }

    private func finishVisibleWindowsLayoutOperation(
        _ operation: VisibleWindowsLayoutOperation,
        totalVisibleCount: Int,
        updatedCount: Int,
        ruleExceptionCount: Int,
        limitedCount: Int,
        failedCount: Int
    ) async {
        let actionMessage: String
        switch operation {
        case .floatAll:
            actionMessage = updatedCount == 0
                ? "All visible windows are already floating."
                : "Set \(updatedCount) visible window(s) to floating."
        case .tileAll:
            actionMessage = updatedCount == 0
                ? "No eligible windows were tiled on this desktop."
                : "Tiled eligible windows on this desktop."
        case .gridFloating:
            actionMessage = "Packed \(totalVisibleCount - limitedCount) controllable window(s) into a floating grid."
        case .rebuildTileLayout:
            actionMessage = updatedCount == 0
                ? "No eligible windows were retiled on this desktop."
                : "Retiled eligible windows into a balanced tiled layout."
        }

        var issues: [String] = []
        if ruleExceptionCount > 0 {
            issues.append("Skipped \(ruleExceptionCount) Never Auto-Tile window(s).")
        }
        if limitedCount > 0 {
            issues.append("Skipped \(limitedCount) limited window(s).")
        }
        if failedCount > 0 {
            issues.append("\(failedCount) window(s) could not be updated.")
        }

        await MainActor.run {
            self.lastActionMessage = actionMessage
            self.lastErrorMessage = issues.isEmpty ? nil : issues.joined(separator: " ")
        }
    }

    func openWindowBehaviorSettings() {
        requestOpenTilePilotTab(.windowBehavior)
    }

    func openTilePilotDashboard() {
        acknowledgeInitialStatusIfNeeded()
        requestOpenTilePilotTab(.now)
        NSApp.activate(ignoringOtherApps: true)
        if let mainWindow = NSApp.windows.first(where: { window in
            window.styleMask.contains(.titled) && window.title == "TilePilot"
        }) {
            mainWindow.makeKeyAndOrderFront(nil)
        }
    }

    func openShortcutsDashboard() {
        acknowledgeInitialStatusIfNeeded()
        requestOpenTilePilotTab(.shortcuts)
        NSApp.activate(ignoringOtherApps: true)
        if let mainWindow = NSApp.windows.first(where: { window in
            window.styleMask.contains(.titled) && window.title == "TilePilot"
        }) {
            mainWindow.makeKeyAndOrderFront(nil)
        }
    }

    func openShortcutSource(_ entry: ShortcutEntry) {
        selectShortcut(entry)
        requestOpenFile(path: entry.sourceFile, line: entry.sourceLine)
    }

    var canRunYabaiRuntimeCommands: Bool {
        guard let snapshot = doctorSnapshot else { return false }
        let map = Dictionary(uniqueKeysWithValues: snapshot.capabilities.map { ($0.key, $0.status) })
        return map["yabai-binary"] == .available && map["yabai-daemon"] == .available
    }

    var canRunScriptingAdditionDesktopActions: Bool {
        guard let snapshot = doctorSnapshot else { return false }
        let map = Dictionary(uniqueKeysWithValues: snapshot.capabilities.map { ($0.key, $0.status) })
        return map["scripting-addition"] == .available
    }

    func isScriptingAdditionDesktopShortcut(_ entry: ShortcutEntry) -> Bool {
        entry.command.lowercased().contains("yabai -m window --space")
    }

    var yabaiRuntimeControlDisabledReason: String? {
        guard let snapshot = doctorSnapshot else { return "Open System and run Recheck first." }
        let map = Dictionary(uniqueKeysWithValues: snapshot.capabilities.map { ($0.key, $0) })
        if map["yabai-binary"]?.status != .available {
            return map["yabai-binary"]?.message ?? "yabai is not installed."
        }
        if map["yabai-daemon"]?.status != .available {
            return map["yabai-daemon"]?.message ?? "yabai is not running."
        }
        return nil
    }

    private struct MissionControlDesktopBinding {
        let keyCode: CGKeyCode
        let flags: CGEventFlags
    }

    private func isScriptingAdditionDesktopFocusFailure(_ result: CommandResult) -> Bool {
        let text = "\(result.stderr)\n\(result.stdout)".lowercased()
        return (text.contains("cannot focus space") && text.contains("scripting-addition"))
            || (text.contains("cannot focus space") && text.contains("scripting addition"))
    }

    private func focusDesktopInternal(
        index: Int,
        updateMessages: Bool,
        megamapCapturePolicy: MegamapDesktopSwitchCapturePolicy
    ) async -> Bool {
        let currentSpace = await queryCurrentFocusedSpaceIndex()
        if megamapCapturePolicy == .incremental,
           let currentSpace,
           currentSpace != index {
            await captureMegamapDesktopIfNeeded(spaceIndex: currentSpace, reason: .beforeTilePilotDesktopSwitch)
        }

        let result = await self.doctorService.runSupportCommand(
            yabaiCommand(["-m", "space", "--focus", String(index)], timeout: 1.5)
        )
        await MainActor.run {
            self.appendCommandLog(from: result)
        }
        if result.isSuccess {
            if updateMessages {
                await MainActor.run {
                    self.lastActionMessage = "Switched to Desktop \(index)."
                    self.lastErrorMessage = nil
                }
            }
            return true
        }

        if await self.focusAnyWindowOnDesktop(index: index) {
            if updateMessages {
                await MainActor.run {
                    self.lastActionMessage = "Switched to Desktop \(index)."
                    self.lastErrorMessage = nil
                }
            }
            return true
        }

        if self.isScriptingAdditionDesktopFocusFailure(result),
           self.triggerMissionControlDesktopShortcut(index: index) {
            if updateMessages {
                await MainActor.run {
                    self.lastActionMessage = "Switched to Desktop \(index) using macOS shortcut fallback."
                    self.lastErrorMessage = nil
                }
            }
            return true
        }

        if updateMessages {
            await MainActor.run {
                self.lastErrorMessage = "Could not switch to Desktop \(index)."
                self.lastActionMessage = nil
            }
        }
        return false
    }

    func focusDesktopForMegamapCapture(index: Int) async -> Bool {
        let issued = await focusDesktopInternal(index: index, updateMessages: false, megamapCapturePolicy: .none)
        guard issued else { return false }

        for _ in 0..<8 {
            if let focusedSpace = await queryCurrentFocusedSpaceIndex(), focusedSpace == index {
                return true
            }
            try? await Task.sleep(for: .milliseconds(50))
        }

        return false
    }

    private func focusAnyWindowOnDesktop(index: Int) async -> Bool {
        let query = await doctorService.runSupportCommand(
            yabaiCommand(["-m", "query", "--windows", "--space", String(index)], timeout: 1.2)
        )
        await MainActor.run {
            appendCommandLog(from: query)
        }
        guard query.isSuccess,
              let data = query.stdout.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              !rows.isEmpty else {
            return false
        }

        let sorted = rows.sorted { lhs, rhs in
            let lhsAX = boolFromAny(lhs["has-ax-reference"]) == true
            let rhsAX = boolFromAny(rhs["has-ax-reference"]) == true
            if lhsAX != rhsAX { return lhsAX && !rhsAX }
            let lhsMove = boolFromAny(lhs["can-move"]) == true
            let rhsMove = boolFromAny(rhs["can-move"]) == true
            if lhsMove != rhsMove { return lhsMove && !rhsMove }
            let lhsID = intFromAny(lhs["id"]) ?? Int.max
            let rhsID = intFromAny(rhs["id"]) ?? Int.max
            return lhsID < rhsID
        }

        guard let targetID = sorted.compactMap({ intFromAny($0["id"]) }).first else {
            return false
        }

        let focus = await doctorService.runSupportCommand(
            yabaiCommand(["-m", "window", "--focus", String(targetID)], timeout: 1.2)
        )
        await MainActor.run {
            appendCommandLog(from: focus)
        }
        return focus.isSuccess
    }

    private func triggerMissionControlDesktopShortcut(index: Int) -> Bool {
        let binding = missionControlDesktopBinding(for: index)
            ?? missionControlDefaultBinding(for: index)
        guard let binding else { return false }
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: binding.keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: binding.keyCode, keyDown: false) else {
            return false
        }
        keyDown.flags = binding.flags
        keyUp.flags = binding.flags
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    private func missionControlDesktopBinding(for desktopIndex: Int) -> MissionControlDesktopBinding? {
        guard (1...16).contains(desktopIndex) else { return nil }
        let actionID = String(117 + desktopIndex)

        guard let domain = UserDefaults.standard.persistentDomain(forName: "com.apple.symbolichotkeys"),
              let allHotKeys = domain["AppleSymbolicHotKeys"] as? [String: Any],
              let entry = allHotKeys[actionID] as? [String: Any] else {
            return nil
        }

        guard boolFromAny(entry["enabled"]) == true else { return nil }
        guard let value = entry["value"] as? [String: Any],
              let parameters = value["parameters"] as? [Any],
              parameters.count >= 3,
              let keyCodeInt = intFromAny(parameters[1]),
              let modifierInt = intFromAny(parameters[2]),
              keyCodeInt >= 0 else {
            return nil
        }

        return MissionControlDesktopBinding(
            keyCode: CGKeyCode(keyCodeInt),
            flags: CGEventFlags(rawValue: UInt64(modifierInt))
        )
    }

    private func missionControlDefaultBinding(for desktopIndex: Int) -> MissionControlDesktopBinding? {
        let keyCode: Int
        switch desktopIndex {
        case 1: keyCode = 18
        case 2: keyCode = 19
        case 3: keyCode = 20
        case 4: keyCode = 21
        case 5: keyCode = 23
        case 6: keyCode = 22
        case 7: keyCode = 26
        case 8: keyCode = 28
        case 9: keyCode = 25
        case 10: keyCode = 29
        default: return nil
        }
        return MissionControlDesktopBinding(
            keyCode: CGKeyCode(keyCode),
            flags: .maskControl
        )
    }

    private func boolFromAny(_ value: Any?) -> Bool? {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        return nil
    }

    private func intFromAny(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }

    func queryCurrentFocusedSpaceIndex() async -> Int? {
        let result = await doctorService.runSupportCommand(
            yabaiCommand(["-m", "query", "--spaces", "--space"], timeout: 1.0)
        )
        await MainActor.run {
            appendCommandLog(from: result)
        }
        guard result.isSuccess,
              let data = result.stdout.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let index = object["index"] as? Int { return index }
        if let number = object["index"] as? NSNumber { return number.intValue }
        return nil
    }

    private func runtimeControllableWindow(windowID: Int) -> WindowState? {
        guard canRunYabaiRuntimeCommands else {
            lastErrorMessage = yabaiRuntimeControlDisabledReason ?? "Window controls are unavailable right now."
            lastActionMessage = nil
            return nil
        }
        guard let window = liveStateSnapshot?.windows.first(where: { $0.id == windowID }) else {
            lastErrorMessage = "Window is no longer available."
            lastActionMessage = nil
            return nil
        }
        guard window.isRuntimeManageable else {
            lastErrorMessage = "\(window.app) does not expose move/control hooks for this window right now, so TilePilot cannot tile/float it."
            lastActionMessage = nil
            return nil
        }
        return window
    }

    private func focusableWindow(windowID: Int) -> WindowState? {
        guard canRunYabaiRuntimeCommands else {
            lastErrorMessage = yabaiRuntimeControlDisabledReason ?? "Window controls are unavailable right now."
            lastActionMessage = nil
            return nil
        }
        guard let window = (latestLiveStateSnapshot ?? liveStateSnapshot)?.windows.first(where: { $0.id == windowID }) else {
            lastErrorMessage = "Window is no longer available."
            lastActionMessage = nil
            return nil
        }
        return window
    }

    private func focusWindowWithRestore(windowID: Int, knownWindow: WindowState) async -> Bool {
        let focus = await doctorService.runSupportCommand(
            yabaiCommand(["-m", "window", "--focus", String(windowID)], timeout: 1.5)
        )
        await MainActor.run {
            appendCommandLog(from: focus)
        }
        if focus.isSuccess {
            return true
        }

        if await focusWindowUsingAppScriptFallback(knownWindow) {
            return true
        }

        if focusWindowUsingAccessibilityFallback(knownWindow) {
            return true
        }

        if await focusWindowUsingAppActivationFallback(knownWindow) {
            return true
        }

        let latestWindow = (latestLiveStateSnapshot ?? liveStateSnapshot)?.windows.first(where: { $0.id == windowID }) ?? knownWindow
        guard latestWindow.isMinimized else {
            await MainActor.run {
                self.lastErrorMessage = "Could not focus \(knownWindow.app)."
                self.lastActionMessage = nil
            }
            return false
        }

        let restore = await doctorService.runSupportCommand(
            yabaiCommand(["-m", "window", "--deminimize", String(windowID)], timeout: 1.5)
        )
        await MainActor.run {
            appendCommandLog(from: restore)
        }

        guard restore.isSuccess else {
            await MainActor.run {
                self.lastErrorMessage = "Could not restore minimized window for \(knownWindow.app)."
                self.lastActionMessage = nil
            }
            return false
        }

        let refocus = await doctorService.runSupportCommand(
            yabaiCommand(["-m", "window", "--focus", String(windowID)], timeout: 1.5)
        )
        await MainActor.run {
            appendCommandLog(from: refocus)
        }

        if refocus.isSuccess {
            return true
        }

        if await focusWindowUsingAppScriptFallback(latestWindow) {
            return true
        }

        if focusWindowUsingAccessibilityFallback(latestWindow) {
            return true
        }

        if await focusWindowUsingAppActivationFallback(latestWindow) {
            return true
        }

        await MainActor.run {
            self.lastErrorMessage = "Could not focus restored window for \(knownWindow.app)."
            self.lastActionMessage = nil
        }
        return false
    }

    private func closeRecentWindowTilerWindow(windowID: Int, knownWindow: WindowState?) async -> Bool {
        if let knownWindow, recentWindowTilerShouldPreferAccessibilityClose(knownWindow) {
            if closeWindowUsingAccessibilityFallback(knownWindow) {
                return true
            }
        }

        let close = await doctorService.runSupportCommand(
            yabaiCommand(["-m", "window", String(windowID), "--close"], timeout: 1.5)
        )
        await MainActor.run {
            appendCommandLog(from: close)
        }
        if close.isSuccess {
            return true
        }

        guard let knownWindow else {
            return false
        }

        return closeWindowUsingAccessibilityFallback(knownWindow)
    }

    private func recentWindowTilerShouldPreferAccessibilityClose(_ window: WindowState) -> Bool {
        !window.isRuntimeManageable || !window.isVisible || !window.hasWindowServerMatch
    }

    private func closeWindowUsingAccessibilityFallback(_ window: WindowState) -> Bool {
        let appPID = pid_t(window.pid)
        NSRunningApplication(processIdentifier: appPID)?.activate(options: [.activateIgnoringOtherApps])

        let appElement = AXUIElementCreateApplication(appPID)
        var windowsRef: CFTypeRef?
        let windowsResult = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
        guard windowsResult == .success,
              let windows = windowsRef as? [AXUIElement],
              let targetWindow = matchingAXWindow(for: window, in: windows) else {
            return false
        }

        if window.isMinimized || axBoolValue(targetWindow, kAXMinimizedAttribute as CFString) == true {
            _ = AXUIElementSetAttributeValue(targetWindow, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        _ = AXUIElementPerformAction(targetWindow, kAXRaiseAction as CFString)
        _ = AXUIElementSetAttributeValue(targetWindow, kAXMainAttribute as CFString, kCFBooleanTrue)
        _ = AXUIElementSetAttributeValue(targetWindow, kAXFocusedAttribute as CFString, kCFBooleanTrue)

        var closeButtonRef: CFTypeRef?
        let closeButtonResult = AXUIElementCopyAttributeValue(
            targetWindow,
            kAXCloseButtonAttribute as CFString,
            &closeButtonRef
        )
        guard closeButtonResult == .success,
              let closeButton = closeButtonRef as! AXUIElement? else {
            return false
        }

        return AXUIElementPerformAction(closeButton, kAXPressAction as CFString) == .success
    }

    private func focusWindowUsingAppScriptFallback(_ window: WindowState) async -> Bool {
        let scriptLines: [String]
        switch window.app {
        case "iTerm2":
            scriptLines = [
                "tell application \"iTerm2\" to activate",
                "tell application \"iTerm2\" to select (first window whose id is \(window.id))"
            ]
        case "Notes":
            scriptLines = [
                "tell application \"Notes\" to activate",
                "tell application \"Notes\" to set index of window id \(window.id) to 1"
            ]
        default:
            return false
        }

        var args: [String] = []
        for line in scriptLines {
            args.append("-e")
            args.append(line)
        }

        let result = await doctorService.runSupportCommand(
            ShellCommand("/usr/bin/osascript", args, timeout: 2.0)
        )
        await MainActor.run {
            appendCommandLog(from: result)
        }

        guard result.isSuccess else {
            return false
        }

        try? await Task.sleep(for: .milliseconds(120))
        let frontApp = NSWorkspace.shared.frontmostApplication?.localizedName
        return frontApp == window.app
    }

    private func focusWindowUsingAppActivationFallback(_ window: WindowState) async -> Bool {
        guard !window.isVisible || window.isHidden || !window.hasAXReference else {
            return false
        }

        let appPID = pid_t(window.pid)
        let runningApp = NSRunningApplication(processIdentifier: appPID)
        runningApp?.unhide()
        _ = runningApp?.activate(options: [.activateIgnoringOtherApps])

        try? await Task.sleep(for: .milliseconds(140))

        let frontmostPID = Int(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)
        if frontmostPID == Int(window.pid) {
            return true
        }

        let escapedAppName = window.app
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let result = await doctorService.runSupportCommand(
            ShellCommand("/usr/bin/osascript", ["-e", "tell application \"\(escapedAppName)\" to activate"], timeout: 2.0)
        )
        await MainActor.run {
            appendCommandLog(from: result)
        }

        guard result.isSuccess else {
            return false
        }

        try? await Task.sleep(for: .milliseconds(180))
        return Int(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0) == Int(window.pid)
    }

    private func focusWindowUsingAccessibilityFallback(_ window: WindowState) -> Bool {
        let appPID = pid_t(window.pid)
        NSRunningApplication(processIdentifier: appPID)?.activate(options: [.activateIgnoringOtherApps])

        let appElement = AXUIElementCreateApplication(appPID)
        var windowsRef: CFTypeRef?
        let windowsResult = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
        guard windowsResult == .success, let windows = windowsRef as? [AXUIElement], !windows.isEmpty else {
            return false
        }

        guard let targetWindow = matchingAXWindow(for: window, in: windows) else {
            return false
        }

        if window.isMinimized || axBoolValue(targetWindow, kAXMinimizedAttribute as CFString) == true {
            _ = AXUIElementSetAttributeValue(targetWindow, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }

        let raised = AXUIElementPerformAction(targetWindow, kAXRaiseAction as CFString) == .success
        let mainSet = AXUIElementSetAttributeValue(targetWindow, kAXMainAttribute as CFString, kCFBooleanTrue) == .success
        let focusedSet = AXUIElementSetAttributeValue(targetWindow, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success

        let frontmostPID = Int(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)
        return raised || mainSet || focusedSet || frontmostPID == Int(appPID)
    }

    private func recentWindowTilerAccessibilityInfo(for window: WindowState) -> RecentWindowTilerAccessibilityInfo? {
        let appPID = pid_t(window.pid)
        let appElement = AXUIElementCreateApplication(appPID)
        var windowsRef: CFTypeRef?
        let windowsResult = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
        guard windowsResult == .success,
              let windows = windowsRef as? [AXUIElement],
              let targetWindow = matchingAXWindow(for: window, in: windows) else {
            return nil
        }

        let role = axStringValue(targetWindow, kAXRoleAttribute as CFString) ?? ""
        let subrole = axStringValue(targetWindow, kAXSubroleAttribute as CFString) ?? ""
        guard role == "AXWindow", subrole == "AXStandardWindow" else {
            return nil
        }

        let canMove = axAttributeIsSettable(targetWindow, kAXPositionAttribute as CFString)
        let canResize = axAttributeIsSettable(targetWindow, kAXSizeAttribute as CFString)
        let identifier = axStringValue(targetWindow, "AXIdentifier" as CFString) ?? ""
        let isSupportedForPicker = window.app != "Finder" || identifier == "FinderWindow"
        let title = axStringValue(targetWindow, kAXTitleAttribute as CFString)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return RecentWindowTilerAccessibilityInfo(
            title: title,
            canMoveAndResize: canMove && canResize,
            isSupportedForPicker: isSupportedForPicker
        )
    }

    private func setWindowFrameUsingAccessibility(window: WindowState, frame: CGRect) async -> Bool {
        let appPID = pid_t(window.pid)
        let appElement = AXUIElementCreateApplication(appPID)
        var windowsRef: CFTypeRef?
        let windowsResult = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
        guard windowsResult == .success,
              let windows = windowsRef as? [AXUIElement],
              let targetWindow = matchingAXWindow(for: window, in: windows),
              axAttributeIsSettable(targetWindow, kAXPositionAttribute as CFString),
              axAttributeIsSettable(targetWindow, kAXSizeAttribute as CFString) else {
            return false
        }
        if window.app == "Finder",
           axStringValue(targetWindow, "AXIdentifier" as CFString) != "FinderWindow" {
            return false
        }

        var size = frame.size
        var origin = frame.origin
        guard let sizeValue = AXValueCreate(.cgSize, &size),
              let positionValue = AXValueCreate(.cgPoint, &origin) else {
            return false
        }

        let sizeSet: Bool
        let positionSet: Bool
        if window.app == "Finder" || !window.canResize {
            // Finder's move animation cancels a simultaneous size write. Its
            // yabai can-resize flag also changes between snapshots, so identify
            // Finder directly and always let the move settle before resizing.
            positionSet = AXUIElementSetAttributeValue(
                targetWindow,
                kAXPositionAttribute as CFString,
                positionValue
            ) == .success
            if positionSet {
                try? await Task.sleep(for: .milliseconds(300))
            }
            sizeSet = AXUIElementSetAttributeValue(
                targetWindow,
                kAXSizeAttribute as CFString,
                sizeValue
            ) == .success
        } else {
            sizeSet = AXUIElementSetAttributeValue(
                targetWindow,
                kAXSizeAttribute as CFString,
                sizeValue
            ) == .success
            positionSet = AXUIElementSetAttributeValue(
                targetWindow,
                kAXPositionAttribute as CFString,
                positionValue
            ) == .success
        }

        if sizeSet || positionSet {
            _ = AXUIElementPerformAction(targetWindow, kAXRaiseAction as CFString)
        }

        guard sizeSet && positionSet else { return false }

        // Some apps, notably Finder, acknowledge AX frame writes before the new
        // frame is observable. Poll briefly before falling back to yabai, which
        // may report those same windows as non-resizable.
        for attempt in 0..<12 {
            if let actualFrame = axFrameValue(targetWindow),
               recentWindowFrameMatches(actualFrame, frame) {
                return true
            }
            if attempt < 11 {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        return false
    }

    private func recentWindowFrameMatches(
        _ lhs: CGRect,
        _ rhs: CGRect,
        tolerance: CGFloat = 8
    ) -> Bool {
        abs(lhs.minX - rhs.minX) <= tolerance &&
            abs(lhs.minY - rhs.minY) <= tolerance &&
            abs(lhs.width - rhs.width) <= tolerance &&
            abs(lhs.height - rhs.height) <= tolerance
    }

    private func matchingAXWindow(for window: WindowState, in windows: [AXUIElement]) -> AXUIElement? {
        let wantedTitle = window.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !wantedTitle.isEmpty,
           let byTitle = windows.first(where: { axStringValue($0, kAXTitleAttribute as CFString) == wantedTitle }) {
            return byTitle
        }

        let wantedFrame = CGRect(x: window.frameX, y: window.frameY, width: window.frameW, height: window.frameH)
        if let byFrame = windows
            .compactMap({ element -> (AXUIElement, CGFloat)? in
                guard let frame = axFrameValue(element) else { return nil }
                let delta =
                    abs(frame.origin.x - wantedFrame.origin.x) +
                    abs(frame.origin.y - wantedFrame.origin.y) +
                    abs(frame.size.width - wantedFrame.size.width) +
                    abs(frame.size.height - wantedFrame.size.height)
                return (element, delta)
            })
            .min(by: { $0.1 < $1.1 })?
            .0 {
            return byFrame
        }

        if let focused = windows.first(where: { axBoolValue($0, kAXFocusedAttribute as CFString) == true }) {
            return focused
        }

        return windows.first
    }

    private func axStringValue(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success else { return nil }
        return value as? String
    }

    private func axBoolValue(_ element: AXUIElement, _ attribute: CFString) -> Bool? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success else { return nil }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        return nil
    }

    private func axAttributeIsSettable(_ element: AXUIElement, _ attribute: CFString) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, attribute, &settable) == .success && settable.boolValue
    }

    private func axFrameValue(_ element: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionValue = positionRef,
              let sizeValue = sizeRef
        else {
            return nil
        }

        var point = CGPoint.zero
        var size = CGSize.zero
        guard CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID(),
              AXValueGetValue(positionValue as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        else {
            return nil
        }

        return CGRect(origin: point, size: size)
    }
}
