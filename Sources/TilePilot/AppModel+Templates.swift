import AppKit
import Foundation

private struct CurrentDesktopTemplateImportSource {
    let display: OverviewDisplayPreview
    let desktop: OverviewDesktopPreview
}

struct TemplateImportDisplayOption: Identifiable, Hashable, Sendable {
    let id: Int
    let name: String
    let currentDesktopIndex: Int
    let windowCount: Int
}

@MainActor
extension AppModel {
    func visibleTemplateTargetCandidates(in snapshot: LiveStateSnapshot) -> [(space: SpaceState, display: DisplayState)] {
        snapshot.spaces
            .filter(\.visible)
            .compactMap { space in
                guard let display = snapshot.displays.first(where: { $0.id == space.displayId }) else { return nil }
                return (space, display)
            }
    }

    func preferredTemplateTarget(
        for template: WindowLayoutTemplate,
        in snapshot: LiveStateSnapshot
    ) -> (space: SpaceState, display: DisplayState)? {
        let visibleCandidates = visibleTemplateTargetCandidates(in: snapshot)
        guard !visibleCandidates.isEmpty else { return nil }

        if let exactSourceMatch = visibleCandidates.first(where: {
            $0.display.name.localizedCaseInsensitiveCompare(template.sourceDisplayName) == .orderedSame
        }) {
            return exactSourceMatch
        }

        if let activeSpace = activeSpaceIndex(in: snapshot),
           let activeMatch = visibleCandidates.first(where: { $0.space.index == activeSpace }) {
            return activeMatch
        }

        if let focusedDisplayMatch = visibleCandidates.first(where: { $0.display.focused || $0.space.focused }) {
            return focusedDisplayMatch
        }

        return visibleCandidates.first
    }

    private static let windowLayoutTemplateFeaturePrefix = "template.apply."

    func templateFeatureID(for template: WindowLayoutTemplate) -> FeatureControlID {
        FeatureControlID(rawValue: Self.windowLayoutTemplateFeaturePrefix + template.id.uuidString.lowercased())
    }

    func templateID(from featureID: FeatureControlID) -> UUID? {
        guard featureID.rawValue.hasPrefix(Self.windowLayoutTemplateFeaturePrefix) else { return nil }
        let raw = String(featureID.rawValue.dropFirst(Self.windowLayoutTemplateFeaturePrefix.count))
        return UUID(uuidString: raw)
    }

    func windowLayoutTemplate(withID id: UUID) -> WindowLayoutTemplate? {
        windowLayoutTemplates.first(where: { $0.id == id })
    }

