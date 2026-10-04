import Foundation

struct WorkSetDesktopContext: Sendable {
    let scopeKey: WorkSetScopeKey
    let display: DisplayState
    let windows: [WindowState]
}

@MainActor
extension AppModel {
    private static let workSetFeaturePrefix = "workset.activate."
    private static let workSetAssignWindowFeaturePrefix = "workset.assign-window."
    static let cycleWorkSetsFeatureID: FeatureControlID = "workset.cycle-current-desktop"

    func workSetFeatureID(for workSet: WorkSet) -> FeatureControlID {
        FeatureControlID(rawValue: Self.workSetFeaturePrefix + workSet.id.uuidString.lowercased())
    }

    func workSetAssignWindowFeatureID(for workSet: WorkSet) -> FeatureControlID {
        FeatureControlID(rawValue: Self.workSetAssignWindowFeaturePrefix + workSet.id.uuidString.lowercased())
    }

    func workSetID(from featureID: FeatureControlID) -> UUID? {
        guard featureID.rawValue.hasPrefix(Self.workSetFeaturePrefix) else { return nil }
        let raw = String(featureID.rawValue.dropFirst(Self.workSetFeaturePrefix.count))
        return UUID(uuidString: raw)
    }

    func workSetIDForAssignWindowFeature(from featureID: FeatureControlID) -> UUID? {
        guard featureID.rawValue.hasPrefix(Self.workSetAssignWindowFeaturePrefix) else { return nil }
        let raw = String(featureID.rawValue.dropFirst(Self.workSetAssignWindowFeaturePrefix.count))
        return UUID(uuidString: raw)
    }

    func workSet(withID id: UUID) -> WorkSet? {
        workSets.first(where: { $0.id == id })
    }

    func assignFocusedWindowToWorkSet(_ workSetID: UUID) {
        assignWindowToWorkSet(workSetID: workSetID, windowID: focusedWindowState?.id)
    }

    func assignWindowToWorkSet(workSetID: UUID, windowID: Int?) {
        guard let workSet = workSet(withID: workSetID) else {
            lastErrorMessage = "Work Set no longer exists."
            lastActionMessage = nil
            return
        }
        guard let window = workSetAssignableWindow(windowID: windowID) else {
            return
        }

        let member = WorkSetMember(window: window)
        if workSet.members.contains(where: { workSetMembersRepresentSameWindow($0, member) }) {
            lastActionMessage = "\(window.app) is already in \(workSet.name)."
            lastErrorMessage = nil
            return
        }

        addMemberToWorkSet(workSetID: workSetID, member: member)
        lastActionMessage = "Added \(window.app) to \(workSet.name)."
        lastErrorMessage = nil
    }

    func isWindowAssignedToWorkSet(windowID: Int, workSet: WorkSet) -> Bool {
        guard let window = workSetAssignableWindow(windowID: windowID, reportErrors: false) else {
            return false
        }
        let member = WorkSetMember(window: window)
        return workSet.members.contains(where: { workSetMembersRepresentSameWindow($0, member) })
    }

