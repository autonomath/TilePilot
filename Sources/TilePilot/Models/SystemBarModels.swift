import CoreGraphics
import Foundation

/// Opaque handle for an Accessibility element that `AccessibilityMirrorReader` owns. Only the
/// reader ever touches the element; everything else passes the handle around.
typealias MirrorElementID = String

/// The one icon row the mirror shows when it includes every display's icons: each icon exactly
/// once, packed from the right edge with real spacing, in the same place whichever display is
/// active. Pixels and clicks still go to wherever macOS draws each icon.
enum SystemBarIconRow {
    /// One icon on a real bar, for choosing the mirror's row.
    struct Sighting: Equatable, Sendable {
        let bar: String
        let minX: CGFloat
    }

    /// Identifies a real menu bar by its top-left corner.
    static func barKey(_ bar: CGRect) -> String {
        "\(Int(bar.minX)),\(Int(bar.minY))"
    }

    /// Bars must draw this many more third-party icons than the current reference to replace it,
    /// so the row does not flip back and forth while macOS moves icons around.
    static let referenceSwitchMargin = 3

    /// The row to show, left to right. macOS keeps no single order across displays (each bar
    /// orders the icons it draws its own way), so the mirror copies one bar: the one that draws
    /// the most third-party icons. An icon that bar does not draw keeps its place from
    /// `previousOrder` (right after the icon it followed there), so icons macOS moves to another
    /// display as focus changes stay put. Icons never placed before go at the left (third-party)
    /// or the right (system), in their own bar's order.
    static func order(
        icons: [(key: String, sightings: [Sighting], isSystem: Bool)],
        previousReference: String?,
        previousOrder: [String] = []
    ) -> (order: [String], reference: String?) {
        var counts: [String: Int] = [:]
        for icon in icons where !icon.isSystem {
            for bar in Set(icon.sightings.map(\.bar)) {
                counts[bar, default: 0] += 1
            }
        }
        let best = counts.max { lhs, rhs in lhs.value == rhs.value ? lhs.key > rhs.key : lhs.value < rhs.value }
        var reference = best?.key
        if let previousReference, let previousCount = counts[previousReference], let best,
           best.value - previousCount < referenceSwitchMargin {
            reference = previousReference
        }
        var onReference: [(String, CGFloat)] = []
        var offReference: [String: (minX: CGFloat, isSystem: Bool)] = [:]
        for icon in icons {
            if let sighting = icon.sightings.first(where: { $0.bar == reference }) {
                onReference.append((icon.key, sighting.minX))
            } else {
                offReference[icon.key] = (icon.sightings.first?.minX ?? 0, icon.isSystem)
            }
        }
        let byPosition: ((String, CGFloat), (String, CGFloat)) -> Bool = { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 < $1.1 }
        var row = onReference.sorted(by: byPosition).map(\.0)
        var placed = Set(row)
        for (index, key) in previousOrder.enumerated() where offReference[key] != nil && !placed.contains(key) {
            if insert(key, at: index, of: previousOrder, into: &row, placed: placed) {
                placed.insert(key)
            }
        }
        let unplaced = offReference.filter { !placed.contains($0.key) }
        let leftOver = unplaced.filter { !$0.value.isSystem }.map { ($0.key, $0.value.minX) }.sorted(by: byPosition).map(\.0)
        let rightOver = unplaced.filter { $0.value.isSystem }.map { ($0.key, $0.value.minX) }.sorted(by: byPosition).map(\.0)
        return (leftOver + row + rightOver, reference)
    }

    /// `order` plus the icons of `previous` missing from it right now that `keep` accepts, each
    /// right after the icon it followed, so an icon that vanishes for a while (macOS removes the
    /// system icons while the screen is locked) gets its slot back. Pass the result as the next
    /// `previousOrder`.
    static func remembered(order: [String], previous: [String], keep: (String) -> Bool) -> [String] {
        var row = order
        var placed = Set(row)
        for (index, key) in previous.enumerated() where !placed.contains(key) && keep(key) {
            if insert(key, at: index, of: previous, into: &row, placed: placed) {
                placed.insert(key)
            }
        }
        return row
    }

