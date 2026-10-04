import AppKit
import ApplicationServices
import Foundation

@MainActor
final class KeepOnTopCoordinator {
    private var lastRaisedAtByWindowID: [Int: Date] = [:]
    private var keepOnTopOcclusionActiveByWindowID: [Int: Bool] = [:]
    private var lastKeepOnTopAutoAttemptAtByWindowID: [Int: Date] = [:]
    private let raiseCooldownSeconds: TimeInterval = 1.2
    private let keepOnTopAutoRetrySeconds: TimeInterval = 2.0

    func applyForegroundPolicyTransitions(
        on model: AppModel,
        previous: LiveStateSnapshot?,
        current: LiveStateSnapshot
    ) async {
        guard model.keepOnTopEnforcementEnabled else { return }
        let currentTransition = foregroundTransitionSnapshot(on: model, from: current)
        guard currentTransition.isEligible else { return }

        let previousTransition: (isEligible: Bool, activeSpace: Int?, visibleFlaggedFloatingWindowIDs: Set<Int>)
        if let previous {
            previousTransition = foregroundTransitionSnapshot(on: model, from: previous)
        } else {
            previousTransition = (true, nil, [])
        }
        guard previousTransition.isEligible else { return }

        let activeDesktopChanged = previousTransition.activeSpace != currentTransition.activeSpace
        let newlyVisibleFlagged = currentTransition.visibleFlaggedFloatingWindowIDs.subtracting(previousTransition.visibleFlaggedFloatingWindowIDs)
        guard activeDesktopChanged || !newlyVisibleFlagged.isEmpty else { return }
        await bringFloatingWindowsToFrontCurrentDesktop(
            on: model,
            flaggedOnly: true,
            reason: .autoTransition,
            bypassCooldown: false
        )
    }

    func enforceKeepOnTopPoliciesIfNeeded(
        on model: AppModel,
        snapshot: LiveStateSnapshot
    ) async {
        guard model.keepOnTopEnforcementEnabled else { return }
        guard snapshot.source == .yabai, !snapshot.degraded else { return }
        let hasKeepOnTopPolicy = model.appForegroundPolicyByName.values.contains(.keepFrontWhenFloating)
        guard hasKeepOnTopPolicy else { return }
        await bringFloatingWindowsToFrontCurrentDesktop(
            on: model,
            flaggedOnly: true,
            reason: .autoEnforce,
            bypassCooldown: false
        )
    }

