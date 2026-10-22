import AppKit
import CoreGraphics
import Foundation

@MainActor
extension AppModel {
    static let workAreaToggleFeatureID: FeatureControlID = "app.toggle-work-area"
    static let workAreaFillFeatureID: FeatureControlID = "screen.fill-work-area"
    private static let workAreaPaddingRetrySeconds: TimeInterval = 15
    private static let workAreaPaddingVerifySeconds: TimeInterval = 60
    private static let workAreaUndoWindowSeconds: TimeInterval = 10

    // MARK: - Persistence and lookup

    func persistWorkAreas() {
        guard let data = try? JSONEncoder().encode(workAreas) else { return }
        UserDefaults.standard.set(data, forKey: AppModel.workAreasDefaultsKey)
    }

    var workAreaSnapshot: LiveStateSnapshot? {
        latestLiveStateSnapshot ?? liveStateSnapshot
    }

    /// Displays with real geometry, ordered as yabai reports them.
    var workAreaDisplays: [DisplayState] {
        (workAreaSnapshot?.displays ?? []).filter { $0.frameW > 1 && $0.frameH > 1 && $0.source != .fallback }
    }

    var hasEnabledWorkArea: Bool {
        workAreas.contains(where: \.enabled)
    }

    var hasActiveWorkAreaContainment: Bool {
        workAreas.contains { $0.enabled && $0.containmentEnabled }
    }

    var canUndoLastWorkAreaFit: Bool {
        guard let batch = workAreaLastFitBatch else { return false }
        return Date().timeIntervalSince(batch.createdAt) <= Self.workAreaUndoWindowSeconds
    }

    func workAreaDisplayFrame(for display: DisplayState) -> CGRect {
        CGRect(x: display.frameX, y: display.frameY, width: display.frameW, height: display.frameH)
    }

    func workAreaConfigurationIndex(for display: DisplayState) -> Int? {
        let connected = Set((workAreaSnapshot?.displays ?? []).compactMap(\.uuid))
        return WorkAreaConfiguration.matchIndex(
            displayUUID: display.uuid,
            displayName: display.name,
            width: display.frameW,
            height: display.frameH,
            connectedUUIDs: connected,
            in: workAreas
        )
    }

    func workAreaConfiguration(for display: DisplayState) -> WorkAreaConfiguration? {
        guard let index = workAreaConfigurationIndex(for: display) else { return nil }
        return workAreas[index]
    }

