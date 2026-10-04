import Foundation
import SwiftUI

@MainActor
extension AppModel {
var unifiedControlRows: [UnifiedControlRow] {
    cachedUnifiedControlRows
}

func buildUnifiedControlRows() -> [UnifiedControlRow] {
    var byIntent: [String: UnifiedControlRow] = [:]
    var actionIDsBoundToShortcut: Set<TilePilotActionID> = []

    for entry in shortcutEntries {
        let intent = shortcutIntentKey(for: entry)
        let group = unifiedGroup(for: entry)
        let matchingAction = matchingActionID(forShortcutIntentKey: intent)
        if let matchingAction {
            actionIDsBoundToShortcut.insert(matchingAction)
        }

        let row = UnifiedControlRow(
            id: "shortcut-\(entry.stableKey)",
            group: group,
            title: shortcutTitle(entry),
            description: shortcutExplanation(entry),
            shortcutEntry: entry,
            actionID: matchingAction,
            secondaryActionIDs: [],
            isExperimental: group == .experimental,
            disabledReason: matchingAction.flatMap { actionCard(for: $0)?.disabledReason },
            intentKey: intent,
            featureID: nil
        )
        byIntent[intent] = row
    }

    for card in actionCards {
        let intent = actionIntentKey(for: card.id)
        if var existing = byIntent[intent] {
            if existing.actionID == nil {
                existing = UnifiedControlRow(
                    id: existing.id,
                    group: existing.group,
                    title: existing.title,
                    description: existing.description,
                    shortcutEntry: existing.shortcutEntry,
                    actionID: card.id,
                    secondaryActionIDs: existing.secondaryActionIDs,
                    isExperimental: existing.isExperimental,
                    disabledReason: card.disabledReason,
                    intentKey: existing.intentKey,
                    featureID: existing.featureID
                )
                byIntent[intent] = existing
            } else if existing.actionID != card.id {
                var secondary = existing.secondaryActionIDs
                secondary.append(card.id)
                var dedupedSecondary: [TilePilotActionID] = []
                for actionID in secondary where !dedupedSecondary.contains(actionID) {
                    dedupedSecondary.append(actionID)
                }
                existing = UnifiedControlRow(
                    id: existing.id,
                    group: existing.group,
                    title: existing.title,
                    description: existing.description,
                    shortcutEntry: existing.shortcutEntry,
                    actionID: existing.actionID,
                    secondaryActionIDs: dedupedSecondary,
                    isExperimental: existing.isExperimental,
                    disabledReason: existing.disabledReason ?? card.disabledReason,
                    intentKey: existing.intentKey,
                    featureID: existing.featureID
                )
                byIntent[intent] = existing
            }
            continue
        }

        if actionIDsBoundToShortcut.contains(card.id) {
            continue
        }

        let group = unifiedGroup(forActionCategory: card.category)
        byIntent[intent] = UnifiedControlRow(
            id: "action-\(card.id.rawValue)",
            group: group,
            title: card.title,
            description: card.subtitle,
            shortcutEntry: nil,
            actionID: card.id,
            secondaryActionIDs: [],
            isExperimental: group == .experimental,
            disabledReason: card.disabledReason,
            intentKey: intent,
            featureID: nil
        )
    }

    return byIntent.values.sorted { lhs, rhs in
        if lhs.group.sortRank != rhs.group.sortRank { return lhs.group.sortRank < rhs.group.sortRank }
        if lhs.title != rhs.title { return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending }
        return lhs.id < rhs.id
    }
}

func filteredUnifiedControlRows(query: String) -> [UnifiedControlRow] {
    let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !q.isEmpty else { return unifiedControlRows }
    return unifiedControlRows.filter { row in
        row.title.lowercased().contains(q) ||
            row.description.lowercased().contains(q) ||
            row.shortcutEntry?.combo.lowercased().contains(q) == true ||
            row.shortcutEntry?.command.lowercased().contains(q) == true ||
            row.group.title.lowercased().contains(q)
    }
}


var featureControlRows: [FeatureControlRow] {
    cachedFeatureControlRows
}

func buildFeatureControlRows(from baseRows: [UnifiedControlRow]) -> [FeatureControlRow] {
    var usedFeatureIDs: Set<FeatureControlID> = []
    var result: [FeatureControlRow] = []
    var featureRowsByID: [FeatureControlID: FeatureControlRow] = [:]
    var seenNonFeatureSignatures: Set<String> = []

    for row in baseRows {
        let mappedDefinition = row.shortcutEntry.flatMap(featureDefinition(for:))
            ?? row.actionID.flatMap(featureDefinition(forActionID:))
        if let mappedDefinition {
            usedFeatureIDs.insert(mappedDefinition.id)
        }
        let disabledReason = mappedDefinition.map { featureDisabledReason(for: $0) } ?? row.disabledReason
        let bindingState: FeatureShortcutBindingState
        if let disabledReason {
            bindingState = .disabled(reason: disabledReason)
        } else if let entry = row.shortcutEntry {
            bindingState = .assigned(combo: entry.combo)
        } else {
            bindingState = .missing(defaultCombo: mappedDefinition?.defaultCombo)
        }
        let candidate = FeatureControlRow(
            id: mappedDefinition.map { "feature-\($0.id.rawValue)" } ?? row.id,
            featureID: mappedDefinition?.id,
            group: mappedDefinition?.group ?? row.group,
            title: mappedDefinition?.title ?? row.title,
            description: mappedDefinition?.description ?? row.description,
            backend: mappedDefinition?.backend ?? (row.shortcutEntry == nil ? .tilePilotAction : .shortcutCommand),
            capabilityGate: mappedDefinition?.capabilityGate ?? .none,
            shortcutEntry: row.shortcutEntry,
            actionID: mappedDefinition?.actionID ?? row.actionID,
            preferredCommand: mappedDefinition?.preferredCommand,
            assignedCombo: row.shortcutEntry?.combo,
            defaultCombo: mappedDefinition?.defaultCombo,
            bindingState: bindingState,
            isExperimental: mappedDefinition?.isExperimental ?? row.isExperimental,
            disabledReason: disabledReason
        )
        if let featureID = candidate.featureID {
            if let existing = featureRowsByID[featureID] {
                featureRowsByID[featureID] = preferredFeatureRow(existing: existing, candidate: candidate)
            } else {
                featureRowsByID[featureID] = candidate
            }
        } else {
            let signature = nonFeatureRowSignature(candidate)
            if seenNonFeatureSignatures.insert(signature).inserted {
                result.append(candidate)
            }
        }
    }

    result.append(contentsOf: featureRowsByID.values)

    for definition in featureDefinitions where !usedFeatureIDs.contains(definition.id) {
        let disabledReason = featureDisabledReason(for: definition)
        let bindingState: FeatureShortcutBindingState
        if let disabledReason {
            bindingState = .disabled(reason: disabledReason)
        } else {
            bindingState = .missing(defaultCombo: definition.defaultCombo)
        }
        result.append(
            FeatureControlRow(
                id: "feature-\(definition.id.rawValue)",
                featureID: definition.id,
                group: definition.group,
                title: definition.title,
                description: definition.description,
                backend: definition.backend,
                capabilityGate: definition.capabilityGate,
                shortcutEntry: nil,
                actionID: definition.actionID,
                preferredCommand: definition.preferredCommand,
                assignedCombo: nil,
                defaultCombo: definition.defaultCombo,
                bindingState: bindingState,
                isExperimental: definition.isExperimental,
                disabledReason: disabledReason
            )
        )
    }

    return result.sorted { lhs, rhs in
        if lhs.group.sortRank != rhs.group.sortRank { return lhs.group.sortRank < rhs.group.sortRank }
        if lhs.group == .tilingLayout && rhs.group == .tilingLayout {
            let lhsPriority = featureControlRowSortPriority(lhs)
            let rhsPriority = featureControlRowSortPriority(rhs)
            if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
        }
        if lhs.title != rhs.title { return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending }
        return lhs.id < rhs.id
    }
}

func featureControlRowSortPriority(_ row: FeatureControlRow) -> Int {
    guard row.group == .tilingLayout else { return 1_000 }
    if let featureID = row.featureID {
        switch featureID.rawValue {
        case "screen.set-floating-all-visible": return 10
        case "screen.set-tiled-all-visible": return 20
        case "screen.bring-floating-front": return 25
        case "screen.grid-floating": return 30
        case "screen.grid-auto-tiled": return 40
        case "screen.pick-windows-to-tile": return 45
        case "screen.balance-current-desktop": return 50
        case "screen.current-desktop-tiling-on": return 55
        case "screen.current-desktop-tiling-off": return 56
        case "screen.layout-bsp-balance": return 60
        case "action.layout-stack": return 70
        case "screen.rotate-layout": return 80
        default: return 500
        }
    }

    let command = row.shortcutEntry?.command.lowercased() ?? row.preferredCommand?.lowercased() ?? ""
    let title = row.title.lowercased()
    if command.contains("yabai -m space --rotate") || title.contains("rotate layout") { return 80 }
    if command.contains("yabai -m space --layout stack") || title.contains("stack layout") { return 70 }
    if command.contains("yabai -m space --layout float") || title.contains("desktop → tiling off") { return 56 }
    if command.contains("yabai -m space --layout bsp"), !command.contains("space --balance") { return 55 }
    if command.contains("yabai -m space --layout bsp") || title.contains("tile layout + balance") { return 60 }
    if command.contains("yabai -m space --balance") || title.contains("balance tiles") { return 50 }
    return 500
}

func filteredFeatureControlRows(query: String) -> [FeatureControlRow] {
    let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !q.isEmpty else { return featureControlRows }
    return featureControlRows.filter { row in
        row.title.lowercased().contains(q) ||
            row.description.lowercased().contains(q) ||
            row.assignedCombo?.lowercased().contains(q) == true ||
            row.shortcutEntry?.command.lowercased().contains(q) == true ||
            row.group.title.lowercased().contains(q)
    }
}

func shortcutsCatalogGroup(for item: ShortcutsDisplayItem) -> UnifiedControlGroup {
    switch item {
    case .featureRow(let row):
        return row.group
    case .directionalFamily(let group, _):
        switch group {
        case .moveWindow, .swapWindow:
            return .windowPlacement
        case .resizeWindow:
            return .windowSize
        case .focusWindow:
            return .focus
        }
    case .desktopJumpFamily:
        return .desktops
    case .desktopMoveFamily:
        return .experimental
    }
}

func groupedFlatShortcutsSections(query: String) -> [ShortcutsCatalogSection] {
    let orderedItems = flatShortcutsItems(query: query)
    guard !orderedItems.isEmpty else { return [] }

    var groupedItems: [UnifiedControlGroup: [ShortcutsDisplayItem]] = [:]
    for item in orderedItems {
        groupedItems[shortcutsCatalogGroup(for: item), default: []].append(item)
    }

    return UnifiedControlGroup.allCases
        .sorted { lhs, rhs in lhs.sortRank < rhs.sortRank }
        .compactMap { group in
            guard let items = groupedItems[group], !items.isEmpty else { return nil }
            return ShortcutsCatalogSection(group: group, items: items)
        }
}

func flatShortcutsItems(query: String) -> [ShortcutsDisplayItem] {
    let baseItems = buildFlatShortcutsItemsBaseOrder()
    let orderedItems = applyShortcutsCustomOrder(baseItems)
    let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !q.isEmpty else { return orderedItems }
    return orderedItems.filter { item in
        switch item {
        case .featureRow(let row):
            return row.title.lowercased().contains(q) ||
                row.description.lowercased().contains(q) ||
                row.assignedCombo?.lowercased().contains(q) == true ||
                row.shortcutEntry?.combo.lowercased().contains(q) == true ||
                row.shortcutEntry?.command.lowercased().contains(q) == true
        case .directionalFamily(let group, let bindings):
            if directionalFamilyTitle(for: group).lowercased().contains(q) ||
                directionalFamilyDescription(for: group).lowercased().contains(q) {
                return true
            }
            return bindings.contains { binding in
                binding.entry.combo.lowercased().contains(q) ||
                    binding.entry.command.lowercased().contains(q) ||
                    shortcutExplanation(binding.entry).lowercased().contains(q) ||
                    binding.direction.label.lowercased().contains(q)
            }
        case .desktopJumpFamily(let entries):
            if "jump to desktop".contains(q) || "macos keyboard shortcuts".contains(q) {
                return true
            }
            return entries.contains { entry in
                entry.combo.lowercased().contains(q) ||
                    entry.command.lowercased().contains(q) ||
                    shortcutExplanation(entry).lowercased().contains(q)
            }
        case .desktopMoveFamily(let entries):
            if "move window to desktop".contains(q) ||
                "advanced desktop move".contains(q) ||
                "scripting addition".contains(q) ||
                "sip".contains(q) {
                return true
            }
            return entries.contains { entry in
                entry.combo.lowercased().contains(q) ||
                    entry.command.lowercased().contains(q) ||
                    shortcutExplanation(entry).lowercased().contains(q)
            }
        }
    }
}

func moveFlatShortcutsItems(fromOffsets: IndexSet, toOffset: Int) {
    let orderedIDs = flatShortcutsItems(query: "").map(\.id)
    guard !orderedIDs.isEmpty else { return }
    var mutableIDs = orderedIDs
    mutableIDs.move(fromOffsets: fromOffsets, toOffset: toOffset)
    guard mutableIDs != shortcutsCustomOrderIDs else { return }
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) {
        shortcutsCustomOrderIDs = mutableIDs
    }
    persistShortcutsCustomOrderIDs()
    rebuildShortcutPresentationCaches()
}