    var availableTemplateDisplayOptions: [TemplateDisplayOption] {
        let snapshot = latestLiveStateSnapshot ?? liveStateSnapshot
        if let snapshot, !snapshot.displays.isEmpty {
            return snapshot.displays.compactMap { display in
                guard let shapeKey = DisplayShapeKey.from(width: display.frameW, height: display.frameH) else { return nil }
                return TemplateDisplayOption(
                    displayID: display.id,
                    name: display.name,
                    frameWidth: display.frameW,
                    frameHeight: display.frameH,
                    shapeKey: shapeKey
                )
            }
            .sorted { lhs, rhs in
                if lhs.displayID == currentTemplateTargetDisplayOption()?.displayID { return true }
                if rhs.displayID == currentTemplateTargetDisplayOption()?.displayID { return false }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        }

        return NSScreen.screens.compactMap { screen in
            guard let shapeKey = DisplayShapeKey.from(width: screen.frame.width, height: screen.frame.height) else { return nil }
            return TemplateDisplayOption(
                displayID: nil,
                name: screen.localizedName,
                frameWidth: screen.frame.width,
                frameHeight: screen.frame.height,
                shapeKey: shapeKey
            )
        }
    }

    func currentTemplateTargetDisplayOption() -> TemplateDisplayOption? {
        let snapshot = latestLiveStateSnapshot ?? liveStateSnapshot
        if let snapshot,
           let activeSpace = activeSpaceIndex(in: snapshot),
           let space = snapshot.spaces.first(where: { $0.index == activeSpace }),
           let display = snapshot.displays.first(where: { $0.id == space.displayId }),
           let shapeKey = DisplayShapeKey.from(width: display.frameW, height: display.frameH) {
            return TemplateDisplayOption(
                displayID: display.id,
                name: display.name,
                frameWidth: display.frameW,
                frameHeight: display.frameH,
                shapeKey: shapeKey
            )
        }

        guard let screen = NSScreen.main ?? NSScreen.screens.first,
              let shapeKey = DisplayShapeKey.from(width: screen.frame.width, height: screen.frame.height) else {
            return nil
        }
        return TemplateDisplayOption(
            displayID: nil,
            name: screen.localizedName,
            frameWidth: screen.frame.width,
            frameHeight: screen.frame.height,
            shapeKey: shapeKey
        )
    }

    func templateTargetDisplayOption(for template: WindowLayoutTemplate) -> TemplateDisplayOption? {
        let snapshot = latestLiveStateSnapshot ?? liveStateSnapshot
        if let snapshot,
           let target = preferredTemplateTarget(for: template, in: snapshot),
           let shapeKey = DisplayShapeKey.from(width: target.display.frameW, height: target.display.frameH) {
            return TemplateDisplayOption(
                displayID: target.display.id,
                name: target.display.name,
                frameWidth: target.display.frameW,
                frameHeight: target.display.frameH,
                shapeKey: shapeKey
            )
        }
        return currentTemplateTargetDisplayOption()
    }

    func templateMatchesCurrentDisplay(_ template: WindowLayoutTemplate) -> Bool {
        guard let option = templateTargetDisplayOption(for: template) else { return false }
        return template.displayShapeKey.matches(width: option.frameWidth, height: option.frameHeight)
    }

    func templateApplyDisabledReason(_ template: WindowLayoutTemplate) -> String? {
        if let runtimeReason = yabaiRuntimeControlDisabledReason, !canRunYabaiRuntimeCommands {
            return runtimeReason
        }
        guard templateTargetDisplayOption(for: template) != nil else {
            return "Current desktop display is unavailable."
        }
        return nil
    }

    func templateNeedsDisplayAutoFit(_ template: WindowLayoutTemplate) -> Bool {
        guard let option = templateTargetDisplayOption(for: template) else { return false }
        return !template.displayShapeKey.matches(width: option.frameWidth, height: option.frameHeight)
    }

    var overviewTemplateImportDisplayOptions: [TemplateImportDisplayOption] {
        currentOverviewTemplateImportPreviewDisplays().compactMap { display in
            guard let desktop = currentOverviewTemplateImportSource(displayID: display.id)?.desktop else { return nil }
            return TemplateImportDisplayOption(
                id: display.id,
                name: display.name,
                currentDesktopIndex: desktop.desktopIndex,
                windowCount: desktop.windows.count
            )
        }
        .sorted { lhs, rhs in
            if lhs.id == currentOverviewTemplateImportDisplayID() { return true }
            if rhs.id == currentOverviewTemplateImportDisplayID() { return false }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    func currentOverviewTemplateImportDisplayID() -> Int? {
        let displays = currentOverviewTemplateImportPreviewDisplays()
        if let focusedDisplayID = displays.first(where: \.focused)?.id {
            return focusedDisplayID
        }
        if let focusedDesktopDisplayID = displays.first(where: { $0.desktops.contains(where: \.focused) })?.id {
            return focusedDesktopDisplayID
        }
        if let visibleDesktopDisplayID = displays.first(where: { $0.desktops.contains(where: \.visible) })?.id {
            return visibleDesktopDisplayID
        }
        return displays.first?.id
    }

    func currentOverviewTemplateImportDisabledReason(displayID: Int?) -> String? {
        guard let displayID,
              let source = currentOverviewTemplateImportSource(displayID: displayID),
              source.display.frameW > 1,
              source.display.frameH > 1,
              !source.desktop.windows.isEmpty else {
            return "Current desktop layout is unavailable right now."
        }
        return nil
    }

    @discardableResult
    func importCurrentDesktopWindowLayoutTemplate(displayID: Int?) async -> UUID? {
        await refreshLiveState()

        guard currentOverviewTemplateImportDisabledReason(displayID: displayID) == nil,
              let displayID,
              let source = currentOverviewTemplateImportSource(displayID: displayID),
              let shapeKey = DisplayShapeKey.from(width: source.display.frameW, height: source.display.frameH) else {
            lastErrorMessage = "Current desktop layout is unavailable right now."
            lastActionMessage = nil
            return nil
        }

        let importedSlots = normalizedTemplateSlotZOrder(
            source.desktop.windows.map { window in
                WindowLayoutSlot(
                    normalizedX: window.normalizedX,
                    normalizedY: window.normalizedY,
                    normalizedWidth: window.normalizedW,
                    normalizedHeight: window.normalizedH,
                    allowedApps: [window.app]
                )
            }
        )

        let template = WindowLayoutTemplate(
            name: nextAvailableTemplateName(base: "Desktop \(source.desktop.desktopIndex) Layout"),
            sourceDisplayName: source.display.name,
            displayShapeKey: shapeKey,
            slots: importedSlots
        )
        windowLayoutTemplates.append(template)
        persistWindowLayoutTemplates()
        lastActionMessage = "Imported \(template.name)."
        lastErrorMessage = nil
        return template.id
    }

    @discardableResult
    func createWindowLayoutTemplate(from optionID: String) -> UUID? {
        guard let option = availableTemplateDisplayOptions.first(where: { $0.id == optionID }) else {
            lastErrorMessage = "Display shape is unavailable right now."
            lastActionMessage = nil
            return nil
        }
        let template = WindowLayoutTemplate(
            name: nextAvailableTemplateName(base: "Template"),
            sourceDisplayName: option.name,
            displayShapeKey: option.shapeKey,
            slots: []
        )
        windowLayoutTemplates.append(template)
        persistWindowLayoutTemplates()
        lastActionMessage = "Created \(template.name)."
        lastErrorMessage = nil
        return template.id
    }

    @discardableResult
    func duplicateWindowLayoutTemplate(_ id: UUID) -> UUID? {
        guard let template = windowLayoutTemplate(withID: id) else {
            lastErrorMessage = "Template no longer exists."
            lastActionMessage = nil
            return nil
        }
        let duplicate = WindowLayoutTemplate(
            name: nextAvailableTemplateName(base: template.name + " Copy"),
            sourceDisplayName: template.sourceDisplayName,
            displayShapeKey: template.displayShapeKey,
            slots: template.slots
        )
        if let index = windowLayoutTemplates.firstIndex(where: { $0.id == id }) {
            windowLayoutTemplates.insert(duplicate, at: index + 1)
        } else {
            windowLayoutTemplates.append(duplicate)
        }
        persistWindowLayoutTemplates()
        lastActionMessage = "Duplicated \(template.name)."
        lastErrorMessage = nil
        return duplicate.id
    }

    func renameWindowLayoutTemplate(_ id: UUID, to rawName: String) {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = windowLayoutTemplates.firstIndex(where: { $0.id == id }) else { return }
        guard windowLayoutTemplates[index].name != trimmed else { return }
        windowLayoutTemplates[index] = windowLayoutTemplates[index].with(name: trimmed)
        persistWindowLayoutTemplates()
    }

    func deleteWindowLayoutTemplate(_ id: UUID) {
        guard let template = windowLayoutTemplate(withID: id) else { return }
        windowLayoutTemplates.removeAll { $0.id == id }
        for index in workSets.indices where workSets[index].linkedTemplateID == id {
            workSets[index] = workSets[index].with(linkedTemplateID: .some(nil))
        }
        persistWindowLayoutTemplates()
        persistWorkSets()
        lastActionMessage = "Deleted \(template.name)."
        lastErrorMessage = nil
    }

    @discardableResult
    func addWindowLayoutTemplateSlot(templateID: UUID, rect: CGRect) -> UUID? {
        guard let index = windowLayoutTemplates.firstIndex(where: { $0.id == templateID }) else { return nil }
        let nextZIndex = (windowLayoutTemplates[index].slots.map(\.zIndex).max() ?? -1) + 1
        let slot = WindowLayoutSlot(
            normalizedX: rect.origin.x,
            normalizedY: rect.origin.y,
            normalizedWidth: rect.width,
            normalizedHeight: rect.height,
            zIndex: nextZIndex
        )
        var slots = windowLayoutTemplates[index].slots
        slots.append(slot)
        windowLayoutTemplates[index] = windowLayoutTemplates[index].with(slots: slots)
        persistWindowLayoutTemplates()
        return slot.id
    }

    func availableTemplateAllowedAppSuggestions(excluding existingValues: [String] = []) -> [String] {
        let existingKeys = Set(existingValues.map(normalizedAppRuleKey).filter { !$0.isEmpty })
        let snapshot = latestLiveStateSnapshot ?? liveStateSnapshot
        let apps = canonicalizeAppRuleList(snapshot?.windows.map(\.app) ?? [])
        return apps.filter { !existingKeys.contains(normalizedAppRuleKey($0)) }
    }

    @discardableResult
    func addFullScreenWindowLayoutTemplateSlot(templateID: UUID) -> UUID? {
        addWindowLayoutTemplateSlot(
            templateID: templateID,
            rect: CGRect(x: 0, y: 0, width: 1, height: 1)
        )
    }

    func updateWindowLayoutTemplateSlot(templateID: UUID, slotID: UUID, rect: CGRect) {
        guard let templateIndex = windowLayoutTemplates.firstIndex(where: { $0.id == templateID }),
              let slotIndex = windowLayoutTemplates[templateIndex].slots.firstIndex(where: { $0.id == slotID }) else { return }
        var slots = windowLayoutTemplates[templateIndex].slots
        slots[slotIndex] = slots[slotIndex].with(rect: rect)
        windowLayoutTemplates[templateIndex] = windowLayoutTemplates[templateIndex].with(slots: slots)
        persistWindowLayoutTemplates()
    }

    func addAllowedAppToWindowLayoutTemplateSlot(templateID: UUID, slotID: UUID, appName: String) {
        guard let templateIndex = windowLayoutTemplates.firstIndex(where: { $0.id == templateID }),
              let slotIndex = windowLayoutTemplates[templateIndex].slots.firstIndex(where: { $0.id == slotID }) else { return }
        let slot = windowLayoutTemplates[templateIndex].slots[slotIndex]
        let updatedApps = addingAppName(appName, to: slot.allowedApps)
        guard updatedApps != slot.allowedApps else { return }
        var slots = windowLayoutTemplates[templateIndex].slots
        slots[slotIndex] = slot.with(allowedApps: updatedApps)
        windowLayoutTemplates[templateIndex] = windowLayoutTemplates[templateIndex].with(slots: slots)
        persistWindowLayoutTemplates()
    }

    func removeAllowedAppFromWindowLayoutTemplateSlot(templateID: UUID, slotID: UUID, appName: String) {
        guard let templateIndex = windowLayoutTemplates.firstIndex(where: { $0.id == templateID }),
              let slotIndex = windowLayoutTemplates[templateIndex].slots.firstIndex(where: { $0.id == slotID }) else { return }
        let slot = windowLayoutTemplates[templateIndex].slots[slotIndex]
        let updatedApps = removeAppName(appName, from: slot.allowedApps)
        guard updatedApps != slot.allowedApps else { return }
        var slots = windowLayoutTemplates[templateIndex].slots
        slots[slotIndex] = slot.with(allowedApps: updatedApps)
        windowLayoutTemplates[templateIndex] = windowLayoutTemplates[templateIndex].with(slots: slots)
        persistWindowLayoutTemplates()
    }

    func deleteWindowLayoutTemplateSlot(templateID: UUID, slotID: UUID) {
        guard let templateIndex = windowLayoutTemplates.firstIndex(where: { $0.id == templateID }) else { return }
        let originalSlots = canvasOrderedTemplateSlots(windowLayoutTemplates[templateIndex].slots)
        let originalCount = originalSlots.count
        let filtered = normalizedTemplateSlotZOrderPreservingOrder(
            originalSlots.filter { $0.id != slotID }
        )
        guard filtered.count != originalCount else { return }
        windowLayoutTemplates[templateIndex] = windowLayoutTemplates[templateIndex].with(slots: filtered)
        persistWindowLayoutTemplates()
    }

    @discardableResult
    func splitWindowLayoutTemplateSlot(templateID: UUID, slotID: UUID, axis: TemplateSlotSplitAxis) -> [UUID]? {
        guard let templateIndex = windowLayoutTemplates.firstIndex(where: { $0.id == templateID }),
              let slotIndex = windowLayoutTemplates[templateIndex].slots.firstIndex(where: { $0.id == slotID }) else {
            return nil
        }

        let slot = windowLayoutTemplates[templateIndex].slots[slotIndex]
        guard let splitRects = splitTemplateSlotRect(slot.normalizedRect, axis: axis) else {
            return nil
        }

        let existingSlots = windowLayoutTemplates[templateIndex].slots
        var canvasOrdered = canvasOrderedTemplateSlots(existingSlots)
        guard let canvasIndex = canvasOrdered.firstIndex(where: { $0.id == slotID }) else { return nil }
        canvasOrdered.remove(at: canvasIndex)
        let first = WindowLayoutSlot(
            normalizedX: splitRects.0.origin.x,
            normalizedY: splitRects.0.origin.y,
            normalizedWidth: splitRects.0.width,
            normalizedHeight: splitRects.0.height,
            zIndex: 0,
            allowedApps: slot.allowedApps
        )
        let second = WindowLayoutSlot(
            normalizedX: splitRects.1.origin.x,
            normalizedY: splitRects.1.origin.y,
            normalizedWidth: splitRects.1.width,
            normalizedHeight: splitRects.1.height,
            zIndex: 0,
            allowedApps: slot.allowedApps
        )
        canvasOrdered.insert(first, at: canvasIndex)
        canvasOrdered.insert(second, at: min(canvasIndex + 1, canvasOrdered.count))
        windowLayoutTemplates[templateIndex] = windowLayoutTemplates[templateIndex].with(
            slots: normalizedTemplateSlotZOrderPreservingOrder(canvasOrdered)
        )
        persistWindowLayoutTemplates()
        return [first.id, second.id]
    }

    func bringWindowLayoutTemplateSlotToFront(templateID: UUID, slotID: UUID) {
        guard let templateIndex = windowLayoutTemplates.firstIndex(where: { $0.id == templateID }) else { return }
        var canvasOrdered = canvasOrderedTemplateSlots(windowLayoutTemplates[templateIndex].slots)
        guard let index = canvasOrdered.firstIndex(where: { $0.id == slotID }) else { return }
        let slot = canvasOrdered.remove(at: index)
        canvasOrdered.append(slot)
        windowLayoutTemplates[templateIndex] = windowLayoutTemplates[templateIndex].with(
            slots: normalizedTemplateSlotZOrderPreservingOrder(canvasOrdered)
        )
        persistWindowLayoutTemplates()
    }

    func sendWindowLayoutTemplateSlotToBack(templateID: UUID, slotID: UUID) {
        guard let templateIndex = windowLayoutTemplates.firstIndex(where: { $0.id == templateID }) else { return }
        var canvasOrdered = canvasOrderedTemplateSlots(windowLayoutTemplates[templateIndex].slots)
        guard let index = canvasOrdered.firstIndex(where: { $0.id == slotID }) else { return }
        let slot = canvasOrdered.remove(at: index)
        canvasOrdered.insert(slot, at: 0)
        windowLayoutTemplates[templateIndex] = windowLayoutTemplates[templateIndex].with(
            slots: normalizedTemplateSlotZOrderPreservingOrder(canvasOrdered)
        )
        persistWindowLayoutTemplates()
    }

    func moveWindowLayoutTemplateSlotForward(templateID: UUID, slotID: UUID) {
        guard let templateIndex = windowLayoutTemplates.firstIndex(where: { $0.id == templateID }) else { return }
        var canvasOrdered = canvasOrderedTemplateSlots(windowLayoutTemplates[templateIndex].slots)
        guard let index = canvasOrdered.firstIndex(where: { $0.id == slotID }),
              index < canvasOrdered.count - 1 else { return }
        canvasOrdered.swapAt(index, index + 1)
        windowLayoutTemplates[templateIndex] = windowLayoutTemplates[templateIndex].with(
            slots: normalizedTemplateSlotZOrderPreservingOrder(canvasOrdered)
        )
        persistWindowLayoutTemplates()
    }

    func moveWindowLayoutTemplateSlotBackward(templateID: UUID, slotID: UUID) {
        guard let templateIndex = windowLayoutTemplates.firstIndex(where: { $0.id == templateID }) else { return }
        var canvasOrdered = canvasOrderedTemplateSlots(windowLayoutTemplates[templateIndex].slots)
        guard let index = canvasOrdered.firstIndex(where: { $0.id == slotID }),
              index > 0 else { return }
        canvasOrdered.swapAt(index, index - 1)
        windowLayoutTemplates[templateIndex] = windowLayoutTemplates[templateIndex].with(
            slots: normalizedTemplateSlotZOrderPreservingOrder(canvasOrdered)
        )
        persistWindowLayoutTemplates()
    }

    @discardableResult
    func duplicateWindowLayoutTemplateSlot(templateID: UUID, slotID: UUID) -> UUID? {
        guard let templateIndex = windowLayoutTemplates.firstIndex(where: { $0.id == templateID }) else { return nil }
        let existingSlots = windowLayoutTemplates[templateIndex].slots
        guard let slot = existingSlots.first(where: { $0.id == slotID }) else { return nil }

        var duplicatedRect = slot.normalizedRect.offsetBy(dx: 0.03, dy: 0.03)
        duplicatedRect = clampedNormalizedTemplateRect(duplicatedRect)
        if duplicatedRect.equalTo(slot.normalizedRect) {
            duplicatedRect = clampedNormalizedTemplateRect(
                slot.normalizedRect.offsetBy(dx: -0.03, dy: -0.03)
            )
        }

        var canvasOrdered = canvasOrderedTemplateSlots(existingSlots)
        let duplicate = WindowLayoutSlot(
            normalizedX: duplicatedRect.origin.x,
            normalizedY: duplicatedRect.origin.y,
            normalizedWidth: duplicatedRect.width,
            normalizedHeight: duplicatedRect.height,
            zIndex: 0,
            allowedApps: slot.allowedApps
        )
        canvasOrdered.append(duplicate)
        windowLayoutTemplates[templateIndex] = windowLayoutTemplates[templateIndex].with(
            slots: normalizedTemplateSlotZOrderPreservingOrder(canvasOrdered)
        )
        persistWindowLayoutTemplates()
        return duplicate.id
    }

    private func nextAvailableTemplateName(base: String) -> String {
        let existing = Set(windowLayoutTemplates.map { $0.name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current) })
        let baseTrimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !baseTrimmed.isEmpty else { return nextAvailableTemplateName(base: "Template") }
        if !existing.contains(baseTrimmed.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)) {
            return baseTrimmed
        }
        for suffix in 2...999 {
            let candidate = "\(baseTrimmed) \(suffix)"
            let normalized = candidate.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            if !existing.contains(normalized) {
                return candidate
            }
        }
        return baseTrimmed + " Copy"
    }

    func persistWindowLayoutTemplates() {
        let defaults = UserDefaults.standard
        if windowLayoutTemplates.isEmpty {
            defaults.removeObject(forKey: AppModel.windowLayoutTemplatesDefaultsKey)
        } else if let data = try? JSONEncoder().encode(windowLayoutTemplates) {
            defaults.set(data, forKey: AppModel.windowLayoutTemplatesDefaultsKey)
        }
        reconcileDynamicFeaturePresentationState()
    }

    private func currentOverviewTemplateImportSource(displayID: Int) -> CurrentDesktopTemplateImportSource? {
        let displays = currentOverviewTemplateImportPreviewDisplays()
        guard !displays.isEmpty else { return nil }

        guard let display = displays.first(where: { $0.id == displayID }),
              let desktop = display.desktops.first(where: \.visible)
                ?? display.desktops.first(where: \.focused)
                ?? display.desktops.first else {
            return nil
        }
        return CurrentDesktopTemplateImportSource(display: display, desktop: desktop)
    }

    private func currentOverviewTemplateImportPreviewDisplays() -> [OverviewDisplayPreview] {
        guard let snapshot = latestLiveStateSnapshot ?? liveStateSnapshot else { return [] }
        return buildOverviewPreviews(from: snapshot)
    }
}
