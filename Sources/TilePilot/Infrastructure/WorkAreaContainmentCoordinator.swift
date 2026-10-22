import AppKit
import Foundation

/// Keeps floating windows inside each display's Work Area. Corrections run after live-state
/// refreshes and right after a mouse drag ends, never while the left mouse button is held.
@MainActor
final class WorkAreaContainmentCoordinator {
    private static let cooldownSeconds: TimeInterval = 30
    private static let retryDelayMilliseconds = 200
    private static let mouseUpDelayMilliseconds = 250
    /// Double-clicking a title bar zooms the window with a short animation; check after it settles
    /// and once more in case the app animates slowly.
    private static let doubleClickDelaysMilliseconds = [450, 1200]
    private static let dragPressSeconds: TimeInterval = 0.15

    private var cooldownUntilByWindowID: [Int: Date] = [:]
    private var isEnforcing = false
    private var mouseMonitor: Any?
    private var mouseDownAt: Date?
    private var sawDragSinceMouseDown = false
    private var mouseUpRefreshTask: Task<Void, Never>?

    private struct PendingFit {
        let window: WindowState
        let frame: CGRect
        let target: CGRect
        let workArea: CGRect
        let entry: WorkAreaUnfitWindow
    }

    private var isLeftMouseButtonDown: Bool {
        NSEvent.pressedMouseButtons & 0x1 != 0
    }

    func enforce(on model: AppModel, snapshot: LiveStateSnapshot) async {
        guard model.hasActiveWorkAreaContainment else {
            cooldownUntilByWindowID = [:]
            model.updateWorkAreaUnfitWindows([])
            return
        }
        guard !isEnforcing, !isLeftMouseButtonDown else { return }
        isEnforcing = true
        defer { isEnforcing = false }

        let ownPID = Int(ProcessInfo.processInfo.processIdentifier)
        let visibleSpaces = Set(snapshot.spaces.filter(\.visible).map(\.index))
        let layoutBySpace = Dictionary(
            snapshot.spaces.map { ($0.index, ($0.layout ?? "").lowercased()) },
            uniquingKeysWith: { first, _ in first }
        )
        var previousFrames: [Int: CGRect] = [:]
        var unfit: [WorkAreaUnfitWindow] = []
        var seenWindowIDs = Set<Int>()
        var pending: [PendingFit] = []

        for display in snapshot.displays {
            guard let configuration = model.workAreaConfiguration(for: display),
                  configuration.enabled,
                  configuration.containmentEnabled,
                  let workArea = model.resolvedWorkArea(for: display) else {
                continue
            }

            for window in snapshot.windows where window.display == display.id {
                guard window.pid != ownPID,
                      Self.isCandidate(
                          window,
                          configuration: configuration,
                          visibleSpaces: visibleSpaces,
                          spaceLayout: layoutBySpace[window.space] ?? "float",
                          allowedWindowIDs: model.workAreaSessionAllowedWindowIDs
                      ) else {
                    continue
                }
                seenWindowIDs.insert(window.id)

                let frame = CGRect(x: window.frameX, y: window.frameY, width: window.frameW, height: window.frameH)
                guard let target = WorkAreaGeometry.containedFrame(
                    windowFrame: frame,
                    workArea: workArea,
                    canResize: window.canResize
                ) else {
                    cooldownUntilByWindowID.removeValue(forKey: window.id)
                    continue
                }

                let entry = WorkAreaUnfitWindow(
                    windowID: window.id,
                    app: window.app,
                    title: window.title,
                    displayID: display.id
                )
                if let until = cooldownUntilByWindowID[window.id], until > Date() {
                    unfit.append(entry)
                    continue
                }
                pending.append(PendingFit(window: window, frame: frame, target: target, workArea: workArea, entry: entry))
            }
        }

        // Snapshot frames come from the window server. Mission Control, App Exposé, and Show
        // Desktop (and their animations) move and scale those without moving the windows, so
        // acting on them would shrink or nudge real windows. Check each window's real frame
        // first; when some cannot be read and the window server looks transformed, skip the pass.
        let realFrames = pending.isEmpty ? [:] : await model.workAreaAccessibilityFrames(for: pending.map(\.window))
        if pending.contains(where: { realFrames[$0.window.id] == nil }),
           await model.workAreaWindowServerFramesLookTransformed(
               snapshot: snapshot,
               visibleSpaces: visibleSpaces,
               knownRealFrames: realFrames
           ) {
            return
        }

        for item in pending {
            // The user grabbed a window while this pass was running; let them finish first.
            if isLeftMouseButtonDown { break }
            var frame = item.frame
            var target = item.target
            if let realFrame = realFrames[item.window.id] {
                // Inside after all: the window server was showing it somewhere else.
                guard let realTarget = WorkAreaGeometry.containedFrame(
                    windowFrame: realFrame,
                    workArea: item.workArea,
                    canResize: item.window.canResize
                ) else {
                    continue
                }
                frame = realFrame
                target = realTarget
            }
            var fitted = await model.moveWindowForWorkArea(item.window, to: target, acceptableArea: item.workArea)
            if !fitted {
                try? await Task.sleep(for: .milliseconds(Self.retryDelayMilliseconds))
                if isLeftMouseButtonDown { break }
                fitted = await model.moveWindowForWorkArea(item.window, to: target, acceptableArea: item.workArea)
            }

            if fitted {
                previousFrames[item.window.id] = frame
                cooldownUntilByWindowID.removeValue(forKey: item.window.id)
            } else {
                cooldownUntilByWindowID[item.window.id] = Date().addingTimeInterval(Self.cooldownSeconds)
                unfit.append(item.entry)
            }
        }

        let now = Date()
        cooldownUntilByWindowID = cooldownUntilByWindowID.filter { seenWindowIDs.contains($0.key) && $0.value > now }
        model.recordWorkAreaFitBatch(previousFrames)
        model.updateWorkAreaUnfitWindows(unfit)
    }