func moveFlatShortcutsItem(draggedID: String, before targetID: String) {
    guard draggedID != targetID else { return }
    var orderedIDs = flatShortcutsItems(query: "").map(\.id)
    guard
        let sourceIndex = orderedIDs.firstIndex(of: draggedID),
        let targetIndex = orderedIDs.firstIndex(of: targetID)
    else { return }

    let movingID = orderedIDs.remove(at: sourceIndex)
    let destinationIndex = sourceIndex < targetIndex ? max(0, targetIndex - 1) : targetIndex
    orderedIDs.insert(movingID, at: destinationIndex)

    guard orderedIDs != shortcutsCustomOrderIDs else { return }
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) {
        shortcutsCustomOrderIDs = orderedIDs
    }
    persistShortcutsCustomOrderIDs()
    rebuildShortcutPresentationCaches()
}

func resetShortcutsCustomOrderToDefault() {
    shortcutsCustomOrderIDs = []
    persistShortcutsCustomOrderIDs()
    reconcileShortcutsCustomOrderIDsToCurrentItems()
    rebuildShortcutPresentationCaches()
}

func applyShortcutsCustomOrderIDs(_ ids: [String]) {
    let normalized = Array(NSOrderedSet(array: ids)) as? [String] ?? ids
    guard normalized != shortcutsCustomOrderIDs else { return }
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) {
        shortcutsCustomOrderIDs = normalized
    }
    persistShortcutsCustomOrderIDs()
    rebuildShortcutPresentationCaches()
}

