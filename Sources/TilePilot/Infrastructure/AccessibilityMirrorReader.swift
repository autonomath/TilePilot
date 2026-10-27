import AppKit
import ApplicationServices
import Foundation

/// Reads app menus and menu bar icons through Accessibility and performs actions on them. Every
/// `AXUIElement` stays inside this object; callers work with snapshots and opaque IDs. Calls run on
/// private queues with short messaging timeouts so a hung app never blocks TilePilot's UI.
final class AccessibilityMirrorReader: @unchecked Sendable {
    struct RunningApp: Sendable, Equatable {
        let pid: pid_t
        let bundleIdentifier: String
        let name: String
        /// Apps that started moments ago may not have added their icon yet.
        var launchedAt: Date? = nil
    }

    enum PressOutcome: Sendable, Equatable {
        case failed
        case menuOpened([MirroredMenuItem])
        case pressed
    }

    private enum ElementKind {
        case menuBarItem
        case menuItem
        case statusItem
    }

    private struct Entry {
        let element: AXUIElement
        let kind: ElementKind
        let generation: Int
    }

    private static let messagingTimeout: Float = 0.25
    private static let noExtrasRescanSeconds: TimeInterval = 30
    private static let dynamicMenuWaitSeconds: TimeInterval = 0.6

    private let scanQueue = DispatchQueue(label: "com.klode.tilepilot.system-bar.scan", qos: .utility)
    private let menuQueue = DispatchQueue(label: "com.klode.tilepilot.system-bar.menu", qos: .userInitiated)
    private let lock = NSLock()
    private var entries: [MirrorElementID: Entry] = [:]
    private var appElements: [pid_t: AXUIElement] = [:]
    private var noExtrasUntil: [pid_t: Date] = [:]
    private var generations: [ElementKind: Int] = [:]
    private var relocationByKey: [String: Relocation] = [:]
    private var ownProbeByKey: [String: OwnBarProbe] = [:]
    /// Each app's AXExtrasMenuBar, so hit tests can tell an icon container from a menu bar.
    private var statusContainerByPID: [pid_t: AXUIElement] = [:]
    private var pidsWithIcons = Set<pid_t>()
    /// The real bars of the current scan and, once a hit test needed it, which app's menu bar
    /// answers for each bar's empty stretches (see barOwnerPID).
    private var scanMenuBars: [CGRect] = []
    private var barOwners: [String: pid_t] = [:]
    private var scanHitTests = 0
    private var scanSearches: [String] = []
    private var scanStats = ScanStats(seconds: 0, hitTests: 0, searchedKeys: [])
    private var clickNote = ""

    /// What the last icon scan cost, for the status route.
    struct ScanStats: Sendable {
        let seconds: TimeInterval
        let hitTests: Int
        /// Icons whose drawn place had to be searched for instead of confirmed in one hit test.
        let searchedKeys: [String]
    }

    var lastScanStats: ScanStats {
        lock.lock()
        defer { lock.unlock() }
        return scanStats
    }
    /// What the last icon click did, for the status route.
    var lastClickNote: String {
        lock.lock()
        defer { lock.unlock() }
        return clickNote
    }

    private func noteClick(_ note: String) {
        lock.lock()
        clickNote = note
        lock.unlock()
    }
    private let systemWide: AXUIElement = {
        let element = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(element, 0.25)
        return element
    }()

    // MARK: - Menu bar titles

    func readMenuBar(pid: pid_t) async -> [SystemBarMenuTitle] {
        await withCheckedContinuation { continuation in
            menuQueue.async {
                continuation.resume(returning: self.readMenuBarSync(pid: pid))
            }
        }
    }

    private func readMenuBarSync(pid: pid_t) -> [SystemBarMenuTitle] {
        let app = applicationElement(pid: pid)
        guard let bar = elementAttribute(app, kAXMenuBarAttribute) else { return [] }
        let generation = beginGeneration(.menuBarItem)
        var titles: [SystemBarMenuTitle] = []
        for (index, item) in children(of: bar).enumerated() {
            let title = string(item, kAXTitleAttribute)
            let frame = frame(of: item)
            titles.append(
                SystemBarMenuTitle(
                    id: register(item, kind: .menuBarItem, generation: generation),
                    title: title,
                    isAppleMenu: index == 0 && (title == "Apple" || title.isEmpty),
                    isEnabled: bool(item, kAXEnabledAttribute) ?? true,
                    axWidth: frame.width
                )
            )
        }
        return titles
    }

    // MARK: - Menu items

