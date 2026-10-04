import SwiftUI
import UniformTypeIdentifiers

struct WorkSetsDashboardView: View {
    @EnvironmentObject private var model: AppModel
    @State private var renamingWorkSetID: UUID?
    @State private var renameDraft = ""
    @State private var selectedScopeID: String?
    @FocusState private var focusedRenameWorkSetID: UUID?

    private var visibleContexts: [WorkSetDesktopContext] {
        model.visibleWorkSetContexts
    }

    private var matchingVisibleContexts: [WorkSetDesktopContext] {
        visibleContexts.filter { liveDisplayMatchesSavedScope(for: $0.scopeKey, liveDisplayName: $0.display.name) }
    }

    private var currentDesktopContext: WorkSetDesktopContext? {
        model.currentDesktopWorkSetContext
    }

    private var savedScopeKeys: [WorkSetScopeKey] {
        var ordered: [WorkSetScopeKey] = []
        for workSet in model.workSets where !ordered.contains(workSet.scopeKey) {
            ordered.append(workSet.scopeKey)
        }
        return ordered
    }

    private var scopeMenuKeys: [WorkSetScopeKey] {
        var ordered = visibleContexts.map(\.scopeKey)
        for scopeKey in savedScopeKeys where !ordered.contains(scopeKey) {
            ordered.append(scopeKey)
        }
        return ordered
    }

    private var selectedScopeKey: WorkSetScopeKey? {
        if let selectedScopeID {
            if let exactVisible = visibleContexts.first(where: { $0.scopeKey.id == selectedScopeID })?.scopeKey {
                return exactVisible
            }
            if let exactSaved = savedScopeKeys.first(where: { $0.id == selectedScopeID }) {
                return exactSaved
            }
        }
        if let current = currentDesktopContext,
           liveDisplayMatchesSavedScope(for: current.scopeKey, liveDisplayName: current.display.name),
           !model.workSets(for: current.scopeKey).isEmpty {
            return current.scopeKey
        }
        if let visibleWithWorkSets = matchingVisibleContexts.first(where: { !model.workSets(for: $0.scopeKey).isEmpty }) {
            return visibleWithWorkSets.scopeKey
        }
        if let saved = savedScopeKeys.first {
            return saved
        }
        if let current = currentDesktopContext {
            return current.scopeKey
        }
        return visibleContexts.first?.scopeKey
    }

    private var selectedContext: WorkSetDesktopContext? {
        guard let selectedScopeKey else { return nil }
        guard let context = model.workSetContext(for: selectedScopeKey) else { return nil }
        guard liveDisplayMatchesSavedScope(for: selectedScopeKey, liveDisplayName: context.display.name) else {
            return nil
        }
        return context
    }

    private var selectedVisibleContext: WorkSetDesktopContext? {
        guard let selectedScopeKey else { return nil }
        guard let context = matchingVisibleContexts.first(where: { $0.scopeKey == selectedScopeKey }) else { return nil }
        guard liveDisplayMatchesSavedScope(for: selectedScopeKey, liveDisplayName: context.display.name) else {
            return nil
        }
        return context
    }

    private var selectedWorkSets: [WorkSet] {
        guard let scopeKey = selectedScopeKey else { return [] }
        return model.workSets(for: scopeKey)
    }

    private var selectedPaletteWindows: [WindowState] {
        guard let scopeKey = selectedVisibleContext?.scopeKey else { return [] }
        return model.paletteWindows(for: scopeKey)
    }