func directionalFamilyTitle(for group: DirectionalShortcutGroup) -> String {
    switch group {
    case .focusWindow:
        return "Change Focus"
    case .moveWindow:
        return "Move Window in Layout (Direction Keys)"
    case .resizeWindow:
        return "Resize Window"
    case .swapWindow:
        return "Swap Window (Direction Keys)"
    }
}

func directionalFamilyDescription(for group: DirectionalShortcutGroup) -> String {
    switch group {
    case .focusWindow:
        return "Use the I / J / K / L direction keys to move focus up, left, down, and right."
    case .moveWindow:
        return "Use the I / J / K / L direction keys to move the focused window to another tile position."
    case .resizeWindow:
        return "Use the I / J / K / L direction keys to resize the focused window up, left, down, and right."
    case .swapWindow:
        return "Use the I / J / K / L direction keys to swap with a neighboring window in a direction."
    }
}

private func buildFlatShortcutsItemsBaseOrder() -> [ShortcutsDisplayItem] {
    let rows = featureControlRows
    let directionalGroups: [DirectionalShortcutGroup] = [.moveWindow, .swapWindow, .focusWindow, .resizeWindow]
    let directionalBindingsByGroup = Dictionary(uniqueKeysWithValues: directionalGroups.map { group in
        (group, directionalShortcutBindings(for: group))
    })
    var insertedDirectionalGroups: Set<DirectionalShortcutGroup> = []
    var desktopJumpEntries: [ShortcutEntry] = []
    var desktopMoveEntries: [ShortcutEntry] = []
    var desktopJumpInsertIndex: Int?
    var desktopMoveInsertIndex: Int?
    var items: [ShortcutsDisplayItem] = []

    for row in rows {
        if let entry = row.shortcutEntry, desktopJumpTarget(from: entry.command) != nil {
            if desktopJumpInsertIndex == nil {
                desktopJumpInsertIndex = items.count
            }
            desktopJumpEntries.append(entry)
            continue
        }
        if let entry = row.shortcutEntry, isScriptingAdditionDesktopShortcut(entry) {
            if desktopMoveInsertIndex == nil {
                desktopMoveInsertIndex = items.count
            }
            desktopMoveEntries.append(entry)
            continue
        }
        guard let entry = row.shortcutEntry, let binding = directionalShortcutBinding(for: entry) else {
            items.append(.featureRow(row))
            continue
        }
        if insertedDirectionalGroups.contains(binding.group) {
            continue
        }
        let bindings = directionalBindingsByGroup[binding.group] ?? []
        guard !bindings.isEmpty else { continue }
        items.append(.directionalFamily(group: binding.group, bindings: bindings))
        insertedDirectionalGroups.insert(binding.group)
    }

    for group in directionalGroups where !insertedDirectionalGroups.contains(group) {
        guard let bindings = directionalBindingsByGroup[group], !bindings.isEmpty else { continue }
        items.append(.directionalFamily(group: group, bindings: bindings))
    }

    if !desktopJumpEntries.isEmpty {
        let sortedDesktopJumpEntries = desktopJumpEntries.sorted { lhs, rhs in
            let lhsDesktop = desktopJumpTarget(from: lhs.command) ?? Int.max
            let rhsDesktop = desktopJumpTarget(from: rhs.command) ?? Int.max
            if lhsDesktop != rhsDesktop { return lhsDesktop < rhsDesktop }
            return lhs.sourceLine < rhs.sourceLine
        }
        let familyItem: ShortcutsDisplayItem = .desktopJumpFamily(entries: sortedDesktopJumpEntries)
        if let insertIndex = desktopJumpInsertIndex, insertIndex <= items.count {
            items.insert(familyItem, at: insertIndex)
        } else {
            items.insert(familyItem, at: 0)
        }
    }

    if !desktopMoveEntries.isEmpty {
        let sortedDesktopMoveEntries = desktopMoveEntries.sorted { lhs, rhs in
            let lhsDesktop = desktopMoveTarget(from: lhs.command) ?? Int.max
            let rhsDesktop = desktopMoveTarget(from: rhs.command) ?? Int.max
            if lhsDesktop != rhsDesktop { return lhsDesktop < rhsDesktop }
            return lhs.sourceLine < rhs.sourceLine
        }
        let familyItem: ShortcutsDisplayItem = .desktopMoveFamily(entries: sortedDesktopMoveEntries)
        if let insertIndex = desktopMoveInsertIndex, insertIndex <= items.count {
            items.insert(familyItem, at: insertIndex)
        } else {
            items.append(familyItem)
        }
    }

    return items
}