    func bringFloatingWindowsToFrontCurrentDesktop(
        on model: AppModel,
        flaggedOnly: Bool,
        reason: AppModel.FloatingBringReason,
        bypassCooldown: Bool
    ) async {
        guard model.canRunYabaiRuntimeCommands else {
            if reason == .manualAll || reason == .manualFlagged {
                model.lastErrorMessage = model.yabaiRuntimeControlDisabledReason ?? "Window controls are unavailable right now."
                model.lastActionMessage = nil
            }
            return
        }
        guard let snapshot = model.liveStateSnapshot, snapshot.source == .yabai, !snapshot.degraded else {
            if reason == .manualAll || reason == .manualFlagged {
                model.lastErrorMessage = "Live window mapping is not precise right now."
                model.lastActionMessage = nil
            }
            return
        }

        let activeSpace = model.activeSpaceIndex(in: snapshot)
        let candidates = candidateFloatingWindows(
            on: model,
            in: snapshot,
            activeSpace: activeSpace,
            flaggedOnly: flaggedOnly,
            requireRuntimeManageable: false
        )
        let candidateIDs = Set(candidates.map(\.id))
        keepOnTopOcclusionActiveByWindowID = keepOnTopOcclusionActiveByWindowID.filter { candidateIDs.contains($0.key) }
        lastKeepOnTopAutoAttemptAtByWindowID = lastKeepOnTopAutoAttemptAtByWindowID.filter { candidateIDs.contains($0.key) }

        guard !candidates.isEmpty else {
            if reason == .manualAll {
                model.lastActionMessage = "No floating windows on the current desktop."
                model.lastErrorMessage = nil
            } else if reason == .manualFlagged {
                model.lastActionMessage = "No flagged floating windows on the current desktop."
                model.lastErrorMessage = nil
            }
            return
        }

        var raisedCount = 0
        let useAccessibilityRaise = AXIsProcessTrusted()
        let isAutomaticReason = (reason == .autoTransition || reason == .autoEnforce || reason == .floatToggle)
        for window in candidates {
            if isAutomaticReason {
                let isOccluded = isWindowLikelyOccluded(on: model, window)
                let wasOccluded = keepOnTopOcclusionActiveByWindowID[window.id] ?? false
                keepOnTopOcclusionActiveByWindowID[window.id] = isOccluded
                if !isOccluded { continue }
                if window.focused { continue }
                if wasOccluded {
                    let now = Date()
                    if let lastAttempt = lastKeepOnTopAutoAttemptAtByWindowID[window.id],
                       now.timeIntervalSince(lastAttempt) < keepOnTopAutoRetrySeconds {
                        continue
                    }
                    lastKeepOnTopAutoAttemptAtByWindowID[window.id] = now
                } else {
                    lastKeepOnTopAutoAttemptAtByWindowID[window.id] = Date()
                }
            }

            if useAccessibilityRaise {
                let axRaised = raiseWindowUsingAccessibilityDirectly(on: model, windowID: window.id, bypassCooldown: bypassCooldown)
                let stillOccluded = isWindowLikelyOccluded(on: model, window)
                if axRaised && !stillOccluded {
                    raisedCount += 1
                } else if await focusWindowForKeepOnTop(on: model, windowID: window.id, targetSpace: window.space, bypassCooldown: bypassCooldown) {
                    raisedCount += 1
                }
                continue
            }

            if await focusWindowForKeepOnTop(on: model, windowID: window.id, targetSpace: window.space, bypassCooldown: bypassCooldown) {
                raisedCount += 1
            }
        }

        switch reason {
        case .manualAll:
            let desktopLabel = activeSpace.map { "Desktop \($0)" } ?? "current desktop"
            model.lastActionMessage = "Kept \(raisedCount) floating window(s) on top on \(desktopLabel)."
            model.lastErrorMessage = nil
        case .manualFlagged:
            let desktopLabel = activeSpace.map { "Desktop \($0)" } ?? "current desktop"
            model.lastActionMessage = "Kept \(raisedCount) flagged floating window(s) on top on \(desktopLabel)."
            model.lastErrorMessage = nil
        case .autoTransition, .floatToggle, .autoEnforce:
            break
        }
    }

