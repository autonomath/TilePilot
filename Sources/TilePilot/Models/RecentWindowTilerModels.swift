import CoreGraphics
import Foundation

enum RecentWindowTilerMode: String, CaseIterable, Identifiable, Sendable {
    case floatingGrid
    case autoTiled
    case template

    static let pickerModes: [RecentWindowTilerMode] = [.floatingGrid, .template]

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .autoTiled:
            return "Auto-Tiled"
        case .floatingGrid:
            return "Floating Grid"
        case .template:
            return "Template"
        }
    }
}

struct RecentWindowTilerCandidate: Identifiable, Equatable, Sendable {
    let windowID: Int
    let pid: Int
    let app: String
    let title: String
    let focused: Bool
    let floating: Bool
    let minimized: Bool
    let canAutoTile: Bool
    let canFloatingGrid: Bool
    let isOnTargetDisplay: Bool
    let frame: CGRect
    let frontToBackOrder: Int

    init(
        windowID: Int,
        pid: Int,
        app: String,
        title: String,
        focused: Bool,
        floating: Bool,
        minimized: Bool = false,
        canAutoTile: Bool,
        canFloatingGrid: Bool,
        isOnTargetDisplay: Bool = true,
        frame: CGRect = .zero,
        frontToBackOrder: Int = 0
    ) {
        self.windowID = windowID
        self.pid = pid
        self.app = app
        self.title = title
        self.focused = focused
        self.floating = floating
        self.minimized = minimized
        self.canAutoTile = canAutoTile
        self.canFloatingGrid = canFloatingGrid
        self.isOnTargetDisplay = isOnTargetDisplay
        self.frame = frame
        self.frontToBackOrder = frontToBackOrder
    }

    var id: Int { windowID }

    var isAXOnly: Bool {
        !canAutoTile && canFloatingGrid
    }

    var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var cleanedTitle: String {
        Self.titleWithoutRedundantAppName(trimmedTitle, appName: app)
    }

    var hasDistinctTitle: Bool {
        guard !cleanedTitle.isEmpty else { return false }
        return Self.normalizedLabel(cleanedTitle) != Self.normalizedLabel(app)
    }

    var primaryDisplayText: String {
        hasDistinctTitle ? cleanedTitle : app
    }

    var secondaryDisplayText: String? {
        hasDistinctTitle ? app : nil
    }

    func isSelectable(in mode: RecentWindowTilerMode) -> Bool {
        switch mode {
        case .autoTiled:
            return canAutoTile
        case .floatingGrid, .template:
            return canFloatingGrid
        }
    }

    func disabledReason(in mode: RecentWindowTilerMode) -> String? {
        guard !isSelectable(in: mode) else { return nil }
        switch mode {
        case .autoTiled:
            return "\(app) cannot join yabai Auto-Tiled mode right now. Use Floating Grid for AX-only placement."
        case .floatingGrid, .template:
            return "\(app) cannot be moved or resized right now."
        }
    }