    private var scopeSignature: String {
        (scopeMenuKeys.map(\.id) + model.workSets.map(\.id.uuidString)).joined(separator: "|")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    scopeToolbar
                    workSetsBoard
                    paletteCard
                }
                .padding(12)
            }
            .navigationTitle("TilePilot")
            .task {
                model.rebuildShortcutPresentationCaches()
                await model.refreshLiveState()
                syncSelectedScopeIfNeeded()
            }
            .onAppear {
                model.rebuildShortcutPresentationCaches()
                syncSelectedScopeIfNeeded()
            }
            .onChange(of: focusedRenameWorkSetID) { focusedID in
                if focusedID == nil {
                    commitWorkSetRenameIfNeeded()
                }
            }
            .onChange(of: scopeSignature) { _ in
                syncSelectedScopeIfNeeded()
            }
        }
    }

    private var scopeToolbar: some View {
        HStack(spacing: 10) {
            if let selectedScopeKey {
                Menu {
                    ForEach(scopeMenuKeys, id: \.id) { scopeKey in
                        Button {
                            selectedScopeID = scopeKey.id
                        } label: {
                            Text(scopeMenuTitle(for: scopeKey))
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        metaChip(scopeDisplayName(for: selectedScopeKey), systemImage: "display")
                        metaChip("Desktop \(selectedScopeKey.spaceIndex)", systemImage: "rectangle.3.group")
                        if let windowCount = scopeWindowCount(for: selectedScopeKey) {
                            metaChip("\(windowCount) window\(windowCount == 1 ? "" : "s")", systemImage: "macwindow")
                        } else {
                            let workSetCount = model.workSets(for: selectedScopeKey).count
                            metaChip("\(workSetCount) Work Set\(workSetCount == 1 ? "" : "s")", systemImage: "square.stack.3d.up")
                        }
                        if currentDesktopContext?.scopeKey == selectedScopeKey {
                            statusChip("Current", systemImage: "scope", tint: .green)
                        }
                        if !isScopeVisible(selectedScopeKey) {
                            statusChip("Saved", systemImage: "archivebox.fill", tint: .secondary)
                        }
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .buttonStyle(.plain)
            } else {
                metaChip("No visible desktop", systemImage: "display.trianglebadge.exclamationmark")
            }

            Button("Import Visible Windows") {
                guard let scopeKey = selectedVisibleContext?.scopeKey else { return }
                Task { @MainActor in
                    _ = model.importWorkSet(for: scopeKey)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(selectedVisibleContext == nil)

            Button("Create Empty Set") {
                guard let scopeKey = selectedVisibleContext?.scopeKey else { return }
                _ = model.createEmptyWorkSet(for: scopeKey)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(selectedVisibleContext == nil)

            Spacer(minLength: 0)

            WorkSetInfoBubbleButton(text: "Use the scope picker to switch between visible desktops and saved Work Set scopes. Work Sets are shown left to right, front to back. Import builds one pile from the selected visible desktop.")
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.secondary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.secondary.opacity(0.10), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var workSetsBoard: some View {
        if selectedScopeKey == nil {
            EmptyStateView(
                title: model.workSets.isEmpty ? "No Work Sets yet" : "Desktop data unavailable",
                systemImage: "square.stack.3d.up.slash",
                message: model.workSets.isEmpty
                    ? "Import visible windows to create the first Work Set."
                    : "TilePilot needs a live desktop snapshot to attach saved Work Sets to a desktop."
            )
        } else {
            VStack(alignment: .leading, spacing: 10) {
                if selectedVisibleContext == nil && !selectedWorkSets.isEmpty {
                    Text("This desktop is not visible right now. Saved Work Sets stay visible here, but import, live preview, and the window palette are unavailable until the desktop is visible.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if selectedWorkSets.isEmpty {
                    Text(selectedVisibleContext == nil
                        ? "No saved Work Sets exist for this desktop yet."
                        : "Import visible windows to create the first Work Set, or drag a current desktop window into New Work Set.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(selectedWorkSets) { workSet in
                            workSetLane(for: workSet)
                        }

                        if selectedVisibleContext != nil {
                            newWorkSetLane
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.secondary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.secondary.opacity(0.10), lineWidth: 1)
            )
        }
    }

    private func workSetLane(for workSet: WorkSet) -> some View {
        let resolvedMembers = model.workSetResolvedMembers(for: workSet, in: selectedContext)
        let disabledReason = model.workSetActivationDisabledReason(workSet)

        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        if renamingWorkSetID == workSet.id {
                            TextField("Work Set Name", text: $renameDraft)
                                .textFieldStyle(.roundedBorder)
                                .focused($focusedRenameWorkSetID, equals: workSet.id)
                                .onSubmit {
                                    commitWorkSetRenameIfNeeded()
                                }
                        } else {
                            Text(workSet.name)
                                .font(.headline)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 0)

                    Menu {
                        Button("Rename") {
                            startRenaming(workSetID: workSet.id)
                        }
                        Button("Duplicate") {
                            _ = model.duplicateWorkSet(workSet.id)
                        }
                        Button("Delete", role: .destructive) {
                            if renamingWorkSetID == workSet.id {
                                renamingWorkSetID = nil
                                renameDraft = ""
                            }
                            model.deleteWorkSet(workSet.id)
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                }

                HStack(spacing: 6) {
                    metaChip("\(workSet.sourceDisplayName) · Desktop \(workSet.scopeKey.spaceIndex)", systemImage: "display")

                    if model.isActiveWorkSet(workSet) {
                        statusChip("Active", systemImage: "checkmark.circle.fill", tint: .green)
                    }
                    if let disabledReason {
                        statusChip(shortWorkSetStatusLabel(for: disabledReason), systemImage: "exclamationmark.triangle.fill", tint: .orange)
                    }
                }

                HStack(spacing: 8) {
                    Button("Activate") {
                        model.activateWorkSet(workSetID: workSet.id)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(disabledReason != nil)
                    .help("Activate Work Set")

                    Picker("Restore as", selection: workSetLayoutModeBinding(for: workSet)) {
                        ForEach(WorkSetLayoutMode.allCases, id: \.self) { layoutMode in
                            Text(layoutMode.title).tag(layoutMode)
                        }
                    }
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .labelsHidden()
                    .frame(width: 104, alignment: .leading)
                    .help("How this Work Set restores windows")

                    Spacer(minLength: 0)
                }

                HStack(spacing: 10) {
                    Toggle("Launch Missing Apps", isOn: workSetLaunchMissingAppsBinding(for: workSet))
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                        .fixedSize(horizontal: true, vertical: false)
                        .help("Open apps that are not running when this Work Set is activated.")

                    Spacer(minLength: 0)

                    Toggle("Backdrop", isOn: workSetBackdropEnabledBinding(for: workSet))
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                        .fixedSize(horizontal: true, vertical: false)

                    ColorPicker(
                        "",
                        selection: workSetBackdropColorBinding(for: workSet),
                        supportsOpacity: false
                    )
                    .labelsHidden()
                    .padding(.leading, 4)
                    .frame(width: 40)
                    .help("Backdrop color")
                }

                if workSet.layoutMode == .template {
                    HStack(spacing: 8) {
                        Picker("Template", selection: workSetLinkedTemplateBinding(for: workSet)) {
                            Text("Choose Template").tag(UUID?.none)
                            ForEach(model.windowLayoutTemplates) { template in
                                Text(template.name).tag(UUID?.some(template.id))
                            }
                        }
                        .pickerStyle(.menu)
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if let templateWarning = model.workSetTemplateWarning(workSet) {
                        Text(templateWarning)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
            }

            if let display = selectedContext?.display {
                WorkSetLayoutPreview(
                    resolvedMembers: resolvedMembers,
                    display: display
                )
            }

            if resolvedMembers.isEmpty {
                WorkSetLaneDropTarget(text: "Drop windows here") { payload in
                    handleLaneDrop(payload, into: workSet, before: nil)
                }
                .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                VStack(spacing: 8) {
                    ForEach(Array(resolvedMembers.enumerated()), id: \.element.id) { offset, resolved in
                        WorkSetMemberRow(
                            workSetID: workSet.id,
                            member: resolved.member,
                            matchedWindow: resolved.matchedWindow,
                            status: resolved.status,
                            onFocus: {
                                guard let matchedWindow = resolved.matchedWindow else { return }
                                model.focusWindow(windowID: matchedWindow.id)
                            },
                            onRemove: {
                                model.removeWorkSetMember(workSetID: workSet.id, memberID: resolved.member.id)
                            },
                            duplicateTargets: selectedWorkSets.filter { $0.id != workSet.id },
                            onDuplicateToWorkSet: { destinationWorkSetID in
                                _ = model.copyWorkSetMember(
                                    from: workSet.id,
                                    memberID: resolved.member.id,
                                    to: destinationWorkSetID
                                )
                            },
                            onDuplicateToNewWorkSet: {
                                guard let scopeKey = selectedVisibleContext?.scopeKey else { return }
                                _ = model.createEmptyWorkSet(for: scopeKey, announce: false).flatMap { newWorkSetID in
                                    _ = model.copyWorkSetMember(
                                        from: workSet.id,
                                        memberID: resolved.member.id,
                                        to: newWorkSetID
                                    )
                                    if let newWorkSet = model.workSet(withID: newWorkSetID) {
                                        model.lastActionMessage = "Created \(newWorkSet.name) with \(resolved.member.appName)."
                                        model.lastErrorMessage = nil
                                    }
                                    return newWorkSetID
                                }
                            },
                            onDropPayload: { payload in
                                handleLaneDrop(payload, into: workSet, before: resolved.member.id)
                            }
                        )
                    }

                    WorkSetLaneDropTarget(text: "Drop here to add to end") { payload in
                        handleLaneDrop(payload, into: workSet, before: nil)
                    }
                    .frame(maxWidth: .infinity, minHeight: 74)
                }
            }
        }
        .padding(10)
        .frame(width: 360, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.secondary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
        )
    }

    private var newWorkSetLane: some View {
        WorkSetNewLane(
            onCreate: {
                guard let scopeKey = selectedVisibleContext?.scopeKey else { return }
                _ = model.createEmptyWorkSet(for: scopeKey)
            },
            onDropPayload: { payload in
                guard let scopeKey = selectedVisibleContext?.scopeKey,
                      let newWorkSetID = model.createEmptyWorkSet(for: scopeKey, announce: false) else {
                    return
                }
                switch payload {
                case .member(let sourceWorkSetID, let memberID):
                    model.moveWorkSetMember(
                        from: sourceWorkSetID,
                        memberID: memberID,
                        to: newWorkSetID,
                        before: nil
                    )
                case .window(let member):
                    model.addMemberToWorkSet(workSetID: newWorkSetID, member: member, at: nil)
                }
                if let workSet = model.workSet(withID: newWorkSetID) {
                    model.lastActionMessage = "Created \(workSet.name)."
                    model.lastErrorMessage = nil
                }
            }
        )
        .frame(width: 250)
    }

    private var paletteCard: some View {
        let windows = selectedPaletteWindows

        return GroupBox {
            if selectedVisibleContext == nil {
                EmptyStateView(
                    title: "Desktop not visible",
                    systemImage: "display.slash",
                    message: "Current desktop windows only appear here when the selected Work Set desktop is visible."
                )
                .frame(minHeight: 120)
            } else if windows.isEmpty {
                EmptyStateView(
                    title: "No eligible windows",
                    systemImage: "macwindow.badge.plus",
                    message: "Current desktop windows appear here when TilePilot can manage them."
                )
                .frame(minHeight: 120)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 8)], spacing: 8) {
                    ForEach(windows) { window in
                        WorkSetPaletteWindowChip(
                            window: window,
                            onFocus: {
                                model.focusWindow(windowID: window.id)
                            }
                        )
                    }
                }
            }
        } label: {
            Label("Current Desktop Windows", systemImage: "macwindow")
        }
    }

    private func syncSelectedScopeIfNeeded() {
        if let selectedScopeID,
           scopeMenuKeys.contains(where: { $0.id == selectedScopeID }) {
            return
        }
        selectedScopeID = selectedScopeKey?.id
    }

    private func scopeDisplayName(for scopeKey: WorkSetScopeKey) -> String {
        let savedDisplayName = savedDisplayName(for: scopeKey)
        if let context = model.workSetContext(for: scopeKey),
           liveDisplayMatchesSavedScope(for: scopeKey, liveDisplayName: context.display.name) {
            return context.display.name
        }
        if let savedDisplayName {
            return savedDisplayName
        }
        return "Display \(scopeKey.displayID)"
    }

    private func scopeWindowCount(for scopeKey: WorkSetScopeKey) -> Int? {
        guard let context = model.workSetContext(for: scopeKey),
              liveDisplayMatchesSavedScope(for: scopeKey, liveDisplayName: context.display.name) else {
            return nil
        }
        return context.windows.count
    }

    private func isScopeVisible(_ scopeKey: WorkSetScopeKey) -> Bool {
        matchingVisibleContexts.contains(where: { $0.scopeKey == scopeKey })
    }

    private func savedDisplayName(for scopeKey: WorkSetScopeKey) -> String? {
        model.workSets(for: scopeKey).first?.sourceDisplayName
    }

    private func liveDisplayMatchesSavedScope(for scopeKey: WorkSetScopeKey, liveDisplayName: String) -> Bool {
        guard let workSet = model.workSets(for: scopeKey).first else { return true }
        if let context = model.workSetContext(for: scopeKey) {
            if let savedWidth = workSet.sourceDisplayWidth,
               let savedHeight = workSet.sourceDisplayHeight,
               abs(context.display.frameW - savedWidth) <= 1,
               abs(context.display.frameH - savedHeight) <= 1 {
                return true
            }
            if let shapeKey = workSet.sourceDisplayShapeKey,
               shapeKey.matches(width: context.display.frameW, height: context.display.frameH) {
                return true
            }
        }
        return normalizedDisplayName(workSet.sourceDisplayName) == normalizedDisplayName(liveDisplayName)
    }

    private func normalizedDisplayName(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    }

    private func scopeMenuTitle(for scopeKey: WorkSetScopeKey) -> String {
        let displayName = scopeDisplayName(for: scopeKey)
        let tail: String
        if let windowCount = scopeWindowCount(for: scopeKey) {
            tail = "\(windowCount) window\(windowCount == 1 ? "" : "s")"
        } else {
            tail = "\(model.workSets(for: scopeKey).count) Work Set\(model.workSets(for: scopeKey).count == 1 ? "" : "s")"
        }
        let savedSuffix = isScopeVisible(scopeKey) ? "" : " · saved"
        return "\(displayName) · Desktop \(scopeKey.spaceIndex) · \(tail)\(savedSuffix)"
    }

    private func handleLaneDrop(_ payload: WorkSetDropPayload, into workSet: WorkSet, before targetMemberID: UUID?) {
        switch payload {
        case .member(let sourceWorkSetID, let memberID):
            model.moveWorkSetMember(
                from: sourceWorkSetID,
                memberID: memberID,
                to: workSet.id,
                before: targetMemberID
            )
        case .window(let member):
            let insertionIndex = targetMemberID.flatMap { memberID in
                workSet.members.firstIndex(where: { $0.id == memberID })
            }
            model.addMemberToWorkSet(workSetID: workSet.id, member: member, at: insertionIndex)
        }
    }

    private func startRenaming(workSetID: UUID) {
        guard let workSet = model.workSet(withID: workSetID) else { return }
        renamingWorkSetID = workSetID
        renameDraft = workSet.name
        focusedRenameWorkSetID = workSetID
    }

    private func commitWorkSetRenameIfNeeded() {
        guard let renamingWorkSetID,
              let workSet = model.workSet(withID: renamingWorkSetID) else {
            self.renamingWorkSetID = nil
            renameDraft = ""
            return
        }

        let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != workSet.name {
            model.renameWorkSet(renamingWorkSetID, name: trimmed)
        }
        self.renamingWorkSetID = nil
        renameDraft = ""
    }

    private func shortWorkSetStatusLabel(for disabledReason: String) -> String {
        if disabledReason.localizedCaseInsensitiveContains("switch to desktop") {
            return "Other Desktop"
        }
        if disabledReason.localizedCaseInsensitiveContains("runtime") || disabledReason.localizedCaseInsensitiveContains("unavailable") {
            return "Unavailable"
        }
        return "Needs Attention"
    }

    private func workSetBackdropEnabledBinding(for workSet: WorkSet) -> Binding<Bool> {
        Binding(
            get: { workSet.backdropEnabled },
            set: { enabled in
                model.setWorkSetBackdropEnabled(enabled, workSetID: workSet.id)
            }
        )
    }

    private func workSetLaunchMissingAppsBinding(for workSet: WorkSet) -> Binding<Bool> {
        Binding(
            get: { workSet.launchMissingApps },
            set: { enabled in
                model.setWorkSetLaunchMissingApps(enabled, workSetID: workSet.id)
            }
        )
    }

    private func workSetBackdropColorBinding(for workSet: WorkSet) -> Binding<Color> {
        Binding(
            get: { workSet.backdropColor.swiftUIColor },
            set: { newColor in
                guard let converted = OverlayAccentColor.from(swiftUIColor: newColor) else { return }
                model.setWorkSetBackdropColor(converted, workSetID: workSet.id)
            }
        )
    }

    private func workSetLayoutModeBinding(for workSet: WorkSet) -> Binding<WorkSetLayoutMode> {
        Binding(
            get: { workSet.layoutMode },
            set: { layoutMode in
                model.setWorkSetLayoutMode(layoutMode, workSetID: workSet.id)
            }
        )
    }

    private func workSetLinkedTemplateBinding(for workSet: WorkSet) -> Binding<UUID?> {
        Binding(
            get: { workSet.linkedTemplateID },
            set: { templateID in
                model.setWorkSetLinkedTemplateID(templateID, workSetID: workSet.id)
            }
        )
    }

    private func metaChip(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.secondary.opacity(0.10), in: Capsule())
    }

    private func statusChip(_ text: String, systemImage: String, tint: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(tint.opacity(0.14), in: Capsule())
    }

    private func workSetLayoutModeSystemImage(_ layoutMode: WorkSetLayoutMode) -> String {
        switch layoutMode {
        case .stackOnly:
            return "square.stack.3d.up"
        case .tiled:
            return "rectangle.split.3x1"
        case .template:
            return "rectangle.3.offgrid"
        }
    }
}

private struct WorkSetMemberRow: View {
    let workSetID: UUID
    let member: WorkSetMember
    let matchedWindow: WindowState?
    let status: WorkSetMemberMatchStatus
    let onFocus: () -> Void
    let onRemove: () -> Void
    let duplicateTargets: [WorkSet]
    let onDuplicateToWorkSet: (UUID) -> Void
    let onDuplicateToNewWorkSet: () -> Void
    let onDropPayload: (WorkSetDropPayload) -> Void

    @State private var isDropTargeted = false

    var body: some View {
        HStack(spacing: 10) {
            if let icon = AppIconResolver.shared.icon(forAppNamed: member.appName, size: 24) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 24, height: 24)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            } else {
                Image(systemName: "app")
                    .frame(width: 24, height: 24)
                    .foregroundStyle(.secondary)
            }

            Button(action: onFocus) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(member.appName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(member.windowTitle.isEmpty ? "Untitled Window" : member.windowTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(matchedWindow == nil)

            Spacer(minLength: 0)

            if shouldShowStatusBadge {
                Text(status.label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.orange.opacity(0.14), in: Capsule())
            }

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove this window from the Work Set")

            Menu {
                if duplicateTargets.isEmpty {
                    Button("Also Add to New Work Set", action: onDuplicateToNewWorkSet)
                } else {
                    ForEach(duplicateTargets) { workSet in
                        Button("Also Add to \(workSet.name)") {
                            onDuplicateToWorkSet(workSet.id)
                        }
                    }
                    Divider()
                    Button("Also Add to New Work Set", action: onDuplicateToNewWorkSet)
                }
            } label: {
                Image(systemName: "plus.square.on.square")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .help("Keep this window in another Work Set too")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isDropTargeted ? Color.accentColor.opacity(0.14) : Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.10), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onDrag {
            WorkSetDragDrop.provider(forMemberID: member.id, sourceWorkSetID: workSetID)
        }
        .onDrop(of: WorkSetDragDrop.dropTypeIdentifiers, isTargeted: $isDropTargeted) { providers in
            WorkSetDragDrop.loadPayload(from: providers) { payload in
                onDropPayload(payload)
            }
        }
        .help(statusHelpText)
    }

    private var shouldShowStatusBadge: Bool {
        switch status {
        case .exact, .sameApp:
            return false
        case .minimized, .otherDesktop, .otherScreen, .missing:
            return true
        }
    }

    private var statusHelpText: String {
        switch status {
        case .exact, .sameApp:
            return member.windowTitle.isEmpty ? member.appName : "\(member.appName) - \(member.windowTitle)"
        case .minimized:
            return "This window is open but minimized. Activating the Work Set will restore it."
        case .otherDesktop:
            return "This window is open on another desktop. Activating the Work Set can pull it back."
        case .otherScreen:
            return "This window is open on another screen. Activating the Work Set can pull it back."
        case .missing:
            return "TilePilot cannot find this saved window right now."
        }
    }
}

private struct WorkSetLayoutPreview: View {
    let resolvedMembers: [WorkSetResolvedMember]
    let display: DisplayState

    private var previewItems: [WorkSetLayoutPreviewItem] {
        resolvedMembers.enumerated().compactMap { offset, resolved in
            guard resolved.status == .exact || resolved.status == .sameApp,
                  let matchedWindow = resolved.matchedWindow,
                  let normalized = OverviewPreviewBuilder.normalizedPreview(
                    for: matchedWindow,
                    in: display,
                    desktopIndex: display.id
                  ) else {
                return nil
            }

            return WorkSetLayoutPreviewItem(
                memberID: resolved.member.id,
                appName: resolved.member.appName,
                windowTitle: resolved.member.windowTitle,
                normalizedWindow: normalized,
                frontOrder: offset + 1,
                status: resolved.status
            )
        }
    }

    private var missingCount: Int {
        resolvedMembers.filter { $0.matchedWindow == nil }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Preview")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                if missingCount > 0 {
                    Text("\(missingCount) missing")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.orange.opacity(0.12), in: Capsule())
                }

                Spacer(minLength: 0)
            }

            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.secondary.opacity(0.05))

                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.secondary.opacity(0.12), lineWidth: 1)

                if previewItems.isEmpty {
                    Text("No live window positions yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    GeometryReader { proxy in
                        let canvasSize = proxy.size
                        ForEach(previewItems.sorted(by: { $0.frontOrder > $1.frontOrder })) { item in
                            WorkSetLayoutPreviewWindow(item: item, canvasSize: canvasSize)
                        }
                    }
                    .padding(6)
                }
            }
            .aspectRatio(max(display.frameW, 1) / max(display.frameH, 1), contentMode: .fit)
        }
    }
}

private struct WorkSetLayoutPreviewItem: Identifiable {
    let memberID: UUID
    let appName: String
    let windowTitle: String
    let normalizedWindow: OverviewWindowPreview
    let frontOrder: Int
    let status: WorkSetMemberMatchStatus

    var id: UUID { memberID }

    var tooltipTitle: String {
        let trimmedTitle = windowTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedTitle.isEmpty ? appName : "\(appName) - \(trimmedTitle)"
    }
}

private struct WorkSetLayoutPreviewWindow: View {
    let item: WorkSetLayoutPreviewItem
    let canvasSize: CGSize

    private var frame: CGRect {
        OverviewMiniMapGeometry.frame(for: item.normalizedWindow, in: canvasSize)
    }

    private var iconFrame: CGRect {
        OverviewMiniMapGeometry.iconFrame(
            for: item.normalizedWindow,
            iconSize: 18,
            inset: 4,
            in: canvasSize
        )
    }

    private var borderTint: Color {
        switch item.status {
        case .exact, .sameApp:
            return Color.accentColor.opacity(0.85)
        case .minimized, .otherDesktop, .otherScreen, .missing:
            return Color.secondary.opacity(0.45)
        }
    }

    private var fillTint: Color {
        borderTint.opacity(0.12)
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(fillTint)

            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(borderTint, lineWidth: 1.5)

            if let icon = AppIconResolver.shared.icon(forAppNamed: item.appName, size: iconFrame.width) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: iconFrame.width, height: iconFrame.height)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .offset(x: 4, y: 4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .help(item.tooltipTitle)
            }

            Text("\(item.frontOrder)")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                .background(borderTint, in: Capsule())
                .padding(4)
        }
        .frame(width: frame.width, height: frame.height, alignment: .topLeading)
        .offset(x: frame.minX, y: frame.minY)
        .help(item.tooltipTitle)
    }
}

