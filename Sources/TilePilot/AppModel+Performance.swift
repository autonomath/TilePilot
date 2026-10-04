import Foundation

@MainActor
extension AppModel {
    var overlayRefreshPolicy: OverlayRefreshPolicy {
        performanceSettings.overlayRefreshPolicy
    }

    var performanceDegradationMode: PerformanceDegradationMode {
        performanceSettings.degradationMode(
            currentKeepOnTopEnforcementIntervalSeconds: currentKeepOnTopEnforcementIntervalSeconds(),
            hasActiveOverlayTargets: hasActiveOverlayTargets,
            hasVisibleWindowBadgePanels: hasVisibleWindowBadgePanels,
            hasActiveKeepOnTopWindows: hasActiveKeepOnTopWindows
        )
    }

    var performanceSettings: PerformanceSettings {
        PerformanceSettings(
            preset: performancePreset,
            foregroundPollingSeconds: performanceForegroundPollingSeconds,
            backgroundPollingSeconds: performanceBackgroundPollingSeconds,
            keepOnTopEnforcementSeconds: performanceKeepOnTopEnforcementSeconds,
            miniMapHoverTitlesEnabled: miniMapHoverTitlesEnabled,
            hideMinimizedHelperWindowsInMaps: hideMinimizedHelperWindowsInMaps,
            fastLiveRefreshEnabled: performanceFastLiveRefreshEnabled,
            keepOnTopEnforcementEnabled: keepOnTopEnforcementEnabled
        )
    }

    var effectivePerformancePreset: PerformancePreset {
        performanceSettings.inferredPreset
    }

    var performanceStatusLine: String {
        let preset = effectivePerformancePreset.title
        let overlaySummary = [
            showWindowBadgeOverlay ? "badges" : nil,
            showWindowOutlineOverlay ? "outlines" : nil,
            keepOnTopEnforcementEnabled ? "keep-on-top" : nil,
        ]
            .compactMap { $0 }
            .joined(separator: ", ")
        let overlaysText = overlaySummary.isEmpty ? "runtime helpers off" : overlaySummary
        return "\(preset) · \(runtimeActivityMode.title.lowercased()) · fg \(formattedSeconds(currentPollingIntervalSeconds())) · bg \(formattedSeconds(max(10.0, performanceBackgroundPollingSeconds))) · \(overlaysText)"
    }

    var performanceDiagnosticsRows: [(label: String, value: String)] {
        [
            ("App memory", ProcessMemoryDiagnostics.formattedPhysicalFootprint()),
            ("Performance mode", performanceDegradationMode.title),
            ("Runtime mode", runtimeDiagnostics.runtimeActivityMode),
            ("Dominant source (10s)", runtimeDiagnostics.dominantBurstSource),
            ("Current poll", formattedSeconds(runtimeDiagnostics.currentPollingIntervalSeconds)),
            ("Keep-on-top interval", runtimeDiagnostics.currentKeepOnTopIntervalSeconds > 0 ? formattedSeconds(runtimeDiagnostics.currentKeepOnTopIntervalSeconds) : "Suspended"),
            ("Live refreshes", "\(runtimeDiagnostics.liveStateRefreshCount)"),
            ("Published snapshots", "\(runtimeDiagnostics.liveStatePublishedCount)"),
            ("Unchanged polls", "\(runtimeDiagnostics.liveStateUnchangedPollCount)"),
            ("Overview cache rebuilds", "\(runtimeDiagnostics.overviewCacheRebuildCount)"),
            ("Shortcuts cache rebuilds", "\(runtimeDiagnostics.shortcutsCacheRebuildCount)"),
            ("Keep-on-top passes", "\(runtimeDiagnostics.keepOnTopEnforcementPassCount)"),
            ("Mini-map hover updates", "\(runtimeDiagnostics.miniMapHoverUpdateCount)"),
            ("Overlay updates", "\(runtimeDiagnostics.overlayPanelUpdateCount)"),
            ("Recent live refreshes (10s)", "\(runtimeDiagnostics.recentLiveStateRefreshCount)"),
            ("Recent publishes (10s)", "\(runtimeDiagnostics.recentLiveStatePublishedCount)"),
            ("Recent unchanged polls (10s)", "\(runtimeDiagnostics.recentLiveStateUnchangedPollCount)"),
            ("Recent overview rebuilds (10s)", "\(runtimeDiagnostics.recentOverviewCacheRebuildCount)"),
            ("Recent shortcuts rebuilds (10s)", "\(runtimeDiagnostics.recentShortcutsCacheRebuildCount)"),
            ("Recent keep-on-top passes (10s)", "\(runtimeDiagnostics.recentKeepOnTopEnforcementPassCount)"),
            ("Recent overlay updates (10s)", "\(runtimeDiagnostics.recentOverlayPanelUpdateCount)"),
            ("MegaMap refreshes", "\(runtimeDiagnostics.megamapRefreshCount)"),
            ("MegaMap first switch", runtimeDiagnostics.megamapFirstSwitchLatencyMilliseconds > 0 ? "\(Int(runtimeDiagnostics.megamapFirstSwitchLatencyMilliseconds)) ms" : "—"),
            ("MegaMap avg switch verify", runtimeDiagnostics.megamapAverageSwitchVerificationMilliseconds > 0 ? "\(Int(runtimeDiagnostics.megamapAverageSwitchVerificationMilliseconds)) ms" : "—"),
            ("MegaMap avg capture", runtimeDiagnostics.megamapAverageCaptureMilliseconds > 0 ? "\(Int(runtimeDiagnostics.megamapAverageCaptureMilliseconds)) ms" : "—"),
            ("MegaMap total sweep", runtimeDiagnostics.megamapTotalSweepMilliseconds > 0 ? "\(Int(runtimeDiagnostics.megamapTotalSweepMilliseconds)) ms" : "—"),
            ("MegaMap desktops captured", "\(runtimeDiagnostics.megamapCapturedDesktopCount)"),
            ("MegaMap desktops failed", "\(runtimeDiagnostics.megamapFailedDesktopCount)"),
        ]
    }