    /// Puts `key` (at `index` in `previous`) into `row` right after the nearest earlier icon of
    /// `previous` already in the row, or before the nearest later one. False when neither exists.
    private static func insert(_ key: String, at index: Int, of previous: [String], into row: inout [String], placed: Set<String>) -> Bool {
        if let before = previous[..<index].last(where: placed.contains), let at = row.firstIndex(of: before) {
            row.insert(key, at: at + 1)
            return true
        }
        if let after = previous[(index + 1)...].first(where: placed.contains), let at = row.firstIndex(of: after) {
            row.insert(key, at: at)
            return true
        }
        return false
    }

    /// Natural gaps between neighbouring icons stay under this; a wider stretch means another icon
    /// sits between them on that bar.
    static let maximumNaturalGap: CGFloat = 24

    /// The gap after each icon in `order` to its right-hand neighbour, measured where macOS draws
    /// both on the same bar right next to each other. Pairs that cannot be measured now (one of
    /// them moved to another display) keep their `previous` gap, so the row does not shift.
    static func learnedGaps(
        order: [String],
        frames: [String: [String: CGRect]],
        previous: [String: CGFloat]
    ) -> [String: CGFloat] {
        let present = Set(order)
        var gaps = previous.filter { present.contains($0.key) }
        for (left, right) in zip(order, order.dropFirst()) {
            guard let leftFrames = frames[left], let rightFrames = frames[right] else { continue }
            for (bar, leftFrame) in leftFrames.sorted(by: { $0.key < $1.key }) {
                guard let rightFrame = rightFrames[bar] else { continue }
                let gap = rightFrame.minX - leftFrame.maxX
                if gap >= -4, gap <= maximumNaturalGap {
                    gaps[left] = gap
                    break
                }
            }
        }
        return gaps
    }

    /// Distance from the bar's right edge for each icon in `order` (left to right), packed with
    /// each icon's remembered gap to its right-hand neighbour.
    static func packedRightOffsets(
        order: [String],
        widths: [String: CGFloat],
        trailingGaps: [String: CGFloat],
        trailingInset: CGFloat,
        defaultGap: CGFloat = 6
    ) -> [String: CGFloat] {
        var result: [String: CGFloat] = [:]
        var cursor = trailingInset
        for index in order.indices.reversed() {
            let key = order[index]
            guard let width = widths[key], width > 0 else { continue }
            result[key] = cursor
            cursor += width
            if index > 0 {
                cursor += trailingGaps[order[index - 1]] ?? defaultGap
            }
        }
        return result
    }
}


/// An icon remembered on a display's own real menu bar: its distance from the bar's right edge,
/// its width, and since when the bar has been active without drawing it.
struct SystemBarStickyIcon: Equatable, Sendable {
    var rightOffset: CGFloat
    var width: CGFloat
    var missingSince: Date?

    func overlaps(_ other: SystemBarStickyIcon) -> Bool {
        rightOffset < other.rightOffset + other.width - 1 && other.rightOffset < rightOffset + width - 1
    }
}

/// Which icons the mirror shows for a display, and where. While that display's bar is the active
/// one it draws the display's whole set, so it is the authority: icons it stops drawing leave
/// after a short grace. While another display is active, macOS draws fewer icons there and shifts
/// the rest, so the set and places from the last active moment are kept. Positions always come from
/// one moment, so remembered icons never land on top of each other.
enum SystemBarStickyIconPolicy {
    static let missingGraceSeconds: TimeInterval = 6

    static func update(
        _ remembered: [String: SystemBarStickyIcon],
        drawn: [String: (rightOffset: CGFloat, width: CGFloat)],
        ownBarIsActive: Bool,
        now: Date
    ) -> [String: SystemBarStickyIcon] {
        if ownBarIsActive || remembered.isEmpty {
            var next = drawn.mapValues { SystemBarStickyIcon(rightOffset: $0.rightOffset, width: $0.width, missingSince: nil) }
            guard ownBarIsActive else { return next }
            for (key, icon) in remembered where next[key] == nil {
                let missingSince = icon.missingSince ?? now
                if now.timeIntervalSince(missingSince) < missingGraceSeconds {
                    next[key] = SystemBarStickyIcon(rightOffset: icon.rightOffset, width: icon.width, missingSince: missingSince)
                }
            }
            return next
        }
        var next = remembered
        for (key, place) in drawn.sorted(by: { $0.key < $1.key }) {
            if next[key] != nil {
                next[key]?.missingSince = nil
                continue
            }
            let icon = SystemBarStickyIcon(rightOffset: place.rightOffset, width: place.width, missingSince: nil)
            if !shown(next).values.contains(where: { $0.overlaps(icon) }) {
                next[key] = icon
            }
        }
        return next
    }