    private static func normalizedLabel(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private static func titleWithoutRedundantAppName(_ rawTitle: String, appName: String) -> String {
        let trimmedTitle = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAppName = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty, !trimmedAppName.isEmpty else { return trimmedTitle }

        if normalizedLabel(trimmedTitle) == normalizedLabel(trimmedAppName) {
            return ""
        }

        let separators = [" - ", " — ", " – ", " | ", " · ", " • "]
        var result = trimmedTitle

        for separator in separators {
            let suffix = "\(separator)\(trimmedAppName)"
            if let range = result.range(
                of: suffix,
                options: [.caseInsensitive, .diacriticInsensitive, .backwards],
                range: result.startIndex..<result.endIndex,
                locale: .current
            ),
               range.upperBound == result.endIndex {
                result.removeSubrange(range)
                return result.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            let prefix = "\(trimmedAppName)\(separator)"
            if let range = result.range(
                of: prefix,
                options: [.caseInsensitive, .diacriticInsensitive],
                range: result.startIndex..<result.endIndex,
                locale: .current
            ),
               range.lowerBound == result.startIndex {
                result.removeSubrange(range)
                return result.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return result
    }
}

struct RecentWindowTilerTemplateOption: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let slots: [WindowLayoutSlot]
    let displayShapeKey: DisplayShapeKey

    var slotCount: Int { slots.count }
}

struct RecentWindowTilerTargetOption: Identifiable, Equatable, Sendable {
    let displayID: Int
    let displayName: String
    let spaceIndex: Int

    var id: Int { displayID }

    var title: String {
        "\(displayName) · Desktop \(spaceIndex)"
    }
}

struct RecentWindowTilerPresentationState: Equatable, Sendable {
    var candidates: [RecentWindowTilerCandidate]
    var selectedWindowIDs: Set<Int>
    var mode: RecentWindowTilerMode
    var backdropEnabled = false
    var backdropColor: OverlayAccentColor = .workSetBackdropDefault
    let targetSpaceIndex: Int
    let targetDisplayID: Int?
    var targetOptions: [RecentWindowTilerTargetOption]
    let displayAspectRatio: Double
    let displayFrame: CGRect?
    var templateOptions: [RecentWindowTilerTemplateOption]
    var selectedTemplateID: UUID?
    var templateSlotWindowIDs: [Int?]

    var selectedTemplateOption: RecentWindowTilerTemplateOption? {
        guard let selectedTemplateID else { return nil }
        return templateOptions.first(where: { $0.id == selectedTemplateID })
    }

    var canUseTemplateMode: Bool {
        !templateOptions.isEmpty
    }

    var effectiveSelectedWindowIDs: Set<Int> {
        selectedWindowIDs.intersection(selectableWindowIDs(for: mode))
    }

    var orderedEffectiveSelectedWindowIDs: [Int] {
        if mode == .template, !templateSlotWindowIDs.isEmpty {
            let slotWindowIDs = templateSlotWindowIDs.compactMap { $0 }.filter { effectiveSelectedWindowIDs.contains($0) }
            let slotWindowIDSet = Set(slotWindowIDs)
            let extraWindowIDs = candidates
                .filter { effectiveSelectedWindowIDs.contains($0.windowID) && !slotWindowIDSet.contains($0.windowID) }
                .map(\.windowID)
            return slotWindowIDs + extraWindowIDs
        }

        return candidates
            .filter { effectiveSelectedWindowIDs.contains($0.windowID) }
            .map(\.windowID)
    }

    var orderedEffectiveSelectedCandidates: [RecentWindowTilerCandidate] {
        let candidateByID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.windowID, $0) })
        if mode == .template, !templateSlotWindowIDs.isEmpty {
            return orderedEffectiveSelectedWindowIDs.compactMap { candidateByID[$0] }
        }
        return candidates.filter { effectiveSelectedWindowIDs.contains($0.windowID) }
    }

    var templateSlotCandidates: [RecentWindowTilerCandidate?] {
        let candidateByID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.windowID, $0) })
        return templateSlotWindowIDs.map { windowID in
            windowID.flatMap { candidateByID[$0] }
        }
    }

    var selectedCount: Int {
        effectiveSelectedWindowIDs.count
    }

    func selectableWindowIDs(for mode: RecentWindowTilerMode) -> Set<Int> {
        Set(candidates.filter { $0.isSelectable(in: mode) }.map(\.windowID))
    }
}

struct RecentWindowTemplatePlanner {
    static let exactFrameTolerance: CGFloat = 12

    static func orderedCandidateIDs(
        for template: RecentWindowTilerTemplateOption,
        candidates: [RecentWindowTilerCandidate],
        displayFrame: CGRect?
    ) -> [Int] {
        slotWindowIDs(
            for: template,
            candidates: candidates,
            displayFrame: displayFrame
        ).compactMap { $0 }
    }