    func workSetsForWindowAssignment(windowID: Int?) -> [WorkSet] {
        let window = workSetAssignableWindow(windowID: windowID, reportErrors: false)
        return workSets.sorted { lhs, rhs in
            let lhsSameScope = window.map { $0.display == lhs.scopeKey.displayID && $0.space == lhs.scopeKey.spaceIndex } ?? false
            let rhsSameScope = window.map { $0.display == rhs.scopeKey.displayID && $0.space == rhs.scopeKey.spaceIndex } ?? false
            if lhsSameScope != rhsSameScope { return lhsSameScope && !rhsSameScope }
            let lhsActive = activeWorkSetID(for: lhs.scopeKey) == lhs.id
            let rhsActive = activeWorkSetID(for: rhs.scopeKey) == rhs.id
            if lhsActive != rhsActive { return lhsActive && !rhsActive }
            if lhs.scopeKey.spaceIndex != rhs.scopeKey.spaceIndex { return lhs.scopeKey.spaceIndex < rhs.scopeKey.spaceIndex }
            let displayCompare = lhs.sourceDisplayName.localizedCaseInsensitiveCompare(rhs.sourceDisplayName)
            if displayCompare != .orderedSame { return displayCompare == .orderedAscending }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    func workSetAssignmentMenuTitle(for workSet: WorkSet, windowID: Int?) -> String {
        let sameScope: Bool
        if let window = workSetAssignableWindow(windowID: windowID, reportErrors: false) {
            sameScope = window.display == workSet.scopeKey.displayID && window.space == workSet.scopeKey.spaceIndex
        } else {
            sameScope = false
        }

        guard !sameScope else { return workSet.name }
        return "\(workSet.name) — \(workSet.sourceDisplayName) · Desktop \(workSet.scopeKey.spaceIndex)"
    }

    var currentDesktopWorkSetContext: WorkSetDesktopContext? {
        rebuildWorkSetRuntimeCachesIfNeeded()
        return cachedCurrentDesktopWorkSetContext
    }

    var currentDesktopWorkSetScopeKey: WorkSetScopeKey? {
        currentDesktopWorkSetContext?.scopeKey
    }

    var currentDesktopWorkSets: [WorkSet] {
        guard let scopeKey = currentDesktopWorkSetScopeKey else { return [] }
        return workSets(for: scopeKey)
    }

    var currentDesktopPaletteWindows: [WindowState] {
        guard let scopeKey = currentDesktopWorkSetScopeKey else { return [] }
        return paletteWindows(for: scopeKey)
    }

    var visibleWorkSetContexts: [WorkSetDesktopContext] {
        rebuildWorkSetRuntimeCachesIfNeeded()
        return cachedWorkSetVisibleContexts
    }

    func activeWorkSetID(for scopeKey: WorkSetScopeKey) -> UUID? {
        guard let raw = activeWorkSetIDsByScope[scopeKey.id] else { return nil }
        return UUID(uuidString: raw)
    }

    func isActiveWorkSet(_ workSet: WorkSet) -> Bool {
        activeWorkSetID(for: workSet.scopeKey) == workSet.id
    }

    func setActiveWorkSetID(_ workSetID: UUID?, for scopeKey: WorkSetScopeKey) {
        if let workSetID {
            activeWorkSetIDsByScope[scopeKey.id] = workSetID.uuidString.lowercased()
        } else {
            activeWorkSetIDsByScope.removeValue(forKey: scopeKey.id)
        }
        persistActiveWorkSetIDsByScope()
    }

    func workSetActivationDisabledReason(_ workSet: WorkSet) -> String? {
        if let runtimeReason = yabaiRuntimeControlDisabledReason, !canRunYabaiRuntimeCommands {
            return runtimeReason
        }
        guard !workSet.members.isEmpty else {
            return "Work Set has no windows yet."
        }
        guard !visibleWorkSetContexts.isEmpty else {
            return nil
        }
        guard visibleWorkSetContexts.contains(where: { $0.scopeKey == workSet.scopeKey }) else {
            return "Make Desktop \(workSet.scopeKey.spaceIndex) on \(workSet.sourceDisplayName) visible to activate this Work Set."
        }
        return nil
    }

    func workSetResolvedMembers(for workSet: WorkSet) -> [WorkSetResolvedMember] {
        workSetResolvedMembers(for: workSet, in: currentDesktopWorkSetContext)
    }

    func workSetResolvedMembers(for workSet: WorkSet, in context: WorkSetDesktopContext?) -> [WorkSetResolvedMember] {
        rebuildWorkSetRuntimeCachesIfNeeded()
        let visibleScopeWindows = context?.scopeKey == workSet.scopeKey ? context?.windows ?? [] : []
        return resolveWorkSetMembersForScope(
            workSet.members,
            visibleScopeWindows: visibleScopeWindows,
            allWindows: cachedWorkSetStatusCandidateWindows,
            scopeKey: workSet.scopeKey
        )
    }

    func workSetLinkedTemplate(_ workSet: WorkSet) -> WindowLayoutTemplate? {
        guard let linkedTemplateID = workSet.linkedTemplateID else { return nil }
        return windowLayoutTemplate(withID: linkedTemplateID)
    }

    func workSetTemplateWarning(_ workSet: WorkSet) -> String? {
        guard workSet.layoutMode == .template else { return nil }
        guard let linkedTemplateID = workSet.linkedTemplateID else {
            return "Choose a template."
        }
        guard let template = windowLayoutTemplate(withID: linkedTemplateID) else {
            return "Linked template is missing."
        }
        guard let display = workSetContext(for: workSet.scopeKey)?.display else {
            return "Current desktop display is unavailable."
        }
        guard template.displayShapeKey.matches(width: display.frameW, height: display.frameH) else {
            return "Linked template does not match this display shape."
        }
        return nil
    }

    func cycleWorkSetsDisabledReason() -> String? {
        if let runtimeReason = yabaiRuntimeControlDisabledReason, !canRunYabaiRuntimeCommands {
            return runtimeReason
        }
        guard currentDesktopWorkSetContext != nil else {
            return "Current desktop data is unavailable right now."
        }
        guard !currentDesktopWorkSets.isEmpty else {
            return "No Work Sets exist on this desktop yet."
        }
        return nil
    }

    func nextWorkSetForCurrentDesktopCycle() -> WorkSet? {
        guard let scopeKey = currentDesktopWorkSetScopeKey else { return nil }
        return nextWorkSetToCycle(
            in: currentDesktopWorkSets,
            activeWorkSetID: activeWorkSetID(for: scopeKey)
        )
    }

    func workSets(for scopeKey: WorkSetScopeKey) -> [WorkSet] {
        workSets
            .filter { $0.scopeKey == scopeKey }
    }

    func paletteWindows(for scopeKey: WorkSetScopeKey) -> [WindowState] {
        orderedWorkSetCandidateWindows(from: workSetContext(for: scopeKey)?.windows ?? [])
    }

    @discardableResult
    func createEmptyWorkSetForCurrentDesktop(announce: Bool = true) -> UUID? {
        guard let scopeKey = currentDesktopWorkSetScopeKey else {
            lastErrorMessage = "Current desktop data is unavailable right now."
            lastActionMessage = nil
            return nil
        }
        return createEmptyWorkSet(for: scopeKey, announce: announce)
    }

    @discardableResult
    func createEmptyWorkSet(for scopeKey: WorkSetScopeKey, announce: Bool = true) -> UUID? {
        guard let context = workSetContext(for: scopeKey) else {
            lastErrorMessage = "Desktop data is unavailable right now."
            lastActionMessage = nil
            return nil
        }

        return createWorkSet(
            name: nextAvailableWorkSetName(base: "Work Set"),
            sourceDisplay: context.display,
            scopeKey: context.scopeKey,
            members: [],
            announce: announce,
            actionMessage: "Created"
        )
    }

    @discardableResult
    func importCurrentDesktopWorkSet() async -> UUID? {
        await refreshLiveState()
        guard let scopeKey = currentDesktopWorkSetScopeKey else {
            lastErrorMessage = "Current desktop data is unavailable right now."
            lastActionMessage = nil
            return nil
        }
        return importWorkSet(for: scopeKey)
    }

    @discardableResult
    func importWorkSet(for scopeKey: WorkSetScopeKey) -> UUID? {
        guard let context = workSetContext(for: scopeKey) else {
            lastErrorMessage = "Desktop data is unavailable right now."
            lastActionMessage = nil
            return nil
        }

        let orderedWindows = orderedWorkSetCandidateWindows(from: context.windows)
        guard !orderedWindows.isEmpty else {
            lastErrorMessage = "No eligible windows are available on this desktop right now."
            lastActionMessage = nil
            return nil
        }

        return createWorkSet(
            name: nextAvailableWorkSetName(base: "Desktop \(context.scopeKey.spaceIndex) Set"),
            sourceDisplay: context.display,
            scopeKey: context.scopeKey,
            members: orderedWindows.map(WorkSetMember.init(window:)),
            announce: true,
            actionMessage: "Imported"
        )
    }

    @discardableResult
    func duplicateWorkSet(_ id: UUID) -> UUID? {
        guard let workSet = workSet(withID: id) else { return nil }
        let duplicate = WorkSet(
            name: nextAvailableWorkSetName(base: workSet.name + " Copy"),
            sourceDisplayName: workSet.sourceDisplayName,
            sourceDisplayWidth: workSet.sourceDisplayWidth,
            sourceDisplayHeight: workSet.sourceDisplayHeight,
            sourceDisplayShapeKey: workSet.sourceDisplayShapeKey,
            scopeKey: workSet.scopeKey,
            members: workSet.members,
            layoutMode: workSet.layoutMode,
            linkedTemplateID: workSet.linkedTemplateID,
            launchMissingApps: workSet.launchMissingApps,
            backdropEnabled: workSet.backdropEnabled,
            backdropColor: workSet.backdropColor
        )
        if let index = workSets.firstIndex(where: { $0.id == id }) {
            workSets.insert(duplicate, at: index + 1)
        } else {
            workSets.append(duplicate)
        }
        persistWorkSets()
        lastActionMessage = "Duplicated \(workSet.name)."
        lastErrorMessage = nil
        return duplicate.id
    }

    func renameWorkSet(_ id: UUID, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = workSets.firstIndex(where: { $0.id == id }) else { return }
        guard workSets[index].name != trimmed else { return }
        workSets[index] = workSets[index].with(name: trimmed)
        persistWorkSets()
    }

    func deleteWorkSet(_ id: UUID) {
        guard let workSet = workSet(withID: id) else { return }
        let removedActiveTiledWorkSet = activeWorkSetID(for: workSet.scopeKey) == id && workSet.layoutMode == .tiled
        workSets.removeAll { $0.id == id }
        activeWorkSetIDsByScope = activeWorkSetIDsByScope.filter { _, rawID in rawID.lowercased() != id.uuidString.lowercased() }
        if workSetBackdropPresentations[workSet.scopeKey]?.workSetID == id {
            hideWorkSetBackdrop(for: workSet.scopeKey)
        }
        if dismissedWorkSetBackdropIDsByScope[workSet.scopeKey] == id {
            dismissedWorkSetBackdropIDsByScope.removeValue(forKey: workSet.scopeKey)
        }
        if removedActiveTiledWorkSet {
            savedWindowFramesBeforeTiledWorkSetByScope.removeValue(forKey: workSet.scopeKey)
        }
        lastWorkSetOwnedLayoutSyncSignatureByScope.removeValue(forKey: workSet.scopeKey.id)
        persistActiveWorkSetIDsByScope()
        persistWorkSets()
        if removedActiveTiledWorkSet {
            Task { @MainActor [weak self] in
                guard let self else { return }
                _ = await self.restoreSavedTiledWorkSetDesktopLayoutIfNeeded(scopeKey: workSet.scopeKey)
                await self.refreshLiveState()
            }
        }
        lastActionMessage = "Deleted \(workSet.name)."
        lastErrorMessage = nil
    }

    func setWorkSetBackdropEnabled(_ enabled: Bool, workSetID: UUID) {
        guard let index = workSets.firstIndex(where: { $0.id == workSetID }) else { return }
        guard workSets[index].backdropEnabled != enabled else { return }
        workSets[index] = workSets[index].with(backdropEnabled: enabled)
        persistWorkSets()
        syncBackdropRuntimeStateForActiveWorkSet(workSets[index])
    }

    func setWorkSetBackdropColor(_ color: OverlayAccentColor, workSetID: UUID) {
        guard let index = workSets.firstIndex(where: { $0.id == workSetID }) else { return }
        guard workSets[index].backdropColor != color else { return }
        workSets[index] = workSets[index].with(backdropColor: color)
        persistWorkSets()
        syncBackdropRuntimeStateForActiveWorkSet(workSets[index])
    }

    func setWorkSetLayoutMode(_ layoutMode: WorkSetLayoutMode, workSetID: UUID) {
        guard let index = workSets.firstIndex(where: { $0.id == workSetID }) else { return }
        guard workSets[index].layoutMode != layoutMode else { return }
        workSets[index] = workSets[index].with(layoutMode: layoutMode)
        persistWorkSets()
        if activeWorkSetID(for: workSets[index].scopeKey) == workSetID {
            activateWorkSet(workSetID: workSetID)
        }
    }

    func setWorkSetLinkedTemplateID(_ templateID: UUID?, workSetID: UUID) {
        guard let index = workSets.firstIndex(where: { $0.id == workSetID }) else { return }
        guard workSets[index].linkedTemplateID != templateID else { return }
        workSets[index] = workSets[index].with(linkedTemplateID: .some(templateID))
        persistWorkSets()
        if activeWorkSetID(for: workSets[index].scopeKey) == workSetID,
           workSets[index].layoutMode == .template {
            activateWorkSet(workSetID: workSetID)
        }
    }

    func setWorkSetLaunchMissingApps(_ enabled: Bool, workSetID: UUID) {
        guard let index = workSets.firstIndex(where: { $0.id == workSetID }) else { return }
        guard workSets[index].launchMissingApps != enabled else { return }
        workSets[index] = workSets[index].with(launchMissingApps: enabled)
        persistWorkSets()
    }

    func addWindowToWorkSet(workSetID: UUID, window: WindowState, at insertionIndex: Int? = nil) {
        addMemberToWorkSet(workSetID: workSetID, member: WorkSetMember(window: window), at: insertionIndex)
    }

    func addMemberToWorkSet(workSetID: UUID, member: WorkSetMember, at insertionIndex: Int? = nil) {
        guard let workSetIndex = workSets.firstIndex(where: { $0.id == workSetID }) else { return }
        var members = workSets[workSetIndex].members

        let duplicateExists = members.contains { existing in
            workSetMembersRepresentSameWindow(existing, member)
        }
        guard !duplicateExists else { return }

        let index = min(max(0, insertionIndex ?? members.count), members.count)
        members.insert(member, at: index)
        workSets[workSetIndex] = workSets[workSetIndex].with(members: members)
        persistWorkSets()
        if activeWorkSetID(for: workSets[workSetIndex].scopeKey) == workSetID,
           workSets[workSetIndex].layoutMode != .stackOnly {
            activateWorkSet(workSetID: workSetID)
        }
    }

    func removeWorkSetMember(workSetID: UUID, memberID: UUID) {
        guard let workSetIndex = workSets.firstIndex(where: { $0.id == workSetID }) else { return }
        var members = workSets[workSetIndex].members
        let originalCount = members.count
        members.removeAll { $0.id == memberID }
        guard members.count != originalCount else { return }
        workSets[workSetIndex] = workSets[workSetIndex].with(members: members)
        persistWorkSets()
        if activeWorkSetID(for: workSets[workSetIndex].scopeKey) == workSetID,
           workSets[workSetIndex].layoutMode != .stackOnly {
            activateWorkSet(workSetID: workSetID)
        }
    }

    func moveWorkSetMember(workSetID: UUID, memberID: UUID, before targetMemberID: UUID?) {
        guard let workSetIndex = workSets.firstIndex(where: { $0.id == workSetID }) else { return }
        if targetMemberID == memberID {
            return
        }
        var members = workSets[workSetIndex].members
        guard let sourceIndex = members.firstIndex(where: { $0.id == memberID }) else { return }

        let movingMember = members.remove(at: sourceIndex)
        let destinationIndex: Int
        if let targetMemberID,
           let targetIndex = members.firstIndex(where: { $0.id == targetMemberID }) {
            destinationIndex = targetIndex
        } else {
            destinationIndex = members.count
        }
        members.insert(movingMember, at: min(max(0, destinationIndex), members.count))

        guard members != workSets[workSetIndex].members else { return }
        workSets[workSetIndex] = workSets[workSetIndex].with(members: members)
        persistWorkSets()
        if activeWorkSetID(for: workSets[workSetIndex].scopeKey) == workSetID,
           workSets[workSetIndex].layoutMode != .stackOnly {
            activateWorkSet(workSetID: workSetID)
        }
    }

    func moveWorkSetMember(
        from sourceWorkSetID: UUID,
        memberID: UUID,
        to destinationWorkSetID: UUID,
        before targetMemberID: UUID?
    ) {
        if sourceWorkSetID == destinationWorkSetID {
            moveWorkSetMember(workSetID: destinationWorkSetID, memberID: memberID, before: targetMemberID)
            return
        }

        guard let sourceIndex = workSets.firstIndex(where: { $0.id == sourceWorkSetID }),
              let destinationIndex = workSets.firstIndex(where: { $0.id == destinationWorkSetID }),
              let movingMember = workSets[sourceIndex].members.first(where: { $0.id == memberID }) else {
            return
        }

        var sourceMembers = workSets[sourceIndex].members
        var destinationMembers = workSets[destinationIndex].members

        sourceMembers.removeAll { $0.id == memberID }
        destinationMembers.removeAll { existing in
            workSetMembersRepresentSameWindow(existing, movingMember)
        }

        let insertionIndex: Int
        if let targetMemberID,
           let targetIndex = destinationMembers.firstIndex(where: { $0.id == targetMemberID }) {
            insertionIndex = targetIndex
        } else {
            insertionIndex = destinationMembers.count
        }
        destinationMembers.insert(movingMember, at: min(max(0, insertionIndex), destinationMembers.count))

        workSets[sourceIndex] = workSets[sourceIndex].with(members: sourceMembers)
        workSets[destinationIndex] = workSets[destinationIndex].with(members: destinationMembers)
        persistWorkSets()
    }

    @discardableResult
    func copyWorkSetMember(
        from sourceWorkSetID: UUID,
        memberID: UUID,
        to destinationWorkSetID: UUID,
        before targetMemberID: UUID? = nil
    ) -> Bool {
        guard sourceWorkSetID != destinationWorkSetID,
              let sourceIndex = workSets.firstIndex(where: { $0.id == sourceWorkSetID }),
              let destinationIndex = workSets.firstIndex(where: { $0.id == destinationWorkSetID }),
              let sourceMember = workSets[sourceIndex].members.first(where: { $0.id == memberID }) else {
            return false
        }

        var destinationMembers = workSets[destinationIndex].members
        let destinationWorkSet = workSets[destinationIndex]

        guard !destinationMembers.contains(where: { workSetMembersRepresentSameWindow($0, sourceMember) }) else {
            lastActionMessage = "\(sourceMember.appName) is already in \(destinationWorkSet.name)."
            lastErrorMessage = nil
            return false
        }

        let copiedMember = duplicatedMembershipCopy(of: sourceMember)
        let insertionIndex: Int
        if let targetMemberID,
           let targetIndex = destinationMembers.firstIndex(where: { $0.id == targetMemberID }) {
            insertionIndex = targetIndex
        } else {
            insertionIndex = destinationMembers.count
        }
        destinationMembers.insert(copiedMember, at: min(max(0, insertionIndex), destinationMembers.count))

        workSets[destinationIndex] = destinationWorkSet.with(members: destinationMembers)
        persistWorkSets()
        lastActionMessage = "Added \(sourceMember.appName) to \(destinationWorkSet.name)."
        lastErrorMessage = nil
        return true
    }

    @discardableResult
    func createWorkSetWithCopiedMember(_ member: WorkSetMember) -> UUID? {
        guard let context = currentDesktopWorkSetContext else {
            lastErrorMessage = "Current desktop data is unavailable right now."
            lastActionMessage = nil
            return nil
        }

        let workSetID = createWorkSet(
            name: nextAvailableWorkSetName(base: "Work Set"),
            sourceDisplay: context.display,
            scopeKey: context.scopeKey,
            members: [duplicatedMembershipCopy(of: member)],
            announce: false,
            actionMessage: "Created"
        )
        if let workSet = workSet(withID: workSetID) {
            lastActionMessage = "Created \(workSet.name) with \(member.appName)."
            lastErrorMessage = nil
        }
        return workSetID
    }

    @discardableResult
    func createWorkSetFromDrop(
        payload: WorkSetDropPayload,
        before targetMemberID: UUID? = nil
    ) -> UUID? {
        guard let newWorkSetID = createEmptyWorkSetForCurrentDesktop(announce: false) else {
            return nil
        }

        switch payload {
        case .member(let sourceWorkSetID, let memberID):
            moveWorkSetMember(
                from: sourceWorkSetID,
                memberID: memberID,
                to: newWorkSetID,
                before: targetMemberID
            )
        case .window(let member):
            addMemberToWorkSet(workSetID: newWorkSetID, member: member, at: targetMemberID == nil ? nil : 0)
        }

        if let workSet = workSet(withID: newWorkSetID) {
            lastActionMessage = "Created \(workSet.name)."
            lastErrorMessage = nil
        }
        return newWorkSetID
    }

    func persistWorkSets() {
        let defaults = UserDefaults.standard
        if workSets.isEmpty {
            defaults.removeObject(forKey: AppModel.workSetsDefaultsKey)
        } else if let data = try? JSONEncoder().encode(workSets) {
            defaults.set(data, forKey: AppModel.workSetsDefaultsKey)
        }
        let validWorkSetIDs = Set(workSets.map { $0.id.uuidString.lowercased() })
        activeWorkSetIDsByScope = activeWorkSetIDsByScope.filter { _, rawID in
            validWorkSetIDs.contains(rawID.lowercased())
        }
        persistActiveWorkSetIDsByScope()
        reconcileDynamicFeaturePresentationState()
    }

    func persistActiveWorkSetIDsByScope() {
        let defaults = UserDefaults.standard
        if activeWorkSetIDsByScope.isEmpty {
            defaults.removeObject(forKey: AppModel.activeWorkSetIDsByScopeDefaultsKey)
        } else {
            defaults.set(activeWorkSetIDsByScope, forKey: AppModel.activeWorkSetIDsByScopeDefaultsKey)
        }
    }

    func reconcileDynamicFeaturePresentationState() {
        let validFeatureIDs = Set(featureDefinitions.map { $0.id.rawValue })
        let filteredPins = pinnedFeatureControlIDs.filter { validFeatureIDs.contains($0) }
        if filteredPins != pinnedFeatureControlIDs {
            pinnedFeatureControlIDs = filteredPins
            persistPinnedFeatureControlIDs()
        }
        rebuildShortcutPresentationCaches()
        reconcileShortcutsCustomOrderIDsToCurrentItems()
        rebuildShortcutPresentationCaches()
    }

    func currentDesktopWorkSetContext(in snapshot: LiveStateSnapshot?) -> WorkSetDesktopContext? {
        guard let snapshot,
              snapshot.source == .yabai,
              !snapshot.degraded,
              let spaceIndex = activeSpaceIndex(in: snapshot),
              let space = snapshot.spaces.first(where: { $0.index == spaceIndex }) else {
            return nil
        }

        return workSetContext(
            for: WorkSetScopeKey(displayID: space.displayId, spaceIndex: spaceIndex),
            in: snapshot
        )
    }

    func workSetContext(for scopeKey: WorkSetScopeKey) -> WorkSetDesktopContext? {
        rebuildWorkSetRuntimeCachesIfNeeded()
        return cachedWorkSetContextByScopeKey[scopeKey]
    }

    func workSetContext(for scopeKey: WorkSetScopeKey, in snapshot: LiveStateSnapshot?) -> WorkSetDesktopContext? {
        guard let snapshot,
              snapshot.source == .yabai,
              !snapshot.degraded,
              let space = snapshot.spaces.first(where: { $0.index == scopeKey.spaceIndex && $0.displayId == scopeKey.displayID }) else {
            return nil
        }

        let displaysByID = Dictionary(uniqueKeysWithValues: snapshot.displays.map { ($0.id, $0) })
        let eligibleWindowsBySpace = Dictionary(
            grouping: eligibleWindowsForWorkSets(in: snapshot),
            by: \.space
        )
        return workSetContext(
            for: scopeKey,
            space: space,
            displaysByID: displaysByID,
            eligibleWindowsBySpace: eligibleWindowsBySpace
        )
    }

    func rebuildWorkSetRuntimeCachesIfNeeded() {
        guard let snapshot = latestLiveStateSnapshot ?? liveStateSnapshot else {
            clearWorkSetRuntimeCaches()
            return
        }
        guard cachedWorkSetRuntimeSnapshotUpdatedAt != snapshot.lastUpdatedAt else { return }
        rebuildWorkSetRuntimeCaches(using: snapshot)
    }

    func rebuildWorkSetRuntimeCaches(using snapshot: LiveStateSnapshot?, contentSignature: String? = nil) {
        guard let snapshot,
              snapshot.source == .yabai,
              !snapshot.degraded else {
            clearWorkSetRuntimeCaches()
            return
        }

        let resolvedSignature = contentSignature ?? liveStateContentSignature(for: snapshot)
        guard cachedWorkSetRuntimeContentSignature != resolvedSignature else {
            cachedWorkSetRuntimeSnapshotUpdatedAt = snapshot.lastUpdatedAt
            return
        }

        let displaysByID = Dictionary(uniqueKeysWithValues: snapshot.displays.map { ($0.id, $0) })
        let eligibleWindowsBySpace = Dictionary(
            grouping: eligibleWindowsForWorkSets(in: snapshot),
            by: \.space
        )
        let spacesByScopeKey = Dictionary(
            uniqueKeysWithValues: snapshot.spaces.map {
                (WorkSetScopeKey(displayID: $0.displayId, spaceIndex: $0.index), $0)
            }
        )
        let contexts = snapshot.spaces.compactMap { space in
            workSetContext(
                for: WorkSetScopeKey(displayID: space.displayId, spaceIndex: space.index),
                space: space,
                displaysByID: displaysByID,
                eligibleWindowsBySpace: eligibleWindowsBySpace
            )
        }
        let contextByScopeKey = Dictionary(uniqueKeysWithValues: contexts.map { ($0.scopeKey, $0) })
        let currentScopeKey = currentWorkSetScopeKey(in: snapshot)

        cachedWorkSetRuntimeContentSignature = resolvedSignature
        cachedWorkSetRuntimeSnapshotUpdatedAt = snapshot.lastUpdatedAt
        cachedWorkSetContextByScopeKey = contextByScopeKey
        cachedCurrentDesktopWorkSetContext = currentScopeKey.flatMap { contextByScopeKey[$0] }
        cachedWorkSetVisibleContexts = sortWorkSetVisibleContexts(
            contexts.filter { context in
                spacesByScopeKey[context.scopeKey]?.visible == true
            },
            currentScopeKey: currentScopeKey
        )
        cachedWorkSetStatusCandidateWindows = workSetStatusCandidateWindows(in: snapshot)
    }

    private func clearWorkSetRuntimeCaches() {
        cachedWorkSetRuntimeContentSignature = nil
        cachedWorkSetRuntimeSnapshotUpdatedAt = nil
        cachedWorkSetVisibleContexts = []
        cachedWorkSetContextByScopeKey = [:]
        cachedCurrentDesktopWorkSetContext = nil
        cachedWorkSetStatusCandidateWindows = []
    }

    private func workSetContext(
        for scopeKey: WorkSetScopeKey,
        space: SpaceState,
        displaysByID: [Int: DisplayState],
        eligibleWindowsBySpace: [Int: [WindowState]]
    ) -> WorkSetDesktopContext? {
        guard let display = displaysByID[space.displayId] else { return nil }
        return WorkSetDesktopContext(
            scopeKey: scopeKey,
            display: display,
            windows: eligibleWindowsBySpace[scopeKey.spaceIndex] ?? []
        )
    }

    private func workSetAssignableWindow(windowID: Int?, reportErrors: Bool = true) -> WindowState? {
        guard let snapshot = latestLiveStateSnapshot ?? liveStateSnapshot,
              snapshot.source == .yabai,
              !snapshot.degraded else {
            if reportErrors {
                lastErrorMessage = "Current desktop data is unavailable right now."
                lastActionMessage = nil
            }
            return nil
        }

        let resolvedWindow: WindowState?
        if let windowID {
            resolvedWindow = snapshot.windows.first(where: { $0.id == windowID })
        } else {
            resolvedWindow = snapshot.windows.first(where: \.focused)
        }

        guard let resolvedWindow else {
            if reportErrors {
                lastErrorMessage = windowID == nil ? "No focused window is available right now." : "Window is no longer available."
                lastActionMessage = nil
            }
            return nil
        }

        guard resolvedWindow.isVisible, !resolvedWindow.isMinimized, !resolvedWindow.isHidden else {
            if reportErrors {
                lastErrorMessage = "\(resolvedWindow.app) is not currently available for Work Set assignment."
                lastActionMessage = nil
            }
            return nil
        }

        guard resolvedWindow.isRuntimeManageable else {
            if reportErrors {
                lastErrorMessage = "\(resolvedWindow.app) does not expose move/control hooks for this window right now."
                lastActionMessage = nil
            }
            return nil
        }

        guard !isBackdropSurfaceWindow(
            resolvedWindow,
            normalizedTitle: resolvedWindow.title.trimmingCharacters(in: .whitespacesAndNewlines),
            normalizedRole: resolvedWindow.role.trimmingCharacters(in: .whitespacesAndNewlines),
            normalizedSubrole: resolvedWindow.subrole.trimmingCharacters(in: .whitespacesAndNewlines),
            in: snapshot
        ) else {
            if reportErrors {
                lastErrorMessage = "That surface cannot be assigned to a Work Set."
                lastActionMessage = nil
            }
            return nil
        }

        return resolvedWindow
    }

    func visibleWorkSetContexts(in snapshot: LiveStateSnapshot?) -> [WorkSetDesktopContext] {
        guard let snapshot,
              snapshot.source == .yabai,
              !snapshot.degraded else {
            return []
        }

        rebuildWorkSetRuntimeCaches(using: snapshot)
        return cachedWorkSetVisibleContexts
    }

    func eligibleWindowsForWorkSets(in snapshot: LiveStateSnapshot, spaceIndex: Int) -> [WindowState] {
        eligibleWindowsForWorkSets(in: snapshot)
            .filter { $0.space == spaceIndex }
    }

    func eligibleWindowsForWorkSets(in snapshot: LiveStateSnapshot?) -> [WindowState] {
        guard let snapshot else { return [] }
        return eligibleWindowsForWorkSets(in: snapshot)
    }

    func eligibleWindowsForWorkSets(in snapshot: LiveStateSnapshot) -> [WindowState] {
        snapshot.windows.filter {
            $0.isVisible &&
                !$0.isMinimized &&
                !$0.isHidden &&
                $0.isRuntimeManageable &&
                !isBackdropSurfaceWindow(
                    $0,
                    normalizedTitle: $0.title.trimmingCharacters(in: .whitespacesAndNewlines),
                    normalizedRole: $0.role.trimmingCharacters(in: .whitespacesAndNewlines),
                    normalizedSubrole: $0.subrole.trimmingCharacters(in: .whitespacesAndNewlines),
                    in: snapshot
                )
        }
        .sorted(by: workSetWindowSort)
    }

    private func currentWorkSetScopeKey(in snapshot: LiveStateSnapshot) -> WorkSetScopeKey? {
        guard let spaceIndex = activeSpaceIndex(in: snapshot),
              let space = snapshot.spaces.first(where: { $0.index == spaceIndex }) else {
            return nil
        }
        return WorkSetScopeKey(displayID: space.displayId, spaceIndex: spaceIndex)
    }

    private func sortWorkSetVisibleContexts(
        _ contexts: [WorkSetDesktopContext],
        currentScopeKey: WorkSetScopeKey?
    ) -> [WorkSetDesktopContext] {
        contexts.sorted { lhs, rhs in
            let lhsCurrent = lhs.scopeKey == currentScopeKey
            let rhsCurrent = rhs.scopeKey == currentScopeKey
            if lhsCurrent != rhsCurrent { return lhsCurrent }
            if lhs.display.focused != rhs.display.focused { return lhs.display.focused && !rhs.display.focused }
            if lhs.scopeKey.spaceIndex != rhs.scopeKey.spaceIndex { return lhs.scopeKey.spaceIndex < rhs.scopeKey.spaceIndex }
            return lhs.display.name.localizedCaseInsensitiveCompare(rhs.display.name) == .orderedAscending
        }
    }

    @discardableResult
    func reconcileWorkSetScopesIfNeeded(using snapshot: LiveStateSnapshot?, contentSignature: String? = nil) -> Bool {
        guard let snapshot,
              snapshot.source == .yabai,
              !snapshot.degraded,
              !workSets.isEmpty else {
            lastWorkSetScopeReconciliationSignature = nil
            return false
        }

        let resolvedContentSignature = contentSignature ?? liveStateContentSignature(for: snapshot)
        let reconciliationSignature = workSetScopeReconciliationSignature(contentSignature: resolvedContentSignature)
        guard reconciliationSignature != lastWorkSetScopeReconciliationSignature else { return false }
        lastWorkSetScopeReconciliationSignature = reconciliationSignature

        var updatedWorkSets = workSets
        var didChange = false

        for index in updatedWorkSets.indices {
            let workSet = updatedWorkSets[index]
            let resolvedScopeKey = resolvedScopeKey(for: workSet, in: snapshot)
            if resolvedScopeKey != workSet.scopeKey {
                moveWorkSetScopedRuntimeState(from: workSet.scopeKey, to: resolvedScopeKey)
            }

            let resolvedDisplay = snapshot.displays.first(where: { $0.id == resolvedScopeKey.displayID })
            let resolvedShapeKey = resolvedDisplay.flatMap { DisplayShapeKey.from(width: $0.frameW, height: $0.frameH) }
            let shouldAdoptResolvedDisplayMetadata = resolvedScopeKey != workSet.scopeKey
                || resolvedDisplay.map { displayMatchesSavedFingerprint($0, workSet: workSet) } == true
            let updatedWorkSet = workSet.with(
                sourceDisplayName: shouldAdoptResolvedDisplayMetadata ? (resolvedDisplay?.name ?? workSet.sourceDisplayName) : workSet.sourceDisplayName,
                sourceDisplayWidth: .some(shouldAdoptResolvedDisplayMetadata ? (resolvedDisplay?.frameW ?? workSet.sourceDisplayWidth) : workSet.sourceDisplayWidth),
                sourceDisplayHeight: .some(shouldAdoptResolvedDisplayMetadata ? (resolvedDisplay?.frameH ?? workSet.sourceDisplayHeight) : workSet.sourceDisplayHeight),
                sourceDisplayShapeKey: .some(shouldAdoptResolvedDisplayMetadata ? (resolvedShapeKey ?? workSet.sourceDisplayShapeKey) : workSet.sourceDisplayShapeKey),
                scopeKey: resolvedScopeKey
            )
            guard updatedWorkSet != workSet else { continue }
            updatedWorkSets[index] = updatedWorkSet
            didChange = true
        }

        guard didChange else { return false }
        workSets = updatedWorkSets
        persistWorkSets()
        lastWorkSetScopeReconciliationSignature = workSetScopeReconciliationSignature(contentSignature: resolvedContentSignature)
        return true
    }

    private func workSetScopeReconciliationSignature(contentSignature: String) -> String {
        let workSetSignature = workSets
            .map { workSet in
                let members = workSet.members.map {
                    [
                        $0.appName,
                        $0.windowTitle,
                        $0.role,
                        $0.subrole,
                        $0.lastSeenWindowID.map { String($0) } ?? "",
                        $0.lastSeenPID.map { String($0) } ?? "",
                        $0.bundleIdentifier ?? "",
                    ].joined(separator: "|")
                }.joined(separator: ",")
                return [
                    workSet.id.uuidString,
                    workSet.scopeKey.id,
                    workSet.sourceDisplayName,
                    workSet.sourceDisplayWidth.map { String($0) } ?? "",
                    workSet.sourceDisplayHeight.map { String($0) } ?? "",
                    workSet.sourceDisplayShapeKey?.description ?? "",
                    members,
                ].joined(separator: "||")
            }
            .joined(separator: "###")
        return [contentSignature, workSetSignature].joined(separator: "%%%%")
    }

    private func resolvedScopeKey(for workSet: WorkSet, in snapshot: LiveStateSnapshot) -> WorkSetScopeKey {
        if let inferredScope = inferredResolvedScopeKey(for: workSet, in: snapshot) {
            return inferredScope
        }

        let eligibleDisplays = snapshot.displays.filter { display in
            snapshot.spaces.contains(where: { $0.index == workSet.scopeKey.spaceIndex && $0.displayId == display.id })
        }

        if eligibleDisplays.isEmpty {
            return workSet.scopeKey
        }

        if let currentDisplay = eligibleDisplays.first(where: { $0.id == workSet.scopeKey.displayID }),
           displayMatchesSavedFingerprint(currentDisplay, workSet: workSet) {
            return workSet.scopeKey
        }

        let exactResolutionMatches = eligibleDisplays.filter { display in
            guard let savedWidth = workSet.sourceDisplayWidth,
                  let savedHeight = workSet.sourceDisplayHeight else {
                return false
            }
            return abs(display.frameW - savedWidth) <= 1 && abs(display.frameH - savedHeight) <= 1
        }
        if exactResolutionMatches.count == 1, let match = exactResolutionMatches.first {
            return WorkSetScopeKey(displayID: match.id, spaceIndex: workSet.scopeKey.spaceIndex)
        }

        let shapeMatches = eligibleDisplays.filter { display in
            guard let shapeKey = workSet.sourceDisplayShapeKey else { return false }
            return shapeKey.matches(width: display.frameW, height: display.frameH)
        }
        if shapeMatches.count == 1, let match = shapeMatches.first {
            return WorkSetScopeKey(displayID: match.id, spaceIndex: workSet.scopeKey.spaceIndex)
        }

        let normalizedSourceName = normalizedWorkSetDisplayName(workSet.sourceDisplayName)
        if !normalizedSourceName.isEmpty {
            let nameMatches = eligibleDisplays.filter { display in
                normalizedWorkSetDisplayName(display.name) == normalizedSourceName
            }
            if nameMatches.count == 1, let match = nameMatches.first {
                return WorkSetScopeKey(displayID: match.id, spaceIndex: workSet.scopeKey.spaceIndex)
            }
        }

        return workSet.scopeKey
    }

    private func inferredResolvedScopeKey(for workSet: WorkSet, in snapshot: LiveStateSnapshot) -> WorkSetScopeKey? {
        let matchedWindows = resolveWorkSetMembers(workSet.members, in: scopeInferenceCandidateWindowsForWorkSets(in: snapshot))
            .compactMap(\.matchedWindow)
        guard !matchedWindows.isEmpty else { return nil }

        let countsByScope = matchedWindows.reduce(into: [WorkSetScopeKey: Int]()) { partialResult, window in
            partialResult[WorkSetScopeKey(displayID: window.display, spaceIndex: window.space), default: 0] += 1
        }
        guard let best = countsByScope.max(by: { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value < rhs.value }
            return lhs.key.id > rhs.key.id
        }) else {
            return nil
        }

        let tiedBestCount = countsByScope.values.filter { $0 == best.value }.count
        guard tiedBestCount == 1 else { return nil }

        let currentCount = countsByScope[workSet.scopeKey] ?? 0
        let totalMatched = matchedWindows.count
        let hasStrongMajority = Double(best.value) / Double(totalMatched) >= 0.6
        guard best.key != workSet.scopeKey,
              hasStrongMajority,
              best.value > currentCount else {
            return nil
        }
        return best.key
    }

    private func scopeInferenceCandidateWindowsForWorkSets(in snapshot: LiveStateSnapshot) -> [WindowState] {
        snapshot.windows.filter {
            !$0.isMinimized &&
                !$0.isHidden &&
                $0.isRuntimeManageable &&
                !isBackdropSurfaceWindow(
                    $0,
                    normalizedTitle: $0.title.trimmingCharacters(in: .whitespacesAndNewlines),
                    normalizedRole: $0.role.trimmingCharacters(in: .whitespacesAndNewlines),
                    normalizedSubrole: $0.subrole.trimmingCharacters(in: .whitespacesAndNewlines),
                    in: snapshot
                )
        }
        .sorted(by: workSetWindowSort)
    }

    private func normalizedWorkSetDisplayName(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    }

    private func displayMatchesSavedFingerprint(_ display: DisplayState, workSet: WorkSet) -> Bool {
        if let savedWidth = workSet.sourceDisplayWidth,
           let savedHeight = workSet.sourceDisplayHeight,
           abs(display.frameW - savedWidth) <= 1,
           abs(display.frameH - savedHeight) <= 1 {
            return true
        }

        if let shapeKey = workSet.sourceDisplayShapeKey,
           shapeKey.matches(width: display.frameW, height: display.frameH) {
            return true
        }

        let normalizedSourceName = normalizedWorkSetDisplayName(workSet.sourceDisplayName)
        return !normalizedSourceName.isEmpty && normalizedWorkSetDisplayName(display.name) == normalizedSourceName
    }

    private func moveWorkSetScopedRuntimeState(from oldScopeKey: WorkSetScopeKey, to newScopeKey: WorkSetScopeKey) {
        guard oldScopeKey != newScopeKey else { return }

        if let activeWorkSetID = activeWorkSetIDsByScope.removeValue(forKey: oldScopeKey.id) {
            activeWorkSetIDsByScope[newScopeKey.id] = activeWorkSetID
        }
        if let dismissedBackdropID = dismissedWorkSetBackdropIDsByScope.removeValue(forKey: oldScopeKey) {
            dismissedWorkSetBackdropIDsByScope[newScopeKey] = dismissedBackdropID
        }
        if let backdropPresentation = workSetBackdropPresentations.removeValue(forKey: oldScopeKey) {
            workSetBackdropPresentations[newScopeKey] = WorkSetBackdropPresentation(
                workSetID: backdropPresentation.workSetID,
                scopeKey: newScopeKey,
                display: backdropPresentation.display,
                color: backdropPresentation.color,
                anchorWindow: backdropPresentation.anchorWindow
            )
        }
        if let savedLayout = savedDesktopLayoutBeforeTiledWorkSetByScope.removeValue(forKey: oldScopeKey) {
            savedDesktopLayoutBeforeTiledWorkSetByScope[newScopeKey] = savedLayout
        }
        if let savedFrames = savedWindowFramesBeforeTiledWorkSetByScope.removeValue(forKey: oldScopeKey) {
            savedWindowFramesBeforeTiledWorkSetByScope[newScopeKey] = savedFrames
        }
        if let signature = lastWorkSetOwnedLayoutSyncSignatureByScope.removeValue(forKey: oldScopeKey.id) {
            lastWorkSetOwnedLayoutSyncSignatureByScope[newScopeKey.id] = signature
        }
    }

    func orderedWorkSetCandidateWindows(from windows: [WindowState]) -> [WindowState] {
        windows.sorted(by: workSetWindowSort)
    }

    private func workSetStatusCandidateWindows(in snapshot: LiveStateSnapshot?) -> [WindowState] {
        guard let snapshot else { return [] }
        return snapshot.windows.filter {
            !$0.isHidden &&
                $0.isRuntimeManageable &&
                !isBackdropSurfaceWindow(
                    $0,
                    normalizedTitle: $0.title.trimmingCharacters(in: .whitespacesAndNewlines),
                    normalizedRole: $0.role.trimmingCharacters(in: .whitespacesAndNewlines),
                    normalizedSubrole: $0.subrole.trimmingCharacters(in: .whitespacesAndNewlines),
                    in: snapshot
                )
        }
        .sorted(by: workSetWindowSort)
    }

    func workSetWindowSort(_ lhs: WindowState, _ rhs: WindowState) -> Bool {
        switch (lhs.windowServerOrderIndex, rhs.windowServerOrderIndex) {
        case let (lhsOrder?, rhsOrder?):
            if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        case (.none, .none):
            break
        }

        if lhs.focused != rhs.focused { return lhs.focused && !rhs.focused }
        if abs(lhs.frameY - rhs.frameY) > 8 { return lhs.frameY < rhs.frameY }
        if abs(lhs.frameX - rhs.frameX) > 8 { return lhs.frameX < rhs.frameX }
        return lhs.id < rhs.id
    }

    @discardableResult
    private func createWorkSet(
        name: String,
        sourceDisplay: DisplayState,
        scopeKey: WorkSetScopeKey,
        members: [WorkSetMember],
        announce: Bool,
        actionMessage: String
    ) -> UUID {
        let workSet = WorkSet(
            name: name,
            sourceDisplayName: sourceDisplay.name,
            sourceDisplayWidth: sourceDisplay.frameW,
            sourceDisplayHeight: sourceDisplay.frameH,
            sourceDisplayShapeKey: DisplayShapeKey.from(width: sourceDisplay.frameW, height: sourceDisplay.frameH),
            scopeKey: scopeKey,
            members: members
        )
        workSets.append(workSet)
        persistWorkSets()
        if announce {
            lastActionMessage = "\(actionMessage) \(workSet.name)."
            lastErrorMessage = nil
        }
        return workSet.id
    }

    private func nextAvailableWorkSetName(base: String) -> String {
        let existing = Set(workSets.map { $0.name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current) })
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nextAvailableWorkSetName(base: "Work Set")
        }
        if !existing.contains(trimmed.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)) {
            return trimmed
        }
        for suffix in 2...999 {
            let candidate = "\(trimmed) \(suffix)"
            let normalized = candidate.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            if !existing.contains(normalized) {
                return candidate
            }
        }
        return trimmed + " Copy"
    }

    private func workSetMembersRepresentSameWindow(_ lhs: WorkSetMember, _ rhs: WorkSetMember) -> Bool {
        if let lhsWindowID = lhs.lastSeenWindowID,
           let lhsPID = lhs.lastSeenPID,
           let rhsWindowID = rhs.lastSeenWindowID,
           let rhsPID = rhs.lastSeenPID,
           lhsWindowID == rhsWindowID,
           lhsPID == rhsPID {
            return true
        }

        return normalizedAppRuleKey(lhs.appName) == normalizedAppRuleKey(rhs.appName)
            && lhs.windowTitle.localizedCaseInsensitiveCompare(rhs.windowTitle) == .orderedSame
            && lhs.role.localizedCaseInsensitiveCompare(rhs.role) == .orderedSame
            && lhs.subrole.localizedCaseInsensitiveCompare(rhs.subrole) == .orderedSame
    }

    private func duplicatedMembershipCopy(of member: WorkSetMember) -> WorkSetMember {
        WorkSetMember(
            appName: member.appName,
            windowTitle: member.windowTitle,
            role: member.role,
            subrole: member.subrole,
            lastSeenWindowID: member.lastSeenWindowID,
            lastSeenPID: member.lastSeenPID,
            bundleIdentifier: member.bundleIdentifier,
            bundleURLPath: member.bundleURLPath
        )
    }

    func clearDismissedWorkSetBackdrop(for scopeKey: WorkSetScopeKey) {
        dismissedWorkSetBackdropIDsByScope.removeValue(forKey: scopeKey)
    }

    func dismissActiveWorkSetBackdrop(for scopeKey: WorkSetScopeKey) {
        if let presentation = workSetBackdropPresentations[scopeKey] {
            dismissedWorkSetBackdropIDsByScope[scopeKey] = presentation.workSetID
        }
        hideWorkSetBackdrop(for: scopeKey)
    }

    func dismissActiveBackdrop(for scopeKey: WorkSetScopeKey) {
        if recentWindowTilerBackdropPresentations.removeValue(forKey: scopeKey) != nil {
            return
        }
        dismissActiveWorkSetBackdrop(for: scopeKey)
    }

    func hideWorkSetBackdrop(for scopeKey: WorkSetScopeKey) {
        guard workSetBackdropPresentations[scopeKey] != nil else { return }
        workSetBackdropPresentations.removeValue(forKey: scopeKey)
    }

    func showWorkSetBackdrop(for workSet: WorkSet, display: DisplayState, anchorWindow: WindowState?) {
        guard workSet.backdropEnabled else {
            hideWorkSetBackdrop(for: workSet.scopeKey)
            return
        }
        guard dismissedWorkSetBackdropIDsByScope[workSet.scopeKey] != workSet.id else {
            hideWorkSetBackdrop(for: workSet.scopeKey)
            return
        }
        workSetBackdropPresentations[workSet.scopeKey] = WorkSetBackdropPresentation(
            workSetID: workSet.id,
            scopeKey: workSet.scopeKey,
            display: display,
            color: workSet.backdropColor,
            anchorWindow: anchorWindow
        )
    }

    func showRecentWindowTilerBackdrop(
        scopeKey: WorkSetScopeKey,
        display: DisplayState,
        color: OverlayAccentColor,
        excluding activeWindowIDs: Set<Int>
    ) {
        recentWindowTilerBackdropPresentations[scopeKey] = WorkSetBackdropPresentation(
            workSetID: UUID(),
            scopeKey: scopeKey,
            display: display,
            color: color,
            anchorWindow: workSetBackdropAnchorWindow(
                scopeKey: scopeKey,
                excluding: activeWindowIDs
            )
        )
    }

    func hideRecentWindowTilerBackdrop(for scopeKey: WorkSetScopeKey) {
        recentWindowTilerBackdropPresentations.removeValue(forKey: scopeKey)
    }

    private func syncBackdropRuntimeStateForActiveWorkSet(_ workSet: WorkSet) {
        guard activeWorkSetID(for: workSet.scopeKey) == workSet.id else { return }
        guard let context = workSetContext(for: workSet.scopeKey) else {
            return
        }

        if !workSet.backdropEnabled {
            hideWorkSetBackdrop(for: workSet.scopeKey)
            return
        }

        let activeWindowIDs = Set(resolveWorkSetMembers(workSet.members, in: context.windows).compactMap { $0.matchedWindow?.id })
        let anchorWindow = workSetBackdropAnchorWindow(
            scopeKey: workSet.scopeKey,
            excluding: activeWindowIDs
        )
        showWorkSetBackdrop(for: workSet, display: context.display, anchorWindow: anchorWindow)
    }

    func workSetBackdropAnchorWindow(scopeKey: WorkSetScopeKey, excluding activeWindowIDs: Set<Int>) -> WindowState? {
        let snapshot = latestLiveStateSnapshot ?? liveStateSnapshot
        guard let snapshot,
              snapshot.source == .yabai,
              !snapshot.degraded else {
            return nil
        }

        return snapshot.windows
            .filter {
                $0.space == scopeKey.spaceIndex &&
                $0.display == scopeKey.displayID &&
                $0.isVisible &&
                !$0.isMinimized &&
                !$0.isHidden &&
                !activeWindowIDs.contains($0.id) &&
                !isBackdropSurfaceWindow(
                    $0,
                    normalizedTitle: $0.title.trimmingCharacters(in: .whitespacesAndNewlines),
                    normalizedRole: $0.role.trimmingCharacters(in: .whitespacesAndNewlines),
                    normalizedSubrole: $0.subrole.trimmingCharacters(in: .whitespacesAndNewlines),
                    in: snapshot
                )
            }
            .sorted(by: workSetWindowSort)
            .first
    }
}