    /// The remembered icons to draw: all present ones, plus missing ones that do not overlap them.
    static func shown(_ remembered: [String: SystemBarStickyIcon]) -> [String: SystemBarStickyIcon] {
        let present = remembered.filter { $0.value.missingSince == nil }
        var result = present
        for (key, icon) in remembered.sorted(by: { $0.key < $1.key }) where icon.missingSince != nil {
            if !result.values.contains(where: { $0.overlaps(icon) }) {
                result[key] = icon
            }
        }
        return result
    }
}


/// When to try capturing a display's real menu bar again after its stream stopped or failed to
/// start. Display reconnects are the usual cause and recover within seconds, so the first retry
/// is quick; repeated failures back off.
enum SystemBarCapturePolicy {
    /// Failures in a row before TilePilot mentions the simplified look; a single display
    /// reconnect stays quiet.
    static let attemptsBeforeMessage = 3

    static func retryDelay(afterFailures attempts: Int) -> TimeInterval {
        switch attempts {
        case ...1: return 2
        case 2: return 10
        default: return 30
        }
    }
}

/// Modifier keys of a menu item shortcut, decoded from `AXMenuItemCmdModifiers`. Command is
/// implied unless bit 3 is set; bit 0 is Shift, bit 1 is Option, bit 2 is Control, bit 4 is Fn.
struct MirroredMenuModifiers: Equatable, Hashable, Sendable {
    var command: Bool
    var shift: Bool
    var option: Bool
    var control: Bool
    var function: Bool

    static let none = MirroredMenuModifiers(command: false, shift: false, option: false, control: false, function: false)

    init(command: Bool, shift: Bool, option: Bool, control: Bool, function: Bool) {
        self.command = command
        self.shift = shift
        self.option = option
        self.control = control
        self.function = function
    }

    /// Decodes the raw Accessibility mask. A negative or missing mask means "no shortcut".
    init(axModifiers raw: Int?, hasCommandCharacter: Bool) {
        guard let raw, raw >= 0 else {
            self = .none
            return
        }
        shift = raw & 1 != 0
        option = raw & 2 != 0
        control = raw & 4 != 0
        function = raw & 16 != 0
        // Items without any key still report a mask (for Option alternates). Command only counts
        // when a character exists, so "Zoom" (mask 8) and "Bring All to Front" stay plain.
        command = raw & 8 == 0 && hasCommandCharacter
    }

    /// The same modifiers plus Option, which is how macOS marks an alternate item.
    var addingOption: MirroredMenuModifiers {
        var copy = self
        copy.option = true
        return copy
    }
}

/// One entry of a mirrored menu, read from an `AXMenuItem`.
struct MirroredMenuItem: Identifiable, Equatable, Sendable {
    let id: MirrorElementID
    var title: String
    var isEnabled: Bool
    var hasSubmenu: Bool
    var markCharacter: String
    var commandCharacter: String
    var commandGlyph: Int
    var modifiers: MirroredMenuModifiers
    var isAlternate: Bool = false

    /// Cocoa reports separators as disabled, untitled items without children.
    var isSeparator: Bool {
        title.isEmpty && !isEnabled && !hasSubmenu && commandCharacter.isEmpty
    }

    var isOn: Bool {
        !markCharacter.isEmpty
    }

    /// Marks Option alternates: an item that directly follows another with the same command
    /// character and the same modifiers plus Option (Close / Close All, Zoom / Zoom All).
    static func markingAlternates(_ items: [MirroredMenuItem]) -> [MirroredMenuItem] {
        var result = items
        var index = 1
        while index < result.count {
            let previous = result[index - 1]
            let current = result[index]
            if !previous.isSeparator, !current.isSeparator,
               !previous.isAlternate,
               previous.commandCharacter == current.commandCharacter,
               !previous.modifiers.option,
               current.modifiers == previous.modifiers.addingOption {
                result[index].isAlternate = true
            }
            index += 1
        }
        return result
    }
}

/// One title in the frontmost app's menu bar.
struct SystemBarMenuTitle: Identifiable, Equatable, Sendable {
    let id: MirrorElementID
    let title: String
    let isAppleMenu: Bool
    let isEnabled: Bool
    /// Width of the real title on the menu bar, or 0 when the app has no visible menu bar.
    let axWidth: CGFloat
}

