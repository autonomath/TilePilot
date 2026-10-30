import AppKit
import SwiftUI

struct ShortcutsDashboardView: View {
    @EnvironmentObject private var model: AppModel
    private let shortcutDescriptionColumnWidth: CGFloat = 410
    private let shortcutRecorderWidth: CGFloat = 196
    private let shortcutActionSlotWidth: CGFloat = 52
    private let shortcutActionButtonLabelWidth: CGFloat = 34
    private let shortcutLeadingSlotWidth: CGFloat = 24
    private let reorderRowHeight: CGFloat = 48
    @State private var searchText = ""
    @State private var showDesktopMoveAdvanced = false
    @State private var isReordering = false
    @State private var reorderPinnedDraftIDs: [String] = []

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                shortcutsToolbar
                searchCard
                shortcutFeedback

                if !model.shortcutParseIssues.isEmpty {
                    issuesCard
                }

                shortcutsListCard
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .navigationTitle("TilePilot")
            .task {
                if model.shortcutEntries.isEmpty && !model.isRefreshingShortcuts {
                    await model.refreshShortcuts()
                }
                model.ensureShortcutPresentationCachesIfNeeded()
            }
            .onAppear {
                model.ensureShortcutPresentationCachesIfNeeded()
            }
            .onChange(of: searchText) { _ in
                if isSearchActive {
                    isReordering = false
                }
            }
            .onChange(of: isReordering) { enabled in
                if enabled {
                    syncPinnedReorderDraft()
                } else {
                    reorderPinnedDraftIDs = []
                }
            }
            .onChange(of: model.pinnedShortcutContextItems.map(\.id)) { _ in
                if reorderEnabled {
                    syncPinnedReorderDraft()
                }
            }
            .onDisappear {
                model.stopShortcutRecording()
            }
        }
    }

    private var filteredSections: [ShortcutsCatalogSection] {
        model.groupedFlatShortcutsSections(query: searchText)
    }

    @ViewBuilder
    private var shortcutFeedback: some View {
        if let error = model.lastErrorMessage {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
                .textSelection(.enabled)
        } else if let message = model.lastActionMessage {
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private var pinnedReorderItems: [PinnedShortcutContextItem] {
        let baseItems = model.pinnedShortcutContextItems
        let byID = Dictionary(uniqueKeysWithValues: baseItems.map { ($0.id, $0) })
        let ids = reorderPinnedDraftIDs.isEmpty ? baseItems.map(\.id) : reorderPinnedDraftIDs
        return ids.compactMap { byID[$0] }
    }

    private var isSearchActive: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var reorderEnabled: Bool {
        isReordering && !isSearchActive
    }

    private func syncPinnedReorderDraft() {
        let allIDs = model.pinnedShortcutContextItems.map(\.id)
        let allSet = Set(allIDs)
        var seen: Set<String> = []
        var next: [String] = []
        for id in reorderPinnedDraftIDs where allSet.contains(id) {
            guard seen.insert(id).inserted else { continue }
            next.append(id)
        }
        for id in allIDs where !seen.contains(id) {
            seen.insert(id)
            next.append(id)
        }
        reorderPinnedDraftIDs = next
    }

    private var shortcutsToolbar: some View {
        HStack(spacing: 8) {
            if isSearchActive {
                Text("Clear search to reorder")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }

    private var searchCard: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search controls or shortcuts", text: $searchText)
        }
        .textFieldStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private var issuesCard: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("\(model.shortcutParseIssues.count) lines were skipped while loading shortcuts.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button(model.isRefreshingShortcuts ? "Reloading..." : "Reload") {
                Task { await model.refreshShortcuts() }
            }
            .disabled(model.isRefreshingShortcuts)
            .buttonStyle(.bordered)
            .controlSize(.mini)
            Button("Logs") {
                model.requestOpenSystemSection(.diagnostics)
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private var shortcutsListCard: some View {
        Group {
            if reorderEnabled {
                VStack(alignment: .leading, spacing: 10) {
                    reorderModeHeader

                    Text("Drag pinned items to reorder the right-click menu.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if pinnedReorderItems.isEmpty {
                        EmptyStateView(
                            title: "Nothing is pinned yet",
                            systemImage: "pin.slash",
                            message: "Pin actions below first, then reorder the right-click menu here."
                        )
                        .frame(minHeight: 180)
                    } else {
                        reorderList
                    }
                }
            } else {
                shortcutsCatalogList
            }
        }
    }

    private var shortcutsCatalogList: some View {
        List {
            quickMenuCard
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                .listRowSeparator(.hidden)

            if filteredSections.isEmpty {
                EmptyStateView(
                    title: model.shortcutEntries.isEmpty ? "No controls loaded" : "No matching controls",
                    systemImage: "keyboard",
                    message: model.shortcutEntries.isEmpty
                        ? "Reload after creating `skhdrc`, or check shortcut parse issues."
                        : "Try a broader search query."
                )
                .frame(minHeight: 160)
                .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                .listRowSeparator(.hidden)

                if model.shortcutEntries.isEmpty {
                    HStack {
                        Button(model.isRefreshingShortcuts ? "Reloading..." : "Reload Shortcuts") {
                            Task { await model.refreshShortcuts() }
                        }
                        .disabled(model.isRefreshingShortcuts)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        Spacer(minLength: 0)
                    }
                    .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
                    .listRowSeparator(.hidden)
                }
            } else {
                ForEach(filteredSections) { section in
                    Section {
                        ForEach(section.items) { item in
                            flatShortcutsRow(item)
                                .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
                                .listRowSeparator(.hidden)
                        }
                    } header: {
                        shortcutsSectionHeader(section.group)
                            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                    }
                    .textCase(nil)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private var reorderList: some View {
        List {
            ForEach(pinnedReorderItems) { item in
                reorderPinnedItemRowBody(item)
                    .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
                    .listRowSeparator(.hidden)
            }
            .onMove(perform: movePinnedReorderItems)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private var quickMenuCard: some View {
        let pinnedItems = model.pinnedShortcutContextItems

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                HStack(spacing: 5) {
                    Label("Right-Click Menu", systemImage: "pin.circle.fill")
                        .font(.subheadline.weight(.semibold))
                    ContextHelpButton(topic: .rightClickMenu)
                }
                Spacer(minLength: 0)
                reorderToggleButton
            }

            Text(
                pinnedItems.isEmpty
                    ? "Pin items below to make them appear when you right-click the TilePilot menu bar icon."
                    : "These pinned items appear when you right-click the TilePilot menu bar icon, in the same order shown here."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            if pinnedItems.isEmpty {
                Text("Nothing is pinned yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(pinnedItems) { item in
                        quickMenuPinnedItemRow(item)
                    }
                }
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
    }

    /// Header shown in reorder mode, mirroring the Right-Click Menu card so the Done control sits
    /// where the Reorder button was.
    private var reorderModeHeader: some View {
        HStack(alignment: .center, spacing: 8) {
            HStack(spacing: 5) {
                Label("Right-Click Menu", systemImage: "pin.circle.fill")
                    .font(.subheadline.weight(.semibold))
                ContextHelpButton(topic: .rightClickMenu)
            }
            Spacer(minLength: 0)
            reorderToggleButton
        }
        .padding(.horizontal, 8)
    }

    private var reorderToggleButton: some View {
        Button {
            if !isReordering && isSearchActive {
                searchText = ""
            }
            isReordering.toggle()
        } label: {
            if isReordering {
                Label("Done", systemImage: "checkmark")
            } else {
                Label("Reorder…", systemImage: "arrow.up.arrow.down")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .environment(\.controlActiveState, .key)
        .help(isReordering ? "Finish reordering the right-click menu" : "Change the order of pinned items in the right-click menu")
    }

    @ViewBuilder
    private func flatShortcutsRow(_ item: ShortcutsDisplayItem) -> some View {
        flatShortcutsRowBody(item)
    }

    private func reorderPinnedItemRowBody(_ item: PinnedShortcutContextItem) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "pin.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(reorderPinnedItemTitle(for: item))
                    .font(.body.weight(.semibold))
                    .lineLimit(1)

                if let secondary = reorderPinnedItemSecondaryText(for: item) {
                    Text(secondary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            if let trailing = reorderPinnedItemTrailingText(for: item) {
                Text(trailing)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, minHeight: reorderRowHeight, alignment: .leading)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.04))
        )
    }

    @ViewBuilder
    private func flatShortcutsRowBody(_ item: ShortcutsDisplayItem) -> some View {
        switch item {
        case .featureRow(let row):
            if let entry = row.shortcutEntry {
                shortcutRow(entry)
            } else {
                unifiedActionOnlyRow(row)
            }
        case .directionalFamily(let group, let bindings):
            if let summary = directionalSummary(group: group, bindings: bindings) {
                directionalShortcutFamilyCard(summary, emphasized: group == .focusWindow || group == .resizeWindow)
            }
        case .desktopJumpFamily(let entries):
            jumpDesktopFamilyCard(entries)
        case .desktopMoveFamily(let entries):
            desktopMoveAdvancedFamilyCard(entries)
        }
    }

    @ViewBuilder
    private func quickMenuPinnedItemRow(_ item: PinnedShortcutContextItem) -> some View {
        switch item {
        case .feature(let row):
            quickMenuFeatureRow(row)
        case .directional(let group, let bindings):
            if let summary = directionalSummary(group: group, bindings: bindings) {
                directionalShortcutFamilyCard(summary)
            }
        case .shortcut(let entry):
            quickMenuShortcutRow(entry)
        }
    }

    private func quickMenuFeatureRow(_ row: FeatureControlRow) -> some View {
        let comboRaw = row.shortcutEntry?.combo ?? row.assignedCombo ?? row.defaultCombo

        return HStack(alignment: .center, spacing: 8) {
            if let featureID = row.featureID {
                Button {
                    model.toggleFeaturePinned(featureID)
                } label: {
                    Image(systemName: model.isFeaturePinned(featureID) ? "pin.fill" : "pin")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(model.isFeaturePinned(featureID) ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .help(model.isFeaturePinned(featureID) ? "Remove from the right-click menu" : "Add to the right-click menu")
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(row.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            quickMenuComboView(comboRaw: comboRaw)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.white.opacity(0.0001), in: RoundedRectangle(cornerRadius: 8))
    }

    private func quickMenuShortcutRow(_ entry: ShortcutEntry) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Button {
                model.toggleShortcutPinned(entry)
            } label: {
                Image(systemName: model.isShortcutPinned(entry) ? "pin.fill" : "pin")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(model.isShortcutPinned(entry) ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .help(model.isShortcutPinned(entry) ? "Remove from the right-click menu" : "Add to the right-click menu")

            VStack(alignment: .leading, spacing: 2) {
                Text(model.shortcutTitle(entry))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if let secondaryText = model.shortcutSecondaryText(entry) {
                    Text(secondaryText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            quickMenuComboView(comboRaw: entry.combo)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.white.opacity(0.0001), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func quickMenuComboView(comboRaw: String?) -> some View {
        if let comboRaw, !comboRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text(model.displayShortcutComboSymbols(from: comboRaw))
                .font(.system(size: 13, weight: .semibold))
                .tracking(1.5)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .help(model.displayShortcutComboWords(from: comboRaw))
                .accessibilityLabel(model.displayShortcutComboWords(from: comboRaw))
        } else {
            Text("No shortcut")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func movePinnedReorderItems(fromOffsets: IndexSet, toOffset: Int) {
        guard reorderEnabled else { return }
        var nextIDs = reorderPinnedDraftIDs
        nextIDs.move(fromOffsets: fromOffsets, toOffset: toOffset)
        guard nextIDs != reorderPinnedDraftIDs else { return }
        reorderPinnedDraftIDs = nextIDs

        let currentOverallIDs = model.flatShortcutsItems(query: "").map(\.id)
        let pinnedSet = Set(nextIDs)
        var remainingPinned = nextIDs[...]
        let mergedIDs = currentOverallIDs.map { id in
            if pinnedSet.contains(id), let replacement = remainingPinned.popFirst() {
                return replacement
            }
            return id
        }

        model.applyShortcutsCustomOrderIDs(mergedIDs)
        syncPinnedReorderDraft()
    }

    private func reorderPinnedItemTitle(for item: PinnedShortcutContextItem) -> String {
        switch item {
        case .feature(let row):
            return row.title
        case .directional(let group, let bindings):
            return directionalSummary(group: group, bindings: bindings).map { directionalFamilyTitle($0.kind) } ?? group.menuTitle
        case .shortcut(let entry):
            return model.shortcutTitle(entry)
        }
    }

    private func reorderPinnedItemSecondaryText(for item: PinnedShortcutContextItem) -> String? {
        switch item {
        case .feature(let row):
            return row.description
        case .directional(let group, let bindings):
            return directionalSummary(group: group, bindings: bindings).map { directionalFamilyDescription($0.kind) }
        case .shortcut(let entry):
            return model.shortcutSecondaryText(entry)
        }
    }

    private func reorderPinnedItemTrailingText(for item: PinnedShortcutContextItem) -> String? {
        switch item {
        case .feature(let row):
            let comboRaw = row.shortcutEntry?.combo ?? row.assignedCombo ?? row.defaultCombo
            guard let comboRaw, !comboRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return model.displayShortcutComboSymbols(from: comboRaw)
        case .directional(_, let bindings):
            return bindings.isEmpty ? nil : "\(bindings.count)"
        case .shortcut(let entry):
            let combo = entry.combo.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !combo.isEmpty else { return nil }
            return model.displayShortcutComboSymbols(from: combo)
        }
    }

    private func jumpDesktopFamilyCard(_ entries: [ShortcutEntry]) -> some View {
        let mapped = entries.compactMap { entry -> (entry: ShortcutEntry, desktop: Int)? in
            guard let desktop = desktopGoToTarget(from: entry.command) else { return nil }
            return (entry: entry, desktop: desktop)
        }
        .sorted { lhs, rhs in
            if lhs.desktop != rhs.desktop { return lhs.desktop < rhs.desktop }
            return lhs.entry.sourceLine < rhs.entry.sourceLine
        }
        let displayed = Array(mapped.prefix(3))
        let hasMore = mapped.count > displayed.count

        return HStack(alignment: .top, spacing: 8) {
            Color.clear
                .frame(width: shortcutLeadingSlotWidth, height: 1)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center, spacing: 8) {
                    Text("Jump to Desktop #")
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 0)
                    Button("Open macOS Keyboard Shortcuts") {
                        model.openMissionControlKeyboardShortcuts()
                    }
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .environment(\.controlActiveState, .key)
                }

                if mapped.isEmpty {
                    Text("No Jump shortcuts are configured yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    HStack(alignment: .top, spacing: 10) {
                        HStack(spacing: 6) {
                            ForEach(displayed, id: \.entry.id) { sample in
                                Button {
                                    model.selectShortcut(sample.entry)
                                } label: {
                                    VStack(alignment: .leading, spacing: 1) {
                                        HStack(alignment: .center, spacing: 6) {
                                            Text(model.displayShortcutComboWords(sample.entry))
                                                .font(.system(size: 11, weight: .semibold))
                                                .lineLimit(1)
                                            shortcutSymbolCaps(for: sample.entry, glyphSize: 13, highlighted: true)
                                        }
                                        Text("Desktop \(sample.desktop)")
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                                }
                                .buttonStyle(.plain)
                                .help("\(model.displayShortcutComboWords(sample.entry)) jumps to Desktop \(sample.desktop).")
                            }
                            if hasMore {
                                Text("...")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                            }
                        }

                        Spacer(minLength: 0)

                        Text("Then: Keyboard Shortcuts → Desktop Controls (Mission Control).")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                            .lineLimit(2)
                    }
                }
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
    }

    private func desktopMoveAdvancedFamilyCard(_ entries: [ShortcutEntry]) -> some View {
        let sortedEntries = entries.sorted { lhs, rhs in
            let lhsDesktop = desktopMoveAndFollowTarget(from: lhs.command) ?? Int.max
            let rhsDesktop = desktopMoveAndFollowTarget(from: rhs.command) ?? Int.max
            if lhsDesktop != rhsDesktop { return lhsDesktop < rhsDesktop }
            return lhs.sourceLine < rhs.sourceLine
        }

        return HStack(alignment: .top, spacing: 8) {
            Color.clear
                .frame(width: shortcutLeadingSlotWidth, height: 1)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center, spacing: 8) {
                    Label("Unsupported Desktop Move", systemImage: "minus.circle")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }

                Text("TilePilot does not support this desktop-move shortcut family.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                DisclosureGroup(
                    isExpanded: $showDesktopMoveAdvanced,
                    content: {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(sortedEntries, id: \.id) { entry in
                                shortcutRow(entry)
                            }
                        }
                        .padding(.top, 4)
                    },
                    label: {
                        Text(showDesktopMoveAdvanced ? "Hide Unsupported Desktop Move Shortcuts" : "Show Unsupported Desktop Move Shortcuts")
                            .font(.caption.weight(.semibold))
                    }
                )
            }
        }
        .padding(8)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func shortcutRow(_ entry: ShortcutEntry) -> some View {
        let featureRow = model.featureControlRow(forShortcutEntry: entry)
        let featureID = featureRow?.featureID
        let title = model.shortcutTitle(entry)
        let secondaryText = model.shortcutSecondaryText(entry)
        let isPinned = featureID.map(model.isFeaturePinned) ?? model.isShortcutPinned(entry)
        return HStack(alignment: .center, spacing: 8) {
            catalogPinButton(isPinned: isPinned) {
                if let featureID {
                    model.toggleFeaturePinned(featureID)
                } else {
                    model.toggleShortcutPinned(entry)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)

                if let secondaryText {
                    Text(secondaryText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if let warning = entry.warning {
                    Text(warning)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Group {
                if let featureID {
                    featureRecorderField(featureID, entry: entry)
                } else {
                    entryRecorderField(entry)
                }
            }
            .layoutPriority(1)

            catalogActionSlot {
                catalogActionButton("Test", help: "Run this action now") {
                    if let featureID {
                        model.runFeatureControl(featureID, source: .shortcutsUI)
                    } else {
                        model.runShortcut(entry)
                    }
                }
                .disabled(featureRow?.disabledReason != nil)
            }

            catalogActionSlot {
                catalogActionButton("Edit", help: "Open this shortcut's line in skhdrc") {
                    model.openShortcutSource(entry)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            model.selectShortcut(entry)
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(model.isShortcutSelected(entry) ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(model.isShortcutSelected(entry) ? Color.accentColor.opacity(0.30) : Color.clear, lineWidth: 1)
        )
        .id(entry.stableKey)
    }

    private func unifiedActionOnlyRow(_ row: FeatureControlRow) -> some View {
        HStack(alignment: .center, spacing: 8) {
            if let featureID = row.featureID {
                catalogPinButton(isPinned: model.isFeaturePinned(featureID)) {
                    model.toggleFeaturePinned(featureID)
                }
            } else {
                Color.clear
                    .frame(width: shortcutLeadingSlotWidth, height: 1)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Text(row.description)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Group {
                if let featureID = row.featureID, row.preferredCommand != nil {
                    featureRecorderField(featureID, entry: row.shortcutEntry)
                } else if let entry = row.shortcutEntry {
                    entryRecorderField(entry)
                } else {
                    Color.clear
                        .frame(width: shortcutRecorderWidth, height: 1)
                }
            }
            .layoutPriority(1)

            catalogActionSlot {
                catalogActionButton("Test", help: "Run this action now") {
                    if let featureID = row.featureID {
                        model.runFeatureControl(featureID, source: .shortcutsUI)
                    } else if let actionID = row.actionID {
                        model.performTilePilotAction(actionID)
                    }
                }
                .disabled(row.disabledReason != nil || model.activeActionID != nil)
            }

            catalogActionSlot {
                if let entry = row.shortcutEntry {
                    catalogActionButton("Edit", help: "Open this shortcut's line in skhdrc") {
                        model.openShortcutSource(entry)
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.04))
        )
    }

    private func catalogPinButton(isPinned: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: isPinned ? "pin.fill" : "pin")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isPinned ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.bordered)
        .controlSize(.mini)
        .frame(width: shortcutLeadingSlotWidth)
        .help(isPinned ? "Remove from the right-click menu" : "Add to the right-click menu")
        .accessibilityLabel(isPinned ? "Unpin from right-click menu" : "Pin to right-click menu")
    }

    /// A fixed-width trailing slot, so Test and Edit line up on every row even when a row has
    /// no Edit button.
    private func catalogActionSlot<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        // An empty slot (EmptyView) collapses even with a fixed frame, so a clear spacer holds
        // the width.
        ZStack {
            Color.clear
                .frame(width: shortcutActionSlotWidth, height: 1)
            content()
        }
        .frame(width: shortcutActionSlotWidth, alignment: .center)
    }

    private func catalogActionButton(_ title: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .frame(width: shortcutActionButtonLabelWidth)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .font(.system(size: 12, weight: .semibold))
        .lineLimit(1)
        .help(help)
    }

    private func featureRecorderField(_ featureID: FeatureControlID, entry: ShortcutEntry?) -> some View {
        let canClear = model.featureControlRow(forID: featureID)?.shortcutEntry != nil
        return ShortcutRecorderField(
            symbols: entry.map { model.displayShortcutComboSymbols($0) } ?? "",
            spelledOut: entry.map { model.displayShortcutComboWords($0) },
            isRecording: model.recordingFeatureID == featureID,
            onRecord: { model.beginShortcutRecording(for: featureID) },
            onCancelRecording: { model.stopShortcutRecording() },
            onClear: canClear ? { model.removeShortcut(for: featureID) } : nil,
            width: shortcutRecorderWidth
        )
    }

    private func entryRecorderField(_ entry: ShortcutEntry) -> some View {
        ShortcutRecorderField(
            symbols: model.displayShortcutComboSymbols(entry),
            spelledOut: model.displayShortcutComboWords(entry),
            isRecording: model.recordingShortcutStableKey == entry.stableKey,
            onRecord: { model.beginShortcutRecording(for: entry) },
            onCancelRecording: { model.stopShortcutRecording() },
            width: shortcutRecorderWidth
        )
    }

    private struct DesktopShortcutFamilySummary: Identifiable {
        enum Kind: String {
            case goToDesktop
            case moveWindowToDesktopAndFollow
        }

        let kind: Kind
        let entries: [(entry: ShortcutEntry, desktop: Int)]
        var id: String { kind.rawValue }
    }

    private struct DirectionalShortcutFamilySummary: Identifiable {
        enum Kind: String, CaseIterable {
            case focusWindow
            case moveWindow
            case resizeWindow
            case swapWindow
        }

        enum Direction: String, CaseIterable {
            case up
            case left
            case down
            case right

            var sortRank: Int {
                switch self {
                case .up: return 0
                case .left: return 1
                case .down: return 2
                case .right: return 3
                }
            }
        }

        let kind: Kind
        let entries: [(entry: ShortcutEntry, direction: Direction)]
        var id: String { kind.rawValue }
    }

    @ViewBuilder
    private func desktopShortcutsSection(_ entries: [ShortcutEntry]) -> some View {
        let summaries = desktopShortcutFamilies(from: entries)
        let covered = Set(summaries.flatMap { $0.entries.map { $0.entry.id } })
        let leftovers = entries.filter { !covered.contains($0.id) }

        VStack(alignment: .leading, spacing: 8) {
            ForEach(summaries) { summary in
                desktopShortcutFamilyCard(summary)
            }
            if !leftovers.isEmpty {
                ForEach(leftovers) { entry in
                    shortcutRow(entry)
                }
            }
        }
    }

    @ViewBuilder
    private func directionalShortcutsSection(
        _ entries: [ShortcutEntry],
        kinds: Set<DirectionalShortcutFamilySummary.Kind>
    ) -> some View {
        let summaries = directionalShortcutFamilies(from: entries).filter { kinds.contains($0.kind) }
        let covered = Set(summaries.flatMap { $0.entries.map { $0.entry.id } })
        let leftovers = entries.filter { !covered.contains($0.id) }

        VStack(alignment: .leading, spacing: 8) {
            ForEach(summaries) { summary in
                directionalShortcutFamilyCard(summary)
            }
            if !leftovers.isEmpty {
                ForEach(leftovers) { entry in
                    shortcutRow(entry)
                }
            }
        }
    }

    private func directionalSummary(
        group: DirectionalShortcutGroup,
        bindings: [DirectionalShortcutBinding]
    ) -> DirectionalShortcutFamilySummary? {
        guard let kind = DirectionalShortcutFamilySummary.Kind(rawValue: group.rawValue) else { return nil }
        let mappedEntries: [(entry: ShortcutEntry, direction: DirectionalShortcutFamilySummary.Direction)] = bindings.compactMap { binding in
            guard let direction = DirectionalShortcutFamilySummary.Direction(rawValue: binding.direction.rawValue) else { return nil }
            return (entry: binding.entry, direction: direction)
        }
        guard !mappedEntries.isEmpty else { return nil }
        return DirectionalShortcutFamilySummary(kind: kind, entries: mappedEntries)
    }

    private func directionalKinds(for group: UnifiedControlGroup) -> Set<DirectionalShortcutFamilySummary.Kind> {
        switch group {
        case .windowPlacement:
            return [.moveWindow, .swapWindow]
        case .windowSize:
            return [.resizeWindow]
        case .focus:
            return [.focusWindow]
        default:
            return []
        }
    }

    private func directionalShortcutFamilyCard(_ summary: DirectionalShortcutFamilySummary) -> some View {
        directionalShortcutFamilyCard(summary, emphasized: false)
    }

    private func directionalShortcutFamilyCard(_ summary: DirectionalShortcutFamilySummary, emphasized: Bool) -> some View {
        let orderedEntries = summary.entries.sorted { lhs, rhs in
            if lhs.direction.sortRank != rhs.direction.sortRank { return lhs.direction.sortRank < rhs.direction.sortRank }
            return lhs.entry.sourceLine < rhs.entry.sourceLine
        }
        let byDirection = Dictionary(uniqueKeysWithValues: orderedEntries.map { ($0.direction, $0.entry) })
        return HStack(alignment: .center, spacing: 8) {
            if let group = directionalGroup(from: summary.kind) {
                catalogPinButton(isPinned: model.isDirectionalGroupPinned(group)) {
                    model.toggleDirectionalGroupPinned(group)
                }
            } else {
                Color.clear
                    .frame(width: shortcutLeadingSlotWidth, height: 1)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(directionalFamilyTitle(summary.kind))
                    .font(emphasized ? .headline.weight(.semibold) : .subheadline.weight(.semibold))

                Text(directionalFamilyDescription(summary.kind))
                    .font(emphasized ? .subheadline : .caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(width: shortcutDescriptionColumnWidth, alignment: .leading)
            .layoutPriority(5)

            VStack(spacing: 5) {
                HStack {
                    Spacer(minLength: 0)
                    directionalDirectionBox(direction: .up, entry: byDirection[.up])
                    Spacer(minLength: 0)
                }

                HStack(spacing: 6) {
                    directionalDirectionBox(direction: .left, entry: byDirection[.left])
                    directionalDirectionBox(direction: .down, entry: byDirection[.down])
                    directionalDirectionBox(direction: .right, entry: byDirection[.right])
                }
            }
            .frame(minWidth: 220, idealWidth: 260, maxWidth: 320, alignment: .leading)
            .layoutPriority(8)

            Spacer(minLength: 2)
        }
        .padding(8)
        .background(Color.secondary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func directionalDirectionBox(
        direction: DirectionalShortcutFamilySummary.Direction,
        entry: ShortcutEntry?
    ) -> some View {
        if let entry {
            Button {
                model.runShortcut(entry)
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: directionArrowSymbolName(direction))
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.primary)

                    shortcutSymbolCaps(for: entry, glyphSize: 14, highlighted: false)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .frame(minWidth: 74, maxWidth: 80, minHeight: 48)
                .background(Color.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.blue.opacity(0.28), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .help(model.shortcutExplanation(entry))
        } else {
            VStack(spacing: 3) {
                Image(systemName: directionArrowSymbolName(direction))
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.secondary)
                Text("—")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .frame(minWidth: 74, maxWidth: 80, minHeight: 48)
            .background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.secondary.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            )
        }
    }

    private func desktopShortcutFamilyCard(_ summary: DesktopShortcutFamilySummary) -> some View {
        let exampleLimit = summary.entries.count <= 4 ? 4 : 3
        let examples = Array(summary.entries.prefix(exampleLimit))
        let moreCount = max(0, summary.entries.count - examples.count)

        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(desktopFamilyTitle(summary.kind))
                        .font(.subheadline.weight(.semibold))
                    Text(desktopFamilyDescription(summary.kind))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                if summary.kind == .goToDesktop {
                    Button("Use macOS Shortcut") {
                        model.openMissionControlKeyboardShortcuts()
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .environment(\.controlActiveState, .key)
                } else {
                    Text("Requires SA")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.orange.opacity(0.1), in: Capsule())
                }
            }

            HStack(spacing: 6) {
                ForEach(examples, id: \.entry.id) { sample in
                    Button {
                        model.selectShortcut(sample.entry)
                    } label: {
                        HStack(alignment: .center, spacing: 6) {
                            Text(model.displayShortcutComboWords(sample.entry))
                                .font(.system(size: 11, weight: .semibold))
                            Text(model.displayShortcutComboSymbolsSpaced(sample.entry))
                                .font(.system(size: 14, weight: .semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .help(desktopExampleHelp(sample.entry, desktop: sample.desktop, kind: summary.kind))
                }
                if moreCount > 0 {
                    Text("+\(moreCount) more")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
    }

    private func desktopShortcutFamilies(from entries: [ShortcutEntry]) -> [DesktopShortcutFamilySummary] {
        var goTo: [(ShortcutEntry, Int)] = []

        for entry in entries {
            if let desktop = desktopGoToTarget(from: entry.command), !entry.command.lowercased().contains("window --space") {
                goTo.append((entry, desktop))
                continue
            }
        }

        let sortedGoTo = goTo.sorted { lhs, rhs in lhs.1 == rhs.1 ? lhs.0.sourceLine < rhs.0.sourceLine : lhs.1 < rhs.1 }

        var output: [DesktopShortcutFamilySummary] = []
        if !sortedGoTo.isEmpty {
            output.append(.init(kind: .goToDesktop, entries: sortedGoTo.map { ($0.0, $0.1) }))
        }
        return output
    }

    private func directionalShortcutFamilies(from entries: [ShortcutEntry]) -> [DirectionalShortcutFamilySummary] {
        var buckets: [DirectionalShortcutFamilySummary.Kind: [(ShortcutEntry, DirectionalShortcutFamilySummary.Direction)]] = [:]

        for entry in entries {
            guard let (kind, direction) = directionalShortcutKindAndDirection(from: entry.command) else { continue }
            buckets[kind, default: []].append((entry, direction))
        }

        var output: [DirectionalShortcutFamilySummary] = []
        for kind in DirectionalShortcutFamilySummary.Kind.allCases {
            guard let rawEntries = buckets[kind], !rawEntries.isEmpty else { continue }
            let sorted = rawEntries.sorted { lhs, rhs in
                if lhs.1.sortRank != rhs.1.sortRank { return lhs.1.sortRank < rhs.1.sortRank }
                return lhs.0.sourceLine < rhs.0.sourceLine
            }
            output.append(.init(kind: kind, entries: sorted.map { ($0.0, $0.1) }))
        }
        return output
    }

    private func directionalShortcutKindAndDirection(from command: String) -> (DirectionalShortcutFamilySummary.Kind, DirectionalShortcutFamilySummary.Direction)? {
        let c = command.lowercased()

        if let direction = cardinalDirection(from: c, west: "yabai -m window --focus west", east: "yabai -m window --focus east", north: "yabai -m window --focus north", south: "yabai -m window --focus south") {
            return (.focusWindow, direction)
        }
        if let direction = cardinalDirection(from: c, west: "yabai -m window --warp west", east: "yabai -m window --warp east", north: "yabai -m window --warp north", south: "yabai -m window --warp south") {
            return (.moveWindow, direction)
        }
        if let direction = cardinalDirection(from: c, west: "yabai -m window --swap west", east: "yabai -m window --swap east", north: "yabai -m window --swap north", south: "yabai -m window --swap south") {
            return (.swapWindow, direction)
        }

        if c.contains("yabai -m window --resize left:") { return (.resizeWindow, .left) }
        if c.contains("yabai -m window --resize right:") { return (.resizeWindow, .right) }
        if c.contains("yabai -m window --resize top:") { return (.resizeWindow, .up) }
        if c.contains("yabai -m window --resize bottom:") { return (.resizeWindow, .down) }

        return nil
    }

    private func cardinalDirection(
        from command: String,
        west: String,
        east: String,
        north: String,
        south: String
    ) -> DirectionalShortcutFamilySummary.Direction? {
        if command.contains(north) { return .up }
        if command.contains(west) { return .left }
        if command.contains(south) { return .down }
        if command.contains(east) { return .right }
        return nil
    }

    private func directionalFamilyTitle(_ kind: DirectionalShortcutFamilySummary.Kind) -> String {
        switch kind {
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

    private func directionalFamilyDescription(_ kind: DirectionalShortcutFamilySummary.Kind) -> String {
        switch kind {
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

    private func directionalGroup(from kind: DirectionalShortcutFamilySummary.Kind) -> DirectionalShortcutGroup? {
        DirectionalShortcutGroup(rawValue: kind.rawValue)
    }

    private func shortcutsSectionHeader(_ group: UnifiedControlGroup) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: group.systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: shortcutLeadingSlotWidth)
            Text(group.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            if group == .tilingLayout {
                ContextHelpButton(topic: .layoutOutcomes)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            // Pinned headers float over the rows while scrolling; an opaque window-colored band
            // keeps rows from showing through. It extends past the header's own bounds to cover
            // the side insets and the few points the plain List leaves above a pinned header.
            Color(nsColor: .windowBackgroundColor)
                .padding(.horizontal, -16)
                .padding(.top, -6)
        )
    }

    private func directionArrowSymbolName(_ direction: DirectionalShortcutFamilySummary.Direction) -> String {
        switch direction {
        case .up: return "arrow.up"
        case .left: return "arrow.left"
        case .down: return "arrow.down"
        case .right: return "arrow.right"
        }
    }

    @ViewBuilder
    private func shortcutSymbolCaps(
        for entry: ShortcutEntry,
        glyphSize: CGFloat,
        highlighted: Bool
    ) -> some View {
        let symbols = model.displayShortcutComboSymbols(entry)
        let glyphs = symbols.isEmpty ? [] : Array(symbols).map(String.init)
        HStack(spacing: 4) {
            ForEach(Array(glyphs.enumerated()), id: \.offset) { _, glyph in
                Text(glyph)
                    .font(.system(size: glyphSize, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                    .frame(minWidth: glyphSize + 6, minHeight: glyphSize + 4)
                    .background(
                        (highlighted ? Color.blue.opacity(0.10) : Color.primary.opacity(0.08)),
                        in: RoundedRectangle(cornerRadius: 6)
                    )
            }
        }
        .lineLimit(1)
    }

    private func desktopFamilyTitle(_ kind: DesktopShortcutFamilySummary.Kind) -> String {
        switch kind {
        case .goToDesktop: return "Go to Desktop"
        case .moveWindowToDesktopAndFollow: return "Move Window to Desktop"
        }
    }

    private func desktopFamilyDescription(_ kind: DesktopShortcutFamilySummary.Kind) -> String {
        switch kind {
        case .goToDesktop:
            return "Switch to desktop number N using your configured desktop shortcut."
        case .moveWindowToDesktopAndFollow:
            return "This shortcut family is not supported by TilePilot."
        }
    }

    private func desktopExampleHelp(_ entry: ShortcutEntry, desktop: Int, kind: DesktopShortcutFamilySummary.Kind) -> String {
        switch kind {
        case .goToDesktop:
            return "\(model.displayShortcutComboWords(entry)) switches to Desktop \(desktop)."
        case .moveWindowToDesktopAndFollow:
            return "\(model.displayShortcutComboWords(entry)) moves the focused window to Desktop \(desktop), then switches there."
        }
    }

    private func desktopGoToTarget(from command: String) -> Int? {
        let c = command.lowercased()
        guard !c.contains("window --space") else { return nil }
        guard let range = c.range(of: "yabai -m space --focus ") else { return nil }
        let suffix = c[range.upperBound...]
        let digits = suffix.prefix { $0.isNumber }
        return Int(digits)
    }

    private func desktopMoveAndFollowTarget(from command: String) -> Int? {
        let c = command.lowercased()
        guard c.contains("yabai -m window --space ") else { return nil }
        guard let range = c.range(of: "yabai -m window --space ") else { return nil }
        let suffix = c[range.upperBound...]
        let digits = suffix.prefix { $0.isNumber }
        return Int(digits)
    }

    private func shortcutIntentGroup(_ entry: ShortcutEntry) -> String {
        let c = entry.command.lowercased()

        if c.contains("yabai -m window --space") {
            return "Experimental Desktop Move"
        }
        if c.contains("yabai -m space --focus") {
            return "Desktops"
        }
        if c.contains("yabai -m window --warp") {
            return "Window Placement"
        }
        if c.contains("yabai -m window --resize") {
            return "Window Size"
        }
        if c.contains("yabai -m window --toggle float") ||
            c.contains("yabai -m space --balance") ||
            c.contains("yabai -m space --layout") ||
            c.contains("yabai -m space --rotate") {
            return "Tiling & Layout"
        }
        if c.contains("yabai -m window --focus") {
            return "Focus"
        }
        if c.contains("yabai -m display") {
            return "Displays"
        }
        if c.contains("osascript") || c.contains("skhd -k") {
            return "Automation"
        }

        if c.hasPrefix("open ") || c.contains(" open ") {
            return "Apps"
        }
        if let first = c.split(whereSeparator: \.isWhitespace).first {
            let token = String(first)
            if token.hasPrefix("/") || token.hasPrefix("~/") || token.hasPrefix("./") {
                return "Helpers & Scripts"
            }
        }

        if entry.category == "Spaces" { return "Desktops" }
        if entry.category == "Windows" { return "Tiling & Layout" }
        return entry.category == "Other" ? "Other" : entry.category
    }

    private func shortcutGroupRank(_ group: String) -> Int {
        switch group {
        case "Desktops": return 0
        case "Window Placement": return 1
        case "Tiling & Layout": return 2
        case "Window Size": return 3
        case "Helpers & Scripts": return 4
        case "Apps": return 5
        case "Focus": return 6
        case "Displays": return 7
        case "Automation": return 8
        case "Other": return 98
        case "Experimental Desktop Move": return 99
        default: return 50
        }
    }

    private func shortcutGroupTitle(_ group: String) -> String {
        switch group {
        case "Experimental Desktop Move":
            return "Desktop Move (Experimental)"
        default:
            return group
        }
    }
}

private struct ShortcutsRowFramePreferenceKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
