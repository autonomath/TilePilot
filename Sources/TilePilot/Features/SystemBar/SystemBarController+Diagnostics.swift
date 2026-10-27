import AppKit
import Foundation

/// Development routes and the text the status route writes.
extension SystemBarController {
    /// Development route: stops every running capture as a display change would.
    func simulateCaptureStopForDiagnostics() -> String {
        "stopped \(captureSet.simulateUnexpectedStop()) capture(s)"
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
                "bar \(bar.key): frame \(Int(bar.panel.frame.minX)),\(Int(bar.panel.frame.minY)) \(Int(bar.panel.frame.width))x\(Int(bar.panel.frame.height)) appkit; visible \(bar.panel.isVisible); titles \(titles.count) (\(titles.map(\.title).joined(separator: "|"))); icons \(iconSlots.count)/\(statusItems.count) shown, \(matching) matching, overflow menus \(plan.overflowMenuIndices.count) icons \(plan.overflowIconIndices.count); \(captureSet.summary); frontmost pid \(titlesPID ?? -1)"
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
        let look = backgroundLook.current.map { "\($0.color.components?.prefix(3).map { String(format: "%.2f", $0) } ?? []) dark \($0.isDark)" } ?? "none"
        lines.append("active bar \(active); bar look \(look); include other displays \(includeOtherDisplayIcons)")
        let itemsByKey = Dictionary(statusItems.map { ($0.stableKey, $0) }, uniquingKeysWith: { first, _ in first })
        let rowText = iconRow.order.compactMap { key -> String? in
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
        for (id, capture) in captureSet.captures.sorted(by: { $0.key < $1.key }) {
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
}