    func applyPerformancePreset(_ preset: PerformancePreset) {
        let defaults = PerformanceSettings.defaults(for: preset)
        performancePreset = preset
        performanceForegroundPollingSeconds = defaults.foregroundPollingSeconds
        performanceBackgroundPollingSeconds = defaults.backgroundPollingSeconds
        performanceKeepOnTopEnforcementSeconds = defaults.keepOnTopEnforcementSeconds
        miniMapHoverTitlesEnabled = defaults.miniMapHoverTitlesEnabled
        hideMinimizedHelperWindowsInMaps = defaults.hideMinimizedHelperWindowsInMaps
        performanceFastLiveRefreshEnabled = defaults.fastLiveRefreshEnabled
        keepOnTopEnforcementEnabled = defaults.keepOnTopEnforcementEnabled
        persistPerformanceSettings()
        invalidateOverviewCaches()
        ensureOverviewCachesIfNeeded()
        rebuildMegamapSections()
        if !showWindowBadgeOverlay && !showWindowOutlineOverlay {
            windowBadges = []
        } else {
            refreshWindowBadges()
        }
        lastActionMessage = "\(preset.title) performance preset applied."
        lastErrorMessage = nil
    }

    func resetPerformanceSettings() {
        applyPerformancePreset(.balanced)
    }

    func updatePerformanceForegroundPollingSeconds(_ value: Double) {
        performanceForegroundPollingSeconds = clampedInterval(value)
        markPerformanceSettingsCustomAndPersist()
    }

    func updatePerformanceBackgroundPollingSeconds(_ value: Double) {
        performanceBackgroundPollingSeconds = clampedInterval(value)
        markPerformanceSettingsCustomAndPersist()
    }

    func updatePerformanceKeepOnTopEnforcementSeconds(_ value: Double) {
        performanceKeepOnTopEnforcementSeconds = clampedInterval(value)
        markPerformanceSettingsCustomAndPersist()
    }

    func setMiniMapHoverTitlesEnabled(_ enabled: Bool) {
        miniMapHoverTitlesEnabled = enabled
        markPerformanceSettingsCustomAndPersist()
    }

    func setHideMinimizedHelperWindowsInMaps(_ enabled: Bool) {
        hideMinimizedHelperWindowsInMaps = enabled
        invalidateOverviewCaches()
        ensureOverviewCachesIfNeeded()
        rebuildMegamapSections()
        markPerformanceSettingsCustomAndPersist()
    }

    func setPerformanceFastLiveRefreshEnabled(_ enabled: Bool) {
        performanceFastLiveRefreshEnabled = enabled
        markPerformanceSettingsCustomAndPersist()
    }

    func setKeepOnTopEnforcementEnabled(_ enabled: Bool) {
        keepOnTopEnforcementEnabled = enabled
        markPerformanceSettingsCustomAndPersist()
        if !enabled {
            lastActionMessage = "Keep-on-top enforcement disabled."
            lastErrorMessage = nil
        }
    }

    func disablePerformanceOverlays() {
        setWindowBadgeOverlayEnabled(false)
        setWindowOutlineOverlayEnabled(false)
        lastActionMessage = "Overlays disabled."
        lastErrorMessage = nil
    }

    func setWindowBadgeOverlayEnabled(_ enabled: Bool) {
        guard showWindowBadgeOverlay != enabled else { return }
        showWindowBadgeOverlay = enabled
        UserDefaults.standard.set(enabled, forKey: AppModel.showWindowBadgeOverlayDefaultsKey)
        refreshWindowBadges()
    }

    func setWindowOutlineOverlayEnabled(_ enabled: Bool) {
        guard showWindowOutlineOverlay != enabled else { return }
        showWindowOutlineOverlay = enabled
        UserDefaults.standard.set(enabled, forKey: AppModel.showWindowOutlineOverlayDefaultsKey)
        refreshWindowBadges()
    }