    /// The items of the `AXMenu` under a menu bar title, a menu item with a submenu, or a menu bar
    /// icon with a static menu. Nil when the element has no menu right now.
    func readMenuItems(parentID: MirrorElementID) async -> [MirroredMenuItem]? {
        await withCheckedContinuation { continuation in
            menuQueue.async {
                continuation.resume(returning: self.readMenuItemsSync(parentID: parentID, deadline: Date().addingTimeInterval(1.5), startsNewMenu: true))
            }
        }
    }

    /// Blocking variant for `NSMenuDelegate.menuNeedsUpdate`, which must fill submenus
    /// synchronously. Gives up after `timeout` and returns nil.
    func readMenuItemsBlocking(parentID: MirrorElementID, timeout: TimeInterval) -> [MirroredMenuItem]? {
        guard let element = element(for: parentID) else { return nil }
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        // Our own menus are served by the main thread, which is the thread waiting here.
        guard pid != ProcessInfo.processInfo.processIdentifier else { return nil }
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox()
        let deadline = Date().addingTimeInterval(timeout)
        menuQueue.async {
            let items = self.readMenuItemsSync(parentID: parentID, deadline: deadline, startsNewMenu: false)
            box.set(items)
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + timeout + 0.05) == .success else { return nil }
        return box.get()
    }

    /// Reads the items of a menu. Opening a new menu starts a new element generation; submenus
    /// join the generation of the menu they belong to so its items stay pressable.
    private func readMenuItemsSync(parentID: MirrorElementID, deadline: Date, startsNewMenu: Bool) -> [MirroredMenuItem]? {
        guard let parent = element(for: parentID) else { return nil }
        guard let menu = menuChild(of: parent) else { return nil }
        let generation = startsNewMenu ? beginGeneration(.menuItem) : currentGeneration(.menuItem)
        var items: [MirroredMenuItem] = []
        for item in children(of: menu) {
            if Date() > deadline { break }
            let title = string(item, kAXTitleAttribute)
            let enabled = bool(item, kAXEnabledAttribute) ?? false
            let hasSubmenu = menuChild(of: item) != nil
            let command = string(item, "AXMenuItemCmdChar")
            let modifiers = MirroredMenuModifiers(
                axModifiers: integer(item, "AXMenuItemCmdModifiers"),
                hasCommandCharacter: !command.isEmpty || (integer(item, "AXMenuItemCmdGlyph") ?? 0) > 0
            )
            items.append(
                MirroredMenuItem(
                    id: register(item, kind: .menuItem, generation: generation),
                    title: title,
                    isEnabled: enabled,
                    hasSubmenu: hasSubmenu,
                    markCharacter: string(item, "AXMenuItemMarkChar"),
                    commandCharacter: command,
                    commandGlyph: integer(item, "AXMenuItemCmdGlyph") ?? 0,
                    modifiers: modifiers
                )
            )
        }
        return MirroredMenuItem.markingAlternates(items)
    }

    // MARK: - Menu bar icons

    /// Every menu bar icon of the given apps, measured on whichever real menu bar shows it. Apps
    /// without icons are skipped for 30 seconds afterwards.
    /// `ownBars` are the real menu bars of the mirrored displays; each icon is also looked for
    /// there so the mirror knows which icons that display shows, whichever display is active.
    func readStatusItems(apps: [RunningApp], menuBars: [CGRect], ownBars: [CGRect]) async -> [SystemBarStatusItem] {
        await withCheckedContinuation { continuation in
            scanQueue.async {
                continuation.resume(returning: self.readStatusItemsSync(apps: apps, menuBars: menuBars, ownBars: ownBars))
            }
        }
    }