private func applyShortcutsCustomOrder(_ items: [ShortcutsDisplayItem]) -> [ShortcutsDisplayItem] {
    var byID: [String: ShortcutsDisplayItem] = [:]
    for item in items {
        byID[item.id] = item
    }
    var ordered: [ShortcutsDisplayItem] = []
    var seen: Set<String> = []

    for id in shortcutsCustomOrderIDs {
        guard let item = byID[id], seen.insert(id).inserted else { continue }
        ordered.append(item)
    }
    for item in items {
        guard seen.insert(item.id).inserted else { continue }
        ordered.append(item)
    }
    return ordered
}

func reconcileShortcutsCustomOrderIDsToCurrentItems() {
    let availableIDs = buildFlatShortcutsItemsBaseOrder().map(\.id)
    let availableSet = Set(availableIDs)
    var reconciled: [String] = []
    var seen: Set<String> = []

    for id in shortcutsCustomOrderIDs where availableSet.contains(id) {
        guard seen.insert(id).inserted else { continue }
        reconciled.append(id)
    }
    for id in availableIDs where !seen.contains(id) {
        seen.insert(id)
        reconciled.append(id)
    }

    if reconciled != shortcutsCustomOrderIDs {
        shortcutsCustomOrderIDs = reconciled
        persistShortcutsCustomOrderIDs()
    }
}