    /// The display area left free by the menu bar and Dock, in yabai coordinates.
    func workAreaVisibleFrame(for display: DisplayState) -> CGRect? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }
        let primaryMaxY = screens.first(where: { abs($0.frame.minX) < 0.5 && abs($0.frame.minY) < 0.5 })?.frame.maxY
            ?? NSScreen.main?.frame.maxY
            ?? screens[0].frame.maxY

        if let uuid = display.uuid?.uppercased(),
           let screen = screens.first(where: { workAreaScreenUUID($0) == uuid }) {
            return WorkAreaGeometry.topLeftRect(fromAppKit: screen.visibleFrame, primaryScreenMaxY: primaryMaxY)
        }

        let displayFrame = workAreaDisplayFrame(for: display)
        var bestFrame: CGRect?
        var bestArea: CGFloat = 0
        for screen in screens {
            let screenFrame = WorkAreaGeometry.topLeftRect(fromAppKit: screen.frame, primaryScreenMaxY: primaryMaxY)
            let intersection = screenFrame.intersection(displayFrame)
            guard !intersection.isNull, !intersection.isEmpty else { continue }
            let area = intersection.width * intersection.height
            if area > bestArea {
                bestArea = area
                bestFrame = WorkAreaGeometry.topLeftRect(fromAppKit: screen.visibleFrame, primaryScreenMaxY: primaryMaxY)
            }
        }
        return bestFrame
    }

    private func workAreaScreenUUID(_ screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(CGDirectDisplayID(number.uint32Value))?.takeRetainedValue() else {
            return nil
        }
        return (CFUUIDCreateString(nil, uuid) as String).uppercased()
    }

    /// The effective Work Area in yabai coordinates, or nil when the display has none enabled.
    /// When the System Bar sits inside the area, this is the part left for windows.
    func resolvedWorkArea(for display: DisplayState) -> CGRect? {
        guard let fullArea = resolvedWorkAreaIgnoringSystemBar(for: display) else { return nil }
        if let layout = resolvedSystemBarLayout(for: display) {
            return layout.windowArea
        }
        return fullArea
    }

    /// The saved rectangle resolved against the display, before the System Bar takes its share.
    func resolvedWorkAreaIgnoringSystemBar(for display: DisplayState) -> CGRect? {
        guard display.frameW > 1, display.frameH > 1,
              let configuration = workAreaConfiguration(for: display),
              configuration.enabled else {
            return nil
        }
        return WorkAreaGeometry.resolve(
            normalizedRect: configuration.normalizedRect,
            displayFrame: workAreaDisplayFrame(for: display),
            visibleFrame: workAreaVisibleFrame(for: display)
        )
    }

    /// Where TilePilot places windows on this display: the Work Area when enabled, otherwise the
    /// whole display frame.
    func placementFrame(for display: DisplayState) -> CGRect {
        resolvedWorkArea(for: display) ?? workAreaDisplayFrame(for: display)
    }

    /// The rectangle shown in the editor before anything is saved for a display.
    func workAreaEditorNormalizedRect(for display: DisplayState) -> CGRect {
        if let configuration = workAreaConfiguration(for: display) {
            return configuration.normalizedRect
        }
        return WorkAreaGeometry.suggestedNormalizedRect(
            displaySize: CGSize(width: display.frameW, height: display.frameH)
        )
    }

    // MARK: - Editing

    @discardableResult
    private func ensureWorkAreaConfigurationIndex(for display: DisplayState, enabledIfNew: Bool) -> Int {
        if let index = workAreaConfigurationIndex(for: display) {
            // Re-key an orphaned configuration to the display's current identity.
            if workAreas[index].displayUUID != display.uuid?.uppercased() || workAreas[index].displayName != display.name {
                workAreas[index].displayUUID = display.uuid?.uppercased()
                workAreas[index].displayName = display.name
            }
            workAreas[index].displayWidth = display.frameW
            workAreas[index].displayHeight = display.frameH
            return index
        }
        workAreas.append(
            WorkAreaConfiguration(
                displayUUID: display.uuid,
                displayName: display.name,
                displayWidth: display.frameW,
                displayHeight: display.frameH,
                enabled: enabledIfNew,
                normalizedRect: workAreaEditorNormalizedRect(for: display)
            )
        )
        return workAreas.count - 1
    }

    func setWorkAreaEnabled(_ enabled: Bool, for display: DisplayState) {
        let index = ensureWorkAreaConfigurationIndex(for: display, enabledIfNew: enabled)
        workAreas[index].enabled = enabled
        persistWorkAreas()
        lastActionMessage = enabled
            ? "Work Area on for \(display.name). Windows will stay inside it."
            : "Work Area off for \(display.name). Windows can use the whole display."
        lastErrorMessage = nil
        scheduleWorkAreaApply(delayMilliseconds: 0)
    }

    func setWorkAreaNormalizedRect(_ rect: CGRect, for display: DisplayState, debounce: Bool = true) {
        let clamped = WorkAreaGeometry.clampedNormalizedRect(
            rect,
            displaySize: CGSize(width: display.frameW, height: display.frameH)
        )
        let index = ensureWorkAreaConfigurationIndex(for: display, enabledIfNew: false)
        guard workAreas[index].normalizedRect != clamped else { return }
        workAreas[index].normalizedRect = clamped
        persistWorkAreas()
        if workAreas[index].enabled {
            scheduleWorkAreaApply(delayMilliseconds: debounce ? 300 : 0)
        }
    }

    func setWorkAreaContainmentEnabled(_ enabled: Bool, for display: DisplayState) {
        let index = ensureWorkAreaConfigurationIndex(for: display, enabledIfNew: false)
        workAreas[index].containmentEnabled = enabled
        persistWorkAreas()
        if !enabled {
            workAreaUnfitWindows.removeAll { $0.displayID == display.id }
        }
        scheduleWorkAreaApply(delayMilliseconds: 0)
    }

    func addWorkAreaExcludedApp(_ rawName: String, for display: DisplayState) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let index = ensureWorkAreaConfigurationIndex(for: display, enabledIfNew: false)
        guard !workAreas[index].excludesApp(name) else { return }
        workAreas[index].excludedApps.append(name)
        workAreas[index].excludedApps.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        persistWorkAreas()
        workAreaUnfitWindows.removeAll { normalizedAppRuleKey($0.app) == normalizedAppRuleKey(name) }
    }

    func removeWorkAreaExcludedApp(_ name: String, for display: DisplayState) {
        guard let index = workAreaConfigurationIndex(for: display) else { return }
        let key = normalizedAppRuleKey(name)
        workAreas[index].excludedApps.removeAll { normalizedAppRuleKey($0) == key }
        persistWorkAreas()
        scheduleWorkAreaApply(delayMilliseconds: 0)
    }

    func allowWorkAreaWindowOutside(windowID: Int) {
        workAreaSessionAllowedWindowIDs.insert(windowID)
        let window = workAreaUnfitWindows.first(where: { $0.windowID == windowID })
        workAreaUnfitWindows.removeAll { $0.windowID == windowID }
        lastActionMessage = "\(window?.app ?? "That window") can stay outside the Work Area until TilePilot restarts."
        lastErrorMessage = nil
    }

    /// Turns every saved Work Area off when any is on; otherwise turns them all back on.
    func toggleAllWorkAreas() {
        guard !workAreas.isEmpty else {
            lastErrorMessage = "Set up a Work Area in the Work Area tab first."
            lastActionMessage = nil
            return
        }
        let enable = !hasEnabledWorkArea
        for index in workAreas.indices {
            workAreas[index].enabled = enable
        }
        persistWorkAreas()
        if !enable {
            workAreaUnfitWindows = []
        }
        lastActionMessage = enable
            ? "Work Area on. Windows will stay inside it."
            : "Work Area off. Windows can use the whole display."
        lastErrorMessage = nil
        scheduleWorkAreaApply(delayMilliseconds: 0)
    }

    func scheduleWorkAreaApply(delayMilliseconds: Int) {
        workAreaEditApplyTask?.cancel()
        workAreaEditApplyTask = Task { [weak self] in
            if delayMilliseconds > 0 {
                try? await Task.sleep(for: .milliseconds(delayMilliseconds))
            }
            guard let self, !Task.isCancelled else { return }
            for _ in 0..<5 {
                if !self.isRefreshingLiveState {
                    await self.refreshLiveState()
                    return
                }
                try? await Task.sleep(for: .milliseconds(200))
                if Task.isCancelled { return }
            }
        }
    }

    // MARK: - Runtime

    func applyWorkAreaRuntimeIfNeeded(using snapshot: LiveStateSnapshot) async {
        let previousSource = workAreaLastSnapshotSource
        workAreaLastSnapshotSource = snapshot.source
        workAreaContainmentCoordinator.updateMouseMonitor(on: self, needed: hasActiveWorkAreaContainment)
        updateSystemBar(using: snapshot)
        guard snapshot.source == .yabai, !snapshot.degraded else { return }
        if let previousSource, previousSource != .yabai {
            // yabai came back (often after a restart), which drops per-desktop padding.
            invalidateWorkAreaPaddingCache()
        }
        await applyWorkAreaPaddingIfNeeded(using: snapshot)
        await workAreaContainmentCoordinator.enforce(on: self, snapshot: snapshot)
    }

    /// Forget which desktops carry Work Area padding. Call after something resets every desktop to
    /// the global padding, such as saving window behavior or a yabai restart.
    func invalidateWorkAreaPaddingCache() {
        workAreaAppliedPaddingBySpace = [:]
        workAreaPaddingFailureAtBySpace = [:]
        workAreaPaddingLastVerifiedAt = nil
    }

    func reapplyWorkAreaPaddingIfMissing() async {
        guard let snapshot = workAreaSnapshot else { return }
        await applyWorkAreaPaddingIfNeeded(using: snapshot)
    }

    func applyWorkAreaPaddingIfNeeded(using snapshot: LiveStateSnapshot) async {
        guard !workAreaPaddingApplyInProgress else { return }
        guard snapshot.source == .yabai, !snapshot.degraded, canRunYabaiRuntimeCommands else { return }
        workAreaPaddingApplyInProgress = true
        defer { workAreaPaddingApplyInProgress = false }

        let signature = snapshot.spaces.map { "\($0.index):\($0.displayId)" }.joined(separator: ",")
            + "|" + snapshot.displays.map { "\($0.id)=\($0.uuid ?? "?")" }.joined(separator: ",")
        var forceAll = false
        if signature != workAreaPaddingSpaceSignature {
            // Desktop numbers shifted, so cached padding may sit on a different desktop now.
            forceAll = workAreaPaddingSpaceSignature != nil
            workAreaPaddingSpaceSignature = signature
        }

        guard hasEnabledWorkArea || !workAreaAppliedPaddingBySpace.isEmpty else { return }

        await verifyWorkAreaPaddingIfDue()

        let outerPadding = windowBehaviorPolicyDraft.outerPadding
        let globalPadding = WorkAreaPadding.uniform(outerPadding)
        let fullscreenSpaces = Set(snapshot.windows.filter(\.isNativeFullscreen).map(\.space))
        let now = Date()
        var failedSpaces: [Int] = []

        for space in snapshot.spaces where !fullscreenSpaces.contains(space.index) {
            guard let display = snapshot.displays.first(where: { $0.id == space.displayId }) else { continue }
            var desired: WorkAreaPadding?
            if let workArea = resolvedWorkArea(for: display) {
                let visible = workAreaVisibleFrame(for: display) ?? workAreaDisplayFrame(for: display)
                desired = WorkAreaGeometry.yabaiPadding(workArea: workArea, visibleFrame: visible, outerPadding: outerPadding)
            }

            let cached = workAreaAppliedPaddingBySpace[space.index]
            let target: WorkAreaPadding
            if let desired {
                if cached == desired && !forceAll { continue }
                target = desired
            } else {
                guard cached != nil || forceAll else { continue }
                target = globalPadding
            }
            if !forceAll,
               let failedAt = workAreaPaddingFailureAtBySpace[space.index],
               now.timeIntervalSince(failedAt) < Self.workAreaPaddingRetrySeconds {
                continue
            }

            if await setYabaiSpacePadding(target, spaceIndex: space.index) {
                workAreaPaddingFailureAtBySpace.removeValue(forKey: space.index)
                if desired != nil {
                    workAreaAppliedPaddingBySpace[space.index] = target
                } else {
                    workAreaAppliedPaddingBySpace.removeValue(forKey: space.index)
                }
            } else {
                if workAreaPaddingFailureAtBySpace[space.index] == nil {
                    failedSpaces.append(space.index)
                }
                workAreaPaddingFailureAtBySpace[space.index] = now
            }
        }

        if !failedSpaces.isEmpty {
            let list = failedSpaces.map(String.init).joined(separator: ", ")
            lastErrorMessage = "Couldn't apply the Work Area to tiled windows on Desktop \(list). TilePilot will retry."
            lastActionMessage = nil
        }
    }

    private func verifyWorkAreaPaddingIfDue() async {
        guard let entry = workAreaAppliedPaddingBySpace.min(by: { $0.key < $1.key }) else { return }
        let spaceIndex = entry.key
        let padding = entry.value
        let now = Date()
        if let lastVerified = workAreaPaddingLastVerifiedAt,
           now.timeIntervalSince(lastVerified) < Self.workAreaPaddingVerifySeconds {
            return
        }
        workAreaPaddingLastVerifiedAt = now
        // Check every side: a yabai restart resets all four, and a full-width Work Area has a
        // left padding that matches the default.
        let expected: [(String, Int)] = [
            ("top_padding", padding.top),
            ("bottom_padding", padding.bottom),
            ("left_padding", padding.left),
            ("right_padding", padding.right),
        ]
        for (key, value) in expected {
            let result = await doctorService.runSupportCommand(
                yabaiCommand(["-m", "config", "--space", String(spaceIndex), key], timeout: 1.5)
            )
            guard result.isSuccess else { return }
            let reported = Int(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
            if reported != value {
                invalidateWorkAreaPaddingCache()
                workAreaPaddingLastVerifiedAt = now
                return
            }
        }
    }

    private func setYabaiSpacePadding(_ padding: WorkAreaPadding, spaceIndex: Int) async -> Bool {
        let values: [(String, Int)] = [
            ("top_padding", padding.top),
            ("bottom_padding", padding.bottom),
            ("left_padding", padding.left),
            ("right_padding", padding.right),
        ]
        var succeeded = true
        for (key, value) in values {
            let result = await doctorService.runSupportCommand(
                yabaiCommand(["-m", "config", "--space", String(spaceIndex), key, String(value)], timeout: 1.5)
            )
            appendCommandLog(from: result)
            if !result.isSuccess {
                succeeded = false
            }
        }
        return succeeded
    }

    // MARK: - Moving windows

    /// Moves and resizes a window, then reads back its real frame. Returns true when the window
    /// ends up inside `acceptableArea`.
    func moveWindowForWorkArea(_ window: WindowState, to frame: CGRect, acceptableArea: CGRect) async -> Bool {
        let target = frame.integral
        var commandsSucceeded = false
        if window.isRuntimeManageable {
            var resizeOK = true
            // The snapshot frame can lag behind the real window, so always send the size.
            if window.canResize {
                let resize = await doctorService.runSupportCommand(
                    yabaiCommand(
                        ["-m", "window", String(window.id), "--resize", "abs:\(Int(target.width)):\(Int(target.height))"],
                        timeout: 1.5
                    )
                )
                appendCommandLog(from: resize)
                resizeOK = resize.isSuccess
            }
            let move = await doctorService.runSupportCommand(
                yabaiCommand(
                    ["-m", "window", String(window.id), "--move", "abs:\(Int(target.minX)):\(Int(target.minY))"],
                    timeout: 1.5
                )
            )
            appendCommandLog(from: move)
            commandsSucceeded = resizeOK && move.isSuccess
        }

        if commandsSucceeded,
           let actual = await queryWorkAreaWindowFrame(windowID: window.id),
           WorkAreaGeometry.isContained(actual, in: acceptableArea) {
            return true
        }

        let accessibilityOK = await setWindowFrameUsingAccessibility(window: window, frame: target)
        if let actual = await queryWorkAreaWindowFrame(windowID: window.id) {
            return WorkAreaGeometry.isContained(actual, in: acceptableArea)
        }
        return accessibilityOK
    }

    func queryWorkAreaWindowFrame(windowID: Int) async -> CGRect? {
        try? await Task.sleep(for: .milliseconds(60))
        // The window server always knows where a window is; yabai's frame goes stale for windows
        // it has lost track of.
        if let bounds = Self.windowServerBounds(windowID: windowID) {
            return bounds
        }
        let result = await doctorService.runSupportCommand(
            yabaiCommand(["-m", "query", "--windows", "--window", String(windowID)], timeout: 1.0)
        )
        guard result.isSuccess,
              let data = result.stdout.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let frame = object["frame"] as? [String: Any],
              let x = (frame["x"] as? NSNumber)?.doubleValue,
              let y = (frame["y"] as? NSNumber)?.doubleValue,
              let w = (frame["w"] as? NSNumber)?.doubleValue,
              let h = (frame["h"] as? NSNumber)?.doubleValue else {
            return nil
        }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// The real frames of windows TilePilot is about to move, read through Accessibility off the
    /// main thread. Windows it cannot read are left out.
    func workAreaAccessibilityFrames(for windows: [WindowState]) async -> [Int: CGRect] {
        let windowIDsByPID = Dictionary(grouping: windows, by: \.pid).mapValues { Set($0.map(\.id)) }
        guard !windowIDsByPID.isEmpty else { return [:] }
        return await Task.detached(priority: .userInitiated) {
            AccessibilityWindowFrames.frames(windowIDsByPID: windowIDsByPID)
        }.value
    }

    /// True when the window server is showing windows somewhere other than where they are, as in
    /// Mission Control, App Exposé, or Show Desktop (and their animations). Compares snapshot
    /// frames, which come from the window server, with `knownRealFrames` and with yabai's frames
    /// (from Accessibility) for a few more windows it tracks.
    func workAreaWindowServerFramesLookTransformed(
        snapshot: LiveStateSnapshot,
        visibleSpaces: Set<Int>,
        knownRealFrames: [Int: CGRect]
    ) async -> Bool {
        func snapshotFrame(_ window: WindowState) -> CGRect {
            CGRect(x: window.frameX, y: window.frameY, width: window.frameW, height: window.frameH)
        }
        var samples: [(windowServer: CGRect, accessibility: CGRect)] = snapshot.windows.compactMap { window in
            knownRealFrames[window.id].map { (snapshotFrame(window), $0) }
        }
        let extra = snapshot.windows
            .filter {
                knownRealFrames[$0.id] == nil && $0.hasAXReference && $0.hasWindowServerMatch &&
                    visibleSpaces.contains($0.space) && !$0.isMinimized && !$0.isHidden &&
                    $0.frameW > 50 && $0.frameH > 50
            }
            .prefix(max(0, 3 - samples.count))
        for window in extra {
            let result = await doctorService.runSupportCommand(
                yabaiCommand(["-m", "query", "--windows", "--window", String(window.id)], timeout: 1.0)
            )
            guard result.isSuccess,
                  let data = result.stdout.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let frame = object["frame"] as? [String: Any],
                  let x = (frame["x"] as? NSNumber)?.doubleValue,
                  let y = (frame["y"] as? NSNumber)?.doubleValue,
                  let w = (frame["w"] as? NSNumber)?.doubleValue,
                  let h = (frame["h"] as? NSNumber)?.doubleValue else {
                continue
            }
            samples.append((snapshotFrame(window), CGRect(x: x, y: y, width: w, height: h)))
        }
        return WorkAreaGeometry.windowServerLooksTransformed(samples)
    }

    /// A window's frame in top-left screen coordinates, straight from the window server.
    nonisolated static func windowServerBounds(windowID: Int) -> CGRect? {
        guard windowID > 0,
              let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(windowID)) as? [[String: Any]],
              let info = list.first(where: { ($0[kCGWindowNumber as String] as? Int) == windowID }),
              let dictionary = info[kCGWindowBounds as String] as? NSDictionary else {
            return nil
        }
        var bounds = CGRect.zero
        guard CGRectMakeWithDictionaryRepresentation(dictionary, &bounds), bounds.width > 0, bounds.height > 0 else {
            return nil
        }
        return bounds
    }

    func recordWorkAreaFitBatch(_ previousFrames: [Int: CGRect]) {
        guard !previousFrames.isEmpty else { return }
        workAreaLastFitBatch = WorkAreaFitBatch(createdAt: Date(), previousFramesByWindowID: previousFrames)
        workAreaFitBatchExpiryTask?.cancel()
        workAreaFitBatchExpiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.workAreaUndoWindowSeconds))
            guard let self, !Task.isCancelled else { return }
            self.workAreaLastFitBatch = nil
        }
    }

    func updateWorkAreaUnfitWindows(_ windows: [WorkAreaUnfitWindow]) {
        let filtered = windows.filter { !workAreaSessionAllowedWindowIDs.contains($0.windowID) }
        guard filtered != workAreaUnfitWindows else { return }
        workAreaUnfitWindows = filtered
    }

    func undoLastWorkAreaFit() {
        guard canUndoLastWorkAreaFit, let batch = workAreaLastFitBatch else {
            lastErrorMessage = "Nothing to undo. Undo is available for 10 seconds after TilePilot moves windows."
            lastActionMessage = nil
            return
        }
        workAreaLastFitBatch = nil
        workAreaFitBatchExpiryTask?.cancel()
        // Restored windows may sit outside again, so keep containment from moving them straight back.
        workAreaSessionAllowedWindowIDs.formUnion(batch.previousFramesByWindowID.keys)
        Task { [weak self] in
            guard let self else { return }
            let windowsByID = Dictionary(
                (self.workAreaSnapshot?.windows ?? []).map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            var restored = 0
            for (windowID, frame) in batch.previousFramesByWindowID {
                guard let window = windowsByID[windowID] else { continue }
                if await self.moveWindowForWorkArea(window, to: frame, acceptableArea: frame.insetBy(dx: -8, dy: -8)) {
                    restored += 1
                }
            }
            self.lastActionMessage = restored == 1
                ? "Restored 1 window. It can stay outside the Work Area until TilePilot restarts."
                : "Restored \(restored) windows. They can stay outside the Work Area until TilePilot restarts."
            self.lastErrorMessage = nil
            await self.refreshLiveState()
        }
    }

    // MARK: - Fill Work Area

    /// Resizes the focused floating window to the Work Area (or the visible screen when its display
    /// has none). Returns a user-facing message and whether it describes a failure.
    func fillFocusedWindowToWorkArea() async -> (message: String, isError: Bool) {
        await refreshLiveState()
        guard let snapshot = workAreaSnapshot, snapshot.source == .yabai,
              let window = snapshot.windows.first(where: \.focused) else {
            return ("No focused window to fill.", true)
        }
        if window.isNativeFullscreen {
            return ("\(window.app) is in full screen. Exit full screen first.", true)
        }
        let layout = snapshot.spaces.first(where: { $0.index == window.space })?.layout?.lowercased() ?? "float"
        if !window.floating && layout != "float" {
            return ("Tiled windows already fill the Work Area; float it first.", true)
        }
        guard let display = snapshot.displays.first(where: { $0.id == window.display }) else {
            return ("The focused window's display is unavailable.", true)
        }
        let workArea = resolvedWorkArea(for: display)
        let target = workArea.map(WorkAreaGeometry.fillFrame)
            ?? workAreaVisibleFrame(for: display)
            ?? workAreaDisplayFrame(for: display)
        let filled = await moveWindowForWorkArea(window, to: target, acceptableArea: target)
        await refreshLiveState()
        guard filled else {
            return ("Couldn't resize \(window.app) to fill the \(workArea == nil ? "screen" : "Work Area").", true)
        }
        return workArea == nil
            ? ("\(window.app) now fills the screen. Set up a Work Area to use a smaller area.", false)
            : ("\(window.app) now fills the Work Area.", false)
    }

    // MARK: - Templates

    /// Re-expresses a rectangle normalized to the whole display as a rectangle normalized to the
    /// display's placement frame, so captured layouts reapply inside the Work Area.
    func workAreaRelativeNormalizedRect(_ displayNormalized: CGRect, display: DisplayState) -> CGRect {
        let displayFrame = workAreaDisplayFrame(for: display)
        let placement = placementFrame(for: display)
        guard placement != displayFrame else { return displayNormalized }
        let absolute = WorkAreaGeometry.absoluteRect(normalized: displayNormalized, displayFrame: displayFrame)
        let clipped = absolute.intersection(placement)
        let source = clipped.isNull || clipped.isEmpty ? absolute : clipped
        return clampedNormalizedTemplateRect(WorkAreaGeometry.normalizedRect(absolute: source, displayFrame: placement))
    }
}