    private func readStatusItemsSync(apps: [RunningApp], menuBars: [CGRect], ownBars: [CGRect]) -> [SystemBarStatusItem] {
        let now = Date()
        lock.lock()
        scanMenuBars = menuBars
        barOwners = [:]
        scanHitTests = 0
        scanSearches = []
        lock.unlock()
        let generation = beginGeneration(.statusItem)
        var result: [SystemBarStatusItem] = []
        var seenKeys = Set<String>()
        let livePIDs = Set(apps.map(\.pid))
        lock.lock()
        appElements = appElements.filter { livePIDs.contains($0.key) }
        noExtrasUntil = noExtrasUntil.filter { livePIDs.contains($0.key) }
        statusContainerByPID = statusContainerByPID.filter { livePIDs.contains($0.key) }
        let hadIcons = pidsWithIcons
        lock.unlock()
        var withIcons = Set<pid_t>()
        // An app that had icons last time may answer empty for a moment (macOS rebuilds the
        // menu bars when focus moves to another display); only apps that keep having none are
        // skipped for a while.
        func noteNoIcons(_ app: RunningApp) {
            guard !hadIcons.contains(app.pid) else { return }
            if let launchedAt = app.launchedAt, now.timeIntervalSince(launchedAt) < Self.noExtrasRescanSeconds {
                return
            }
            setNoExtrasUntil(app.pid, now.addingTimeInterval(Self.noExtrasRescanSeconds))
        }

        for app in apps {
            if let until = cachedNoExtrasUntil(app.pid), until > now { continue }
            let appElement = applicationElement(pid: app.pid)
            guard let extras = elementAttribute(appElement, "AXExtrasMenuBar") else {
                noteNoIcons(app)
                continue
            }
            lock.lock()
            statusContainerByPID[app.pid] = extras
            lock.unlock()
            let leaves = children(of: extras).flatMap { leafMenuBarItems(under: $0, depth: 0) }
            if leaves.isEmpty {
                noteNoIcons(app)
                continue
            }
            withIcons.insert(app.pid)
            for (index, leaf) in leaves.enumerated() {
                let frame = frame(of: leaf)
                guard frame.width > 0, frame.height > 0 else { continue }
                let midpoint = CGPoint(x: frame.midX, y: frame.midY)
                guard let menuBar = menuBars.first(where: { $0.contains(midpoint) }) else { continue }
                let identifier = string(leaf, "AXIdentifier")
                let key = "\(app.pid):" + (identifier.isEmpty ? "#\(index)" : identifier)
                guard seenKeys.insert(key).inserted else { continue }
                let identity = IconIdentity(pid: app.pid, identifier: identifier)
                let placement = confirmedPlacement(identity: identity, key: key, frame: frame, claimedBar: menuBar, menuBars: menuBars)
                var ownPlacements: [SystemBarPlacement] = []
                for ownBar in ownBars {
                    if let placement, placement.menuBar == ownBar {
                        ownPlacements.append(SystemBarPlacement(menuBar: ownBar, frame: placement.frame))
                    } else if let found = probeOwnBar(identity: identity, key: key, frame: frame, claimedBar: menuBar, ownBar: ownBar) {
                        ownPlacements.append(SystemBarPlacement(menuBar: ownBar, frame: found))
                    }
                }
                result.append(
                    SystemBarStatusItem(
                        id: register(leaf, kind: .statusItem, generation: generation),
                        pid: app.pid,
                        bundleIdentifier: app.bundleIdentifier,
                        appName: app.name,
                        identifier: identifier,
                        title: string(leaf, kAXTitleAttribute),
                        descriptionText: string(leaf, kAXDescriptionAttribute),
                        value: valueString(leaf),
                        frame: placement?.frame ?? frame,
                        menuBarFrame: placement?.menuBar ?? menuBar,
                        isPositionConfirmed: placement != nil,
                        stableKey: key,
                        reportedMenuBarFrame: menuBar,
                        reportedFrame: frame,
                        ownBarPlacements: ownPlacements
                    )
                )
            }
        }
        lock.lock()
        relocationByKey = relocationByKey.filter { seenKeys.contains($0.key) }
        pidsWithIcons = withIcons
        ownProbeByKey = ownProbeByKey.filter { seenKeys.contains(String($0.key.split(separator: "@").first ?? "")) }
        scanStats = ScanStats(seconds: Date().timeIntervalSince(now), hitTests: scanHitTests, searchedKeys: scanSearches)
        lock.unlock()
        return result
    }

    // MARK: - Icon placement

    private struct Relocation {
        let barIndex: Int
        /// Shift from the predicted center to the measured center, in points.
        let centerShift: CGFloat
    }

    /// What a hit test found at a point on a menu bar.
    private enum HitResult: Equatable {
        /// A menu bar icon: owning process and Accessibility identifier.
        case statusItem(pid_t, String)
        /// An app's icon container, which answers for its icons on an inactive display's bar.
        case statusContainer(pid_t)
        /// Anything else, such as the menu bar of the app owning an empty stretch of the bar.
        case other(pid_t)
        case noElement
    }

    private struct IconIdentity {
        let pid: pid_t
        let identifier: String

        /// System icons share one process, so the identifier must match too. A bare process
        /// match would accept an app's menu bar over empty space.
        func matches(_ hit: HitResult) -> Bool {
            switch hit {
            case let .statusItem(hitPID, hitIdentifier):
                return hitPID == pid && hitIdentifier == identifier
            case let .statusContainer(hitPID):
                return hitPID == pid
            case .other, .noElement:
                return false
            }
        }
    }

