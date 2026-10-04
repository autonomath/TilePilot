import AppKit
import Combine
import CoreGraphics
import SwiftUI

@MainActor
final class WindowBadgeOverlayController {
    private final class BadgePanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private final class OutlinePanelView: NSView {
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.backgroundColor = NSColor.clear.cgColor
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func update(strokeColor: NSColor, lineWidth: CGFloat) {
            wantsLayer = true
            layer?.backgroundColor = NSColor.clear.cgColor
            layer?.borderColor = strokeColor.withAlphaComponent(0.85).cgColor
            layer?.borderWidth = lineWidth
            layer?.cornerRadius = 0
        }
    }

    private struct OverlayUpdateSignature: Equatable {
        let showBadges: Bool
        let showOutlines: Bool
        let outlineBaseWidth: Double
        let tiledOverlayAccentColor: OverlayAccentColor
        let floatingOverlayAccentColor: OverlayAccentColor
        let refreshPolicy: OverlayRefreshPolicy
        let badgeTargets: [WindowBadgeState]
        let outlineTargets: [WindowBadgeState]
    }

    private let model: AppModel
    private var cancellables: Set<AnyCancellable> = []
    private var badgePanels: [Int: BadgePanel] = [:]
    private var outlinePanels: [Int: BadgePanel] = [:]
    private var pendingBadges: [WindowBadgeState] = []
    private var pendingSignature: OverlayUpdateSignature?
    private var appliedSignature: OverlayUpdateSignature?
    private var scheduledUpdate: DispatchWorkItem?

    init(model: AppModel) {
        self.model = model
        bind()
    }

    private func bind() {
        model.windowBadgesSubject
            .receive(on: RunLoop.main)
            .sink { [weak self] badges in
                self?.scheduleOverlayUpdate(with: badges)
            }
            .store(in: &cancellables)

        model.$showWindowBadgeOverlay
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.scheduleOverlayUpdate(with: self.pendingBadges)
            }
            .store(in: &cancellables)