    func raiseWindowOnly(
        on model: AppModel,
        windowID: Int,
        targetSpace: Int?,
        bypassCooldown: Bool = false,
        allowFocusFallback: Bool = false
    ) async -> Bool {
        let now = Date()
        if !bypassCooldown,
           let lastRaisedAt = lastRaisedAtByWindowID[windowID],
           now.timeIntervalSince(lastRaisedAt) < raiseCooldownSeconds {
            return false
        }

        if allowFocusFallback, AXIsProcessTrusted(),
           raiseWindowUsingAccessibility(on: model, windowID: windowID) {
            if isWindowLikelyOccludedAfterRaise(on: model, windowID: windowID),
               let targetSpace,
               let currentSpace = await model.queryCurrentFocusedSpaceIndex(),
               currentSpace == targetSpace {
                let focus = await model.doctorService.runSupportCommand(
                    yabaiCommand(["-m", "window", "--focus", String(windowID)], timeout: 1.5)
                )
                model.appendCommandLog(from: focus)
                guard focus.isSuccess else { return false }
            }
            lastRaisedAtByWindowID[windowID] = now
            return true
        }

        let raise = await model.doctorService.runSupportCommand(
            yabaiCommand(["-m", "window", String(windowID), "--raise"], timeout: 1.5)
        )
        model.appendCommandLog(from: raise)
        if !raise.isSuccess {
            if raiseWindowUsingAccessibility(on: model, windowID: windowID) {
                if allowFocusFallback,
                   isWindowLikelyOccludedAfterRaise(on: model, windowID: windowID),
                   let targetSpace,
                   let currentSpace = await model.queryCurrentFocusedSpaceIndex(),
                   currentSpace == targetSpace {
                    let focus = await model.doctorService.runSupportCommand(
                        yabaiCommand(["-m", "window", "--focus", String(windowID)], timeout: 1.5)
                    )
                    model.appendCommandLog(from: focus)
                    guard focus.isSuccess else { return false }
                }
                lastRaisedAtByWindowID[windowID] = now
                return true
            }
            guard allowFocusFallback, isScriptingAdditionRaiseFailure(raise) else {
                return false
            }
            if let targetSpace,
               let currentSpace = await model.queryCurrentFocusedSpaceIndex(),
               currentSpace != targetSpace {
                return false
            }
            let focus = await model.doctorService.runSupportCommand(
                yabaiCommand(["-m", "window", "--focus", String(windowID)], timeout: 1.5)
            )
            model.appendCommandLog(from: focus)
            guard focus.isSuccess else { return false }
            lastRaisedAtByWindowID[windowID] = now
            return true
        }

        lastRaisedAtByWindowID[windowID] = now
        return true
    }

    func raiseWindowUsingAccessibilityOnly(
        on model: AppModel,
        windowID: Int,
        bypassCooldown: Bool = false
    ) -> Bool {
        raiseWindowUsingAccessibilityDirectly(on: model, windowID: windowID, bypassCooldown: bypassCooldown)
    }

    func bringWindowToFront(on model: AppModel, windowID: Int) async {
        _ = await raiseWindowOnly(on: model, windowID: windowID, targetSpace: nil, bypassCooldown: true, allowFocusFallback: true)

        let focus = await model.doctorService.runSupportCommand(
            yabaiCommand(["-m", "window", "--focus", String(windowID)], timeout: 1.5)
        )
        model.appendCommandLog(from: focus)
    }

    func isScriptingAdditionRaiseFailure(_ result: CommandResult) -> Bool {
        let text = "\(result.stderr)\n\(result.stdout)".lowercased()
        return text.contains("scripting-addition") || text.contains("scripting addition")
    }

    private func foregroundTransitionSnapshot(
        on model: AppModel,
        from snapshot: LiveStateSnapshot?
    ) -> (isEligible: Bool, activeSpace: Int?, visibleFlaggedFloatingWindowIDs: Set<Int>) {
        guard let snapshot, snapshot.source == .yabai, !snapshot.degraded else {
            return (false, nil, [])
        }
        let activeSpace = model.activeSpaceIndex(in: snapshot)
        let windows = candidateFloatingWindows(on: model, in: snapshot, activeSpace: activeSpace, flaggedOnly: true)
        return (true, activeSpace, Set(windows.map(\.id)))
    }

    private func candidateFloatingWindows(
        on model: AppModel,
        in snapshot: LiveStateSnapshot,
        activeSpace: Int?,
        flaggedOnly: Bool,
        requireRuntimeManageable: Bool = true
    ) -> [WindowState] {
        snapshot.windows.filter { window in
            guard window.floating else { return false }
            guard !window.isMinimized && !window.isHidden else { return false }
            if requireRuntimeManageable {
                guard window.isRuntimeManageable else { return false }
            }
            if let activeSpace, window.space != activeSpace { return false }
            if flaggedOnly && model.appForegroundPolicy(for: window.app) != .keepFrontWhenFloating {
                return false
            }
            return true
        }
        .sorted { lhs, rhs in
            let lhsArea = lhs.frameW * lhs.frameH
            let rhsArea = rhs.frameW * rhs.frameH
            if lhsArea != rhsArea { return lhsArea > rhsArea }
            return lhs.id < rhs.id
        }
    }

