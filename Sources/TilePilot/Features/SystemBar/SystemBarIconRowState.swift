import CoreGraphics
import Foundation

/// The row shown with every display's icons (see SystemBarIconRow): which icons, in which order,
/// how far apart, and how far from the bar's right edge. Learned from every scan; whatever cannot
/// be measured right now keeps its previous value, so the row does not move when focus does.
///
/// Icons are keyed by their app's bundle ID and their Accessibility identifier, so the row and
/// its spacing survive TilePilot restarts and app relaunches (see `snapshot`). An icon not seen
/// for 30 days is forgotten.
struct SystemBarIconRowState {
    /// What is saved between launches.
    struct Snapshot: Codable, Equatable {
        var memory: [String] = []
        var gaps: [String: Double] = [:]
        var trailingInset: Double?
        var reference: String?
        /// Day number (days since 2001) each remembered icon was last seen.
        var lastSeenDay: [String: Int] = [:]
    }

    static let forgetAfterDays = 30
    static let maximumRemembered = 200

    /// Left-to-right order of the icons present now, as row keys (see `rowKey(for:)`).
    private(set) var order: [String] = []
    /// The same order plus remembered icons missing right now, in their last places.
    private(set) var memory: [String] = []
    /// Each icon's gap to its right-hand neighbour.
    private(set) var gaps: [String: CGFloat] = [:]
    /// Space between the last icon and the bar's right edge.
    private(set) var trailingInset: CGFloat = SystemBarLayoutPlanner.defaultTrailingInset
    /// The real bar whose row the mirror copies; kept until another bar clearly draws more.
    private(set) var reference: String?
    private var lastSeenDay: [String: Int] = [:]

    init() {}

    init(snapshot: Snapshot) {
        memory = snapshot.memory
        gaps = snapshot.gaps.mapValues { CGFloat($0) }
        trailingInset = snapshot.trailingInset.map { CGFloat($0) } ?? SystemBarLayoutPlanner.defaultTrailingInset
        reference = snapshot.reference
        lastSeenDay = snapshot.lastSeenDay
    }

    var snapshot: Snapshot {
        Snapshot(
            memory: memory,
            gaps: gaps.mapValues { Double($0) },
            trailingInset: Double(trailingInset),
            reference: reference,
            lastSeenDay: lastSeenDay
        )
    }

    /// The key an icon keeps across launches: its app's bundle ID (or name) plus its
    /// Accessibility identifier (or its position among the app's icons).
    static func rowKey(for item: SystemBarStatusItem) -> String {
        let app = item.bundleIdentifier.isEmpty ? item.appName : item.bundleIdentifier
        let suffix = item.stableKey.split(separator: ":", maxSplits: 1).dropFirst().first.map(String.init) ?? item.identifier
        return "\(app)|\(suffix)"
    }

    /// Each item with its row key; a second running copy of an app adds its process ID.
    static func keyed(_ items: [SystemBarStatusItem]) -> [(key: String, item: SystemBarStatusItem)] {
        var used = Set<String>()
        return items.map { item in
            var key = rowKey(for: item)
            if !used.insert(key).inserted {
                key += "@\(item.pid)"
                used.insert(key)
            }
            return (key, item)
        }
    }

    static func day(_ date: Date) -> Int {
        Int((date.timeIntervalSinceReferenceDate / 86_400).rounded(.down))
    }

    /// Updates the row from a scan. Only confirmed positions count.
    mutating func learn(from items: [SystemBarStatusItem], now: Date = Date()) {
        let today = Self.day(now)
        var icons: [(key: String, sightings: [SystemBarIconRow.Sighting], isSystem: Bool)] = []
        var frames: [String: [String: CGRect]] = [:]
        var trailingInsets: [String: [String: CGFloat]] = [:]
        for (key, item) in Self.keyed(items) {
            let placements = item.allPlacements.filter { $0.frame.width > 0 }
            for placement in placements {
                let bar = SystemBarIconRow.barKey(placement.menuBar)
                frames[key, default: [:]][bar] = placement.frame
                trailingInsets[key, default: [:]][bar] = placement.menuBar.maxX - placement.frame.maxX
            }
            var sightings = placements.map { SystemBarIconRow.Sighting(bar: SystemBarIconRow.barKey($0.menuBar), minX: $0.frame.minX) }
            if sightings.isEmpty {
                sightings = [SystemBarIconRow.Sighting(bar: SystemBarIconRow.barKey(item.reportedMenuBarFrame), minX: item.reportedFrame.minX)]
            }
            icons.append((key, sightings, item.isSystemExtra))
            lastSeenDay[key] = today
        }
        let result = SystemBarIconRow.order(icons: icons, previousReference: reference, previousOrder: memory)
        order = result.order
        reference = result.reference
        let lastSeen = lastSeenDay
        memory = SystemBarIconRow.remembered(order: result.order, previous: memory) { key in
            lastSeen[key].map { today - $0 <= Self.forgetAfterDays } ?? false
        }
        if memory.count > Self.maximumRemembered {
            let present = Set(order)
            let oldestAbsent = memory.filter { !present.contains($0) }
                .sorted { (lastSeen[$0] ?? 0) < (lastSeen[$1] ?? 0) }
                .prefix(memory.count - Self.maximumRemembered)
            let dropped = Set(oldestAbsent)
            memory.removeAll { dropped.contains($0) }
        }
        let remembered = Set(memory)
        lastSeenDay = lastSeenDay.filter { remembered.contains($0.key) }
        // Gaps of remembered icons stay for when they come back next to the same neighbour.
        let measured = SystemBarIconRow.learnedGaps(order: order, frames: frames, previous: gaps)
        gaps = gaps.filter { remembered.contains($0.key) }.merging(measured) { _, new in new }
        // The last icon's distance from the right edge, as the copied bar draws it.
        if let lastKey = order.last, let reference, let inset = trailingInsets[lastKey]?[reference] {
            trailingInset = min(max(inset, 4), 40)
        }
    }

    /// The icons to show, left to right, each with its width and distance from the bar's right
    /// edge: packed from the right with the learned gaps. `isShown` leaves out icons that cannot
    /// be drawn yet without closing up the row around them later.
    func layout(_ items: [SystemBarStatusItem], isShown: (SystemBarStatusItem) -> Bool) -> [(item: SystemBarStatusItem, metric: SystemBarIconMetric)] {
        let byKey = Dictionary(Self.keyed(items).map { ($0.key, $0.item) }, uniquingKeysWith: { first, _ in first })
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