    private static let searchNudges: [CGFloat] = [0, -4, 4, -8, 8, -12, 12, -16, 16]
    /// Hit areas include roughly 7 pt of padding on each side of the icon.
    private static let hitPaddingAllowance: CGFloat = 20

    /// Where an icon is really drawn. Confirms the reported frame with one hit test; when that
    /// misses, looks on the other menu bars at the same distance from the right edge (icons keep
    /// roughly that distance on every display), then measures the icon's hit area there to center
    /// it exactly. Measurements are cached per icon and re-checked with one hit test, also after
    /// the reported frame shifts (a neighbour changed width; the drawn icon shifts with it). Some apps
    /// answer hit tests with an error; such an area counts as the icon when the reported spot
    /// clearly belonged to another app. Nil when nothing matched.
    private func confirmedPlacement(identity: IconIdentity, key: String, frame: CGRect, claimedBar: CGRect, menuBars: [CGRect]) -> (frame: CGRect, menuBar: CGRect)? {
        let claimedHit = hitTest(at: CGPoint(x: frame.midX, y: frame.midY))
        if identity.matches(claimedHit) {
            return (frame, claimedBar)
        }
        let rightOffset = claimedBar.maxX - frame.maxX
        let localY = frame.minY - claimedBar.minY
        let acceptsNoElement = claimedHit != .noElement
        func predicted(on bar: CGRect) -> CGRect {
            CGRect(x: bar.maxX - rightOffset - frame.width, y: bar.minY + localY, width: frame.width, height: frame.height)
        }
        func matches(_ hit: HitResult) -> Bool {
            identity.matches(hit) || (acceptsNoElement && hit == .noElement)
        }

        lock.lock()
        let remembered = relocationByKey[key]
        lock.unlock()
        if let remembered, menuBars.indices.contains(remembered.barIndex) {
            let bar = menuBars[remembered.barIndex]
            let placed = predicted(on: bar).offsetBy(dx: remembered.centerShift, dy: 0)
            if matches(hitTest(at: CGPoint(x: placed.midX, y: placed.midY))) {
                return (placed, bar)
            }
        }

        lock.lock()
        scanSearches.append(key)
        lock.unlock()
        for (barIndex, bar) in menuBars.enumerated() where bar != claimedBar {
            let guess = predicted(on: bar)
            for nudge in Self.searchNudges {
                let point = CGPoint(x: guess.midX + nudge, y: guess.midY)
                guard bar.contains(point) else { continue }
                let hit = hitTest(at: point)
                guard matches(hit), identity.matches(hit) || nudge == 0 else { continue }
                let shift: CGFloat
                var measured = true
                if let area = hitArea(around: point, matching: hit, iconWidth: frame.width, within: bar),
                   area.width <= frame.width + Self.hitPaddingAllowance {
                    shift = area.midX - guess.midX
                } else if let median = medianShift(barIndex: barIndex) {
                    // Neighbouring icons of the same app share one hit area; use the correction
                    // measured for other icons on this bar.
                    shift = median
                } else {
                    // Nothing measured on this bar yet; try again on the next scan.
                    shift = nudge
                    measured = false
                }
                if measured {
                    lock.lock()
                    relocationByKey[key] = Relocation(barIndex: barIndex, centerShift: shift)
                    lock.unlock()
                }
                return (guess.offsetBy(dx: shift, dy: 0), bar)
            }
        }
        return nil
    }

    private func medianShift(barIndex: Int) -> CGFloat? {
        lock.lock()
        let shifts = relocationByKey.values.filter { $0.barIndex == barIndex }.map(\.centerShift).sorted()
        lock.unlock()
        guard !shifts.isEmpty else { return nil }
        return shifts[shifts.count / 2]
    }

    private struct OwnBarProbe {
        let checkedAt: Date
        /// Shift from the predicted center to the measured one; nil when the icon was not there.
        let centerShift: CGFloat?
    }

    private static let ownProbeNegativeSeconds: TimeInterval = 30
    private static let ownProbeNudges: [CGFloat] = [0, -6, 6, -12, 12]