    private func raiseWindowUsingAccessibilityDirectly(
        on model: AppModel,
        windowID: Int,
        bypassCooldown: Bool
    ) -> Bool {
        let now = Date()
        if !bypassCooldown,
           let lastRaisedAt = lastRaisedAtByWindowID[windowID],
           now.timeIntervalSince(lastRaisedAt) < raiseCooldownSeconds {
            return false
        }
        guard raiseWindowUsingAccessibility(on: model, windowID: windowID) else { return false }
        lastRaisedAtByWindowID[windowID] = now
        return true
    }

    private func focusWindowForKeepOnTop(
        on model: AppModel,
        windowID: Int,
        targetSpace: Int?,
        bypassCooldown: Bool
    ) async -> Bool {
        let now = Date()
        if !bypassCooldown,
           let lastRaisedAt = lastRaisedAtByWindowID[windowID],
           now.timeIntervalSince(lastRaisedAt) < raiseCooldownSeconds {
            return false
        }

        if let targetSpace,
           let currentSpace = await model.queryCurrentFocusedSpaceIndex(),
           currentSpace != targetSpace {
            return false
        }

        let focus = await model.doctorService.runSupportCommand(
            yabaiCommand(["-m", "window", "--focus", String(windowID)], timeout: 1.5)
        )
        model.appendCommandLog(from: focus)
        guard focus.isSuccess else { return false }
        lastRaisedAtByWindowID[windowID] = now
        return true
    }

    private func isWindowLikelyOccludedAfterRaise(on model: AppModel, windowID: Int) -> Bool {
        guard let window = (model.latestLiveStateSnapshot ?? model.liveStateSnapshot)?.windows.first(where: { $0.id == windowID }) else {
            return false
        }
        return isWindowLikelyOccluded(on: model, window)
    }

