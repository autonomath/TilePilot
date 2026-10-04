import AppKit
import Combine
import SwiftUI

@MainActor
final class TilePilotWindowController: NSWindowController, NSWindowDelegate {
    private let model: AppModel

    private enum PersistedWindowSizeKeys {
        static let width = "TilePilot.mainWindow.width"
        static let height = "TilePilot.mainWindow.height"
        static let frameAutosaveName = "TilePilotMainWindow"
    }

    private static let defaultContentSize = NSSize(width: 1180, height: 760)
    private static let minimumWindowSize = NSSize(width: 1120, height: 720)
    private static let minimumVisibleSize = NSSize(width: 160, height: 120)

    init(model: AppModel) {
        self.model = model
        let hosting = TilePilotWindowController.makeHostingController(model: model)

        let window = NSWindow(contentViewController: hosting)
        window.title = "TilePilot"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(Self.defaultContentSize)
        window.minSize = Self.minimumWindowSize
        window.contentMinSize = Self.minimumWindowSize
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.center()
        _ = window.setFrameUsingName(PersistedWindowSizeKeys.frameAutosaveName)
        Self.restorePersistedSize(for: window)
        Self.repairWindowFrameIfNeeded(for: window)
        window.setFrameAutosaveName(PersistedWindowSizeKeys.frameAutosaveName)

        super.init(window: window)
        shouldCascadeWindows = true
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func showAndFocus() {
        ensureContentLoaded()
        if let window {
            Self.repairWindowFrameIfNeeded(for: window)
        }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self] in
            guard let window = self?.window else { return }
            Self.repairWindowFrameIfNeeded(for: window)
        }
    }

    func persistCurrentWindowSize() {
        guard let window else { return }
        Self.repairWindowFrameIfNeeded(for: window)
        guard Self.canPersistFrame(window.frame) else { return }
        persist(size: window.frame.size)
        window.saveFrame(usingName: PersistedWindowSizeKeys.frameAutosaveName)
    }

    func windowWillClose(_ notification: Notification) {
        persistCurrentWindowSize()
        unloadContent()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        persistCurrentWindowSize()
    }

    private func ensureContentLoaded() {
        guard let window else { return }
        if window.contentViewController is NSHostingController<AnyView> {
            return
        }
        window.contentViewController = Self.makeHostingController(model: model)
    }

    private func unloadContent() {
        guard let window else { return }
        if window.contentViewController is NSHostingController<AnyView> {
            window.contentViewController = NSViewController()
        }
    }

    private static func makeHostingController(model: AppModel) -> NSHostingController<AnyView> {
        let rootView = TilePilotRootView()
            .environmentObject(model)
        return NSHostingController(rootView: AnyView(rootView))
    }

    private static func restorePersistedSize(for window: NSWindow) {
        let defaults = UserDefaults.standard
        let persistedWidth = CGFloat(defaults.double(forKey: PersistedWindowSizeKeys.width))
        let persistedHeight = CGFloat(defaults.double(forKey: PersistedWindowSizeKeys.height))
        guard persistedWidth > 0, persistedHeight > 0 else { return }

        let minWidth = window.minSize.width
        let minHeight = window.minSize.height
        let maxFrame = NSScreen.main?.visibleFrame.size
        let maxWidth = maxFrame?.width ?? persistedWidth
        let maxHeight = maxFrame?.height ?? persistedHeight

        let width = min(max(persistedWidth, minWidth), maxWidth)
        let height = min(max(persistedHeight, minHeight), maxHeight)
        var frame = window.frame
        frame.size = NSSize(width: width, height: height)
        window.setFrame(frame, display: false)
    }

    private static func repairWindowFrameIfNeeded(for window: NSWindow) {
        let repairedFrame = repairedFrame(for: window.frame)
        guard repairedFrame != window.frame else { return }
        window.setFrame(repairedFrame, display: true, animate: false)
    }

    private static func canPersistFrame(_ frame: NSRect) -> Bool {
        guard frame.width.isFinite,
              frame.height.isFinite,
              frame.width >= minimumWindowSize.width,
              frame.height >= minimumWindowSize.height else {
            return false
        }
        return visibleScreenFrames().contains { screenFrame in
            let intersection = frame.intersection(screenFrame)
            return intersection.width >= minimumVisibleSize.width && intersection.height >= minimumVisibleSize.height
        }
    }

    private static func repairedFrame(for rawFrame: NSRect) -> NSRect {
        let screens = visibleScreenFrames()
        let fallbackScreen = NSScreen.main?.visibleFrame ?? screens.first ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let screenFrame = bestScreenFrame(for: rawFrame, visibleFrames: screens) ?? fallbackScreen

        var frame = rawFrame
        if !frame.origin.x.isFinite || !frame.origin.y.isFinite || !frame.width.isFinite || !frame.height.isFinite {
            frame = NSRect(origin: .zero, size: defaultContentSize)
        }

        let maxWidth = max(minimumWindowSize.width, screenFrame.width)
        let maxHeight = max(minimumWindowSize.height, screenFrame.height)
        frame.size.width = min(max(frame.width, minimumWindowSize.width), maxWidth)
        frame.size.height = min(max(frame.height, minimumWindowSize.height), maxHeight)

        let intersection = frame.intersection(screenFrame)
        let isEffectivelyVisible = intersection.width >= minimumVisibleSize.width && intersection.height >= minimumVisibleSize.height
        if !isEffectivelyVisible {
            frame.origin.x = screenFrame.midX - (frame.width / 2)
            frame.origin.y = screenFrame.midY - (frame.height / 2)
        }

        frame.origin.x = min(max(frame.minX, screenFrame.minX), screenFrame.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, screenFrame.minY), screenFrame.maxY - frame.height)
        return frame.integral
    }

    private static func bestScreenFrame(for frame: NSRect, visibleFrames: [NSRect]) -> NSRect? {
        visibleFrames.max { lhs, rhs in
            intersectionArea(lhs.intersection(frame)) < intersectionArea(rhs.intersection(frame))
        }
    }

    private static func intersectionArea(_ rect: NSRect) -> CGFloat {
        guard !rect.isNull, !rect.isEmpty else { return 0 }
        return max(0, rect.width) * max(0, rect.height)
    }

    private static func visibleScreenFrames() -> [NSRect] {
        NSScreen.screens.map(\.visibleFrame)
    }

    private func persist(size: NSSize) {
        let defaults = UserDefaults.standard
        defaults.set(size.width, forKey: PersistedWindowSizeKeys.width)
        defaults.set(size.height, forKey: PersistedWindowSizeKeys.height)
    }
}