func flatOrderID(for row: FeatureControlRow) -> String {
    if let featureID = row.featureID {
        return "feature.\(featureID.rawValue)"
    }
    if let stableKey = row.shortcutEntry?.stableKey {
        return "shortcut.\(stableKey)"
    }
    if let actionID = row.actionID {
        return "action.\(actionID.rawValue)"
    }
    return "row.\(row.id)"
}

func flatOrderID(for group: DirectionalShortcutGroup) -> String {
    "directional.\(group.rawValue)"
}

func flatOrderID(for entry: ShortcutEntry) -> String {
    if let featureID = featureDefinition(for: entry)?.id {
        return "feature.\(featureID.rawValue)"
    }
    return "shortcut.\(entry.stableKey)"
}

private func desktopJumpTarget(from command: String) -> Int? {
    let c = command.lowercased()
    guard !c.contains("yabai -m window --space") else { return nil }
    guard let range = c.range(of: "yabai -m space --focus ") else { return nil }
    let suffix = c[range.upperBound...]
    let digits = suffix.prefix { $0.isNumber }
    return Int(digits)
}

private func desktopMoveTarget(from command: String) -> Int? {
    let c = command.lowercased()
    guard let range = c.range(of: "yabai -m window --space ") else { return nil }
    let suffix = c[range.upperBound...]
    let digits = suffix.prefix { $0.isNumber }
    return Int(digits)
}

