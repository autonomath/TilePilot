import AppKit
import Foundation

/// Shows a mirrored menu bar for each Work Area that asks for one and routes clicks to the real
/// menus and icons through Accessibility. The panels never activate TilePilot, so the frontmost
/// app keeps its place while its menus open under the mirrored titles.
@MainActor
final class SystemBarController: NSObject, NSMenuDelegate {
    struct BarRequest: Equatable {
        let key: String
        let layout: SystemBarLayout
        /// The bar frame in AppKit screen coordinates.
        let appKitFrame: CGRect
        /// The real menu bar of the mirrored display, in top-left coordinates.
        let menuBarFrame: CGRect?
    }

    final class SystemBarPanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    struct DisplayBar {
        let key: String
        let panel: SystemBarPanel
        let view: SystemBarView
        var layout: SystemBarLayout
        var menuBarFrame: CGRect?
    }

    private static let refreshTickSeconds: UInt64 = 1
    private static let titleRefreshTicks = 2
    private static let iconRefreshTicks = 3
    private static let redrawThrottleMilliseconds = 250

    let reader = AccessibilityMirrorReader()

    var bars: [String: DisplayBar] = [:]
    var titles: [SystemBarMenuTitle] = []
    var titlesPID: pid_t?
    var statusItems: [SystemBarStatusItem] = []
    private var menuBarFrames: [CGRect] = []
    private var menuBarFramesReadAt: Date?
    let captureSet = SystemBarCaptureSet()
    /// Per bar: icons seen on that display's real bar, with their place there.
    private var stickyIcons: [String: [String: SystemBarStickyIcon]] = [:]
    /// The row shown with every display's icons.
    private(set) var iconRow = SystemBarIconRowState()
    private(set) var backgroundLook = SystemBarBackgroundLook()
    private var activeBackgroundRect: (menuBar: CGRect, rect: CGRect)?
    private var activationScanTask: Task<Void, Never>?
    /// The last copied pixels of each icon, shown while a focus change moves the icon's copy
    /// source to another display and that capture has not delivered the new spot yet.
    private var lastIconImages: [String: (image: CGImage, size: CGSize, top: CGFloat)] = [:]
    private var recentStatusItems: [String: (item: SystemBarStatusItem, seenAt: Date)] = [:]
    private static let missingIconGraceSeconds: TimeInterval = 10

    /// Show every display's icons once, in one row that stays put as focus moves (off by default:
    /// only the mirrored display's own icons).
    var includeOtherDisplayIcons = false {
        didSet {
            guard includeOtherDisplayIcons != oldValue else { return }
            relayoutAllBars()
        }
    }
    /// Running apps as plain values. Reading pid and bundle ID from `NSRunningApplication` asks
    /// LaunchServices each time, so the list is rebuilt only when an app launches or quits.
    private var cachedRunningApps: [AccessibilityMirrorReader.RunningApp]?
    private static let menuBarFramesMaxAge: TimeInterval = 10
    private var appIconCache: [pid_t: NSImage] = [:]
    private var refreshTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    /// Watches the running-app list itself. macOS posts no launch or quit notification for
    /// menu-bar-only apps (LSUIElement), which own most menu bar icons.
    private var runningAppsObservation: NSKeyValueObservation?
    private var launchScanTask: Task<Void, Never>?
    private var redrawScheduled = false
    var menuInProgress = false
    /// The last icon click and its outcome, for the status route.
    var lastClickTrace = "none"
    var watchedPanel: WatchedPanel?
    var panelWatchTask: Task<Void, Never>?
    var overflowContext: OverflowContext?
    var lastMenuActionSummary = "none"
    let ownPID = ProcessInfo.processInfo.processIdentifier

    /// Shows TilePilot's own quick menu for the mirrored TilePilot icon.
    var quickMenuPresenter: ((NSView, NSPoint) -> Void)?
    /// Short status or error text for the TilePilot window.
    var onMessage: ((String, Bool) -> Void)?
    /// Asked when displays change so the owner recomputes bar frames.
    var requestRelayout: (() -> Void)?
    var screenRecordingAuthorized: () -> Bool = { CGPreflightScreenCaptureAccess() }
    var matchingIconsEnabled = true {
        didSet {
            guard matchingIconsEnabled != oldValue else { return }
            updateCaptures()
            relayoutAllBars()
        }
    }

    var isShowingAnyBar: Bool {
        !bars.isEmpty
    }