@MainActor
final class StatusBarController: NSObject {
    private let model: AppModel
    private let onOpenTilePilot: () -> Void
    private let onQuit: () -> Void
    private let statusItem: NSStatusItem
    private var cancellables: Set<AnyCancellable> = []

    init(model: AppModel, onOpenTilePilot: @escaping () -> Void, onQuit: @escaping () -> Void) {
        self.model = model
        self.onOpenTilePilot = onOpenTilePilot
        self.onQuit = onQuit
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        configureStatusButton()
        bindModel()
        updateButtonAppearance()
    }

    private func configureStatusButton() {
        guard let button = statusItem.button else { return }
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(handleStatusItemClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.toolTip = "TilePilot"
    }

    private func bindModel() {
        model.$doctorSnapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateButtonAppearance()
            }
            .store(in: &cancellables)

        model.$isRefreshing
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateButtonAppearance()
            }
            .store(in: &cancellables)
    }

    private func updateButtonAppearance() {
        guard let button = statusItem.button else { return }
        button.image = renderedStatusIcon()
        button.contentTintColor = nil
        button.toolTip = "TilePilot • \(model.menuBarStatusLine)"
    }

    private func renderedStatusIcon() -> NSImage? {
        let symbol = "square.grid.2x2"
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        guard let base = NSImage(systemSymbolName: symbol, accessibilityDescription: "TilePilot status")?
            .withSymbolConfiguration(config) else {
            return nil
        }

        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        let rect = NSRect(origin: .zero, size: size)
        NSColor.clear.setFill()
        rect.fill()

        base.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
        NSColor.white.setFill()
        rect.fill(using: .sourceAtop)

        image.isTemplate = false
        return image
    }

    private func tintColor(for badge: HealthBadgeLevel?) -> NSColor {
        switch badge {
        case .healthy: return .systemGreen
        case .warning: return .systemYellow
        case .degraded: return .systemOrange
        case .blocked: return .systemRed
        case .none: return .labelColor
        }
    }

    @objc
    private func handleStatusItemClick(_ sender: Any?) {
        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseUp || (event?.modifierFlags.contains(.control) == true)
        if isRightClick {
            presentQuickMenu()
        } else {
            onOpenTilePilot()
        }
    }

    func presentQuickMenuForAutomation() {
        presentQuickMenu()
    }

    private func presentQuickMenu() {
        model.rebuildShortcutPresentationCaches()
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(openTilePilotMenuItem())
        menu.addItem(openMegamapMenuItem())
        menu.addItem(.separator())

        _ = addPinnedContextItems(to: menu)
        menu.addItem(.separator())
        menu.addItem(editPinnedActionsMenuItem())
        if let availableRelease = model.availableAppUpdateRelease {
            menu.addItem(.separator())
            menu.addItem(openAvailableUpdateMenuItem(release: availableRelease))
        }
        menu.addItem(checkForUpdatesMenuItem())
        menu.addItem(.separator())
        let runtimeEnabled = model.canRunYabaiRuntimeCommands
        let runtimeReason = model.yabaiRuntimeControlDisabledReason ?? "Unavailable"
        let hoverEnabled = model.windowBehaviorPolicyDraft.hoverFocusMode != .off
        let cursorFollowsFocus = model.windowBehaviorPolicyDraft.mouseFollowsFocusEnabled

        let hoverFocusItem = item(
            runtimeEnabled ? "Hover Focus" : "Hover Focus (\(runtimeReason))",
            action: #selector(toggleHoverFocus),
            enabled: runtimeEnabled
        )
        hoverFocusItem.state = hoverEnabled ? .on : .off
        menu.addItem(hoverFocusItem)

        let cursorFollowsFocusItem = item(
            runtimeEnabled ? "Cursor Follows Focus" : "Cursor Follows Focus (\(runtimeReason))",
            action: #selector(toggleMouseFollowsFocus),
            enabled: runtimeEnabled
        )
        cursorFollowsFocusItem.state = cursorFollowsFocus ? .on : .off
        menu.addItem(cursorFollowsFocusItem)

        let badgeItem = item("Window Badges", action: #selector(toggleWindowBadgeOverlay))
        badgeItem.state = model.showWindowBadgeOverlay ? .on : .off
        menu.addItem(badgeItem)

        let outlineItem = item("Window Outline Overlay", action: #selector(toggleWindowOutlineOverlay))
        outlineItem.state = model.showWindowOutlineOverlay ? .on : .off
        menu.addItem(outlineItem)

        menu.addItem(.separator())
        menu.addItem(item("Quit", action: #selector(quitApp)))

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func item(_ title: String, action: Selector, enabled: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled
        return item
    }

    private func openTilePilotMenuItem() -> NSMenuItem {
        let menuItem = item("Open TilePilot", action: #selector(openTilePilot))
        if let row = model.featureControlRow(forID: FeatureControlID(rawValue: "app.open-tilepilot")) {
            let comboRaw = row.shortcutEntry?.combo ?? row.assignedCombo ?? row.defaultCombo
            applyMenuShortcut(to: menuItem, comboRaw: comboRaw)
        }
        return menuItem
    }

    private func openMegamapMenuItem() -> NSMenuItem {
        let menuItem = item("Open MegaMap", action: #selector(openMegamap))
        if let row = model.featureControlRow(forID: FeatureControlID(rawValue: "app.open-megamap")) {
            let comboRaw = row.shortcutEntry?.combo ?? row.assignedCombo ?? row.defaultCombo
            applyMenuShortcut(to: menuItem, comboRaw: comboRaw)
        }
        return menuItem
    }

    private func editPinnedActionsMenuItem() -> NSMenuItem {
        let menuItem = item("Pin More Shortcuts…", action: #selector(openShortcuts))
        if let image = NSImage(
            systemSymbolName: "slider.horizontal.3",
            accessibilityDescription: "Pin more shortcuts"
        ) {
            image.isTemplate = true
            menuItem.image = image
        }
        menuItem.attributedTitle = NSAttributedString(
            string: "Pin More Shortcuts…",
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
        return menuItem
    }

    private func openAvailableUpdateMenuItem(release: AppUpdateReleaseInfo) -> NSMenuItem {
        let menuItem = item("New Version Available: \(release.tagName)", action: #selector(openLatestReleasePage))
        if let image = NSImage(
            systemSymbolName: "arrow.down.circle.fill",
            accessibilityDescription: "Open latest TilePilot release"
        ) {
            image.isTemplate = true
            menuItem.image = image
        }
        menuItem.attributedTitle = NSAttributedString(
            string: "New Version Available: \(release.tagName)",
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold),
                .foregroundColor: NSColor.systemBlue,
            ]
        )
        return menuItem
    }

    private func checkForUpdatesMenuItem() -> NSMenuItem {
        let menuItem = item("Check for Updates…", action: #selector(checkForUpdates))
        if let image = NSImage(
            systemSymbolName: "arrow.clockwise.circle",
            accessibilityDescription: "Check for updates"
        ) {
            image.isTemplate = true
            menuItem.image = image
        }
        return menuItem
    }

    private func addPinnedContextItems(to menu: NSMenu) -> Bool {
        let pinnedItems = model.pinnedShortcutContextItems
        guard !pinnedItems.isEmpty else { return false }

        for item in pinnedItems {
            switch item {
            case .feature(let row):
                guard let featureID = row.featureID else { continue }
                let disabledReason = pinnedFeatureDisabledReason(row)
                let leftLabel = disabledReason == nil ? row.title : "\(row.title) (\(disabledReason!))"
                let menuItem = self.item(
                    leftLabel,
                    action: #selector(runPinnedFeature(_:)),
                    enabled: disabledReason == nil
                )
                if let appName = focusedAppNameForPinnedAppFeature(), let state = pinnedFeatureState(featureID, appName: appName) {
                    menuItem.state = state
                }
                let comboRaw = row.shortcutEntry?.combo ?? row.assignedCombo ?? row.defaultCombo
                applyMenuShortcut(to: menuItem, comboRaw: comboRaw)
                menuItem.representedObject = featureID.rawValue
                menu.addItem(menuItem)
            case .directional(let group, let bindings):
                addPinnedDirectionalGroupItems(to: menu, group: group, bindings: bindings)
            case .shortcut(let entry):
                let menuItem = self.item(model.shortcutTitle(entry), action: #selector(runPinnedShortcut(_:)))
                applyMenuShortcut(to: menuItem, comboRaw: entry.combo)
                menuItem.representedObject = entry.stableKey
                menu.addItem(menuItem)
            }
        }
        return true
    }

    private func focusedAppNameForPinnedAppFeature() -> String? {
        model.focusedAppName
    }

    private func pinnedFeatureDisabledReason(_ row: FeatureControlRow) -> String? {
        if let disabledReason = row.disabledReason {
            return disabledReason
        }
        if let featureID = row.featureID, isPinnedAppScopedFeature(featureID), focusedAppNameForPinnedAppFeature() == nil {
            return "No focused app"
        }
        return nil
    }

    private func isPinnedAppScopedFeature(_ featureID: FeatureControlID) -> Bool {
        switch featureID.rawValue {
        case "app.keep-on-top-when-floating", "app.never-auto-tile":
            return true
        default:
            return false
        }
    }

    private func pinnedFeatureState(_ featureID: FeatureControlID, appName: String) -> NSControl.StateValue? {
        switch featureID.rawValue {
        case "app.keep-on-top-when-floating":
            return model.appForegroundPolicy(for: appName) == .keepFrontWhenFloating ? .on : .off
        case "app.never-auto-tile":
            return model.isNeverAutoTileEnabled(for: appName) ? .on : .off
        default:
            return nil
        }
    }

    private func addPinnedDirectionalGroupItems(
        to menu: NSMenu,
        group: DirectionalShortcutGroup,
        bindings: [DirectionalShortcutBinding]
    ) {
        guard !bindings.isEmpty else { return }
        let header = NSMenuItem(title: "Pinned \(group.menuTitle)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        for binding in bindings {
            let title = "\(binding.direction.arrow)  \(directionActionLabel(for: group, direction: binding.direction))"
            let item = self.item(title, action: #selector(runPinnedShortcut(_:)))
            applyMenuShortcut(to: item, comboRaw: binding.entry.combo)
            item.representedObject = binding.entry.stableKey
            menu.addItem(item)
        }
    }

    private func directionActionLabel(
        for group: DirectionalShortcutGroup,
        direction: DirectionalShortcutDirection
    ) -> String {
        switch group {
        case .focusWindow:
            return "Focus \(direction.label)"
        case .moveWindow:
            return "Move \(direction.label)"
        case .resizeWindow:
            return "Resize \(direction.label)"
        case .swapWindow:
            return "Swap \(direction.label)"
        }
    }

    private struct ParsedMenuShortcut {
        let keyEquivalent: String
        let modifiers: NSEvent.ModifierFlags
    }

    private func applyMenuShortcut(to item: NSMenuItem, comboRaw: String?) {
        guard let parsed = parseMenuShortcut(comboRaw) else { return }
        item.keyEquivalent = parsed.keyEquivalent
        item.keyEquivalentModifierMask = parsed.modifiers
    }

    private func parseMenuShortcut(_ comboRaw: String?) -> ParsedMenuShortcut? {
        guard let comboRaw, !comboRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let normalized = comboRaw.replacingOccurrences(of: "—", with: "-")
        guard let splitIndex = normalized.lastIndex(of: "-") else { return nil }

        let modifiersPart = String(normalized[..<splitIndex]).lowercased()
        let keyPartRaw = String(normalized[normalized.index(after: splitIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyPartRaw.isEmpty else { return nil }
        let keyToken = keyPartRaw
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .first?
            .lowercased() ?? keyPartRaw.lowercased()

        guard let keyEquivalent = menuKeyEquivalent(for: keyToken) else { return nil }

        var modifiers: NSEvent.ModifierFlags = []
        let modifierTokens = modifiersPart
            .replacingOccurrences(of: "+", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .map { String($0).lowercased() }
        for token in modifierTokens {
            switch token {
            case "shift":
                modifiers.insert(.shift)
            case "alt", "option":
                modifiers.insert(.option)
            case "ctrl", "control":
                modifiers.insert(.control)
            case "cmd", "command":
                modifiers.insert(.command)
            default:
                continue
            }
        }

        return ParsedMenuShortcut(keyEquivalent: keyEquivalent, modifiers: modifiers)
    }

    private func menuKeyEquivalent(for token: String) -> String? {
        if token == "0x32" { return "`" }
        if token.count == 1 { return token.lowercased() }
        switch token {
        case "space":
            return " "
        case "tab":
            return "\t"
        case "return", "enter":
            return "\r"
        case "escape", "esc":
            return String(UnicodeScalar(0x1B)!)
        case "left":
            return String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        case "right":
            return String(UnicodeScalar(NSRightArrowFunctionKey)!)
        case "up":
            return String(UnicodeScalar(NSUpArrowFunctionKey)!)
        case "down":
            return String(UnicodeScalar(NSDownArrowFunctionKey)!)
        default:
            return nil
        }
    }

    @objc private func openTilePilot() { onOpenTilePilot() }

    @objc private func openMegamap() {
        model.acknowledgeInitialStatusIfNeeded()
        model.presentMegamap()
    }

    @objc private func runDoctor() {
        model.acknowledgeInitialStatusIfNeeded()
        Task { await model.refreshDoctor() }
    }

    @objc private func disableHoverFocus() {
        model.acknowledgeInitialStatusIfNeeded()
        model.disableHoverFocus()
    }

    @objc private func toggleHoverFocus() {
        model.acknowledgeInitialStatusIfNeeded()
        if model.windowBehaviorPolicyDraft.hoverFocusMode == .off {
            model.setHoverFocusMode(.autofocus)
        } else {
            model.setHoverFocusMode(.off)
        }
    }

    @objc private func disableMouseFollowsFocus() {
        model.acknowledgeInitialStatusIfNeeded()
        model.disableMouseFollowsFocus()
    }

    @objc private func toggleMouseFollowsFocus() {
        model.acknowledgeInitialStatusIfNeeded()
        model.setMouseFollowsFocusEnabled(!model.windowBehaviorPolicyDraft.mouseFollowsFocusEnabled)
    }

    @objc private func enableManualTilingMode() {
        model.acknowledgeInitialStatusIfNeeded()
        model.enableManualTilingMode()
    }

    @objc private func disableManualTilingMode() {
        model.acknowledgeInitialStatusIfNeeded()
        model.disableManualTilingMode()
    }

    @objc private func toggleWindowBadgeOverlay() {
        model.acknowledgeInitialStatusIfNeeded()
        model.toggleWindowBadgeOverlay()
    }

    @objc private func toggleWindowOutlineOverlay() {
        model.acknowledgeInitialStatusIfNeeded()
        model.toggleWindowOutlineOverlay()
    }

    @objc private func tileFocusedWindow() {
        model.acknowledgeInitialStatusIfNeeded()
        model.tileFocusedWindowNow()
    }

    @objc private func floatFocusedWindow() {
        model.acknowledgeInitialStatusIfNeeded()
        model.floatFocusedWindowNow()
    }

    @objc private func toggleFocusedWindowTiling() {
        model.acknowledgeInitialStatusIfNeeded()
        model.toggleFocusedWindowTiling()
    }

    @objc private func openWindowBehaviorSettings() {
        model.acknowledgeInitialStatusIfNeeded()
        model.openWindowBehaviorSettings()
        onOpenTilePilot()
    }

    @objc private func openShortcuts() {
        model.acknowledgeInitialStatusIfNeeded()
        model.requestOpenTilePilotTab(.shortcuts)
        onOpenTilePilot()
    }

    @objc private func checkForUpdates() {
        model.acknowledgeInitialStatusIfNeeded()
        model.requestOpenTilePilotTab(.system)
        onOpenTilePilot()
        model.checkForAppUpdates(manual: true)
    }

    @objc private func openLatestReleasePage() {
        model.acknowledgeInitialStatusIfNeeded()
        model.openLatestReleasePage()
    }

    @objc private func runSetupInstaller() {
        model.acknowledgeInitialStatusIfNeeded()
        model.performPrimarySetupAction()
    }

    @objc private func runPinnedShortcut(_ sender: NSMenuItem) {
        guard let stableKey = sender.representedObject as? String else { return }
        model.acknowledgeInitialStatusIfNeeded()
        model.runPinnedShortcut(stableKey: stableKey)
    }

    @objc private func runPinnedFeature(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        model.acknowledgeInitialStatusIfNeeded()
        model.runFeatureControl(FeatureControlID(rawValue: raw), source: .statusMenu)
    }

    @objc private func copyIssueSummary() {
        model.acknowledgeInitialStatusIfNeeded()
        model.copyIssueReadySummary()
    }

    @objc private func exportDiagnostics() {
        model.acknowledgeInitialStatusIfNeeded()
        model.exportDiagnostics()
    }

    @objc private func openAccessibilitySettings() {
        model.acknowledgeInitialStatusIfNeeded()
        model.openAccessibilitySettings()
    }

    @objc private func requestAccessibilityAccess() {
        model.acknowledgeInitialStatusIfNeeded()
        model.requestAccessibilityAccessPrompt()
    }

    @objc private func openMissionControlSettings() {
        model.acknowledgeInitialStatusIfNeeded()
        model.openMissionControlSettings()
    }

    @objc private func openSystemSettings() {
        model.acknowledgeInitialStatusIfNeeded()
        model.openSystemSettings()
    }

    @objc private func restartYabai() {
        model.acknowledgeInitialStatusIfNeeded()
        model.restartYabaiBestEffort()
    }

    @objc private func restartSkhd() {
        model.acknowledgeInitialStatusIfNeeded()
        model.restartSkhdBestEffort()
    }

    @objc private func quitApp() {
        onQuit()
    }

    private func menuBarBadgeLevel() -> HealthBadgeLevel? {
        model.menuBarVisualBadgeLevel
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel.shared
    private let isLoginLaunch = TilePilotLaunchPolicy.isLoginLaunch(arguments: ProcessInfo.processInfo.arguments)
    private var tilePilotWindowController: TilePilotWindowController?
    private var megamapWindowController: MegamapWindowController?
    private var statusBarController: StatusBarController?
    private var windowBadgeOverlayController: WindowBadgeOverlayController?
    private var workSetBackdropController: WorkSetBackdropController?
    private var recentWindowTilerWindowController: RecentWindowTilerWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if shouldTerminateAsDuplicateInstance() {
            NSApplication.shared.terminate(nil)
            return
        }

        NSApp.setActivationPolicy(.accessory)
        ColorPanelPresets.installIfNeeded()

        tilePilotWindowController = TilePilotWindowController(model: model)
        megamapWindowController = MegamapWindowController(model: model)
        statusBarController = StatusBarController(
            model: model,
            onOpenTilePilot: { [weak self] in
                self?.model.acknowledgeInitialStatusIfNeeded()
                self?.tilePilotWindowController?.showAndFocus()
            },
            onQuit: { [weak self] in
                self?.tilePilotWindowController?.persistCurrentWindowSize()
                NSApplication.shared.terminate(nil)
            }
        )
        windowBadgeOverlayController = WindowBadgeOverlayController(model: model)
        workSetBackdropController = WorkSetBackdropController(model: model)
        recentWindowTilerWindowController = RecentWindowTilerWindowController(model: model)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(showMegamapWindow),
            name: .tilePilotOpenMegamap,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(hideMegamapWindow),
            name: .tilePilotHideMegamap,
            object: nil
        )

        model.startIfNeeded()

        if !isLoginLaunch {
            // Manual launches should always produce visible UI.
            DispatchQueue.main.async { [weak self] in
                self?.tilePilotWindowController?.showAndFocus()
            }
        }
    }

    private func shouldTerminateAsDuplicateInstance() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let instances = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        guard instances.count > 1 else { return false }
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let keeperPID = instances.map(\.processIdentifier).min() ?? currentPID
        return currentPID != keeperPID
    }

    @objc private func showMegamapWindow() {
        model.acknowledgeInitialStatusIfNeeded()
        megamapWindowController?.showAndFocus()
    }

    @objc private func hideMegamapWindow() {
        megamapWindowController?.hideImmediately()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        tilePilotWindowController?.showAndFocus()
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        Task { [weak self] in
            guard let self else { return }
            await self.model.refreshLiveState()
            await self.model.refreshWindowBehaviorConfig()
            await self.model.refreshBootstrapSetup()
            await self.model.refreshDoctor()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            handleDeepLink(url)
        }
    }

    private func handleDeepLink(_ url: URL) {
        guard url.scheme?.lowercased() == "tilepilot" else { return }
        let host = url.host?.lowercased() ?? ""
        let trimmedPath = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        let routeKind: String
        let routeRaw: String
        if host == "feature" || host == "internal" {
            routeKind = host
            routeRaw = trimmedPath.removingPercentEncoding ?? ""
        } else if host.isEmpty,
                  let slashIndex = trimmedPath.firstIndex(of: "/") {
            routeKind = String(trimmedPath[..<slashIndex]).lowercased()
            routeRaw = String(trimmedPath[trimmedPath.index(after: slashIndex)...]).removingPercentEncoding ?? ""
        } else {
            return
        }

        switch routeKind {
        case "feature":
            let featureRaw = routeRaw
            guard !featureRaw.isEmpty else { return }

            model.acknowledgeInitialStatusIfNeeded()
            Task { [weak self] in
                guard let self else { return }
                await self.model.refreshLiveState()
                self.model.runFeatureControl(FeatureControlID(rawValue: featureRaw), source: .shortcutsUI)
            }
        case "internal":
            let actionRaw = routeRaw
            model.acknowledgeInitialStatusIfNeeded()
            switch actionRaw {
            case let raw where raw.hasPrefix("open-tab/"):
                guard let tab = internalTabRoute(from: String(raw.dropFirst("open-tab/".count))) else { return }
                tilePilotWindowController?.showAndFocus()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    self?.model.requestOpenTilePilotTab(tab)
                }
            case "show-quick-menu":
                statusBarController?.presentQuickMenuForAutomation()
            case "native-spaces-scrub-spike":
                guard model.experimentalNativeSpacesScrubSpikeEnabled else { return }
                Task { [weak self] in
                    guard let self else { return }
                    await self.model.runExperimentalNativeSpacesScrubSpike()
                }
            case "enable-native-spaces-scrub":
                guard model.experimentalNativeSpacesScrubSpikeEnabled else { return }
                model.enableExperimentalNativeSpacesScrubInteraction()
            case "disable-native-spaces-scrub":
                model.disableExperimentalNativeSpacesScrubInteraction()
            default:
                return
            }
        default:
            return
        }
    }

    private func internalTabRoute(from raw: String) -> TilePilotTab? {
        switch raw.lowercased() {
        case "overview", "now":
            return .now
        case "behaviors", "window-behavior", "windowbehavior":
            return .windowBehavior
        case "actions", "shortcuts", "actions-shortcuts":
            return .actions
        case "templates":
            return .templates
        case "work-sets", "worksets":
            return .workSets
        case "appearance":
            return .appearance
        case "config-files", "files":
            return .files
        case "how-it-works", "howitworks":
            return .howItWorks
        case "system":
            return .system
        default:
            return nil
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        tilePilotWindowController?.persistCurrentWindowSize()
        megamapWindowController?.persistCurrentWindowSize()
        windowBadgeOverlayController = nil
        NotificationCenter.default.removeObserver(self, name: .tilePilotOpenMegamap, object: nil)
        NotificationCenter.default.removeObserver(self, name: .tilePilotHideMegamap, object: nil)
        recentWindowTilerWindowController = nil
    }
}