private struct WorkSetPaletteWindowChip: View {
    let window: WindowState
    let onFocus: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: onFocus) {
            HStack(spacing: 8) {
                if let icon = AppIconResolver.shared.icon(forAppNamed: window.app, size: 20) {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 20, height: 20)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                } else {
                    Image(systemName: "app")
                        .frame(width: 20, height: 20)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(window.app)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(window.title.isEmpty ? "Untitled Window" : window.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isHovering ? Color.secondary.opacity(0.10) : Color.secondary.opacity(0.05))
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
        }
        .onDrag {
            WorkSetDragDrop.provider(forWindow: window)
        }
        .help(window.title.isEmpty ? window.app : "\(window.app) - \(window.title)")
    }
}

private struct WorkSetLaneDropTarget: View {
    let text: String
    let onDropPayload: (WorkSetDropPayload) -> Void
    @State private var isDropTargeted = false

    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(isDropTargeted ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.06))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [6, 6]))
                    .foregroundStyle(isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.3))
            )
            .overlay {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.down.to.line.compact")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text(text)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(10)
            }
            .onDrop(of: WorkSetDragDrop.dropTypeIdentifiers, isTargeted: $isDropTargeted) { providers in
                WorkSetDragDrop.loadPayload(from: providers) { payload in
                    onDropPayload(payload)
                }
            }
    }
}

