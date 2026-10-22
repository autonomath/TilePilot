import CoreGraphics
import Foundation

/// Opaque handle for an Accessibility element that `AccessibilityMirrorReader` owns. Only the
/// reader ever touches the element; everything else passes the handle around.
typealias MirrorElementID = String

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