/// An icon frame on a real menu bar, both in top-left screen coordinates.
struct SystemBarPlacement: Equatable, Sendable {
    let menuBar: CGRect
    let frame: CGRect
}

/// A menu bar icon ("extra") of a running app, measured on the real menu bar that shows it.
struct SystemBarStatusItem: Identifiable, Equatable, Sendable {
    let id: MirrorElementID
    let pid: Int32
    let bundleIdentifier: String
    let appName: String
    let identifier: String
    let title: String
    let descriptionText: String
    let value: String
    /// The icon's frame in top-left screen coordinates.
    let frame: CGRect
    /// The real menu bar window the icon sits on, in top-left screen coordinates.
    let menuBarFrame: CGRect
    /// True when a hit test confirmed the icon is drawn at `frame`. Accessibility sometimes
    /// reports an icon on the active display's bar while it is only drawn on another display;
    /// unconfirmed icons are never cropped from the screen.
    var isPositionConfirmed: Bool = true
    /// Identity that survives rescans: pid plus the Accessibility identifier or position.
    var stableKey: String = ""
    /// The bar Accessibility reported the icon on. macOS reports every icon on the active
    /// display's bar, even icons it only draws elsewhere.
    var reportedMenuBarFrame: CGRect = .zero
    /// Where Accessibility reported the icon on that bar.
    var reportedFrame: CGRect = .zero

    /// Every bar the icon is known to be drawn on, one placement per bar.
    var allPlacements: [SystemBarPlacement] {
        var result: [SystemBarPlacement] = isPositionConfirmed ? [SystemBarPlacement(menuBar: menuBarFrame, frame: frame)] : []
        for placement in ownBarPlacements where !result.contains(where: { $0.menuBar == placement.menuBar }) {
            result.append(placement)
        }
        return result
    }
    /// Where the icon is drawn on the mirrored displays' own bars, when it is.
    var ownBarPlacements: [SystemBarPlacement] = []

    /// Where to copy the icon's pixels from: the confirmed position (on the active bar when
    /// possible, so the icon is not dimmed), otherwise its place on a mirrored bar.
    var pixelSource: SystemBarPlacement? {
        if isPositionConfirmed {
            return SystemBarPlacement(menuBar: menuBarFrame, frame: frame)
        }
        return ownBarPlacements.first
    }

    static let systemExtraPrefix = "com.apple.menuextra."

    var isSystemExtra: Bool {
        identifier.hasPrefix(Self.systemExtraPrefix)
    }

    /// A short label for diagnostics: the system icon's name (clock, wifi) or the app's name.
    var shortName: String {
        isSystemExtra ? String(identifier.dropFirst(Self.systemExtraPrefix.count)) : appName
    }

    /// Distance from the right edge of its menu bar; stable while the bar re-flows.
    var rightOffset: CGFloat {
        menuBarFrame.maxX - frame.maxX
    }

    /// Offset of the icon's top from the top of its menu bar.
    var menuBarLocalY: CGFloat {
        frame.minY - menuBarFrame.minY
    }

    var tooltip: String {
        for candidate in [descriptionText, value, title] where !candidate.isEmpty {
            if candidate == descriptionText, !value.isEmpty, candidate != value {
                return "\(candidate): \(value)"
            }
            return candidate
        }
        return appName
    }

    /// A short name for messages: "Battery" for system icons, otherwise the app's name.
    var displayName: String {
        if isSystemExtra, !descriptionText.isEmpty {
            return descriptionText
        }
        return appName
    }

    /// SF Symbol for the Simplified rendering of a system icon, or nil for third-party icons.
    var simplifiedSymbolName: String? {
        guard isSystemExtra else { return nil }
        switch identifier.dropFirst(Self.systemExtraPrefix.count) {
        case "wifi": return "wifi"
        case "battery": return "battery.100"
        case "focusmode": return "moon.fill"
        case "now-playing": return "play.fill"
        case "controlcenter": return "switch.2"
        case "clock": return nil
        case "bluetooth": return "bluetooth"
        case "airplay", "screenmirroring": return "airplayvideo"
        case "volume", "sound": return "speaker.wave.2.fill"
        case "textinput", "keyboard": return "globe"
        case "spotlight": return "magnifyingglass"
        case "siri": return "waveform"
        case "vpn": return "network.badge.shield.half.filled"
        case "displays": return "display"
        default: return "circle.fill"
        }
    }