    var isMatchingIconsActive: Bool {
        matchingIconsEnabled && screenRecordingAuthorized() && captureSet.isAnyRunning
    }

    override init() {
        super.init()
        captureSet.onFrame = { [weak self] in
            self?.scheduleRedraw()
        }
        captureSet.onStartFailure = { [weak self] error, attempts in
            guard let self else { return }
            if attempts == SystemBarCapturePolicy.attemptsBeforeMessage {
                self.onMessage?("Menu bar icons use the simplified look until the real menu bar can be captured (\(error.localizedDescription)).", false)
            }
            self.relayoutAllBars()
        }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleTitleRefresh()
            }
        })
        runningAppsObservation = NSWorkspace.shared.observe(\.runningApplications, options: []) { [weak self] _, _ in
            Task { @MainActor in
                self?.runningAppsChanged()
            }
        }
        observers.append(center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.orderBarsFront()
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.menuBarFramesReadAt = nil
                // A reconnected or rearranged display stops its capture; start over right away.
                self?.captureSet.clearFailures()
                self?.requestRelayout?()
            }
        })
    }

    // MARK: - Real menu bars

    /// Frames of the real menu bar windows, one per display, in top-left screen coordinates. The
    /// cache is dropped on every display change, so a long maximum age only delays auto-hide changes.
    func realMenuBarFrames(maxAge: TimeInterval = menuBarFramesMaxAge) -> [CGRect] {
        if let readAt = menuBarFramesReadAt, Date().timeIntervalSince(readAt) < maxAge, !menuBarFrames.isEmpty {
            return menuBarFrames
        }
        menuBarFrames = Self.readMenuBarFrames()
        menuBarFramesReadAt = Date()
        return menuBarFrames
    }

    nonisolated static func readMenuBarFrames() -> [CGRect] {
        let menuLevel = Int(CGWindowLevelForKey(.mainMenuWindow))
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var frames: [CGRect] = []
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == menuLevel else { continue }
            let owner = (info[kCGWindowOwnerName as String] as? String) ?? ""
            let name = (info[kCGWindowName as String] as? String) ?? ""
            guard let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary else { continue }
            var bounds = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(boundsDictionary, &bounds) else { continue }
            let looksLikeMenuBar = (owner == "Window Server" && name == "Menubar")
                || (bounds.height <= 60 && bounds.width >= 500 && name.lowercased().contains("menubar"))
            guard looksLikeMenuBar else { continue }
            frames.append(bounds)
        }
        return frames.sorted { $0.minX < $1.minX }
    }

    // MARK: - Bars

    func update(_ requests: [BarRequest]) {
        let wanted = Set(requests.map(\.key))
        for key in bars.keys where !wanted.contains(key) {
            if let bar = bars.removeValue(forKey: key) {
                dispose(bar)
            }
        }
        for request in requests {
            if var bar = bars[request.key] {
                bar.layout = request.layout
                bar.menuBarFrame = request.menuBarFrame
                bars[request.key] = bar
                if bar.panel.frame != request.appKitFrame {
                    bar.panel.setFrame(request.appKitFrame, display: true)
                }
                if !bar.panel.isVisible {
                    bar.panel.orderFrontRegardless()
                }
            } else {
                let (panel, view) = makePanel(frame: request.appKitFrame)
                let key = request.key
                view.onClick = { [weak self] slot, _, secondary in
                    self?.handleClick(barKey: key, slot: slot, secondary: secondary)
                }
                let bar = DisplayBar(key: key, panel: panel, view: view, layout: request.layout, menuBarFrame: request.menuBarFrame)
                bars[key] = bar
                panel.orderFrontRegardless()
            }
        }
        if bars.isEmpty {
            stopRefreshLoop()
            captureSet.stopAll()
        } else {
            startRefreshLoop()
            updateCaptures()
        }
        relayoutAllBars()
    }

    func stop() {
        for bar in bars.values {
            dispose(bar)
        }
        bars.removeAll()
        stopRefreshLoop()
        captureSet.stopAll()
    }

    private func dispose(_ bar: DisplayBar) {
        bar.view.onClick = nil
        bar.panel.orderOut(nil)
        bar.panel.contentView = nil
        bar.panel.close()
    }

    private func orderBarsFront() {
        for bar in bars.values {
            bar.panel.orderFrontRegardless()
        }
    }

    private func makePanel(frame: NSRect) -> (SystemBarPanel, SystemBarView) {
        let panel = SystemBarPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "TilePilot Menu Bar"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isExcludedFromWindowsMenu = true
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = false
        panel.acceptsMouseMovedEvents = true
        panel.animationBehavior = .none
        panel.level = .statusBar
        // An 8-bit backing store keeps redraws cheap; the bar never shows wide-gamut or HDR content.
        panel.depthLimit = .twentyfourBitRGB
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        // A plain container: the bar view puts frosted backdrops behind its menus and icons only.
        // A full-width material would catch clicks even where it is masked out.
        let container = NSView(frame: NSRect(origin: .zero, size: frame.size))
        container.autoresizingMask = [.width, .height]
        let view = SystemBarView(frame: container.bounds)
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        panel.contentView = container
        return (panel, view)
    }

    // MARK: - Refresh

    private func startRefreshLoop() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                guard let self else { return }
                if tick % Self.titleRefreshTicks == 0 {
                    await self.refreshTitles()
                }
                if tick % Self.iconRefreshTicks == 0 {
                    await self.refreshIcons()
                }
                tick += 1
                try? await Task.sleep(for: .seconds(Self.refreshTickSeconds))
            }
        }
    }

    private func stopRefreshLoop() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    private func scheduleTitleRefresh() {
        guard !bars.isEmpty else { return }
        Task { [weak self] in
            // Give the newly active app a moment to install its menu bar.
            try? await Task.sleep(for: .milliseconds(120))
            await self?.refreshTitles()
        }
        // Accessibility now reports every icon on the newly active display's bar; rescan soon so
        // confirmed positions, and the bars icons are copied from, follow the switch.
        activationScanTask?.cancel()
        activationScanTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await self?.refreshIcons()
        }
    }

    private func refreshTitles() async {
        guard !bars.isEmpty, let frontmost = NSWorkspace.shared.frontmostApplication else { return }
        let pid = frontmost.processIdentifier
        let fresh = pid == ownPID ? ownMenuTitles() : await reader.readMenuBar(pid: pid)
        guard !bars.isEmpty else { return }
        if fresh.isEmpty, pid != titlesPID, !titles.isEmpty {
            // Keep the previous app's titles until the new app exposes a menu bar.
            return
        }
        let signature: ([SystemBarMenuTitle]) -> [String] = { list in
            list.map { "\($0.title)|\($0.isEnabled)|\(Int($0.axWidth))" }
        }
        let changed = signature(fresh) != signature(titles) || pid != titlesPID
        titles = fresh
        titlesPID = pid
        if changed {
            relayoutAllBars()
        }
    }

    /// An app launched or quit: rebuild the app list and look again once it has had a moment to
    /// add its icon, then once more as the other icons settle into their new places.
    private func runningAppsChanged() {
        cachedRunningApps = nil
        guard !bars.isEmpty else { return }
        launchScanTask?.cancel()
        launchScanTask = Task { [weak self] in
            for delay in [800, 1500] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard !Task.isCancelled else { return }
                await self?.refreshIcons()
            }
        }
    }

    private func refreshIcons() async {
        guard !bars.isEmpty else { return }
        // While the screen is locked macOS hides the icons and capture stops; keep the last state
        // so the bar comes back unchanged after the unlock.
        guard !Self.screenIsLocked() else { return }
        let apps: [AccessibilityMirrorReader.RunningApp]
        if let cachedRunningApps {
            apps = cachedRunningApps
        } else {
            apps = NSWorkspace.shared.runningApplications.map {
                AccessibilityMirrorReader.RunningApp(
                    pid: $0.processIdentifier,
                    bundleIdentifier: $0.bundleIdentifier ?? "",
                    name: $0.localizedName ?? "",
                    launchedAt: $0.launchDate
                )
            }
            cachedRunningApps = apps
        }
        let frames = realMenuBarFrames(maxAge: Self.menuBarFramesMaxAge)
        let ownBars = bars.values.compactMap(\.menuBarFrame)
        let fresh = await reader.readStatusItems(apps: apps, menuBars: frames, ownBars: ownBars)
        guard !bars.isEmpty else { return }
        // Keep an icon that missed one scan for a few seconds so a momentary gap in what
        // Accessibility reports never makes the bar jump.
        let now = Date()
        let freshKeys = Set(fresh.map(\.stableKey))
        var merged = fresh
        for (key, entry) in recentStatusItems where !freshKeys.contains(key) && now.timeIntervalSince(entry.seenAt) < Self.missingIconGraceSeconds {
            merged.append(entry.item)
        }
        recentStatusItems = recentStatusItems.filter { now.timeIntervalSince($0.value.seenAt) < Self.missingIconGraceSeconds }
        for item in fresh {
            recentStatusItems[item.stableKey] = (item, now)
        }
        statusItems = merged
        iconRow.learn(from: statusItems, livePIDs: Set(apps.map(\.pid)))
        updateCaptures()
        relayoutAllBars()
    }

    private static func screenIsLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    /// TilePilot's own menu bar comes straight from AppKit; Accessibility cannot serve a process
    /// its own menus from a background thread.
    private func ownMenuTitles() -> [SystemBarMenuTitle] {
        guard let mainMenu = NSApp.mainMenu else { return [] }
        // AppKit's main menu starts with the application menu; the Apple menu belongs to the system
        // and cannot be popped up from here, so it is shown but disabled.
        let apple = SystemBarMenuTitle(id: "\(Self.ownMenuIDPrefix)apple", title: "Apple", isAppleMenu: true, isEnabled: false, axWidth: 0)
        return [apple] + mainMenu.items.enumerated().map { index, item in
            SystemBarMenuTitle(
                id: "\(Self.ownMenuIDPrefix)\(index)",
                title: item.title,
                isAppleMenu: false,
                isEnabled: item.isEnabled,
                axWidth: 0
            )
        }
    }

    static let ownMenuIDPrefix = "own-menu:"

    // MARK: - Layout and rendering

    private func relayoutAllBars() {
        for key in bars.keys {
            relayoutBar(key: key)
        }
        syncCaptureRegions()
    }

    private func relayoutBar(key: String) {
        guard let bar = bars[key] else { return }
        let menuWidths = titles.enumerated().map { index, title in
            SystemBarView.measuredTitleWidth(title, isApplicationMenu: index == 1)
        }

        // Remember the icons this display's real bar draws, with their place there (see
        // SystemBarStickyIconPolicy): the active bar is the authority; while another display is
        // active the mirror keeps the last consistent set.
        let presentKeys = Set(statusItems.map(\.stableKey))
        var sticky = (stickyIcons[key] ?? [:]).filter { presentKeys.contains($0.key) }
        lastIconImages = lastIconImages.filter { presentKeys.contains($0.key) }
        if let ownBar = bar.menuBarFrame {
            var drawn: [String: (rightOffset: CGFloat, width: CGFloat)] = [:]
            for item in statusItems {
                guard let placement = item.ownBarPlacements.first(where: { $0.menuBar.intersects(ownBar) }) else { continue }
                drawn[item.stableKey] = (ownBar.maxX - placement.frame.maxX, placement.frame.width)
            }
            let ownBarIsActive = activeMenuBar.map { $0.intersects(ownBar) } ?? false
            sticky = SystemBarStickyIconPolicy.update(sticky, drawn: drawn, ownBarIsActive: ownBarIsActive, now: Date())
        }
        stickyIcons[key] = sticky
        let shownSticky = SystemBarStickyIconPolicy.shown(sticky)

        var shown: [SystemBarStatusItem] = []
        var metrics: [SystemBarIconMetric] = []
        if includeOtherDisplayIcons {
            // Every icon once, in the order macOS keeps across displays, packed from the right
            // with real spacing. The row does not change when focus moves; pixels and clicks still
            // go to wherever macOS draws each icon. An icon not yet seen drawn anywhere has no
            // pixels to copy, so it waits instead of showing a stand-in that does not match.
            let canMatch = canMatchIcons
            let row = iconRow.layout(statusItems) { item in
                !canMatch || item.pixelSource != nil || lastIconImages[item.stableKey] != nil
            }
            shown = row.map(\.item)
            metrics = row.map(\.metric)
        } else {
            for item in statusItems {
                guard let own = shownSticky[item.stableKey] else { continue }
                shown.append(item)
                metrics.append(SystemBarIconMetric(width: own.width, rightOffset: own.rightOffset, group: 1_000))
            }
        }
        let plan = SystemBarLayoutPlanner.plan(barWidth: bar.layout.bar.width, menuWidths: menuWidths, icons: metrics)
        activeBackgroundRect = backgroundSampleRect(menuWidths: menuWidths)
        var content = SystemBarContent(titles: titles, icons: shown, iconRenderings: [:], plan: plan)
        fillImages(of: &content, bar: bar)
        bar.view.content = content
    }

    /// Redraws icon pixels after the capture reports changed regions, keeping the layout.
    private func refreshIconImages() {
        for (key, bar) in bars {
            var content = bar.view.content
            fillImages(of: &content, bar: bar)
            bars[key]?.view.content = content
        }
    }

    private static func regionKey(for source: SystemBarPlacement) -> String {
        let frame = source.frame
        return "icon|\(Int(frame.minX))|\(Int(frame.minY))|\(Int(frame.width))x\(Int(frame.height))"
    }

    private static let backgroundRegionKey = "background|active"

    /// The bar macOS treats as active: Accessibility reports every icon there.
    var activeMenuBar: CGRect? {
        var counts: [String: (bar: CGRect, count: Int)] = [:]
        for item in statusItems where item.reportedMenuBarFrame.width > 0 {
            let key = Self.barKey(item.reportedMenuBarFrame)
            counts[key] = (item.reportedMenuBarFrame, (counts[key]?.count ?? 0) + 1)
        }
        return counts.values.max { $0.count < $1.count }?.bar
    }

    /// Tells each capture which rectangles to watch: the shown icons drawn on its display, and
    /// a background sample on the active bar.
    private func syncCaptureRegions() {
        guard !captureSet.isEmpty else { return }
        let display = displayLookup()
        var regionsByDisplay: [CGDirectDisplayID: [String: CGRect]] = [:]
        for bar in bars.values {
            let content = bar.view.content
            for slot in content.plan.slots {
                guard case let .icon(index) = slot.kind, content.icons.indices.contains(index),
                      let source = content.icons[index].pixelSource,
                      let id = display(source.menuBar) else { continue }
                regionsByDisplay[id, default: [:]][Self.regionKey(for: source)] = CGRect(
                    x: source.frame.minX - source.menuBar.minX,
                    y: source.frame.minY - source.menuBar.minY,
                    width: source.frame.width,
                    height: source.frame.height
                )
            }
        }
        if let active = activeBackgroundRect, let id = display(active.menuBar) {
            regionsByDisplay[id, default: [:]][Self.backgroundRegionKey] = active.rect
        }
        captureSet.setRegions(regionsByDisplay)
    }

    private func fillImages(of content: inout SystemBarContent, bar: DisplayBar) {
        let canMatch = canMatchIcons
        let display = displayLookup()
        func capture(for menuBar: CGRect) -> MenuBarStripCapture? {
            guard canMatch, let id = display(menuBar) else { return nil }
            return captureSet.capture(for: id)
        }
        var renderings: [Int: SystemBarIconRendering] = [:]
        for slot in content.plan.slots {
            guard case let .icon(index) = slot.kind, content.icons.indices.contains(index) else { continue }
            let item = content.icons[index]
            var image: CGImage?
            var size = item.frame.size
            var top = item.menuBarLocalY
            if let source = item.pixelSource {
                image = capture(for: source.menuBar)?.image(for: Self.regionKey(for: source))
                size = source.frame.size
                top = source.frame.minY - source.menuBar.minY
            }
            if let image {
                lastIconImages[item.stableKey] = (image, size, top)
            } else if canMatch, let previous = lastIconImages[item.stableKey] {
                image = previous.image
                size = previous.size
                top = previous.top
            }
            renderings[index] = rendering(for: item, barHeight: bar.layout.bar.height, matchingImage: image, size: size, top: top)
        }
        content.iconRenderings = renderings
        if !canMatch {
            lastIconImages.removeAll()
        }

        if canMatch {
            backgroundLook.update(sample: activeBackgroundRect.flatMap { capture(for: $0.menuBar)?.image(for: Self.backgroundRegionKey) })
        } else {
            backgroundLook.reset()
        }
        content.backgroundColor = backgroundLook.current?.color
        content.backgroundIsDark = backgroundLook.current?.isDark ?? false
    }

    /// The empty stretch of the active real bar between its menu titles and its first icon, in
    /// points relative to that bar.
    private func backgroundSampleRect(menuWidths: [CGFloat]) -> (menuBar: CGRect, rect: CGRect)? {
        guard let active = activeMenuBar else { return nil }
        let menusEnd = SystemBarLayoutPlanner.leadingInset + menuWidths.reduce(0, +)
        let iconsStart = statusItems
            .filter { $0.isPositionConfirmed && $0.menuBarFrame.intersects(active) }
            .map { $0.frame.minX - active.minX }
            .min() ?? active.width
        let sample = CGRect(x: menusEnd + 40, y: 0, width: iconsStart - 40 - (menusEnd + 40), height: active.height)
        guard sample.width >= 60 else { return nil }
        return (active, sample.integral)
    }

    private func rendering(for item: SystemBarStatusItem, barHeight: CGFloat, matchingImage: CGImage?, size: CGSize, top: CGFloat) -> SystemBarIconRendering {
        if let matchingImage {
            let realBarHeight = item.pixelSource?.menuBar.height ?? barHeight
            let placedTop = realBarHeight == barHeight ? top : ((barHeight - size.height) / 2).rounded()
            return .matching(matchingImage, size: size, top: placedTop)
        }
        if item.isClock {
            return .text(item.value.isEmpty ? Self.clockFallbackText() : item.value)
        }
        if let symbol = item.simplifiedSymbolName {
            return .symbol(symbol)
        }
        if let text = item.simplifiedTitleText {
            return .text(text)
        }
        if item.pid == ownPID {
            return .appIcon(NSApp.applicationIconImage)
        }
        if let icon = appIcon(for: item.pid) {
            return .appIcon(icon)
        }
        return .symbol("circle.fill")
    }

    private static func clockFallbackText() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE MMM d  h:mm a"
        return formatter.string(from: Date())
    }

    func appIcon(for pid: pid_t) -> NSImage? {
        if let cached = appIconCache[pid] { return cached }
        guard let icon = NSRunningApplication(processIdentifier: pid)?.icon else { return nil }
        appIconCache[pid] = icon
        return icon
    }

    private func scheduleRedraw() {
        guard !redrawScheduled else { return }
        redrawScheduled = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Self.redrawThrottleMilliseconds))
            guard let self else { return }
            self.redrawScheduled = false
            self.refreshIconImages()
        }
    }

    // MARK: - Captures

    /// The display a real menu bar (top-left coordinates) belongs to.
    private func displayID(forMenuBar menuBar: CGRect) -> CGDirectDisplayID? {
        let primaryMaxY = AppModel.primaryScreenMaxY()
        let midpoint = CGPoint(x: menuBar.midX, y: menuBar.midY)
        return NSScreen.screens.first {
            WorkAreaGeometry.topLeftRect(fromAppKit: $0.frame, primaryScreenMaxY: primaryMaxY).contains(midpoint)
        }?.displayID
    }

    /// `displayID(forMenuBar:)` with answers kept for the caller's pass over many icons.
    func displayLookup() -> (CGRect) -> CGDirectDisplayID? {
        var cache: [String: CGDirectDisplayID?] = [:]
        return { [unowned self] menuBar in
            let key = Self.barKey(menuBar)
            if let known = cache[key] { return known }
            let id = self.displayID(forMenuBar: menuBar)
            cache[key] = id
            return id
        }
    }

    /// Identifies a real menu bar by its top-left corner.
    static func barKey(_ bar: CGRect) -> String {
        SystemBarIconRow.barKey(bar)
    }

    private var canMatchIcons: Bool {
        matchingIconsEnabled && !captureSet.isEmpty && screenRecordingAuthorized()
    }

    private func updateCaptures() {
        guard matchingIconsEnabled, screenRecordingAuthorized(), !bars.isEmpty else {
            captureSet.stopAll()
            return
        }
        let screens = NSScreen.screens
        let primaryMaxY = AppModel.primaryScreenMaxY()
        var wanted: [CGDirectDisplayID: (strip: CGRect, scale: CGFloat)] = [:]
        for item in statusItems {
            guard let displayID = displayID(forMenuBar: item.menuBarFrame), wanted[displayID] == nil else { continue }
            guard let screen = screens.first(where: { $0.displayID == displayID }) else { continue }
            let screenTopLeft = WorkAreaGeometry.topLeftRect(fromAppKit: screen.frame, primaryScreenMaxY: primaryMaxY)
            let strip = CGRect(
                x: item.menuBarFrame.minX - screenTopLeft.minX,
                y: item.menuBarFrame.minY - screenTopLeft.minY,
                width: item.menuBarFrame.width,
                height: item.menuBarFrame.height
            )
            wanted[displayID] = (strip, screen.backingScaleFactor)
        }
        captureSet.update(wanted: wanted, colorSpace: bars.values.first?.panel.screen?.colorSpace?.cgColorSpace)
        syncCaptureRegions()
    }

    /// Retries capture right away (for example after Screen Recording was granted).
    func resetCaptureFailures() {
        captureSet.clearFailures()
        updateCaptures()
    }
}