    /// Looks for an icon on a mirrored display's bar at the same distance from the right edge as
    /// where Accessibility reported it. Misses are remembered for 30 seconds; hits are re-checked
    /// with one hit test. Only exact pid matches count, so apps that answer hit tests with an
    /// error are never placed this way.
    private func probeOwnBar(identity: IconIdentity, key: String, frame: CGRect, claimedBar: CGRect, ownBar: CGRect) -> CGRect? {
        let cacheKey = "\(key)@\(Int(ownBar.minX)),\(Int(ownBar.minY))"
        let rightOffset = claimedBar.maxX - frame.maxX
        let guess = CGRect(
            x: ownBar.maxX - rightOffset - frame.width,
            y: ownBar.minY + (frame.minY - claimedBar.minY),
            width: frame.width,
            height: frame.height
        )
        lock.lock()
        let cached = ownProbeByKey[cacheKey]
        lock.unlock()
        if let cached {
            if let shift = cached.centerShift {
                let placed = guess.offsetBy(dx: shift, dy: 0)
                if identity.matches(hitTest(at: CGPoint(x: placed.midX, y: placed.midY))) {
                    return placed
                }
            } else if Date().timeIntervalSince(cached.checkedAt) < Self.ownProbeNegativeSeconds {
                return nil
            }
        }
        for nudge in Self.ownProbeNudges {
            let point = CGPoint(x: guess.midX + nudge, y: guess.midY)
            let hit = hitTest(at: point)
            guard ownBar.contains(point), identity.matches(hit) else { continue }
            var shift = nudge
            if let area = hitArea(around: point, matching: hit, iconWidth: frame.width, within: ownBar),
               area.width <= frame.width + Self.hitPaddingAllowance {
                shift = area.midX - guess.midX
            }
            lock.lock()
            ownProbeByKey[cacheKey] = OwnBarProbe(checkedAt: Date(), centerShift: shift)
            lock.unlock()
            return guess.offsetBy(dx: shift, dy: 0)
        }
        lock.lock()
        ownProbeByKey[cacheKey] = OwnBarProbe(checkedAt: Date(), centerShift: nil)
        lock.unlock()
        return nil
    }

    /// The horizontal extent around `point` that returns the same hit result, found by binary
    /// search to one point. Nil when the area runs past the search limit on either side.
    private func hitArea(around point: CGPoint, matching hit: HitResult, iconWidth: CGFloat, within bar: CGRect) -> CGRect? {
        let reach = iconWidth / 2 + Self.hitPaddingAllowance + 8
        func edge(direction: CGFloat) -> CGFloat? {
            var inside = point.x
            var outside = point.x + direction * reach
            outside = min(max(outside, bar.minX), bar.maxX - 1)
            if hitTest(at: CGPoint(x: outside, y: point.y)) == hit { return nil }
            while abs(outside - inside) > 1 {
                let middle = ((inside + outside) / 2).rounded(.down)
                if middle == inside || middle == outside { break }
                if hitTest(at: CGPoint(x: middle, y: point.y)) == hit {
                    inside = middle
                } else {
                    outside = middle
                }
            }
            return inside
        }
        guard let left = edge(direction: -1), let right = edge(direction: 1) else { return nil }
        return CGRect(x: left, y: point.y, width: right - left + 1, height: 1)
    }