private struct WorkSetNewLane: View {
    let onCreate: () -> Void
    let onDropPayload: (WorkSetDropPayload) -> Void
    @State private var isDropTargeted = false

    var body: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(isDropTargeted ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.05))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [8, 8]))
                    .foregroundStyle(isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.35))
            )
            .overlay {
                VStack(spacing: 12) {
                    Image(systemName: "plus.rectangle.on.rectangle")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    Text("New Work Set")
                        .font(.headline)
                    Text("Drop windows here to create another Work Set.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Create Empty Set", action: onCreate)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                .padding(18)
            }
            .frame(minHeight: 260)
            .onDrop(of: WorkSetDragDrop.dropTypeIdentifiers, isTargeted: $isDropTargeted) { providers in
                WorkSetDragDrop.loadPayload(from: providers) { payload in
                    onDropPayload(payload)
                }
            }
    }
}

private enum WorkSetDragDrop {
    struct MemberPayload: Codable {
        let sourceWorkSetID: UUID
        let memberID: UUID
    }

    static let dropTypeIdentifiers = [
        UTType.utf8PlainText.identifier,
        UTType.plainText.identifier,
        UTType.text.identifier
    ]

    static func provider(forWindow window: WindowState) -> NSItemProvider {
        let member = WorkSetMember(window: window)
        let json = (try? JSONEncoder().encode(member)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return NSItemProvider(object: "window:\(json)" as NSString)
    }

    static func provider(forMemberID memberID: UUID, sourceWorkSetID: UUID) -> NSItemProvider {
        let payload = MemberPayload(sourceWorkSetID: sourceWorkSetID, memberID: memberID)
        let json = (try? JSONEncoder().encode(payload)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return NSItemProvider(object: "member:\(json)" as NSString)
    }

    static func loadPayload(from providers: [NSItemProvider], perform: @escaping @MainActor (WorkSetDropPayload) -> Void) -> Bool {
        guard let provider = providers.first(where: { itemProvider in
            dropTypeIdentifiers.contains { itemProvider.hasItemConformingToTypeIdentifier($0) }
        }) else {
            return false
        }

        provider.loadObject(ofClass: NSString.self) { item, _ in
            guard let stringObject = item as? NSString else { return }
            let raw = String(stringObject)
            if raw.hasPrefix("member:"),
               let data = raw.dropFirst("member:".count).data(using: .utf8),
               let payload = try? JSONDecoder().decode(MemberPayload.self, from: data) {
                Task { @MainActor in
                    perform(.member(sourceWorkSetID: payload.sourceWorkSetID, memberID: payload.memberID))
                }
                return
            }
            if raw.hasPrefix("window:"),
               let data = raw.dropFirst("window:".count).data(using: .utf8),
               let payload = try? JSONDecoder().decode(WorkSetMember.self, from: data) {
                Task { @MainActor in
                    perform(.window(payload))
                }
            }
        }
        return true
    }
}

private struct WorkSetInfoBubbleButton: View {
    let text: String
    @State private var isPopoverPresented = false

    var body: some View {
        Button {
            isPopoverPresented.toggle()
        } label: {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPopoverPresented, arrowEdge: .top) {
            Text(text)
                .font(.caption)
                .foregroundStyle(.primary)
                .padding(12)
                .frame(width: 260, alignment: .leading)
        }
    }
}