    static func isCandidate(
        _ window: WindowState,
        configuration: WorkAreaConfiguration,
        visibleSpaces: Set<Int>,
        spaceLayout: String,
        allowedWindowIDs: Set<Int>
    ) -> Bool {
        guard window.isVisible,
              !window.isMinimized,
              !window.isHidden,
              !window.isNativeFullscreen,
              Self.canTryToMove(window),
              window.frameW > 1,
              window.frameH > 1,
              visibleSpaces.contains(window.space),
              !allowedWindowIDs.contains(window.id),
              !configuration.excludesApp(window.app),
              RecentWindowTilerInventoryPolicy.supportsRole(role: window.role, subrole: window.subrole) else {
            return false
        }
        // yabai already keeps tiled windows inside the Work Area through desktop padding.
        let isTiled = !window.floating && spaceLayout != "float"
        return !isTiled
    }

    /// yabai reports "can't move" both for fixed windows and for windows it has lost track of
    /// (no Accessibility reference, which happens when it restarts while the Mac is locked).
    /// The second kind is on screen and TilePilot can still move it through Accessibility.
    static func canTryToMove(_ window: WindowState) -> Bool {
        window.canMove || (!window.hasAXReference && window.hasWindowServerMatch)
    }

    func updateMouseMonitor(on model: AppModel, needed: Bool) {
        if needed {
            guard mouseMonitor == nil else { return }
            mouseMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
            ) { [weak self, weak model] event in
                let type = event.type
                let clickCount = event.type == .leftMouseUp ? event.clickCount : 0
                MainActor.assumeIsolated {
                    guard let self, let model else { return }
                    self.handleMouseEvent(type, clickCount: clickCount, model: model)
                }
            }
        } else if let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMonitor = nil
            mouseUpRefreshTask?.cancel()
            mouseUpRefreshTask = nil
            mouseDownAt = nil
            sawDragSinceMouseDown = false
        }
    }

    private func handleMouseEvent(_ type: NSEvent.EventType, clickCount: Int, model: AppModel) {
        switch type {
        case .leftMouseDown:
            mouseDownAt = Date()
            sawDragSinceMouseDown = false
        case .leftMouseDragged:
            sawDragSinceMouseDown = true
        case .leftMouseUp:
            let heldLongEnough = mouseDownAt.map { Date().timeIntervalSince($0) >= Self.dragPressSeconds } ?? true
            let isDoubleClick = clickCount >= 2
            let shouldCheck = sawDragSinceMouseDown || heldLongEnough || isDoubleClick
            mouseDownAt = nil
            sawDragSinceMouseDown = false
            guard shouldCheck else { return }
            let delays = isDoubleClick ? Self.doubleClickDelaysMilliseconds : [Self.mouseUpDelayMilliseconds]
            mouseUpRefreshTask?.cancel()
            mouseUpRefreshTask = Task { [weak model] in
                var elapsed = 0
                for delay in delays {
                    try? await Task.sleep(for: .milliseconds(delay - elapsed))
                    elapsed = delay
                    guard let model, !Task.isCancelled else { return }
                    model.scheduleWorkAreaApply(delayMilliseconds: 0)
                }
            }
        default:
            break
        }
    }
}