    private func hitTest(at point: CGPoint) -> HitResult {
        lock.lock()
        scanHitTests += 1
        lock.unlock()
        var found: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &found) == .success,
              let element = found else { return .noElement }
        AXUIElementSetMessagingTimeout(element, Self.messagingTimeout)
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        let role = string(element, kAXRoleAttribute)
        if role == kAXMenuBarItemRole as String {
            guard string(element, kAXSubroleAttribute) == "AXMenuExtra" else { return .other(pid) }
            return .statusItem(pid, string(element, "AXIdentifier"))
        }
        if role == kAXMenuBarRole as String, let container = statusContainer(pid: pid) {
            // On a bar that is not active, an icon answers with its app's icon container or, on
            // recent macOS, with the app's own menu bar. Each bar's empty stretches answer with the
            // menu bar of the app whose menus that bar shows, so for that app only the container
            // counts.
            if CFEqual(element, container) || pid != barOwnerPID(at: point) {
                return .statusContainer(pid)
            }
        }
        return .other(pid)
    }

    /// Which app's menu bar fills the empty stretches of the real bar under `point` (the app whose
    /// menus that bar shows). Measured with a few hit tests the first time a scan needs it; 0 when
    /// no sample answered with a menu bar.
    private func barOwnerPID(at point: CGPoint) -> pid_t? {
        lock.lock()
        let bar = scanMenuBars.first { $0.contains(point) }
        let key = bar.map { "\(Int($0.minX)),\(Int($0.minY))" }
        let known = key.flatMap { barOwners[$0] }
        lock.unlock()
        guard let bar, let key else { return nil }
        if let known { return known }
        var votes: [pid_t: Int] = [:]
        for fraction in [0.2, 0.3, 0.4, 0.5, 0.6] as [CGFloat] {
            var found: AXUIElement?
            let sample = CGPoint(x: bar.minX + bar.width * fraction, y: bar.midY)
            lock.lock()
            scanHitTests += 1
            lock.unlock()
            guard AXUIElementCopyElementAtPosition(systemWide, Float(sample.x), Float(sample.y), &found) == .success,
                  let element = found, string(element, kAXRoleAttribute) == kAXMenuBarRole as String else { continue }
            var pid: pid_t = 0
            AXUIElementGetPid(element, &pid)
            votes[pid, default: 0] += 1
        }
        let owner = votes.max(by: { $0.value < $1.value })?.key ?? 0
        lock.lock()
        barOwners[key] = owner
        lock.unlock()
        return owner
    }

    private func statusContainer(pid: pid_t) -> AXUIElement? {
        lock.lock()
        defer { lock.unlock() }
        return statusContainerByPID[pid]
    }

    private func leafMenuBarItems(under element: AXUIElement, depth: Int) -> [AXUIElement] {
        let role = string(element, kAXRoleAttribute)
        if role == kAXMenuBarItemRole as String {
            return [element]
        }
        guard depth < 3 else { return [] }
        return children(of: element).flatMap { leafMenuBarItems(under: $0, depth: depth + 1) }
    }

    // MARK: - Actions

    func perform(_ action: String, on id: MirrorElementID) async -> Bool {
        await withCheckedContinuation { continuation in
            menuQueue.async {
                guard let element = self.element(for: id) else {
                    continuation.resume(returning: false)
                    return
                }
                continuation.resume(returning: AXUIElementPerformAction(element, action as CFString) == .success)
            }
        }
    }

    func press(_ id: MirrorElementID) async -> Bool {
        await perform(kAXPressAction as String, on: id)
    }

    /// Presses a menu bar icon that has no static menu and reports what happened: a menu that
    /// appeared is read and closed again so TilePilot can show it locally; otherwise the press
    /// stands on its own (a panel or a direct action). Runs on the menu queue.
    private func pressStatusItemAndClassifySync(_ id: MirrorElementID, preferShowMenu: Bool) -> PressOutcome {
        guard let element = element(for: id) else { return .failed }
        let actions = actionNames(of: element)
        let action = preferShowMenu && actions.contains(kAXShowMenuAction as String) ? kAXShowMenuAction : kAXPressAction
        guard AXUIElementPerformAction(element, action as CFString) == .success else { return .failed }

        let deadline = Date().addingTimeInterval(Self.dynamicMenuWaitSeconds)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
            if let menu = menuChild(of: element) {
                let items = readMenuItemsSync(parentID: id, deadline: Date().addingTimeInterval(1), startsNewMenu: true) ?? []
                closeMenu(menu, owner: element, ownerActions: actions)
                return .menuOpened(items)
            }
        }
        return .pressed
    }

    private func closeMenu(_ menu: AXUIElement, owner: AXUIElement, ownerActions: [String]) {
        if AXUIElementPerformAction(menu, kAXCancelAction as CFString) == .success { return }
        if ownerActions.contains(kAXCancelAction as String),
           AXUIElementPerformAction(owner, kAXCancelAction as CFString) == .success {
            return
        }
        let source = CGEventSource(stateID: .combinedSessionState)
        CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: false)?.post(tap: .cghidEventTap)
    }

    /// A secondary click on a menu bar icon. Icons with a "show menu" action (the system icons)
    /// get that action. Others get a real right click at `point`, where the icon is drawn; the
    /// pointer goes there for the click and comes straight back. A menu that opens is read and
    /// closed so the mirror can show it. Without a known position, falls back to a press.
    func rightClickStatusItem(_ id: MirrorElementID, at point: CGPoint?) async -> PressOutcome {
        await withCheckedContinuation { continuation in
            menuQueue.async {
                continuation.resume(returning: self.rightClickStatusItemSync(id, at: point))
            }
        }
    }

    private func rightClickStatusItemSync(_ id: MirrorElementID, at point: CGPoint?) -> PressOutcome {
        guard let element = element(for: id) else {
            noteClick("right click: element expired")
            return .failed
        }
        let actions = actionNames(of: element)
        guard !actions.contains(kAXShowMenuAction as String), let point, isStatusItem(element, drawnAt: point) else {
            noteClick("right click: show-menu press (actions \(actions), point \(point.map { "\(Int($0.x)),\(Int($0.y))" } ?? "none"))")
            return pressStatusItemAndClassifySync(id, preferShowMenu: true)
        }
        noteClick("right click: real click at \(Int(point.x)),\(Int(point.y))")
        guard Self.postClick(at: point, button: .right) else { return .failed }
        return classifyAfterClick(on: element, id: id, actions: actions)
    }

    /// A primary click on a menu bar icon that has no menu to read. Apple's icons (the ones with
    /// a "show menu" action) get an Accessibility press. Other apps often read the mouse event
    /// to tell left from right clicks and ignore that press while reporting success (TraceBar,
    /// BetterDisplay, Lunar, CPU Cap), so they get a real click where the icon is drawn, after
    /// the physical button is released. Without a confirmed position, falls back to a press.
    func clickStatusItem(_ id: MirrorElementID, at point: CGPoint?) async -> PressOutcome {
        await withCheckedContinuation { continuation in
            menuQueue.async {
                continuation.resume(returning: self.clickStatusItemSync(id, at: point))
            }
        }
    }

    private func clickStatusItemSync(_ id: MirrorElementID, at point: CGPoint?) -> PressOutcome {
        guard let element = element(for: id) else {
            noteClick("click: element expired")
            return .failed
        }
        let actions = actionNames(of: element)
        let pointText = point.map { "\(Int($0.x)),\(Int($0.y))" } ?? "none"
        guard !actions.contains(kAXShowMenuAction as String), let point else {
            noteClick("click: press (actions \(actions), point \(pointText))")
            return pressStatusItemAndClassifySync(id, preferShowMenu: false)
        }
        guard Self.waitForPrimaryButtonRelease() else {
            noteClick("click: press (button still held)")
            return pressStatusItemAndClassifySync(id, preferShowMenu: false)
        }
        guard isStatusItem(element, drawnAt: point) else {
            noteClick("click: press (icon not drawn at \(pointText): \(hitTest(at: point)))")
            return pressStatusItemAndClassifySync(id, preferShowMenu: false)
        }
        noteClick("click: real click at \(pointText)")
        guard Self.postClick(at: point, button: .left) else { return .failed }
        return classifyAfterClick(on: element, id: id, actions: actions)
    }

    /// After a real click on an icon: a menu that opened is read and closed so the mirror can show
    /// it; anything else (a panel or a direct action) stands on its own.
    private func classifyAfterClick(on element: AXUIElement, id: MirrorElementID, actions: [String]) -> PressOutcome {
        let deadline = Date().addingTimeInterval(Self.dynamicMenuWaitSeconds)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
            if let menu = menuChild(of: element) {
                let items = readMenuItemsSync(parentID: id, deadline: Date().addingTimeInterval(1), startsNewMenu: true) ?? []
                closeMenu(menu, owner: element, ownerActions: actions)
                return .menuOpened(items)
            }
        }
        return .pressed
    }

    /// True when the real icon is on screen at `point`, so a click there reaches it and nothing
    /// else (the menu bar can be hidden, covered, or rearranged since the icon was placed). On an
    /// inactive display's bar the hit test finds the app's icon container instead of the icon.
    private func isStatusItem(_ element: AXUIElement, drawnAt point: CGPoint) -> Bool {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return false }
        switch hitTest(at: point) {
        case let .statusItem(hitPID, _), let .statusContainer(hitPID):
            return hitPID == pid
        case .other, .noElement:
            return false
        }
    }

    private static func waitForPrimaryButtonRelease(timeout: TimeInterval = 2) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while CGEventSource.buttonState(.combinedSessionState, button: .left) {
            guard Date() < deadline else { return false }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return true
    }

    /// Posts a mouse down and up at a point in top-left screen coordinates, then puts the pointer
    /// back where it was.
    private static func postClick(at point: CGPoint, button: CGMouseButton) -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)
        source?.localEventsSuppressionInterval = 0
        let original = CGEvent(source: nil)?.location
        let downType: CGEventType = button == .right ? .rightMouseDown : .leftMouseDown
        let upType: CGEventType = button == .right ? .rightMouseUp : .leftMouseUp
        guard let down = CGEvent(mouseEventSource: source, mouseType: downType, mouseCursorPosition: point, mouseButton: button),
              let up = CGEvent(mouseEventSource: source, mouseType: upType, mouseCursorPosition: point, mouseButton: button) else {
            return false
        }
        down.post(tap: .cghidEventTap)
        usleep(30_000)
        up.post(tap: .cghidEventTap)
        usleep(30_000)
        if let original,
           let back = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: original, mouseButton: .left) {
            back.post(tap: .cghidEventTap)
        }
        return true
    }

    /// Chooses an item from a menu bar icon's menu that was read while it was open. Tries the
    /// stored item first; when the app rebuilt its menu, reopens it, finds the item by title, and
    /// presses that.
    func pressDynamicMenuItem(statusItemID: MirrorElementID, itemID: MirrorElementID, title: String, index: Int) async -> Bool {
        await withCheckedContinuation { continuation in
            menuQueue.async {
                continuation.resume(returning: self.pressDynamicMenuItemSync(statusItemID: statusItemID, itemID: itemID, title: title, index: index))
            }
        }
    }

    private func pressDynamicMenuItemSync(statusItemID: MirrorElementID, itemID: MirrorElementID, title: String, index: Int) -> Bool {
        if let item = element(for: itemID), AXUIElementPerformAction(item, kAXPressAction as CFString) == .success {
            return true
        }
        guard let owner = element(for: statusItemID) else { return false }
        guard AXUIElementPerformAction(owner, kAXPressAction as CFString) == .success else { return false }
        let deadline = Date().addingTimeInterval(Self.dynamicMenuWaitSeconds)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
            guard let menu = menuChild(of: owner) else { continue }
            let items = children(of: menu)
            let match = items.indices.contains(index) && string(items[index], kAXTitleAttribute) == title
                ? items[index]
                : items.first(where: { string($0, kAXTitleAttribute) == title })
            guard let match else {
                closeMenu(menu, owner: owner, ownerActions: actionNames(of: owner))
                return false
            }
            return AXUIElementPerformAction(match, kAXPressAction as CFString) == .success
        }
        return false
    }

    // MARK: - Element registry

    private func beginGeneration(_ kind: ElementKind) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let next = (generations[kind] ?? 0) + 1
        generations[kind] = next
        // Keep the previous generation so a click that started before a refresh still resolves.
        entries = entries.filter { $0.value.kind != kind || $0.value.generation >= next - 1 }
        return next
    }

    private func currentGeneration(_ kind: ElementKind) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return generations[kind] ?? 0
    }

    private func register(_ element: AXUIElement, kind: ElementKind, generation: Int) -> MirrorElementID {
        let id = UUID().uuidString
        lock.lock()
        entries[id] = Entry(element: element, kind: kind, generation: generation)
        lock.unlock()
        return id
    }

    private func element(for id: MirrorElementID) -> AXUIElement? {
        lock.lock()
        defer { lock.unlock() }
        return entries[id]?.element
    }

    private func applicationElement(pid: pid_t) -> AXUIElement {
        lock.lock()
        if let cached = appElements[pid] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, Self.messagingTimeout)
        lock.lock()
        appElements[pid] = element
        lock.unlock()
        return element
    }

    private func cachedNoExtrasUntil(_ pid: pid_t) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return noExtrasUntil[pid]
    }

    private func setNoExtrasUntil(_ pid: pid_t, _ date: Date) {
        lock.lock()
        noExtrasUntil[pid] = date
        lock.unlock()
    }

    // MARK: - Accessibility helpers

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private func string(_ element: AXUIElement, _ name: String) -> String {
        (attribute(element, name) as? String) ?? ""
    }

    private func elementAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let child = value as! AXUIElement
        AXUIElementSetMessagingTimeout(child, Self.messagingTimeout)
        return child
    }

    private func bool(_ element: AXUIElement, _ name: String) -> Bool? {
        attribute(element, name) as? Bool
    }

    private func integer(_ element: AXUIElement, _ name: String) -> Int? {
        (attribute(element, name) as? NSNumber)?.intValue
    }

    private func valueString(_ element: AXUIElement) -> String {
        guard let value = attribute(element, kAXValueAttribute) else { return "" }
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return ""
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        let list = (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
        for child in list {
            AXUIElementSetMessagingTimeout(child, Self.messagingTimeout)
        }
        return list
    }

    private func menuChild(of element: AXUIElement) -> AXUIElement? {
        children(of: element).first { string($0, kAXRoleAttribute) == kAXMenuRole as String }
    }

    private func frame(of element: AXUIElement) -> CGRect {
        var point = CGPoint.zero
        var size = CGSize.zero
        if let value = attribute(element, kAXPositionAttribute), CFGetTypeID(value) == AXValueGetTypeID() {
            AXValueGetValue(value as! AXValue, .cgPoint, &point)
        }
        if let value = attribute(element, kAXSizeAttribute), CFGetTypeID(value) == AXValueGetTypeID() {
            AXValueGetValue(value as! AXValue, .cgSize, &size)
        }
        return CGRect(origin: point, size: size)
    }

    private func actionNames(of element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [MirroredMenuItem]?

        func set(_ value: [MirroredMenuItem]?) {
            lock.lock()
            items = value
            lock.unlock()
        }

        func get() -> [MirroredMenuItem]? {
            lock.lock()
            defer { lock.unlock() }
            return items
        }
    }
}