        model.$showWindowOutlineOverlay
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.scheduleOverlayUpdate(with: self.pendingBadges)
            }
            .store(in: &cancellables)

        model.$windowOutlineOverlayBaseWidth
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.scheduleOverlayUpdate(with: self.pendingBadges)
            }
            .store(in: &cancellables)

        model.$tiledOverlayAccentColor
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.scheduleOverlayUpdate(with: self.pendingBadges)
            }
            .store(in: &cancellables)

        model.$floatingOverlayAccentColor
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.scheduleOverlayUpdate(with: self.pendingBadges)
            }
            .store(in: &cancellables)

        model.windowBadgeOverlayRefreshSubject
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.invalidateAndReapplyOverlays()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.invalidateAndReapplyOverlays()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.scheduleOverlayUpdate(with: self.pendingBadges.isEmpty ? self.model.windowBadges : self.pendingBadges)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.scheduleOverlayUpdate(with: self.pendingBadges.isEmpty ? self.model.windowBadges : self.pendingBadges)
            }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.invalidateAndReapplyOverlays()
            }
            .store(in: &cancellables)
    }

    private func scheduleOverlayUpdate(with badges: [WindowBadgeState]) {
        pendingBadges = badges
        let signature = makeSignature(from: badges)
        let badgePanelsMissing = signature.showBadges && badgePanels.count != signature.badgeTargets.count
        let outlinePanelsMissing = signature.showOutlines && outlinePanels.count != signature.outlineTargets.count
        let needsRebuild = badgePanelsMissing || outlinePanelsMissing
        if !needsRebuild && (signature == pendingSignature || signature == appliedSignature) {
            return
        }
        pendingSignature = signature
        scheduledUpdate?.cancel()

        let work = DispatchWorkItem { [weak self] in
            self?.applyOverlayUpdate(self?.pendingBadges ?? [])
        }
        scheduledUpdate = work
        let delay: TimeInterval
        switch model.overlayRefreshPolicy {
        case .full:
            delay = 0.05
        case .reduced:
            delay = 0.40
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func invalidateAndReapplyOverlays() {
        pendingSignature = nil
        appliedSignature = nil
        let badges = pendingBadges.isEmpty ? model.windowBadges : pendingBadges
        scheduleOverlayUpdate(with: badges)
    }

    private func applyOverlayUpdate(_ badges: [WindowBadgeState]) {
        let signature = makeSignature(from: badges)
        if signature == appliedSignature {
            return
        }
        pendingSignature = nil
        appliedSignature = signature
        model.incrementOverlayPanelUpdates()
        let targetIDs = Set(signature.outlineTargets.map(\.windowID))
        let badgeTargetIDs = Set(signature.badgeTargets.map(\.windowID))
        model.setHasVisibleWindowBadgePanels(!targetIDs.isEmpty || !badgeTargetIDs.isEmpty)

        if signature.showBadges {
            removeStalePanels(from: &badgePanels, keepIDs: badgeTargetIDs)
            for badge in signature.badgeTargets {
                let panel = badgePanels[badge.windowID] ?? createPanel(ignoresMouseEvents: false, level: .floating)
                badgePanels[badge.windowID] = panel
                updateBadgePanel(panel: panel, with: badge)
            }
        } else {
            closeAllPanels(from: &badgePanels)
        }

        if signature.showOutlines {
            removeStalePanels(from: &outlinePanels, keepIDs: targetIDs)
            for badge in signature.outlineTargets {
                let panel = outlinePanels[badge.windowID] ?? createPanel(ignoresMouseEvents: true, level: .normal)
                outlinePanels[badge.windowID] = panel
                updateOutlinePanel(panel: panel, with: badge)
            }
        } else {
            closeAllPanels(from: &outlinePanels)
        }
    }

    private func makeSignature(from badges: [WindowBadgeState]) -> OverlayUpdateSignature {
        let policy = model.overlayRefreshPolicy
        return OverlayUpdateSignature(
            showBadges: model.showWindowBadgeOverlay,
            showOutlines: model.showWindowOutlineOverlay,
            outlineBaseWidth: model.windowOutlineOverlayBaseWidth,
            tiledOverlayAccentColor: model.tiledOverlayAccentColor,
            floatingOverlayAccentColor: model.floatingOverlayAccentColor,
            refreshPolicy: policy,
            badgeTargets: model.showWindowBadgeOverlay ? normalized(badgeTargets(from: badges), for: policy) : [],
            outlineTargets: model.showWindowOutlineOverlay ? badges : []
        )
    }

    private func normalized(_ badges: [WindowBadgeState], for policy: OverlayRefreshPolicy) -> [WindowBadgeState] {
        guard policy == .reduced else { return badges }
        return badges.map { badge in
            let quantum = 14.0
            return WindowBadgeState(
                windowID: badge.windowID,
                pid: badge.pid,
                app: badge.app,
                title: badge.title,
                isFloating: badge.isFloating,
                isFocused: badge.isFocused,
                isRuntimeManageable: badge.isRuntimeManageable,
                usesLimitedVisualStyle: badge.usesLimitedVisualStyle,
                frameX: rounded(badge.frameX, quantum: quantum),
                frameY: rounded(badge.frameY, quantum: quantum),
                frameW: rounded(badge.frameW, quantum: quantum),
                frameH: rounded(badge.frameH, quantum: quantum)
            )
        }
    }

    private func rounded(_ value: Double, quantum: Double) -> Double {
        (value / quantum).rounded() * quantum
    }

    private func badgeTargets(from badges: [WindowBadgeState]) -> [WindowBadgeState] {
        guard !NSApp.isActive else { return [] }
        guard let focused = badges.first(where: \.isFocused) else { return [] }

        // Some apps (including Zoom) can transiently focus tiny helper/tool windows.
        // Keep focused-window-only behavior, but anchor the badge on the main same-app window.
        let focusedArea = focused.frameW * focused.frameH
        let helperAreaThreshold = 7_500.0 // roughly <= 120x60
        guard focusedArea < helperAreaThreshold else { return [focused] }

        let sameProcessCandidates = badges
            .filter { $0.pid == focused.pid && $0.windowID != focused.windowID }
            .sorted { ($0.frameW * $0.frameH) > ($1.frameW * $1.frameH) }

        guard let mainCandidate = sameProcessCandidates.first else { return [focused] }
        let mainArea = mainCandidate.frameW * mainCandidate.frameH
        if mainArea > focusedArea * 3.0 {
            return [mainCandidate]
        }
        return [focused]
    }

    private func removeStalePanels(from panels: inout [Int: BadgePanel], keepIDs: Set<Int>) {
        for (windowID, panel) in panels where !keepIDs.contains(windowID) {
            dispose(panel)
            panels.removeValue(forKey: windowID)
        }
    }

    private func closeAllPanels(from panels: inout [Int: BadgePanel]) {
        for (_, panel) in panels {
            dispose(panel)
        }
        panels.removeAll()
    }

    private func dispose(_ panel: BadgePanel) {
        panel.contentView = nil
        panel.orderOut(nil)
        panel.close()
    }

    private func createPanel(ignoresMouseEvents: Bool, level: NSWindow.Level) -> BadgePanel {
        let frame = NSRect(origin: .zero, size: NSSize(width: 60, height: 14))
        let panel = BadgePanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = ignoresMouseEvents
        panel.hidesOnDeactivate = false
        panel.isExcludedFromWindowsMenu = true
        panel.collectionBehavior = [
            .fullScreenAuxiliary,
            .moveToActiveSpace,
            .ignoresCycle,
            .transient,
            .stationary,
        ]
        panel.level = level
        panel.contentView = NSHostingView(rootView: AnyView(EmptyView()))
        return panel
    }

    private func setPanelRootView(_ panel: BadgePanel, _ view: AnyView) {
        if let host = panel.contentView as? NSHostingView<AnyView> {
            host.rootView = view
        } else {
            panel.contentView = NSHostingView(rootView: view)
        }
    }

    private func updateBadgePanel(panel: BadgePanel, with badge: WindowBadgeState) {
        let targetWindowRect = resolvedGlobalRect(for: badge)
        let hostScreen = bestScreen(for: targetWindowRect)
        let scale = max(1.0, hostScreen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1.0)

        let screenWidth = max(1200, hostScreen?.frame.width ?? 1800)
        let widthFactor = min(1.35, max(0.9, screenWidth / 1800.0))
        let baseBadgeWidth: CGFloat = scale >= 2.0 ? 52 : 48
        let baseBadgeHeight: CGFloat = scale >= 2.0 ? 11 : 10
        let badgeWidth: CGFloat = round(baseBadgeWidth * widthFactor * 0.8)   // 20% narrower
        let badgeHeight: CGFloat = round(baseBadgeHeight * widthFactor * 0.9) // 10% shorter
        let topInset: CGFloat = -5 // move badge 5px higher
        let leftInset: CGFloat = 12 // +10px right from previous position

        var x = targetWindowRect.minX + leftInset
        var y = targetWindowRect.maxY - badgeHeight - topInset

        if let screen = hostScreen {
            x = max(screen.frame.minX + 2, min(x, screen.frame.maxX - badgeWidth - 2))
            y = max(screen.frame.minY + 2, min(y, screen.frame.maxY - badgeHeight - 2))
        }

        let rootView = WindowBadgeView(
            model: model,
            badge: badge,
            badgeWidth: badgeWidth,
            badgeHeight: badgeHeight
        )
        panel.ignoresMouseEvents = false
        setPanelRootView(panel, AnyView(rootView))
        panel.setFrame(NSRect(x: x, y: y, width: badgeWidth, height: badgeHeight), display: true)
        panel.orderFront(nil)
    }

    private func updateOutlinePanel(panel: BadgePanel, with badge: WindowBadgeState) {
        let targetWindowRect = resolvedGlobalRect(for: badge)
        let hostScreen = bestScreen(for: targetWindowRect)
        let scale = max(1.0, hostScreen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1.0)
        let lineWidth: CGFloat = CGFloat(model.windowOutlineOverlayBaseWidth / scale)
        let outlineRect = targetWindowRect.integral
        let strokeColor: NSColor = badge.usesLimitedVisualStyle
            ? .gray
            : (badge.isFloating ? model.floatingOverlayAccentColor.nsColor : model.tiledOverlayAccentColor.nsColor)
        let outlineView: OutlinePanelView
        if let existing = panel.contentView as? OutlinePanelView {
            outlineView = existing
        } else {
            outlineView = OutlinePanelView(frame: outlineRect)
            panel.contentView = outlineView
        }
        outlineView.frame = NSRect(origin: .zero, size: outlineRect.size)
        outlineView.update(strokeColor: strokeColor, lineWidth: lineWidth)
        panel.ignoresMouseEvents = true
        panel.setFrame(outlineRect, display: true)
        if let windowNumber = targetWindowNumber(for: badge, targetWindowRect: targetWindowRect) {
            panel.order(.above, relativeTo: Int(windowNumber))
        } else {
            panel.orderFront(nil)
        }
    }

    private func resolvedGlobalRect(for badge: WindowBadgeState) -> CGRect {
        convertTopOriginRectToAppKit(badge.frame)
    }

    private func bestScreen(for rect: CGRect) -> NSScreen? {
        var best: NSScreen?
        var bestArea: CGFloat = 0
        for screen in NSScreen.screens {
            let intersection = rect.intersection(screen.frame)
            if intersection.isNull || intersection.isEmpty { continue }
            let area = intersection.width * intersection.height
            if area > bestArea {
                bestArea = area
                best = screen
            }
        }
        return best
    }

    private func convertTopOriginRectToAppKit(_ rect: CGRect) -> CGRect {
        let screens = NSScreen.screens
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

    private func targetWindowNumber(for badge: WindowBadgeState, targetWindowRect: CGRect) -> CGWindowID? {
        guard let rawInfo = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              !rawInfo.isEmpty else {
            return nil
        }

        var bestNumber: CGWindowID?
        var bestScore: CGFloat = .greatestFiniteMagnitude

        for entry in rawInfo {
            guard let ownerPID = entry[kCGWindowOwnerPID as String] as? Int,
                  ownerPID == badge.pid,
                  let layer = entry[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let number = entry[kCGWindowNumber as String] as? UInt32,
                  let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary else {
                continue
            }
            guard let cgRect = CGRect(dictionaryRepresentation: boundsDict) else { continue }

            // CGWindow bounds are top-origin; convert to AppKit coordinates before scoring.
            let rect = convertTopOriginRectToAppKit(cgRect)
            if rect.isEmpty { continue }
            let dx = abs(rect.minX - targetWindowRect.minX)
            let dy = abs(rect.minY - targetWindowRect.minY)
            let dw = abs(rect.width - targetWindowRect.width)
            let dh = abs(rect.height - targetWindowRect.height)
            let score = (dx * 2.0) + (dy * 2.0) + dw + dh
            if score < bestScore {
                bestScore = score
                bestNumber = CGWindowID(number)
            }
        }
        return bestNumber
    }
}