    static func slotWindowIDs(
        for template: RecentWindowTilerTemplateOption,
        candidates: [RecentWindowTilerCandidate],
        displayFrame: CGRect?
    ) -> [Int?] {
        let slots = WindowLayoutTemplate.sortedSlots(template.slots)
        guard !slots.isEmpty else { return [] }

        let eligible = candidates
            .filter { $0.isSelectable(in: .template) }
            .sorted(by: candidateFrontToBackSort)
        var usedWindowIDs = Set<Int>()
        var assignedBySlotID: [UUID: RecentWindowTilerCandidate] = [:]

        if let displayFrame {
            for slot in slots {
                guard assignedBySlotID[slot.id] == nil else { continue }
                let slotFrame = absoluteFrame(for: slot, template: template, displayFrame: displayFrame)
                guard let match = eligible.first(where: {
                    !usedWindowIDs.contains($0.windowID) &&
                    slotAllowsCandidate(slot, candidate: $0) &&
                    framesMatch($0.frame, slotFrame, tolerance: exactFrameTolerance)
                }) else {
                    continue
                }
                usedWindowIDs.insert(match.windowID)
                assignedBySlotID[slot.id] = match
            }
        }

        for slot in layerOrderedSlots(slots) where !slot.allowedApps.isEmpty && assignedBySlotID[slot.id] == nil {
            guard let match = eligible.first(where: {
                !usedWindowIDs.contains($0.windowID) &&
                slotAllowsCandidate(slot, candidate: $0)
            }) else {
                continue
            }
            usedWindowIDs.insert(match.windowID)
            assignedBySlotID[slot.id] = match
        }

        var remaining = eligible.filter { !usedWindowIDs.contains($0.windowID) }.makeIterator()
        for slot in layerOrderedSlots(slots) where slot.allowedApps.isEmpty && assignedBySlotID[slot.id] == nil {
            guard let match = remaining.next() else { break }
            usedWindowIDs.insert(match.windowID)
            assignedBySlotID[slot.id] = match
        }

        return slots.map { assignedBySlotID[$0.id]?.windowID }
    }

    static func reorderedCandidates(
        for template: RecentWindowTilerTemplateOption,
        candidates: [RecentWindowTilerCandidate],
        displayFrame: CGRect?
    ) -> [RecentWindowTilerCandidate] {
        let orderedIDs = orderedCandidateIDs(
            for: template,
            candidates: candidates,
            displayFrame: displayFrame
        )
        let candidateByID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.windowID, $0) })
        let orderedSet = Set(orderedIDs)
        return orderedIDs.compactMap { candidateByID[$0] } + candidates.filter { !orderedSet.contains($0.windowID) }
    }

    private static func candidateFrontToBackSort(
        _ lhs: RecentWindowTilerCandidate,
        _ rhs: RecentWindowTilerCandidate
    ) -> Bool {
        if lhs.frontToBackOrder != rhs.frontToBackOrder {
            return lhs.frontToBackOrder < rhs.frontToBackOrder
        }
        return lhs.windowID < rhs.windowID
    }

    private static func layerOrderedSlots(_ slots: [WindowLayoutSlot]) -> [WindowLayoutSlot] {
        slots.sorted { lhs, rhs in
            if lhs.zIndex != rhs.zIndex {
                return lhs.zIndex > rhs.zIndex
            }
            let geometric = WindowLayoutTemplate.sortedSlots([lhs, rhs])
            return geometric.first?.id == lhs.id
        }
    }

    static func absoluteFrame(
        for slot: WindowLayoutSlot,
        template: RecentWindowTilerTemplateOption,
        displayFrame: CGRect
    ) -> CGRect {
        let normalizedFrame = fittedNormalizedRect(
            for: slot,
            sourceAspectRatio: template.displayShapeKey.aspectRatio,
            targetAspectRatio: Double(displayFrame.width / max(displayFrame.height, 1))
        )
        return CGRect(
            x: displayFrame.minX + (normalizedFrame.minX * displayFrame.width),
            y: displayFrame.minY + (normalizedFrame.minY * displayFrame.height),
            width: max(80, normalizedFrame.width * displayFrame.width),
            height: max(60, normalizedFrame.height * displayFrame.height)
        ).integral
    }

    static func fittedNormalizedRect(
        for slot: WindowLayoutSlot,
        template: RecentWindowTilerTemplateOption,
        targetAspectRatio: Double
    ) -> CGRect {
        fittedNormalizedRect(
            for: slot,
            sourceAspectRatio: template.displayShapeKey.aspectRatio,
            targetAspectRatio: targetAspectRatio
        )
    }

    private static func slotAllowsCandidate(_ slot: WindowLayoutSlot, candidate: RecentWindowTilerCandidate) -> Bool {
        guard !slot.allowedApps.isEmpty else { return true }
        let allowedKeys = Set(slot.allowedApps.map(normalizedAppRuleKey).filter { !$0.isEmpty })
        return allowedKeys.contains(normalizedAppRuleKey(candidate.app))
    }

    private static func framesMatch(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat) -> Bool {
        abs(lhs.minX - rhs.minX) <= tolerance &&
        abs(lhs.minY - rhs.minY) <= tolerance &&
        abs(lhs.width - rhs.width) <= tolerance &&
        abs(lhs.height - rhs.height) <= tolerance
    }

    private static func fittedNormalizedRect(
        for slot: WindowLayoutSlot,
        sourceAspectRatio: Double,
        targetAspectRatio: Double
    ) -> CGRect {
        let sourceAspectRatio = max(sourceAspectRatio, 0.1)
        let targetAspectRatio = max(targetAspectRatio, 0.1)

        var scaleX = 1.0
        var scaleY = 1.0
        var offsetX = 0.0
        var offsetY = 0.0

        if targetAspectRatio > sourceAspectRatio {
            scaleX = sourceAspectRatio / targetAspectRatio
            offsetX = (1 - scaleX) / 2
        } else if targetAspectRatio < sourceAspectRatio {
            scaleY = targetAspectRatio / sourceAspectRatio
            offsetY = (1 - scaleY) / 2
        }

        let rect = slot.normalizedRect
        let fittedRect = CGRect(
            x: offsetX + (rect.minX * scaleX),
            y: offsetY + (rect.minY * scaleY),
            width: rect.width * scaleX,
            height: rect.height * scaleY
        )

        let clampedX = min(max(0, fittedRect.minX), 1)
        let clampedY = min(max(0, fittedRect.minY), 1)
        let maxWidth = max(0, 1 - clampedX)
        let maxHeight = max(0, 1 - clampedY)

        return CGRect(
            x: clampedX,
            y: clampedY,
            width: min(max(0, fittedRect.width), maxWidth),
            height: min(max(0, fittedRect.height), maxHeight)
        )
    }
}