func pinnedContextOrderID(_ item: PinnedShortcutContextItem) -> String {
    switch item {
    case .feature(let row):
        return flatOrderID(for: row)
    case .directional(let group, _):
        return flatOrderID(for: group)
    case .shortcut(let entry):
        return flatOrderID(for: entry)
    }
}

func flatShortcutsOrderRankByID() -> [String: Int] {
    cachedFlatShortcutsOrderRankByID
}

func buildFlatShortcutsOrderRankByID() -> [String: Int] {
    let orderedIDs = applyShortcutsCustomOrder(buildFlatShortcutsItemsBaseOrder()).map(\.id)
    return Dictionary(uniqueKeysWithValues: orderedIDs.enumerated().map { ($0.element, $0.offset) })
}

private func preferredFeatureRow(existing: FeatureControlRow, candidate: FeatureControlRow) -> FeatureControlRow {
    if existing.shortcutEntry == nil, candidate.shortcutEntry != nil { return candidate }
    if existing.shortcutEntry != nil, candidate.shortcutEntry == nil { return existing }
    if existing.disabledReason != nil, candidate.disabledReason == nil { return candidate }
    if existing.assignedCombo == nil, candidate.assignedCombo != nil { return candidate }
    if let existingLine = existing.shortcutEntry?.sourceLine,
       let candidateLine = candidate.shortcutEntry?.sourceLine,
       candidateLine < existingLine {
        return candidate
    }
    return existing
}

private func nonFeatureRowSignature(_ row: FeatureControlRow) -> String {
    let combo = row.assignedCombo ?? ""
    let action = row.actionID?.rawValue ?? ""
    let command = row.shortcutEntry?.command ?? row.preferredCommand ?? ""
    return "\(row.group.rawValue)|\(row.title)|\(combo)|\(action)|\(command)"
}

var pinnedFeatureControlRows: [FeatureControlRow] {
    cachedPinnedFeatureControlRows
}

func buildPinnedFeatureControlRows(orderRank: [String: Int]) -> [FeatureControlRow] {
    var byID: [String: FeatureControlRow] = [:]
    for row in featureControlRows {
        guard let id = row.featureID else { continue }
        byID[id.rawValue] = row
    }
    let fallbackRank = Dictionary(uniqueKeysWithValues: pinnedFeatureControlIDs.enumerated().map { ($0.element, $0.offset) })
    return pinnedFeatureControlIDs.compactMap { byID[$0] }.sorted { lhs, rhs in
        let lhsOrder = orderRank[flatOrderID(for: lhs)] ?? Int.max
        let rhsOrder = orderRank[flatOrderID(for: rhs)] ?? Int.max
        if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
        let lhsFallback = lhs.featureID.flatMap { fallbackRank[$0.rawValue] } ?? Int.max
        let rhsFallback = rhs.featureID.flatMap { fallbackRank[$0.rawValue] } ?? Int.max
        if lhsFallback != rhsFallback { return lhsFallback < rhsFallback }
        return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
    }
}

func featureControlRow(forShortcutEntry entry: ShortcutEntry) -> FeatureControlRow? {
    cachedFeatureControlRowByShortcutStableKey[entry.stableKey]
}

func featureControlRow(forID featureID: FeatureControlID) -> FeatureControlRow? {
    cachedFeatureControlRowByFeatureID[featureID.rawValue]
}

func isFeaturePinned(_ featureID: FeatureControlID) -> Bool {
    pinnedFeatureControlIDs.contains(featureID.rawValue)
}

func toggleFeaturePinned(_ featureID: FeatureControlID) {
    if isFeaturePinned(featureID) {
        pinnedFeatureControlIDs.removeAll { $0 == featureID.rawValue }
        lastActionMessage = "Removed feature from right-click menu."
    } else {
        pinnedFeatureControlIDs.append(featureID.rawValue)
        pinnedFeatureControlIDs = Array(NSOrderedSet(array: pinnedFeatureControlIDs)) as? [String] ?? pinnedFeatureControlIDs
        lastActionMessage = "Pinned feature to right-click menu."
    }
    persistPinnedFeatureControlIDs()
    rebuildShortcutPresentationCaches()
    lastErrorMessage = nil
}

}
