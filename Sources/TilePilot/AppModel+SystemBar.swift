import AppKit
import CoreGraphics
import Foundation

/// System Bar glue: where the mirrored menu bar goes for each display, its settings, and the
/// hand-off to `SystemBarController` on every live-state refresh.
@MainActor
extension AppModel {
    static func primaryScreenMaxY() -> CGFloat {
        let screens = NSScreen.screens
        return screens.first(where: { abs($0.frame.minX) < 0.5 && abs($0.frame.minY) < 0.5 })?.frame.maxY
            ?? NSScreen.main?.frame.maxY
            ?? screens.first?.frame.maxY
            ?? 0
    }

    /// The real menu bar window on this display, in yabai coordinates.
    func systemBarRealMenuBarFrame(for display: DisplayState) -> CGRect? {
        let displayFrame = workAreaDisplayFrame(for: display)
        return systemBarController.realMenuBarFrames().first { bar in
            bar.height <= 60 && !bar.intersection(displayFrame).isNull && bar.intersection(displayFrame).width > displayFrame.width / 2
        }
    }

    func systemBarHeight(for display: DisplayState) -> CGFloat {
        systemBarRealMenuBarFrame(for: display)?.height ?? WorkAreaGeometry.fallbackMenuBarHeight
    }

    /// The bar and the window area for a display whose Work Area shows the System Bar, in yabai
    /// coordinates. Nil when the Work Area or the bar is off.
    func resolvedSystemBarLayout(for display: DisplayState) -> SystemBarLayout? {
        guard let configuration = workAreaConfiguration(for: display),
              configuration.enabled,
              configuration.systemBarEnabled,
              let workArea = resolvedWorkAreaIgnoringSystemBar(for: display) else {
            return nil
        }
        let visible = workAreaVisibleFrame(for: display) ?? workAreaDisplayFrame(for: display)
        return WorkAreaGeometry.systemBarLayout(
            workArea: workArea,
            visibleFrame: visible,
            barHeight: systemBarHeight(for: display)
        )
    }

    var systemBarIconModeDescription: String {
        guard systemBarMatchingIconsEnabled else { return "Simplified" }
        guard megamapCaptureService.screenRecordingAuthorized() else { return "Simplified (Screen Recording is off)" }
        return systemBarController.isShowingAnyBar && !systemBarController.isMatchingIconsActive ? "Matching (starting…)" : "Matching"
    }

    // MARK: - Settings

    func setSystemBarEnabled(_ enabled: Bool, for display: DisplayState) {
        let index = ensureWorkAreaConfigurationIndexForSystemBar(for: display)
        workAreas[index].systemBarEnabled = enabled
        persistWorkAreas()
        lastActionMessage = enabled
            ? "Menu bar on for \(display.name). Menus and icons open at the top of the Work Area."
            : "Menu bar off for \(display.name)."
        lastErrorMessage = nil
        scheduleWorkAreaApply(delayMilliseconds: 0)
    }

