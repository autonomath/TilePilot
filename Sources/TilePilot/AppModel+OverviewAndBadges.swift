import AppKit
import Foundation

@MainActor
extension AppModel {
    private var currentSnapshotForRuntimeConsumers: LiveStateSnapshot? {
        latestLiveStateSnapshot ?? liveStateSnapshot
    }

    var availableAppNamesFromLiveState: [String] {
        cachedAvailableAppNamesFromLiveState
    }

    var appNamesForBehaviorEditor: [String] {
        cachedAppNamesForBehaviorEditor
    }

    var focusedWindowState: WindowState? {
        liveStateSnapshot?.windows.first(where: \.focused)
    }

    var focusedAppName: String? {
        let trimmed = focusedWindowState?.app.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    func isNeverAutoTileEnabled(for appName: String) -> Bool {
        appTilingBehavior(for: appName) == .neverTile
    }

    func isOverviewExcludedWindow(_ window: WindowState, in snapshot: LiveStateSnapshot) -> Bool {
        let normalizedTitle = window.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedRole = window.role.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedSubrole = window.subrole.trimmingCharacters(in: .whitespacesAndNewlines)

        if window.app == "zoom.us" {
            guard !window.canResize else { return false }
            let tiny = window.frameW <= 140 || window.frameH <= 60
            guard tiny else { return false }
            return normalizedTitle.lowercased().isEmpty || normalizedTitle.lowercased() == "window"
        }

        guard hideMinimizedHelperWindowsInMaps else {
            return false
        }

        if window.usesLimitedVisualStyle {
            return true
        }

        if window.isMinimized || window.isHidden {
            return true
        }

        if isBackdropSurfaceWindow(
            window,
            normalizedTitle: normalizedTitle,
            normalizedRole: normalizedRole,
            normalizedSubrole: normalizedSubrole,
            in: snapshot
        ) {
            return true
        }

        if isTransientDialogSiblingWindow(
            window,
            normalizedTitle: normalizedTitle,
            normalizedRole: normalizedRole,
            normalizedSubrole: normalizedSubrole,
            in: snapshot
        ) {
            return true
        }

        if normalizedTitle.isEmpty,
           !window.isMinimized,
           !window.isHidden,
           !window.hasAXReference,
           !window.canMove,
           !window.canResize {
            let hasDescriptiveSiblingOnSameDesktop = snapshot.windows.contains { sibling in
                sibling.id != window.id &&
                    sibling.pid == window.pid &&
                    sibling.space == window.space &&
                    (!sibling.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                     sibling.hasAXReference ||
                     sibling.canMove ||
                     sibling.canResize ||
                     sibling.isVisible)
            }
            if hasDescriptiveSiblingOnSameDesktop {
                return true
            }
        }

        if !window.isVisible,
           !window.isMinimized,
           !window.isHidden,
           !window.hasAXReference,
           !window.canMove,
           !window.canResize {
            let hasVisibleSiblingOnSameDesktop = snapshot.windows.contains { sibling in
                sibling.id != window.id &&
                    sibling.pid == window.pid &&
                    sibling.space == window.space &&
                    sibling.isVisible &&
                    !sibling.isMinimized &&
                    !sibling.isHidden
            }
            if hasVisibleSiblingOnSameDesktop {
                return true
            }
        }

        return false
    }

    func isBackdropSurfaceWindow(
        _ window: WindowState,
        normalizedTitle: String,
        normalizedRole: String,
        normalizedSubrole: String,
        in snapshot: LiveStateSnapshot
    ) -> Bool {
        guard normalizedTitle.isEmpty else { return false }
        guard !window.isMinimized && !window.isHidden else { return false }

        let overlayLikeSubrole = normalizedSubrole == "AXSystemDialog" || normalizedSubrole == "AXDialog"
        let overlayLikeRole = normalizedRole == "AXSystemDialog" || normalizedRole == "AXDialog"
        guard overlayLikeSubrole || overlayLikeRole else { return false }

        guard let display = snapshot.displays.first(where: { $0.id == window.display }) else { return false }
        let widthCoverage = window.frameW / max(display.frameW, 1)
        let heightCoverage = window.frameH / max(display.frameH, 1)
        guard widthCoverage >= 0.96, heightCoverage >= 0.96 else { return false }

        let hasSmallerSibling = snapshot.windows.contains { sibling in
            sibling.id != window.id &&
                sibling.pid == window.pid &&
                sibling.frameW < (window.frameW * 0.9) &&
                sibling.frameH < (window.frameH * 0.9)
        }

        if hasSmallerSibling {
            return true
        }

        return window.floating || !window.hasAXReference || !window.canResize || !window.hasWindowServerMatch
    }

    func isTransientDialogSiblingWindow(
        _ window: WindowState,
        normalizedTitle: String,
        normalizedRole: String,
        normalizedSubrole: String,
        in snapshot: LiveStateSnapshot
    ) -> Bool {
        guard normalizedTitle.isEmpty else { return false }
        guard !window.isMinimized && !window.isHidden else { return false }

        let dialogLikeSubrole = normalizedSubrole == "AXDialog" || normalizedSubrole == "AXSystemDialog"
        let dialogLikeRole = normalizedRole == "AXDialog" || normalizedRole == "AXSystemDialog"
        guard dialogLikeSubrole || dialogLikeRole else { return false }
        guard window.floating else { return false }
        guard !window.canResize else { return false }

        let windowArea = max(window.frameW * window.frameH, 1)

        return snapshot.windows.contains { sibling in
            let siblingTitle = sibling.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let siblingSubrole = sibling.subrole.trimmingCharacters(in: .whitespacesAndNewlines)
            let siblingArea = sibling.frameW * sibling.frameH

            return sibling.id != window.id &&
                sibling.pid == window.pid &&
                sibling.space == window.space &&
                sibling.isVisible &&
                !sibling.isMinimized &&
                !sibling.isHidden &&
                siblingArea > (windowArea * 2.0) &&
                (
                    siblingSubrole == "AXStandardWindow" ||
                    sibling.canResize ||
                    !siblingTitle.isEmpty
                )
        }
    }

    func buildOverviewPreviews(from snapshot: LiveStateSnapshot) -> [OverviewDisplayPreview] {
        OverviewPreviewBuilder.build(snapshot: snapshot) { window in
            self.isOverviewExcludedWindow(window, in: snapshot)
        }
    }

    var canControlFocusedWindow: Bool {
        focusedWindowState != nil && doctorSnapshot != nil
    }

    func refreshWindowBadges(forceRepair: Bool = false, contentSignature: String? = nil) {
        guard showWindowBadgeOverlay || showWindowOutlineOverlay else {
            lastWindowBadgeRefreshSignature = nil
            applyWindowBadgeState([], hoveredWindowID: nil, forcePublish: forceRepair)
            return
        }
        guard let snapshot = currentSnapshotForRuntimeConsumers else {
            lastWindowBadgeRefreshSignature = nil
            applyWindowBadgeState([], hoveredWindowID: nil, forcePublish: forceRepair)
            return
        }
        guard snapshot.source == .yabai, !snapshot.degraded else {
            lastWindowBadgeRefreshSignature = nil
            applyWindowBadgeState([], hoveredWindowID: nil, forcePublish: forceRepair)
            return
        }

        let overlayEligibleWindows = snapshot.windows.filter { window in
            let normalizedTitle = window.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedRole = window.role.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedSubrole = window.subrole.trimmingCharacters(in: .whitespacesAndNewlines)
            return !isBackdropSurfaceWindow(
                window,
                normalizedTitle: normalizedTitle,
                normalizedRole: normalizedRole,
                normalizedSubrole: normalizedSubrole,
                in: snapshot
            ) && !isTransientDialogSiblingWindow(
                window,
                normalizedTitle: normalizedTitle,
                normalizedRole: normalizedRole,
                normalizedSubrole: normalizedSubrole,
                in: snapshot
            )
        }

        let sizeFiltered = overlayEligibleWindows.filter { window in
            guard !window.isMinimized && !window.isHidden else { return false }
            if window.focused { return true }
            return window.frameW > 40 && window.frameH > 24
        }
        guard !sizeFiltered.isEmpty else {
            lastWindowBadgeRefreshSignature = nil
            applyWindowBadgeState([], hoveredWindowID: nil, forcePublish: forceRepair)
            return
        }

        let visibleSpaceIndexes = Set(snapshot.spaces.filter(\.visible).map(\.index))
        let visibleSpaceCandidates: [WindowState]
        if visibleSpaceIndexes.isEmpty {
            visibleSpaceCandidates = sizeFiltered
        } else {
            visibleSpaceCandidates = sizeFiltered.filter { visibleSpaceIndexes.contains($0.space) }
        }
        guard !visibleSpaceCandidates.isEmpty else {
            lastWindowBadgeRefreshSignature = nil
            applyWindowBadgeState([], hoveredWindowID: nil, forcePublish: forceRepair)
            return
        }

        let visibleCandidates = visibleSpaceCandidates.filter(\.isVisible)
        var selectedWindows = visibleCandidates
        let frontmostPID = Int(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)
        let frontmostAppCandidates = visibleSpaceCandidates.filter { $0.pid == frontmostPID }
        let frontmostCandidate = topmostOnScreenBadgeCandidate(from: frontmostAppCandidates)
            ?? preferredFrontmostBadgeCandidate(from: visibleCandidates.filter { $0.pid == frontmostPID })

        if let frontmostCandidate,
           !selectedWindows.contains(where: { $0.id == frontmostCandidate.id }) {
            selectedWindows.append(frontmostCandidate)
        }

        let sortedSelected = selectedWindows.sorted { lhs, rhs in
            if lhs.focused != rhs.focused { return lhs.focused && !rhs.focused }
            if lhs.app != rhs.app { return lhs.app.localizedCaseInsensitiveCompare(rhs.app) == .orderedAscending }
            return lhs.id < rhs.id
        }

        let explicitFocused = sortedSelected.first(where: \.focused)
        let effectiveFocusedID: Int? = {
            if let frontmostCandidate {
                return frontmostCandidate.id
            }
            return explicitFocused?.id
        }()

        let badges = sortedSelected.map { window in
            WindowBadgeState(
                windowID: window.id,
                pid: window.pid,
                app: window.app,
                title: window.title,
                isFloating: effectiveBadgeFloatingState(for: window, in: snapshot),
                isFocused: window.id == effectiveFocusedID,
                isRuntimeManageable: window.isRuntimeManageable,
                usesLimitedVisualStyle: window.usesLimitedVisualStyle,
                frameX: window.frameX,
                frameY: window.frameY,
                frameW: window.frameW,
                frameH: window.frameH
            )
        }
        applyWindowBadgeState(badges, hoveredWindowID: nil, forcePublish: forceRepair)
        lastWindowBadgeRefreshSignature = currentWindowBadgeRefreshSignature(contentSignature: contentSignature)
    }

    private func effectiveBadgeFloatingState(for window: WindowState, in snapshot: LiveStateSnapshot) -> Bool {
        let layout = snapshot.spaces.first(where: { $0.index == window.space })?.layout?.lowercased()
        if layout == "float" {
            return true
        }
        return window.floating
    }

    func updateHoveredWindowForBadges(candidates: [WindowState]? = nil) {
        guard let snapshot = currentSnapshotForRuntimeConsumers, snapshot.source == .yabai, !snapshot.degraded else {
            applyWindowBadgeState(windowBadges, hoveredWindowID: nil)
            return
        }
        let windows = (candidates ?? snapshot.windows).filter { window in
            guard window.isVisible && !window.isMinimized && !window.isHidden else { return false }
            let normalizedTitle = window.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedRole = window.role.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedSubrole = window.subrole.trimmingCharacters(in: .whitespacesAndNewlines)
            return !isBackdropSurfaceWindow(
                window,
                normalizedTitle: normalizedTitle,
                normalizedRole: normalizedRole,
                normalizedSubrole: normalizedSubrole,
                in: snapshot
            ) && !isTransientDialogSiblingWindow(
                window,
                normalizedTitle: normalizedTitle,
                normalizedRole: normalizedRole,
                normalizedSubrole: normalizedSubrole,
                in: snapshot
            )
        }
        guard !windows.isEmpty else {
            applyWindowBadgeState(windowBadges, hoveredWindowID: nil)
            return
        }

        let mouse = NSEvent.mouseLocation
        let screens = NSScreen.screens

        let hovered = windows
            .filter { containsMouse(mouse, in: $0, screens: screens) }
            .sorted { lhs, rhs in
                if lhs.focused != rhs.focused { return lhs.focused && !rhs.focused }
                let lhsArea = lhs.frameW * lhs.frameH
                let rhsArea = rhs.frameW * rhs.frameH
                if lhsArea != rhsArea { return lhsArea < rhsArea }
                return lhs.id < rhs.id
            }
            .first?
            .id

        applyWindowBadgeState(windowBadges, hoveredWindowID: hovered)
    }

    var shouldShowWindowBehaviorRecommendation: Bool {
        guard let snapshot = doctorSnapshot else { return false }
        let capabilityByKey = Dictionary(uniqueKeysWithValues: snapshot.capabilities.map { ($0.key, $0.status) })
        return capabilityByKey["yabai-binary"] == .available && !yabaiConfigHasManagedSection
    }

    private func containsMouse(_ mouse: NSPoint, in window: WindowState, screens: [NSScreen]) -> Bool {
        let rect = convertTopOriginRectToAppKit(CGRect(x: window.frameX, y: window.frameY, width: window.frameW, height: window.frameH), screens: screens)
        return rect.contains(mouse)
    }

    private func convertTopOriginRectToAppKit(_ rect: CGRect, screens: [NSScreen]) -> CGRect {
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

    func applyWindowBadgeState(_ badges: [WindowBadgeState], hoveredWindowID: Int?, forcePublish: Bool = false) {
        if forcePublish || windowBadges != badges {
            windowBadges = badges
        }
        if forcePublish || hoveredWindowIDForBadges != hoveredWindowID {
            hoveredWindowIDForBadges = hoveredWindowID
        }
        if forcePublish {
            windowBadgeOverlayRefreshSubject.send(())
        }
    }

    private func preferredFrontmostBadgeCandidate(from windows: [WindowState]) -> WindowState? {
        windows.sorted { lhs, rhs in
            if lhs.focused != rhs.focused { return lhs.focused && !rhs.focused }
            if lhs.isRuntimeManageable != rhs.isRuntimeManageable { return lhs.isRuntimeManageable && !rhs.isRuntimeManageable }
            let lhsArea = lhs.frameW * lhs.frameH
            let rhsArea = rhs.frameW * rhs.frameH
            if lhsArea != rhsArea { return lhsArea > rhsArea }
            return lhs.id < rhs.id
        }
        .first
    }

    private func topmostOnScreenBadgeCandidate(from windows: [WindowState]) -> WindowState? {
        guard !windows.isEmpty else { return nil }
        let windowsByID = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
        let windowIDs = Set(windowsByID.keys)
        guard let rawInfo = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              !rawInfo.isEmpty else {
            return nil
        }

        for info in rawInfo {
            let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1
            guard layer == 0 else { continue }
            let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            guard alpha > 0.01 else { continue }
            guard let number = (info[kCGWindowNumber as String] as? NSNumber)?.intValue,
                  windowIDs.contains(number) else {
                continue
            }
            if let match = windowsByID[number] {
                return match
            }
        }

        return nil
    }

    func rebuildLiveStateDerivedCaches() {
        let names = Set(
            (liveStateSnapshot?.windows ?? [])
                .map(\.app)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        cachedAvailableAppNamesFromLiveState = names.sorted()
        rebuildBehaviorEditorAppNamesCache()
        rebuildWorkSetRuntimeCaches(using: liveStateSnapshot)
    }

    func rebuildBehaviorEditorAppNamesCache() {
        let names = Set(cachedAvailableAppNamesFromLiveState)
            .union(windowBehaviorPolicyDraft.neverTileApps.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .union(windowBehaviorPolicyDraft.alwaysTileApps.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .union(stagedNeverTileApps.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .union(stagedAlwaysTileApps.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .filter { !$0.isEmpty }
        cachedAppNamesForBehaviorEditor = names.sorted { lhs, rhs in
            lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
    }

    func currentWindowBadgeRefreshSignature(contentSignature: String? = nil) -> String? {
        guard let snapshot = currentSnapshotForRuntimeConsumers, snapshot.source == .yabai, !snapshot.degraded else {
            return nil
        }
        let baseSignature = contentSignature ?? liveStateContentSignature(for: snapshot)
        let frontmostPID = Int(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)
        return "\(baseSignature)###badge|\(frontmostPID)|\(showWindowBadgeOverlay ? 1 : 0)|\(showWindowOutlineOverlay ? 1 : 0)"
    }
}
