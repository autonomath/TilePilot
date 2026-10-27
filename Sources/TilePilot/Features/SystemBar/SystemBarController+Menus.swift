import AppKit
import Foundation

/// Clicks on the mirrored bar: app menus, icon menus and real clicks on icons, the overflow
/// menu, and the panels that real clicks open.
extension SystemBarController {
    /// A submenu whose items are read from Accessibility the moment it opens.
    final class MirroredMenu: NSMenu {
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

    enum MenuItemTarget {
        case element(MirrorElementID)
        case dynamicStatusItem(statusItemID: MirrorElementID, itemID: MirrorElementID, title: String, index: Int)
        case overflowIcon(Int)
    }

    final class MenuItemReference: NSObject {
        let target: MenuItemTarget
        init(_ target: MenuItemTarget) { self.target = target }
    }

    struct OverflowContext {
        let barKey: String
        let slot: SystemBarSlot
        let slotIndex: Int
    }

    /// The panel a real click on an icon opened, watched while it stays open. Clicking that icon
    /// again closes the panel instead of closing and reopening it: many apps close their panel
    /// on any mouse down outside it, before the mirror sees the click.
    struct WatchedPanel {
        let iconKey: String
        let pid: Int32
        let windowIDs: Set<Int>
        var lastSeenOpen: Date
    }

    static let panelWatchInterval: Duration = .milliseconds(100)
    static let panelJustClosedSeconds: TimeInterval = 0.25
    static let submenuReadTimeout: TimeInterval = 0.5

    // MARK: - Clicks

    func handleClick(barKey: String, slot: SystemBarSlot, secondary: Bool) {
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
