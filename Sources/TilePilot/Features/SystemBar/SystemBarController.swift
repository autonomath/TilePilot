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

    private final class SystemBarPanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    /// A submenu whose items are read from Accessibility the moment it opens.
    private final class MirroredMenu: NSMenu {
        let parentID: MirrorElementID
        var isLoaded = false

        init(parentID: MirrorElementID, title: String) {
            self.parentID = parentID
            super.init(title: title)
            autoenablesItems = false
        }

        @available(*, unavailable)
        required init(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }
    }

    private enum MenuItemTarget {
        case element(MirrorElementID)
        case dynamicStatusItem(statusItemID: MirrorElementID, itemID: MirrorElementID, title: String, index: Int)
        case overflowIcon(Int)
    }

    private final class MenuItemReference: NSObject {
        let target: MenuItemTarget
        init(_ target: MenuItemTarget) { self.target = target }
    }

    private struct DisplayBar {
        let key: String
        let panel: SystemBarPanel
        let view: SystemBarView
        var layout: SystemBarLayout
        var menuBarFrame: CGRect?
    }

    private struct OverflowContext {
        let barKey: String
        let slot: SystemBarSlot
        let slotIndex: Int
    }

    private static let refreshTickSeconds: UInt64 = 1
    private static let titleRefreshTicks = 2
    private static let iconRefreshTicks = 3
    private static let redrawThrottleMilliseconds = 250
    private static let submenuReadTimeout: TimeInterval = 0.5

    let reader = AccessibilityMirrorReader()

    private var bars: [String: DisplayBar] = [:]
    private var titles: [SystemBarMenuTitle] = []
    private var titlesPID: pid_t?
    private var statusItems: [SystemBarStatusItem] = []
    private var menuBarFrames: [CGRect] = []
    private var menuBarFramesReadAt: Date?
    private var captures: [CGDirectDisplayID: MenuBarStripCapture] = [:]
    /// Why each display's capture last stopped, and how many tries in a row have failed. A
    /// successful start clears the entry.
    private var captureFailures: [CGDirectDisplayID: (at: Date, reason: String, attempts: Int)] = [:]
    /// Per bar: icons seen on that display's real bar, with their place there.
    private var stickyIcons: [String: [String: SystemBarStickyIcon]] = [:]
    // The row shown with every display's icons (see `learnIconRow`).
    /// Left-to-right order of the icons present now.
    private var iconRowOrder: [String] = []
    /// The same order plus icons missing right now whose app still runs, in their last places.
    private var iconRowMemory: [String] = []
    /// Each icon's gap to its right-hand neighbour.
    private var iconRowGaps: [String: CGFloat] = [:]
    /// Space between the last icon and the bar's right edge.
    private var iconRowTrailingInset: CGFloat = SystemBarLayoutPlanner.defaultTrailingInset
    /// The real bar whose row the mirror copies; kept until another bar clearly draws more.
    private var iconRowReference: String?
    private var activeBackgroundRect: (menuBar: CGRect, rect: CGRect)?
    private var lastBackgroundImage: CGImage?
    /// The newest sampled look and when it was first seen; it replaces `barLook` only after
    /// holding steady, so the fade macOS runs on a switching bar never reaches the mirror.
    private var candidateLook: (color: CGColor, isDark: Bool, since: Date)?
    private static let lookSettleSeconds: TimeInterval = 1.5
    private var activationScanTask: Task<Void, Never>?
    private var barLook: (color: CGColor, isDark: Bool)?
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
    private var menuInProgress = false
    /// The last icon click and its outcome, for the status route.
    private var lastClickTrace = "none"
    /// The panel a real click on an icon opened, watched while it stays open. Clicking that icon
    /// again closes the panel instead of closing and reopening it: many apps close their panel
    /// on any mouse down outside it, before the mirror sees the click.
    private struct WatchedPanel {
        let iconKey: String
        let pid: Int32
        let windowIDs: Set<Int>
        var lastSeenOpen: Date
    }

    private static let panelWatchInterval: Duration = .milliseconds(100)
    private static let panelJustClosedSeconds: TimeInterval = 0.25
    private var watchedPanel: WatchedPanel?
    private var panelWatchTask: Task<Void, Never>?
    private var overflowContext: OverflowContext?
    private(set) var lastMenuActionSummary = "none"
    private let ownPID = ProcessInfo.processInfo.processIdentifier

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
        matchingIconsEnabled && screenRecordingAuthorized() && captures.values.contains { $0.isRunning }
    }

    override init() {
        super.init()
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
                self?.captureFailures.removeAll()
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
            stopAllCaptures()
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
        stopAllCaptures()
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
        learnIconRow(livePIDs: Set(apps.map(\.pid)))
        updateCaptures()
        relayoutAllBars()
    }

    private static func screenIsLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    /// Chooses the mirror's icon row and each icon's spacing from what the real bars draw (see
    /// SystemBarIconRow.order). Only confirmed positions count; what cannot be measured right now
    /// keeps its previous place and spacing.
    private func learnIconRow(livePIDs: Set<pid_t>) {
        let barKey = Self.barKey
        var icons: [(key: String, sightings: [SystemBarIconRow.Sighting], isSystem: Bool)] = []
        var frames: [String: [String: CGRect]] = [:]
        var trailingInsets: [String: [String: CGFloat]] = [:]
        for item in statusItems {
            let placements = item.allPlacements.filter { $0.frame.width > 0 }
            for placement in placements {
                frames[item.stableKey, default: [:]][barKey(placement.menuBar)] = placement.frame
                trailingInsets[item.stableKey, default: [:]][barKey(placement.menuBar)] = placement.menuBar.maxX - placement.frame.maxX
            }
            var sightings = placements.map { SystemBarIconRow.Sighting(bar: barKey($0.menuBar), minX: $0.frame.minX) }
            if sightings.isEmpty {
                sightings = [SystemBarIconRow.Sighting(bar: barKey(item.reportedMenuBarFrame), minX: item.reportedFrame.minX)]
            }
            icons.append((item.stableKey, sightings, item.isSystemExtra))
        }
        let result = SystemBarIconRow.order(icons: icons, previousReference: iconRowReference, previousOrder: iconRowMemory)
        iconRowOrder = result.order
        iconRowReference = result.reference
        iconRowMemory = SystemBarIconRow.remembered(order: result.order, previous: iconRowMemory) { key in
            key.split(separator: ":").first.flatMap { pid_t($0) }.map(livePIDs.contains) ?? false
        }
        iconRowGaps = SystemBarIconRow.learnedGaps(order: iconRowOrder, frames: frames, previous: iconRowGaps)
        // The last icon's distance from the right edge, as the copied bar draws it.
        if let lastKey = iconRowOrder.last, let reference = iconRowReference,
           let inset = trailingInsets[lastKey]?[reference] {
            iconRowTrailingInset = min(max(inset, 4), 40)
        }
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

    private static let ownMenuIDPrefix = "own-menu:"

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
            let byKey = Dictionary(statusItems.map { ($0.stableKey, $0) }, uniquingKeysWith: { first, _ in first })
            let order = iconRowOrder.filter { key in
                guard let item = byKey[key] else { return false }
                return !canMatch || item.pixelSource != nil || lastIconImages[key] != nil
            }
            var widths: [String: CGFloat] = [:]
            for key in order {
                guard let item = byKey[key] else { continue }
                widths[key] = item.frame.width > 0 ? item.frame.width : item.reportedFrame.width
            }
            let offsets = SystemBarIconRow.packedRightOffsets(
                order: order,
                widths: widths,
                trailingGaps: iconRowGaps,
                trailingInset: iconRowTrailingInset
            )
            for key in order {
                guard let item = byKey[key], let offset = offsets[key], let width = widths[key] else { continue }
                shown.append(item)
                metrics.append(SystemBarIconMetric(width: width, rightOffset: offset, group: 1_000))
            }
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
    private var activeMenuBar: CGRect? {
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
        guard !captures.isEmpty else { return }
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
        for (id, capture) in captures {
            capture.setRegions(regionsByDisplay[id] ?? [:])
        }
    }

    private func fillImages(of content: inout SystemBarContent, bar: DisplayBar) {
        let canMatch = canMatchIcons
        let display = displayLookup()
        func capture(for menuBar: CGRect) -> MenuBarStripCapture? {
            guard canMatch, let id = display(menuBar) else { return nil }
            return captures[id]
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

        // One solid color, sampled from the active bar and kept while another display is active,
        // so the mirror never turns gray when macOS dims the real bar.
        if canMatch, let active = activeBackgroundRect,
           let image = capture(for: active.menuBar)?.image(for: Self.backgroundRegionKey),
           image !== lastBackgroundImage {
            lastBackgroundImage = image
            if let look = Self.averageLook(image) {
                if barLook == nil {
                    barLook = look
                } else if !Self.sameLook(look.color, candidateLook?.color) {
                    candidateLook = (look.color, look.isDark, Date())
                }
            }
        }
        if let candidate = candidateLook, Date().timeIntervalSince(candidate.since) >= Self.lookSettleSeconds {
            if !Self.sameLook(candidate.color, barLook?.color) {
                barLook = (candidate.color, candidate.isDark)
            }
            candidateLook = nil
        }
        if !canMatch {
            barLook = nil
            lastBackgroundImage = nil
            candidateLook = nil
        }
        content.backgroundColor = barLook?.color
        content.backgroundIsDark = barLook?.isDark ?? false
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

    /// True when two colors are within 3% per channel (or both missing).
    private static func sameLook(_ lhs: CGColor?, _ rhs: CGColor?) -> Bool {
        guard let left = lhs?.components, let right = rhs?.components, left.count >= 3, right.count >= 3 else {
            return lhs == nil && rhs == nil
        }
        return zip(left.prefix(3), right.prefix(3)).allSatisfy { abs($0 - $1) < 0.03 }
    }

    /// The average color of an image and whether it reads as dark.
    private static func averageLook(_ image: CGImage) -> (color: CGColor, isDark: Bool)? {
        guard let context = CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let data = context.data else { return nil }
        let pixel = data.bindMemory(to: UInt8.self, capacity: 4)
        let red = CGFloat(pixel[0]) / 255, green = CGFloat(pixel[1]) / 255, blue = CGFloat(pixel[2]) / 255
        let luminance = 0.299 * red + 0.587 * green + 0.114 * blue
        return (CGColor(srgbRed: red, green: green, blue: blue, alpha: 1), luminance < 0.5)
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

    private func appIcon(for pid: pid_t) -> NSImage? {
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
    private func displayLookup() -> (CGRect) -> CGDirectDisplayID? {
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
    private static func barKey(_ bar: CGRect) -> String {
        "\(Int(bar.minX)),\(Int(bar.minY))"
    }

    private var canMatchIcons: Bool {
        matchingIconsEnabled && !captures.isEmpty && screenRecordingAuthorized()
    }

    private func updateCaptures() {
        guard matchingIconsEnabled, screenRecordingAuthorized(), !bars.isEmpty else {
            stopAllCaptures()
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

        for (displayID, capture) in captures where wanted[displayID] == nil || wanted[displayID]?.strip != capture.stripRect {
            captures.removeValue(forKey: displayID)
            Task { await capture.stop() }
        }
        for (displayID, spec) in wanted where captures[displayID] == nil {
            if let failure = captureFailures[displayID],
               Date().timeIntervalSince(failure.at) < SystemBarCapturePolicy.retryDelay(afterFailures: failure.attempts) {
                continue
            }
            let barColorSpace = bars.values.first?.panel.screen?.colorSpace?.cgColorSpace
            let capture = MenuBarStripCapture(
                displayID: displayID,
                stripRect: spec.strip,
                scale: spec.scale,
                targetColorSpace: barColorSpace
            ) { [weak self] in
                Task { @MainActor in
                    self?.scheduleRedraw()
                }
            }
            capture.markStarting()
            captures[displayID] = capture
            Task { [weak self] in
                do {
                    try await capture.start()
                    guard let self, self.captures[displayID] === capture else { return }
                    self.captureFailures[displayID] = nil
                } catch {
                    guard let self else { return }
                    if self.captures[displayID] === capture {
                        self.captures.removeValue(forKey: displayID)
                    }
                    let attempts = (self.captureFailures[displayID]?.attempts ?? 0) + 1
                    self.captureFailures[displayID] = (Date(), error.localizedDescription, attempts)
                    if attempts == SystemBarCapturePolicy.attemptsBeforeMessage {
                        self.onMessage?("Menu bar icons use the simplified look until the real menu bar can be captured (\(error.localizedDescription)).", false)
                    }
                    self.relayoutAllBars()
                }
            }
        }
        for (displayID, capture) in captures where !capture.isStartingOrRunning {
            // The stream stopped on its own (display change, lock screen). Drop it so its last
            // pixels are never shown as if live, and start a new one soon.
            let reason: String
            if case let .stopped(why) = capture.state { reason = why } else { reason = "not running" }
            captures.removeValue(forKey: displayID)
            captureFailures[displayID] = (Date(), reason, (captureFailures[displayID]?.attempts ?? 0) + 1)
            Task { await capture.stop() }
        }
        syncCaptureRegions()
    }

    private func stopAllCaptures() {
        let running = captures.values
        captures.removeAll()
        for capture in running {
            Task { await capture.stop() }
        }
    }

    /// Retries capture right away (for example after Screen Recording was granted).
    func resetCaptureFailures() {
        captureFailures.removeAll()
        updateCaptures()
    }

    /// Development route: stops every running capture as a display change would.
    func simulateCaptureStopForDiagnostics() -> String {
        let running = captures.values.filter(\.isRunning)
        for capture in running {
            Task { await capture.simulateUnexpectedStop() }
        }
        return "stopped \(running.count) capture(s)"
    }

    // MARK: - Diagnostics

    /// Runs the click handler for a slot of the first bar, as a left or right click would. Used by
    /// the experimental status route to exercise menus without a pointer.
    func simulateClick(slotIndex: Int, rightClick: Bool) -> String {
        guard let bar = bars.values.sorted(by: { $0.key < $1.key }).first else { return "no bar" }
        let slots = bar.view.content.plan.slots
        guard slots.indices.contains(slotIndex) else { return "no slot \(slotIndex) (\(slots.count) slots)" }
        let slot = slots[slotIndex]
        handleClick(barKey: bar.key, slot: slot, secondary: rightClick)
        return "clicked slot \(slotIndex) \(slot.kind)"
    }

    /// One line per bar describing what it shows right now, for the status route.
    func diagnosticsSummary() -> String {
        var lines: [String] = []
        for bar in bars.values.sorted(by: { $0.key < $1.key }) {
            let plan = bar.view.content.plan
            let iconSlots = plan.slots.filter { if case .icon = $0.kind { return true } else { return false } }
            let matching = bar.view.content.iconRenderings.values.filter { if case .matching = $0 { return true } else { return false } }.count
            lines.append(
                "bar \(bar.key): frame \(Int(bar.panel.frame.minX)),\(Int(bar.panel.frame.minY)) \(Int(bar.panel.frame.width))x\(Int(bar.panel.frame.height)) appkit; visible \(bar.panel.isVisible); titles \(titles.count) (\(titles.map(\.title).joined(separator: "|"))); icons \(iconSlots.count)/\(statusItems.count) shown, \(matching) matching, overflow menus \(plan.overflowMenuIndices.count) icons \(plan.overflowIconIndices.count); captures \(captures.keys.sorted()) running \(captures.values.filter(\.isRunning).count) failed \(captureFailures.map { "\($0.key): \($0.value.reason)" }.sorted()); frontmost pid \(titlesPID ?? -1)"
            )
        }
        if lines.isEmpty { lines.append("no bars") }
        lines.append("last click: \(lastClickTrace); reader: \(reader.lastClickNote)")
        let display = displayLookup()
        // Bars are named by display number in the lines below, for example D2:2870.
        func barName(_ bar: CGRect) -> String {
            display(bar).map { "D\($0)" } ?? Self.barKey(bar)
        }
        var mapping: [String: String] = [:]
        for item in statusItems {
            mapping[Self.barKey(item.menuBarFrame)] = display(item.menuBarFrame).map { "display \($0)" } ?? "no display"
        }
        lines.append("icon bars -> displays: \(mapping.sorted { $0.key < $1.key }); unconfirmed icons: \(statusItems.filter { !$0.isPositionConfirmed }.map(\.appName))")
        let active = activeMenuBar.map(Self.barKey) ?? "unknown"
        let look = barLook.map { "\($0.color.components?.prefix(3).map { String(format: "%.2f", $0) } ?? []) dark \($0.isDark)" } ?? "none"
        lines.append("active bar \(active); bar look \(look); include other displays \(includeOtherDisplayIcons)")
        let itemsByKey = Dictionary(statusItems.map { ($0.stableKey, $0) }, uniquingKeysWith: { first, _ in first })
        let rowText = iconRowOrder.compactMap { key -> String? in
            guard let item = itemsByKey[key] else { return nil }
            let bars = item.allPlacements.map { "\(barName($0.menuBar)):\(Int($0.frame.minX))" }
            return "\(item.shortName)[\(bars.joined(separator: "/"))]"
        }
        lines.append("icon row: \(rowText.joined(separator: " "))")
        let scan = reader.lastScanStats
        let searched = scan.searchedKeys.map { itemsByKey[$0]?.shortName ?? $0 }
        lines.append("last scan: \(String(format: "%.2f", scan.seconds)) s, \(scan.hitTests) hit tests, searched \(searched)")
        for bar in bars.values.sorted(by: { $0.key < $1.key }) {
            let shown = bar.view.content.icons.map { item -> String in
                guard let source = item.pixelSource else { return "\(item.shortName)@-" }
                let confirmed = item.isPositionConfirmed ? "" : "~"
                return "\(item.shortName)@\(barName(source.menuBar))[\(Int(source.frame.minX))..\(Int(source.frame.maxX))]\(confirmed)"
            }
            lines.append("shown on \(bar.key.prefix(8)): \(shown.joined(separator: ", "))")
        }
        for (id, capture) in captures.sorted(by: { $0.key < $1.key }) {
            lines.append("capture \(id): state \(capture.state) strip \(capture.stripRect) scale \(capture.scale) \(capture.regionSummary)")
        }
        for bar in bars.values.sorted(by: { $0.key < $1.key }) {
            let content = bar.view.content
            lines.append("view bounds \(bar.view.bounds) window content \(bar.panel.contentView?.bounds ?? .zero)")
            for slot in content.plan.slots {
                let label: String
                switch slot.kind {
                case let .menu(index): label = "menu " + (content.titles.indices.contains(index) ? content.titles[index].title : "?")
                case let .icon(index): label = "icon " + (content.icons.indices.contains(index) ? content.icons[index].appName + " [" + content.icons[index].identifier + "]" : "?")
                case .overflow: label = "overflow"
                }
                lines.append("  slot x \(Int(slot.x)) w \(Int(slot.width)) \(label)")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Clicks

    private func handleClick(barKey: String, slot: SystemBarSlot, secondary: Bool) {
        guard let bar = bars[barKey] else { return }
        guard !menuInProgress else {
            lastClickTrace = "ignored: a menu is still opening"
            return
        }
        guard let slotIndex = bar.view.content.plan.slots.firstIndex(of: slot) else { return }
        switch slot.kind {
        case let .menu(index):
            guard titles.indices.contains(index) else { return }
            openAppMenu(titles[index], slot: slot, slotIndex: slotIndex, barKey: barKey)
        case let .icon(index):
            let icons = bar.view.content.icons
            guard icons.indices.contains(index) else { return }
            openIcon(icons[index], slot: slot, slotIndex: slotIndex, barKey: barKey, rightClick: secondary)
        case .overflow:
            openOverflow(slot: slot, slotIndex: slotIndex, barKey: barKey)
        }
    }

    private func openAppMenu(_ title: SystemBarMenuTitle, slot: SystemBarSlot, slotIndex: Int, barKey: String) {
        if title.id == "\(Self.ownMenuIDPrefix)apple" { return }
        if title.id.hasPrefix(Self.ownMenuIDPrefix),
           let index = Int(title.id.dropFirst(Self.ownMenuIDPrefix.count)),
           let items = NSApp.mainMenu?.items, items.indices.contains(index),
           let submenu = items[index].submenu {
            popUp(submenu, slot: slot, slotIndex: slotIndex, barKey: barKey)
            return
        }
        menuInProgress = true
        Task { [weak self] in
            guard let self else { return }
            let items = await self.reader.readMenuItems(parentID: title.id)
            self.menuInProgress = false
            guard let items, !items.isEmpty else {
                self.onMessage?("The \(title.title.isEmpty ? "Apple" : title.title) menu is empty right now.", true)
                return
            }
            let menu = NSMenu(title: title.title)
            menu.autoenablesItems = false
            self.fill(menu, with: items) { item, _ in .element(item.id) }
            self.popUp(menu, slot: slot, slotIndex: slotIndex, barKey: barKey)
        }
    }

    private func openIcon(_ item: SystemBarStatusItem, slot: SystemBarSlot, slotIndex: Int, barKey: String, rightClick: Bool) {
        guard let bar = bars[barKey] else { return }
        if item.pid == ownPID, let quickMenuPresenter {
            bar.view.openSlotIndex = slotIndex
            quickMenuPresenter(bar.view, NSPoint(x: slot.x, y: bar.view.bounds.height))
            bar.view.openSlotIndex = nil
            return
        }
        menuInProgress = true
        lastClickTrace = "\(item.appName) \(rightClick ? "right" : "left"): started"
        let closingPanel = rightClick ? nil : watchedPanel.flatMap { panel -> WatchedPanel? in
            guard panel.iconKey == item.stableKey else { return nil }
            let isOpen = !panel.windowIDs.isDisjoint(with: Self.onScreenWindowIDs(pid: panel.pid))
            return isOpen || Date().timeIntervalSince(panel.lastSeenOpen) < Self.panelJustClosedSeconds ? panel : nil
        }
        Task { [weak self] in
            guard let self else { return }
            if let closingPanel {
                await Self.waitForPrimaryButtonRelease()
                try? await Task.sleep(for: .milliseconds(150))
                if closingPanel.windowIDs.isDisjoint(with: Self.onScreenWindowIDs(pid: closingPanel.pid)) {
                    self.stopWatchingPanel()
                    self.lastClickTrace = "\(item.appName) left: its panel closed with the click"
                    self.menuInProgress = false
                    return
                }
            }
            var items: [MirroredMenuItem]?
            var isDynamic = false
            if !rightClick {
                // Icons with a static menu expose it without opening; others return nil here.
                items = await self.reader.readMenuItems(parentID: item.id)
            }
            if let items {
                self.lastClickTrace = "\(item.appName) left: static menu with \(items.count) items"
            }
            if items == nil {
                // Accessibility has no right-click action, and many apps ignore its press for a
                // left click too (they read the mouse event), so third-party icons get real
                // clicks where the icon is drawn. Apps decide what each click does (the Sonos
                // controller plays or pauses on a right click).
                let point = item.pixelSource.map { CGPoint(x: $0.frame.midX, y: $0.frame.midY) }
                let windowsBefore = Self.onScreenWindowIDs(pid: item.pid)
                let outcome: AccessibilityMirrorReader.PressOutcome
                if rightClick {
                    outcome = await self.reader.rightClickStatusItem(item.id, at: point)
                } else {
                    outcome = await self.reader.clickStatusItem(item.id, at: point)
                }
                let opened = Self.onScreenWindowIDs(pid: item.pid).subtracting(windowsBefore)
                if !rightClick {
                    if case .pressed = outcome, !opened.isEmpty {
                        self.watchPanel(WatchedPanel(iconKey: item.stableKey, pid: item.pid, windowIDs: opened, lastSeenOpen: Date()))
                    } else {
                        self.stopWatchingPanel()
                    }
                }
                let summary: String
                switch outcome {
                case .failed: summary = "failed"
                case .pressed: summary = "pressed"
                case let .menuOpened(list): summary = "menu with \(list.count) items"
                }
                self.lastClickTrace = "\(item.appName) \(rightClick ? "right" : "left"): \(summary), new windows \(opened.sorted())"
                switch outcome {
                case .failed:
                    self.onMessage?("TilePilot couldn't open \(item.displayName).", true)
                case .pressed:
                    if !rightClick, !opened.isEmpty {
                        self.onMessage?("\(item.displayName) opened where macOS shows it.", false)
                    }
                case let .menuOpened(list):
                    items = list
                    isDynamic = true
                }
            }
            self.menuInProgress = false
            guard let items, !items.isEmpty else { return }
            let menu = NSMenu(title: item.appName)
            menu.autoenablesItems = false
            self.fill(menu, with: items) { entry, index in
                isDynamic
                    ? .dynamicStatusItem(statusItemID: item.id, itemID: entry.id, title: entry.title, index: index)
                    : .element(entry.id)
            }
            self.popUp(menu, slot: slot, slotIndex: slotIndex, barKey: barKey)
        }
    }

    private func watchPanel(_ panel: WatchedPanel) {
        panelWatchTask?.cancel()
        watchedPanel = panel
        panelWatchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.panelWatchInterval)
                guard let self, let current = self.watchedPanel, !Task.isCancelled else { return }
                // Once it closes, keep the last time it was seen so a click that closed it
                // is recognized, then stop polling.
                guard !current.windowIDs.isDisjoint(with: Self.onScreenWindowIDs(pid: current.pid)) else { return }
                self.watchedPanel?.lastSeenOpen = Date()
            }
        }
    }

    private func stopWatchingPanel() {
        panelWatchTask?.cancel()
        panelWatchTask = nil
        watchedPanel = nil
    }

    private static func onScreenWindowIDs(pid: Int32) -> Set<Int> {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return Set(list.compactMap { info -> Int? in
            guard (info[kCGWindowOwnerPID as String] as? Int32) == pid else { return nil }
            return info[kCGWindowNumber as String] as? Int
        })
    }

    private static func waitForPrimaryButtonRelease() async {
        var attempts = 0
        while NSEvent.pressedMouseButtons & 0x1 != 0, attempts < 200 {
            attempts += 1
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func openOverflow(slot: SystemBarSlot, slotIndex: Int, barKey: String) {
        guard let bar = bars[barKey] else { return }
        let plan = bar.view.content.plan
        let menu = NSMenu(title: "More")
        menu.autoenablesItems = false
        for index in plan.overflowMenuIndices.sorted() where titles.indices.contains(index) {
            let title = titles[index]
            let entry = NSMenuItem(title: title.isAppleMenu ? "Apple" : title.title, action: nil, keyEquivalent: "")
            entry.submenu = MirroredMenu(parentID: title.id, title: title.title)
            entry.submenu?.delegate = self
            menu.addItem(entry)
        }
        let icons = bar.view.content.icons
        // The planner hides the leftmost icons first, so this keeps their left-to-right order.
        let orderedIcons = plan.overflowIconIndices
        if !orderedIcons.isEmpty, menu.numberOfItems > 0 {
            menu.addItem(.separator())
        }
        for index in orderedIcons where icons.indices.contains(index) {
            let item = icons[index]
            let entry = NSMenuItem(title: item.tooltip, action: #selector(menuItemChosen(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = MenuItemReference(.overflowIcon(index))
            if let icon = item.pid == ownPID ? NSApp.applicationIconImage : appIcon(for: item.pid) {
                let small = icon.copy() as! NSImage
                small.size = NSSize(width: 16, height: 16)
                entry.image = small
            }
            menu.addItem(entry)
        }
        guard menu.numberOfItems > 0 else { return }
        overflowContext = OverflowContext(barKey: barKey, slot: slot, slotIndex: slotIndex)
        popUp(menu, slot: slot, slotIndex: slotIndex, barKey: barKey)
    }

    private func popUp(_ menu: NSMenu, slot: SystemBarSlot, slotIndex: Int, barKey: String) {
        guard let bar = bars[barKey] else { return }
        bar.view.openSlotIndex = slotIndex
        menu.popUp(positioning: nil, at: NSPoint(x: slot.x, y: bar.view.bounds.height), in: bar.view)
        bars[barKey]?.view.openSlotIndex = nil
    }

    private func fill(_ menu: NSMenu, with items: [MirroredMenuItem], target: (MirroredMenuItem, Int) -> MenuItemTarget) {
        for (index, item) in items.enumerated() {
            if item.isSeparator {
                menu.addItem(.separator())
                continue
            }
            let entry = NSMenuItem(title: item.title, action: #selector(menuItemChosen(_:)), keyEquivalent: Self.keyEquivalent(for: item))
            entry.target = self
            entry.isEnabled = item.isEnabled
            entry.state = item.isOn ? .on : .off
            entry.isAlternate = item.isAlternate
            entry.keyEquivalentModifierMask = Self.modifierFlags(for: item.modifiers)
            entry.representedObject = MenuItemReference(target(item, index))
            if item.hasSubmenu {
                let submenu = MirroredMenu(parentID: item.id, title: item.title)
                submenu.delegate = self
                entry.submenu = submenu
                entry.action = nil
            }
            menu.addItem(entry)
        }
    }

    static func keyEquivalent(for item: MirroredMenuItem) -> String {
        if !item.commandCharacter.isEmpty {
            let character = item.commandCharacter
            return item.modifiers.shift ? character.uppercased() : character.lowercased()
        }
        switch item.commandGlyph {
        case 2: return "\t"
        case 4, 36: return "\r"
        case 23: return "\u{8}"
        case 27: return "\u{1b}"
        case 100: return String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!))
        case 101: return String(Character(UnicodeScalar(NSRightArrowFunctionKey)!))
        case 102: return String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))
        case 103: return String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))
        default: return ""
        }
    }

    static func modifierFlags(for modifiers: MirroredMenuModifiers) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers.command { flags.insert(.command) }
        if modifiers.shift { flags.insert(.shift) }
        if modifiers.option { flags.insert(.option) }
        if modifiers.control { flags.insert(.control) }
        if modifiers.function { flags.insert(.function) }
        return flags
    }

    @objc private func menuItemChosen(_ sender: NSMenuItem) {
        guard let reference = sender.representedObject as? MenuItemReference else { return }
        let title = sender.title
        switch reference.target {
        case let .element(id):
            Task { [weak self] in
                guard let self else { return }
                let ok = await self.reader.press(id)
                self.lastMenuActionSummary = "\(ok ? "pressed" : "failed") “\(title)” at \(Date())"
                if !ok {
                    self.onMessage?("TilePilot couldn't choose “\(title)”. Try it from the real menu.", true)
                }
            }
        case let .dynamicStatusItem(statusItemID, itemID, itemTitle, index):
            Task { [weak self] in
                guard let self else { return }
                let ok = await self.reader.pressDynamicMenuItem(statusItemID: statusItemID, itemID: itemID, title: itemTitle, index: index)
                self.lastMenuActionSummary = "\(ok ? "pressed" : "failed") “\(title)” (dynamic) at \(Date())"
                if !ok {
                    self.onMessage?("TilePilot couldn't choose “\(title)”. Try it from the real menu bar icon.", true)
                }
            }
        case let .overflowIcon(index):
            guard let context = overflowContext,
                  let icons = bars[context.barKey]?.view.content.icons,
                  icons.indices.contains(index) else { return }
            openIcon(icons[index], slot: context.slot, slotIndex: context.slotIndex, barKey: context.barKey, rightClick: false)
        }
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let mirrored = menu as? MirroredMenu, !mirrored.isLoaded else { return }
        mirrored.isLoaded = true
        mirrored.removeAllItems()
        guard let items = reader.readMenuItemsBlocking(parentID: mirrored.parentID, timeout: Self.submenuReadTimeout), !items.isEmpty else {
            let placeholder = NSMenuItem(title: "Unavailable", action: nil, keyEquivalent: "")
            placeholder.isEnabled = false
            mirrored.addItem(placeholder)
            return
        }
        fill(mirrored, with: items) { item, _ in .element(item.id) }
    }
}