    func setWindowOutlineOverlayBaseWidth(_ value: Double) {
        let clamped = min(max(value, 1.0), 6.0)
        guard abs(windowOutlineOverlayBaseWidth - clamped) > 0.001 else { return }
        windowOutlineOverlayBaseWidth = clamped
        UserDefaults.standard.set(clamped, forKey: AppModel.windowOutlineOverlayBaseWidthDefaultsKey)
    }

    func setTiledOverlayAccentColor(_ color: OverlayAccentColor) {
        guard tiledOverlayAccentColor != color else { return }
        tiledOverlayAccentColor = color
        UserDefaults.standard.set(color.userDefaultsArray, forKey: AppModel.tiledOverlayAccentColorDefaultsKey)
    }

    func setFloatingOverlayAccentColor(_ color: OverlayAccentColor) {
        guard floatingOverlayAccentColor != color else { return }
        floatingOverlayAccentColor = color
        UserDefaults.standard.set(color.userDefaultsArray, forKey: AppModel.floatingOverlayAccentColorDefaultsKey)
    }

    func incrementMiniMapHoverUpdates() {
        mutateRuntimeDiagnostics { $0.miniMapHoverUpdateCount += 1 }
    }

    func incrementOverlayPanelUpdates() {
        recordRuntimeBurst(.overlayUpdate)
        mutateRuntimeDiagnostics { $0.overlayPanelUpdateCount += 1 }
    }

    func recordMegamapRefreshDiagnostics(
        firstSwitchLatencyMilliseconds: Double,
        averageSwitchVerificationMilliseconds: Double,
        averageCaptureMilliseconds: Double,
        totalSweepMilliseconds: Double,
        capturedDesktopCount: Int,
        failedDesktopCount: Int
    ) {
        mutateRuntimeDiagnostics {
            $0.megamapRefreshCount += 1
            $0.megamapFirstSwitchLatencyMilliseconds = firstSwitchLatencyMilliseconds
            $0.megamapAverageSwitchVerificationMilliseconds = averageSwitchVerificationMilliseconds
            $0.megamapAverageCaptureMilliseconds = averageCaptureMilliseconds
            $0.megamapTotalSweepMilliseconds = totalSweepMilliseconds
            $0.megamapCapturedDesktopCount = capturedDesktopCount
            $0.megamapFailedDesktopCount = failedDesktopCount
        }
    }

    func mutateRuntimeDiagnostics(_ mutate: (inout RuntimeDiagnostics) -> Void) {
        var copy = runtimeDiagnosticsStorage
        mutate(&copy)
        runtimeDiagnosticsStorage = copy
        publishRuntimeDiagnosticsIfNeeded()
    }

    func publishRuntimeDiagnosticsIfNeeded(force: Bool = false) {
        guard force || (hasVisibleTilePilotWindow && currentVisibleTab == .system) else { return }
        let now = Date()
        if !force,
           let lastRuntimeDiagnosticsPublishAt,
           now.timeIntervalSince(lastRuntimeDiagnosticsPublishAt) < 0.75 {
            return
        }
        guard runtimeDiagnostics != runtimeDiagnosticsStorage else { return }
        runtimeDiagnostics = runtimeDiagnosticsStorage
        lastRuntimeDiagnosticsPublishAt = now
    }

    func persistPerformanceSettings() {
        let defaults = UserDefaults.standard
        defaults.set(performancePreset.rawValue, forKey: AppModel.performancePresetDefaultsKey)
        defaults.set(performanceForegroundPollingSeconds, forKey: AppModel.performanceForegroundPollingSecondsDefaultsKey)
        defaults.set(performanceBackgroundPollingSeconds, forKey: AppModel.performanceBackgroundPollingSecondsDefaultsKey)
        defaults.set(performanceKeepOnTopEnforcementSeconds, forKey: AppModel.performanceKeepOnTopSecondsDefaultsKey)
        defaults.set(miniMapHoverTitlesEnabled, forKey: AppModel.performanceMiniMapHoverTitlesEnabledDefaultsKey)
        defaults.set(hideMinimizedHelperWindowsInMaps, forKey: AppModel.performanceHideMinimizedHelperWindowsInMapsDefaultsKey)
        defaults.set(performanceFastLiveRefreshEnabled, forKey: AppModel.performanceFastLiveRefreshEnabledDefaultsKey)
        defaults.set(keepOnTopEnforcementEnabled, forKey: AppModel.performanceKeepOnTopEnforcementEnabledDefaultsKey)
    }

    private func markPerformanceSettingsCustomAndPersist() {
        performancePreset = effectivePerformancePreset
        persistPerformanceSettings()
    }

    private func clampedInterval(_ value: Double) -> Double {
        min(max(value, 0.5), 12.0)
    }

    func formattedSeconds(_ seconds: Double) -> String {
        if seconds == 0 {
            return "0.0s"
        }
        return String(format: "%.1fs", seconds)
    }
}