    func setSystemBarMatchingIconsEnabled(_ enabled: Bool) {
        systemBarMatchingIconsEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: AppModel.systemBarMatchingIconsDefaultsKey)
        systemBarController.matchingIconsEnabled = enabled
        if enabled {
            systemBarController.resetCaptureFailures()
        }
    }

    func setSystemBarOtherDisplayIconsEnabled(_ enabled: Bool) {
        systemBarOtherDisplayIconsEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: AppModel.systemBarOtherDisplayIconsDefaultsKey)
        systemBarController.includeOtherDisplayIcons = enabled
    }

    /// Turns the menu bar on or off (nil toggles) for every saved Work Area. Used by the
    /// `tilepilot://internal/system-bar/on|off|toggle` route.
    func setSystemBarEnabledForAllWorkAreas(_ enabled: Bool?) {
        guard !workAreas.isEmpty else {
            lastErrorMessage = "Set up a Work Area in the Work Area tab first."
            lastActionMessage = nil
            return
        }
        let target = enabled ?? !workAreas.contains { $0.enabled && $0.systemBarEnabled }
        for index in workAreas.indices {
            workAreas[index].systemBarEnabled = target
        }
        persistWorkAreas()
        lastActionMessage = target
            ? "Menu bar on. Menus and icons open at the top of the Work Area."
            : "Menu bar off."
        lastErrorMessage = nil
        scheduleWorkAreaApply(delayMilliseconds: 0)
    }

    /// Development aid behind the experimental flag: writes a text description of each bar (layout,
    /// menu titles, icon owners, capture state) to `/tmp/tilepilot-system-bar/status.txt`. No
    /// pixels are written.
    func writeSystemBarDiagnostics() {
        let directory = URL(fileURLWithPath: "/tmp/tilepilot-system-bar", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var text = systemBarController.diagnosticsSummary()
            text += "\nlast menu action: \(systemBarController.lastMenuActionSummary)"
            text += "\nmatching setting \(systemBarMatchingIconsEnabled); screen recording \(megamapCaptureService.screenRecordingAuthorized()); mode \(systemBarIconModeDescription)"
            text += "\nreal menu bars: \(systemBarController.realMenuBarFrames(maxAge: 0).map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" })"
            for display in workAreaDisplays {
                let layout = resolvedSystemBarLayout(for: display)
                text += "\ndisplay \(display.name) \(display.uuid ?? "?"): layout \(layout.map { "bar \($0.bar) window \($0.windowArea) above \($0.isAboveWorkArea)" } ?? "none")"
            }
            text += "\nwritten \(Date())\n"
            try text.write(to: directory.appendingPathComponent("status.txt"), atomically: true, encoding: .utf8)
            lastActionMessage = "System Bar status written to \(directory.path)/status.txt."
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = "Couldn't write System Bar diagnostics: \(error.localizedDescription)"
        }
    }

    private func ensureWorkAreaConfigurationIndexForSystemBar(for display: DisplayState) -> Int {
        if let index = workAreaConfigurationIndex(for: display) {
            return index
        }
        workAreas.append(
            WorkAreaConfiguration(
                displayUUID: display.uuid,
                displayName: display.name,
                displayWidth: display.frameW,
                displayHeight: display.frameH,
                enabled: false,
                normalizedRect: workAreaEditorNormalizedRect(for: display)
            )
        )
        return workAreas.count - 1
    }

    // MARK: - Runtime

    func configureSystemBarControllerIfNeeded() {
        guard !systemBarControllerConfigured else { return }
        systemBarControllerConfigured = true
        systemBarController.matchingIconsEnabled = systemBarMatchingIconsEnabled
        systemBarController.includeOtherDisplayIcons = systemBarOtherDisplayIconsEnabled
        systemBarController.screenRecordingAuthorized = { [megamapCaptureService] in
            megamapCaptureService.screenRecordingAuthorized()
        }
        systemBarController.onMessage = { [weak self] message, isError in
            guard let self else { return }
            if isError {
                self.lastErrorMessage = message
                self.lastActionMessage = nil
            } else {
                self.lastActionMessage = message
                self.lastErrorMessage = nil
            }
        }
        systemBarController.requestRelayout = { [weak self] in
            self?.scheduleWorkAreaApply(delayMilliseconds: 300)
        }
    }

    /// Places or removes the mirrored menu bar on every display, using the latest display frames.
    /// When yabai cannot describe the displays, the frames come from `NSScreen` so the bar stays up.
    func updateSystemBar(using snapshot: LiveStateSnapshot) {
        configureSystemBarControllerIfNeeded()
        let primaryMaxY = AppModel.primaryScreenMaxY()
        var displays = snapshot.displays.filter { $0.frameW > 1 && $0.frameH > 1 && $0.source != .fallback }
        if displays.isEmpty {
            displays = AppModel.screenDisplayStates(primaryMaxY: primaryMaxY)
        }
        var requests: [SystemBarController.BarRequest] = []
        for display in displays {
            guard let layout = resolvedSystemBarLayout(for: display) else { continue }
            requests.append(
                SystemBarController.BarRequest(
                    key: display.uuid?.uppercased() ?? "display-\(display.id)",
                    layout: layout,
                    appKitFrame: WorkAreaGeometry.appKitRect(fromTopLeft: layout.bar, primaryScreenMaxY: primaryMaxY),
                    menuBarFrame: systemBarRealMenuBarFrame(for: display)
                )
            )
        }
        systemBarController.update(requests)
    }

    /// Displays described by AppKit, in yabai's coordinates, for use when yabai is unavailable.
    static func screenDisplayStates(primaryMaxY: CGFloat) -> [DisplayState] {
        NSScreen.screens.enumerated().compactMap { index, screen in
            let frame = WorkAreaGeometry.topLeftRect(fromAppKit: screen.frame, primaryScreenMaxY: primaryMaxY)
            guard frame.width > 1, frame.height > 1 else { return nil }
            var uuid: String?
            if let displayID = screen.displayID,
               let cfUUID = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() {
                uuid = (CFUUIDCreateString(nil, cfUUID) as String).uppercased()
            }
            return DisplayState(
                id: -(index + 1),
                name: screen.localizedName,
                frameX: frame.minX,
                frameY: frame.minY,
                frameW: frame.width,
                frameH: frame.height,
                focused: false,
                windowCount: 0,
                source: .fallback,
                lastUpdatedAt: Date(),
                uuid: uuid
            )
        }
    }
}