struct RecentWindowGridPlanner {
    static func dimensions(windowCount count: Int, displayAspectRatio: Double) -> (rows: Int, cols: Int) {
        guard count > 1 else { return (1, 1) }

        let aspectRatio = max(displayAspectRatio, 0.5)
        let landscape = aspectRatio >= 1
        var best: GridCandidate?

        for rows in 1...count {
            let cols = Int(ceil(Double(count) / Double(rows)))
            guard rows * cols >= count else { continue }
            if landscape, cols < rows { continue }
            if !landscape, rows < cols { continue }

            let spare = (rows * cols) - count
            let gridAspect = Double(cols) / Double(rows)
            let aspectPenalty = abs(log(gridAspect / aspectRatio))
            let sparePenalty = (Double(spare) / Double(count)) * 2.2
            let stripPenalty = count > 3 && min(rows, cols) == 1 ? 1.0 : 0
            let score = aspectPenalty + sparePenalty + stripPenalty
            let candidate = GridCandidate(rows: rows, cols: cols, spare: spare, score: score)

            if best.map({ candidate.isBetter(than: $0) }) ?? true {
                best = candidate
            }
        }

        guard let best else {
            let cols = max(1, Int(ceil(sqrt(Double(count) * aspectRatio))))
            return (max(1, Int(ceil(Double(count) / Double(cols)))), cols)
        }

        return (best.rows, best.cols)
    }

    static func placements(windowCount count: Int, rows: Int, cols: Int) -> [RecentWindowGridPlacement] {
        guard count > 0 else { return [] }

        var placements = (0..<count).map { index in
            RecentWindowGridPlacement(
                row: index / max(cols, 1),
                col: index % max(cols, 1),
                rowSpan: 1,
                colSpan: 1
            )
        }

        let lastRowCount = count % max(cols, 1)
        guard rows > 1, lastRowCount > 0 else { return placements }

        for col in lastRowCount..<cols {
            let indexAboveSpareCell = ((rows - 2) * cols) + col
            guard placements.indices.contains(indexAboveSpareCell) else { continue }
            placements[indexAboveSpareCell].rowSpan = 2
        }

        return placements
    }

    private struct GridCandidate {
        let rows: Int
        let cols: Int
        let spare: Int
        let score: Double

        func isBetter(than other: GridCandidate) -> Bool {
            if abs(score - other.score) > 0.0001 {
                return score < other.score
            }
            if spare != other.spare {
                return spare < other.spare
            }
            return abs(rows - cols) < abs(other.rows - other.cols)
        }
    }
}

struct RecentWindowGridPlacement: Equatable, Sendable {
    let row: Int
    let col: Int
    var rowSpan: Int
    let colSpan: Int
}