    private func isWindowLikelyOccluded(on model: AppModel, _ window: WindowState) -> Bool {
        let targetRect = CGRect(x: window.frameX, y: window.frameY, width: window.frameW, height: window.frameH)
        guard targetRect.width > 1, targetRect.height > 1 else { return false }

        guard let windowInfo = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              !windowInfo.isEmpty else {
            return false
        }

        let appPID = ProcessInfo.processInfo.processIdentifier
        let targetWindowNumber = UInt32(window.id)
        let normalizedTitle = window.title.trimmingCharacters(in: .whitespacesAndNewlines)
        var targetIndex: Int?
        var targetBounds: CGRect?
        var fallbackIndex: Int?
        var fallbackBounds: CGRect?

        for (index, info) in windowInfo.enumerated() {
            guard (info[kCGWindowLayer as String] as? Int ?? -1) == 0 else { continue }
            let ownerPID = (info[kCGWindowOwnerPID as String] as? NSNumber)?.intValue ?? -1
            guard ownerPID == window.pid else { continue }
            guard let bounds = cgWindowBounds(from: info) else { continue }
            if !bounds.intersects(targetRect) { continue }
            if let windowNumber = info[kCGWindowNumber as String] as? UInt32,
               windowNumber == targetWindowNumber {
                targetIndex = index
                targetBounds = bounds
                break
            }
            if !normalizedTitle.isEmpty {
                let cgTitle = (info[kCGWindowName as String] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !cgTitle.isEmpty && cgTitle != normalizedTitle {
                    continue
                }
            }
            if fallbackIndex == nil {
                fallbackIndex = index
                fallbackBounds = bounds
            }
        }

        if targetIndex == nil {
            let targetArea = max(1.0, targetRect.width * targetRect.height)
            for info in windowInfo {
                let layer = info[kCGWindowLayer as String] as? Int ?? -1
                guard layer == 0 else { continue }
                if let alpha = info[kCGWindowAlpha as String] as? Double, alpha <= 0.01 { continue }
                if windowInfoEntryShouldBeIgnoredForOcclusion(info, appPID: appPID) { continue }
                guard let bounds = cgWindowBounds(from: info) else { continue }
                let overlap = bounds.intersection(targetRect)
                if overlap.isNull || overlap.width <= 1 || overlap.height <= 1 { continue }
                let overlapRatio = (overlap.width * overlap.height) / targetArea
                if overlapRatio > 0.12 {
                    return true
                }
            }
            targetIndex = fallbackIndex
            targetBounds = fallbackBounds
        }
        guard let index = targetIndex, let targetBounds else { return false }
        let targetArea = max(1.0, targetBounds.width * targetBounds.height)

        for i in 0 ..< index {
            let info = windowInfo[i]
            let layer = info[kCGWindowLayer as String] as? Int ?? -1
            guard layer == 0 else { continue }
            if let alpha = info[kCGWindowAlpha as String] as? Double, alpha <= 0.01 { continue }
            if windowInfoEntryShouldBeIgnoredForOcclusion(info, appPID: appPID) { continue }
            guard let bounds = cgWindowBounds(from: info) else { continue }
            let overlap = bounds.intersection(targetBounds)
            if overlap.isNull || overlap.width <= 1 || overlap.height <= 1 { continue }
            let overlapRatio = (overlap.width * overlap.height) / targetArea
            if overlapRatio > 0.12 {
                return true
            }
        }
        return false
    }

    private func windowInfoEntryShouldBeIgnoredForOcclusion(_ info: [String: Any], appPID: Int32) -> Bool {
        let ownerPID = (info[kCGWindowOwnerPID as String] as? NSNumber)?.intValue ?? -1
        let owner = (info[kCGWindowOwnerName as String] as? String ?? "").lowercased()
        let name = (info[kCGWindowName as String] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let isWorkSetBackdropSurface = ownerPID == appPID && owner == "tilepilot" && name.isEmpty
        if ownerPID == appPID && !isWorkSetBackdropSurface {
            return true
        }
        if owner == "tilepilot" && !isWorkSetBackdropSurface {
            return true
        }
        return false
    }

    private func cgWindowBounds(from info: [String: Any]) -> CGRect? {
        if let dict = info[kCGWindowBounds as String] as? NSDictionary,
           let rect = CGRect(dictionaryRepresentation: dict) {
            return rect
        }
        return nil
    }

    private func raiseWindowUsingAccessibility(on model: AppModel, windowID: Int) -> Bool {
        guard let targetWindow = (model.latestLiveStateSnapshot ?? model.liveStateSnapshot)?.windows.first(where: { $0.id == windowID }) else { return false }

        let appElement = AXUIElementCreateApplication(pid_t(targetWindow.pid))
        var windowsRef: CFTypeRef?
        let windowsResult = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
        guard windowsResult == .success, let windows = windowsRef as? [AXUIElement], !windows.isEmpty else {
            return false
        }

        guard let selectedWindow = matchingAXWindow(for: targetWindow, in: windows) else {
            return false
        }

        return AXUIElementPerformAction(selectedWindow, kAXRaiseAction as CFString) == .success
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

        if let focusedWindow = windows.first(where: { axBoolValue($0, kAXFocusedAttribute as CFString) == true }) {
            return focusedWindow
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

    private func axFrameValue(_ element: AXUIElement) -> CGRect? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &value)
        guard result == .success, let positionRef = value else { return nil }
        let positionValue = positionRef as! AXValue

        var position = CGPoint.zero
        guard AXValueGetType(positionValue) == .cgPoint,
              AXValueGetValue(positionValue, .cgPoint, &position) else { return nil }

        var sizeRef: CFTypeRef?
        let sizeResult = AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef)
        guard sizeResult == .success, let sizeRawRef = sizeRef else { return nil }
        let sizeValue = sizeRawRef as! AXValue

        var size = CGSize.zero
        guard AXValueGetType(sizeValue) == .cgSize,
              AXValueGetValue(sizeValue, .cgSize, &size) else { return nil }

        return CGRect(origin: position, size: size)
    }
}