    var isClock: Bool {
        identifier == Self.systemExtraPrefix + "clock"
    }

    /// A title worth drawing as text in Simplified mode: short readings such as "23%" or "72°",
    /// never resource names such as "menuBarIcon".
    var simplifiedTitleText: String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 12 else { return nil }
        let hasReadingCharacter = trimmed.contains { $0.isNumber || "%°:/".contains($0) }
        let looksLikeIdentifier = !trimmed.contains(" ") && trimmed.count > 5
            && trimmed.contains(where: \.isUppercase) && trimmed.contains(where: \.isLowercase) && !hasReadingCharacter
        if looksLikeIdentifier { return nil }
        return hasReadingCharacter || trimmed.count <= 5 ? trimmed : nil
    }
}

enum AccessibilityActionName {
    /// Accessibility reports custom actions as "Name:Show Details\nTarget:…\nSelector:…". Returns
    /// the label, or the raw name for standard actions such as `AXPress`.
    static func label(_ raw: String) -> String {
        let firstLine = raw.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? raw
        if firstLine.hasPrefix("Name:") {
            return String(firstLine.dropFirst("Name:".count)).trimmingCharacters(in: .whitespaces)
        }
        return firstLine
    }

    static func isCustomAction(_ raw: String) -> Bool {
        raw.hasPrefix("Name:")
    }
}

/// A rendered position on the System Bar, in bar-local points from the left edge.
struct SystemBarSlot: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case menu(index: Int)
        case icon(index: Int)
        case overflow
    }

    let kind: Kind
    let x: CGFloat
    let width: CGFloat

    var maxX: CGFloat { x + width }
}

/// Everything the planner needs to know about one icon.
struct SystemBarIconMetric: Equatable, Sendable {
    let width: CGFloat
    /// Distance from the right edge of the real menu bar the icon sits on.
    let rightOffset: CGFloat
    /// Which real menu bar it sits on; icons are grouped by this. The bar that belongs to the
    /// mirrored display must use the highest group index so it ends up at the far right.
    let group: Int
}

struct SystemBarLayoutPlan: Equatable, Sendable {
    var slots: [SystemBarSlot]
    var overflowMenuIndices: [Int]
    var overflowIconIndices: [Int]

    var hasOverflow: Bool {
        !overflowMenuIndices.isEmpty || !overflowIconIndices.isEmpty
    }
}

/// Fits menu titles and icons into the bar. Icons keep the spacing of the real bar they come
/// from; groups from other displays sit to the left of the mirrored display's own icons. When
/// space runs out, the leftmost icons move into a "»" overflow menu first, then the rightmost
/// menu titles.
enum SystemBarLayoutPlanner {
    static let leadingInset: CGFloat = 10
    static let groupGap: CGFloat = 16
    static let menuIconGap: CGFloat = 24
    static let overflowWidth: CGFloat = 30
    /// The real bar keeps roughly this much space after the last icon.
    static let defaultTrailingInset: CGFloat = 20

    static func plan(
        barWidth: CGFloat,
        menuWidths: [CGFloat],
        icons: [SystemBarIconMetric]
    ) -> SystemBarLayoutPlan {
        var hiddenIcons: [Int] = []
        var hiddenMenus: [Int] = []
        let iconOrder = iconDisplayOrder(icons)

        func attempt() -> [SystemBarSlot]? {
            let visibleIcons = iconOrder.filter { !hiddenIcons.contains($0) }
            let visibleMenus = menuWidths.indices.filter { !hiddenMenus.contains($0) }
            let needsOverflow = !hiddenIcons.isEmpty || !hiddenMenus.isEmpty

            var slots: [SystemBarSlot] = []
            var cursor = leadingInset
            for index in visibleMenus {
                slots.append(SystemBarSlot(kind: .menu(index: index), x: cursor, width: menuWidths[index]))
                cursor += menuWidths[index]
            }
            let menusMaxX = cursor

            let iconSlots = placeIcons(visibleIcons, icons: icons, barWidth: barWidth)
            var iconsMinX = iconSlots.map(\.x).min() ?? (barWidth - defaultTrailingInset)
            if needsOverflow {
                iconsMinX -= overflowWidth + groupGap / 2
            }
            let gap = visibleMenus.isEmpty ? 0 : menuIconGap
            if menusMaxX + gap > iconsMinX, !(visibleIcons.isEmpty && visibleMenus.isEmpty) {
                return nil
            }
            if needsOverflow {
                slots.append(SystemBarSlot(kind: .overflow, x: max(menusMaxX + gap, iconsMinX), width: overflowWidth))
            }
            slots.append(contentsOf: iconSlots)
            return slots
        }

        while true {
            if let slots = attempt() {
                return SystemBarLayoutPlan(slots: slots, overflowMenuIndices: hiddenMenus, overflowIconIndices: hiddenIcons)
            }
            if let nextIcon = iconOrder.first(where: { !hiddenIcons.contains($0) }) {
                hiddenIcons.append(nextIcon)
                continue
            }
            if let nextMenu = menuWidths.indices.last(where: { !hiddenMenus.contains($0) && $0 != 0 }) {
                hiddenMenus.append(nextMenu)
                continue
            }
            // Nothing left to hide: show the Apple menu and the overflow button regardless.
            var slots: [SystemBarSlot] = []
            if !menuWidths.isEmpty {
                slots.append(SystemBarSlot(kind: .menu(index: 0), x: leadingInset, width: menuWidths[0]))
            }
            slots.append(SystemBarSlot(kind: .overflow, x: max(0, barWidth - overflowWidth - defaultTrailingInset), width: overflowWidth))
            return SystemBarLayoutPlan(slots: slots, overflowMenuIndices: hiddenMenus, overflowIconIndices: hiddenIcons)
        }
    }

