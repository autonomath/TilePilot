import CoreGraphics
import Foundation

/// The row shown with every display's icons (see SystemBarIconRow): which icons, in which order,
/// how far apart, and how far from the bar's right edge. Learned from every scan; whatever cannot
/// be measured right now keeps its previous value, so the row does not move when focus does.
struct SystemBarIconRowState {
    /// Left-to-right order of the icons present now.
    private(set) var order: [String] = []
    /// The same order plus icons missing right now whose app still runs, in their last places.
    private(set) var memory: [String] = []
    /// Each icon's gap to its right-hand neighbour.
    private(set) var gaps: [String: CGFloat] = [:]
    /// Space between the last icon and the bar's right edge.
    private(set) var trailingInset: CGFloat = SystemBarLayoutPlanner.defaultTrailingInset
    /// The real bar whose row the mirror copies; kept until another bar clearly draws more.
    private(set) var reference: String?

    /// Updates the row from a scan. Only confirmed positions count.
    mutating func learn(from items: [SystemBarStatusItem], livePIDs: Set<pid_t>) {
        var icons: [(key: String, sightings: [SystemBarIconRow.Sighting], isSystem: Bool)] = []
        var frames: [String: [String: CGRect]] = [:]
        var trailingInsets: [String: [String: CGFloat]] = [:]
        for item in items {
            let placements = item.allPlacements.filter { $0.frame.width > 0 }
            for placement in placements {
                let bar = SystemBarIconRow.barKey(placement.menuBar)
                frames[item.stableKey, default: [:]][bar] = placement.frame
                trailingInsets[item.stableKey, default: [:]][bar] = placement.menuBar.maxX - placement.frame.maxX
            }
            var sightings = placements.map { SystemBarIconRow.Sighting(bar: SystemBarIconRow.barKey($0.menuBar), minX: $0.frame.minX) }
            if sightings.isEmpty {
                sightings = [SystemBarIconRow.Sighting(bar: SystemBarIconRow.barKey(item.reportedMenuBarFrame), minX: item.reportedFrame.minX)]
            }
            icons.append((item.stableKey, sightings, item.isSystemExtra))
        }
        let result = SystemBarIconRow.order(icons: icons, previousReference: reference, previousOrder: memory)
        order = result.order
        reference = result.reference
        memory = SystemBarIconRow.remembered(order: result.order, previous: memory) { key in
            key.split(separator: ":").first.flatMap { pid_t($0) }.map(livePIDs.contains) ?? false
        }
        gaps = SystemBarIconRow.learnedGaps(order: order, frames: frames, previous: gaps)
        // The last icon's distance from the right edge, as the copied bar draws it.
        if let lastKey = order.last, let reference, let inset = trailingInsets[lastKey]?[reference] {
            trailingInset = min(max(inset, 4), 40)
        }
    }

    /// The icons to show, left to right, each with its width and distance from the bar's right
    /// edge: packed from the right with the learned gaps. `isShown` leaves out icons that cannot
    /// be drawn yet without closing up the row around them later.
    func layout(_ items: [SystemBarStatusItem], isShown: (SystemBarStatusItem) -> Bool) -> [(item: SystemBarStatusItem, metric: SystemBarIconMetric)] {
        let byKey = Dictionary(items.map { ($0.stableKey, $0) }, uniquingKeysWith: { first, _ in first })
        let shownOrder = order.filter { key in byKey[key].map(isShown) ?? false }
        var widths: [String: CGFloat] = [:]
        for key in shownOrder {
            guard let item = byKey[key] else { continue }
            widths[key] = item.frame.width > 0 ? item.frame.width : item.reportedFrame.width
        }
        let offsets = SystemBarIconRow.packedRightOffsets(order: shownOrder, widths: widths, trailingGaps: gaps, trailingInset: trailingInset)
        return shownOrder.compactMap { key in
            guard let item = byKey[key], let offset = offsets[key], let width = widths[key] else { return nil }
            return (item, SystemBarIconMetric(width: width, rightOffset: offset, group: 1_000))
        }
    }
}