    /// Icons ordered as they appear on the bar: lower groups first, then by position within the
    /// group (largest right offset first).
    static func iconDisplayOrder(_ icons: [SystemBarIconMetric]) -> [Int] {
        icons.indices.sorted { lhs, rhs in
            if icons[lhs].group != icons[rhs].group {
                return icons[lhs].group < icons[rhs].group
            }
            if icons[lhs].rightOffset != icons[rhs].rightOffset {
                return icons[lhs].rightOffset > icons[rhs].rightOffset
            }
            return lhs < rhs
        }
    }

    /// The stretches of the bar that hold menus or icons, as x ranges. The rest of the bar stays
    /// transparent. Slots closer than `mergeGap` share a stretch; each stretch gets `padding` on
    /// both sides and runs to the bar's edge when it starts or ends within `edgeSnap` of it.
    static func islands(
        for slots: [SystemBarSlot],
        barWidth: CGFloat,
        mergeGap: CGFloat = 28,
        padding: CGFloat = 6,
        edgeSnap: CGFloat = 32
    ) -> [ClosedRange<CGFloat>] {
        guard barWidth > 0 else { return [] }
        var spans: [(lower: CGFloat, upper: CGFloat)] = []
        for slot in slots.filter({ $0.width > 0 }).sorted(by: { $0.x < $1.x }) {
            if let last = spans.last, slot.x - last.upper <= mergeGap {
                spans[spans.count - 1].upper = max(last.upper, slot.maxX)
            } else {
                spans.append((slot.x, slot.maxX))
            }
        }
        return spans.map { span in
            var lower = max(0, span.lower - padding)
            var upper = min(barWidth, span.upper + padding)
            if lower <= edgeSnap { lower = 0 }
            if upper >= barWidth - edgeSnap { upper = barWidth }
            return lower...max(lower, upper)
        }
    }

    private static func placeIcons(_ visible: [Int], icons: [SystemBarIconMetric], barWidth: CGFloat) -> [SystemBarSlot] {
        guard !visible.isEmpty else { return [] }
        let groups = Dictionary(grouping: visible, by: { icons[$0].group }).sorted { $0.key > $1.key }
        var slots: [SystemBarSlot] = []
        var rightEdge = barWidth
        var isFirstGroup = true
        for (_, members) in groups {
            // Within a group, x = rightEdge - rightOffset - width keeps the real spacing. The first
            // group keeps its real trailing inset; later groups start one gap to the left.
            let minOffset = members.map { icons[$0].rightOffset }.min() ?? 0
            let shift = isFirstGroup ? 0 : minOffset - groupGap
            var groupMinX = rightEdge
            for index in members {
                let metric = icons[index]
                let x = rightEdge - (metric.rightOffset - shift) - metric.width
                slots.append(SystemBarSlot(kind: .icon(index: index), x: x, width: metric.width))
                groupMinX = min(groupMinX, x)
            }
            rightEdge = groupMinX
            isFirstGroup = false
        }
        return slots.sorted { $0.x < $1.x }
    }
}
