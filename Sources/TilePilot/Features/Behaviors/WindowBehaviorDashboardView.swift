import SwiftUI

/// Tiling first (which desktops tile, which apps stay out), then how the mouse, focus, and the
/// keyboard move windows and desktops. Explanations live behind each section's ⓘ.
struct WindowBehaviorDashboardView: View {
    @EnvironmentObject private var model: AppModel
    @State private var newRuleAppName: String = ""
    @State private var newRuleBehavior: AppTilingBehavior = .neverTile
    @State private var desktopScrubSensitivityDraft = 1.0
    @State private var isEditingDesktopScrubSensitivity = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    desktopBehaviorCard
                    appRulesCard
                    HStack(alignment: .top, spacing: 16) {
                        mouseDraggingCard
                        pointerFocusCard
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    desktopScrubCard
                }
                .padding()
            }
            .transaction { transaction in
                transaction.animation = nil
            }
            .navigationTitle("TilePilot")
            .onAppear {
                syncDesktopScrubDraftsFromModel()
            }
            .onChange(of: model.desktopScrubSensitivity) { newValue in
                guard !isEditingDesktopScrubSensitivity else { return }
                desktopScrubSensitivityDraft = newValue
            }
            .task { await model.refreshWindowBehaviorConfig() }
        }
    }

    // MARK: - Desktop auto-tiling

    private var desktopBehaviorCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text("On tiles the windows on that desktop. Off leaves them floating.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let snapshot = model.liveStateSnapshot, snapshot.source == .yabai, !snapshot.degraded {
                    desktopTilingGrid(snapshot)
                } else {
                    Text("These switches appear once TilePilot can read your desktops.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HelpSectionLabel(title: "Desktop Auto-Tiling", systemImage: "rectangle.3.group", topic: .desktopAutoTiling)
        }
    }

    private func desktopTilingGrid(_ snapshot: LiveStateSnapshot) -> some View {
        let displayByID = Dictionary(snapshot.displays.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let spaces = snapshot.spaces.sorted { lhs, rhs in
            if lhs.focused != rhs.focused { return lhs.focused && !rhs.focused }
            return lhs.index < rhs.index
        }
        let enabledStates = spaces.map { space in
            model.desktopTilingEnabled(spaceIndex: space.index) ?? (((space.layout ?? "").lowercased()) != "float")
        }
        let allEnabled = enabledStates.allSatisfy { $0 }
        let anyEnabled = enabledStates.contains(true)
        let allDisabledReason = spaces.compactMap { model.desktopTilingDisabledReason(spaceIndex: $0.index) }.first

        return Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
            ForEach(Array(spaces.enumerated()), id: \.element.index) { offset, space in
                let disabledReason = model.desktopTilingDisabledReason(spaceIndex: space.index)
                GridRow {
                    HStack(spacing: 6) {
                        Text("Desktop \(space.index) · \(displayByID[space.displayId] ?? "Display \(space.displayId)")")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        if space.focused {
                            Text("Current")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    tilingSwitch(
                        selection: Binding(
                            get: { model.desktopTilingEnabled(spaceIndex: space.index) ?? enabledStates[offset] },
                            set: { model.setDesktopTilingEnabled(spaceIndex: space.index, enabled: $0) }
                        ),
                        disabled: disabledReason != nil
                    )
                    Text(disabledReason ?? "")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }

            if spaces.count > 1 {
                Divider()
                GridRow {
                    HStack(spacing: 6) {
                        Text("All Desktops")
                            .font(.subheadline.weight(.semibold))
                        if anyEnabled && !allEnabled {
                            Text("Mixed")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    tilingSwitch(
                        selection: Binding(
                            get: { allEnabled },
                            set: { model.setAllDesktopTilingEnabled(enabled: $0) }
                        ),
                        disabled: allDisabledReason != nil
                    )
                    Text(allDisabledReason ?? "")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private func tilingSwitch(selection: Binding<Bool>, disabled: Bool) -> some View {
        Picker("Tiling", selection: selection) {
            Text("On").tag(true)
            Text("Off").tag(false)
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(width: 110)
        .disabled(disabled)
    }

    // MARK: - App rules

    private var appRulesCard: some View {
        let rows = appRuleRows
        return GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                newWindowsRow

                if let autosaveError = model.windowBehaviorAutosaveErrorMessage {
                    Text(autosaveError)
                        .font(.caption2)
                        .foregroundStyle(.red)
                } else if let autosaveMessage = model.windowBehaviorAutosaveActionMessage {
                    Text(autosaveMessage)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Divider()

                if rows.isEmpty {
                    Text("Open apps show up here once TilePilot can read your windows.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    appRulesTable(rows)
                }

                addRuleRow

                Text("Rules in your yabairc outside TilePilot's section also apply.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HelpSectionLabel(title: "App Rules", systemImage: "list.bullet.clipboard", topic: .appRules)
        }
    }

    private var newWindowsRow: some View {
        let floatsByDefault = model.windowBehaviorPolicyDraft.manualTilingModeEnabled
        return HStack(alignment: .center, spacing: 12) {
            Text("New windows")
                .font(.subheadline.weight(.semibold))
            Picker("New windows", selection: Binding(
                get: { model.windowBehaviorPolicyDraft.manualTilingModeEnabled },
                set: { model.updateManualTilingModeDraft($0) }
            )) {
                Text("Float").tag(true)
                Text("Tile").tag(false)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 130)
            Text(floatsByDefault
                 ? "Apps without a rule float. Always Tile makes exceptions."
                 : "Apps without a rule tile. Never Auto-Tile makes exceptions.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            if let symbols = toggleFloatShortcutSymbols {
                Label {
                    Text("Float or tile the focused window: ") + Text(symbols).fontWeight(.semibold)
                } icon: {
                    Image(systemName: "keyboard")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
    }

    private static let keepOnTopColumnWidth: CGFloat = 80

    private func appRulesTable(_ rows: [AppRuleRowState]) -> some View {
        let ruled = rows.filter(\.hasRule)
        let others = rows.filter { !$0.hasRule }
        return VStack(alignment: .leading, spacing: 12) {
            if !ruled.isEmpty {
                appRuleSection(title: others.isEmpty ? nil : "With a rule", rows: ruled, showsHeader: true)
            }
            if !others.isEmpty {
                appRuleSection(title: ruled.isEmpty ? nil : "Other open apps", rows: others, showsHeader: ruled.isEmpty)
            }
        }
    }

    /// Two columns read top to bottom, so a long app list uses the card's width instead of its
    /// height. Both sections share the same column widths, so their controls line up.
    private func appRuleSection(title: String?, rows: [AppRuleRowState], showsHeader: Bool) -> some View {
        let half = (rows.count + 1) / 2
        let leading = Array(rows.prefix(half))
        let trailing = Array(rows.dropFirst(half))
        return VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 36) {
                appRuleColumn(leading, showsHeader: showsHeader)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                appRuleColumn(trailing, showsHeader: showsHeader && !trailing.isEmpty)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    private func appRuleColumn(_ rows: [AppRuleRowState], showsHeader: Bool) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            if showsHeader {
                GridRow {
                    tableHeader("App")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    tableHeader("Tiling")
                    tableHeader("Keep on Top")
                        .frame(width: Self.keepOnTopColumnWidth)
                        .help("Raise this app's floating windows above other windows.")
                }
            }
            ForEach(rows) { row in
                appRuleGridRows(row)
            }
        }
    }

    @ViewBuilder
    private func appRuleGridRows(_ row: AppRuleRowState) -> some View {
        GridRow {
            AppNameWithIconView(appName: row.appName)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Picker("Tiling for \(row.appName)", selection: Binding(
                get: { row.tilingBehavior },
                set: { model.setAppTilingBehavior($0, for: row.appName) }
            )) {
                ForEach(AppTilingBehavior.allCases, id: \.self) { behavior in
                    Text(behavior.displayName).tag(behavior)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            Toggle("Keep \(row.appName) on Top", isOn: Binding(
                get: { row.foregroundPolicy == .keepFrontWhenFloating },
                set: { model.setAppForegroundPolicy($0 ? .keepFrontWhenFloating : .useDefault, for: row.appName) }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)
            .frame(width: Self.keepOnTopColumnWidth)
        }
        if row.tilingBehavior == .alwaysTile, let conflictDesktop = row.alwaysTileConflictDesktopIndex {
            GridRow {
                HStack(spacing: 8) {
                    Label("Desktop \(conflictDesktop) has tiling Off, so this rule waits.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    Button("Turn On Tiling for Desktop \(conflictDesktop)") {
                        model.setDesktopTilingEnabled(spaceIndex: conflictDesktop, enabled: true)
                    }
                    .buttonStyle(.borderless)
                    .font(.caption2.weight(.semibold))
                }
                .padding(.leading, 24)
                .gridCellColumns(3)
            }
        }
    }

    private func tableHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private var addRuleRow: some View {
        let trimmedName = newRuleAppName.trimmingCharacters(in: .whitespacesAndNewlines)
        return HStack(spacing: 8) {
            TextField("Add an app that isn't open, e.g. Finder", text: $newRuleAppName)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 280)
                .onSubmit(addRule)
            Picker("Rule for the new app", selection: $newRuleBehavior) {
                Text(AppTilingBehavior.neverTile.displayName).tag(AppTilingBehavior.neverTile)
                Text(AppTilingBehavior.alwaysTile.displayName).tag(AppTilingBehavior.alwaysTile)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            Button("Add Rule", action: addRule)
                .disabled(trimmedName.isEmpty)
            Spacer(minLength: 0)
        }
    }

    private func addRule() {
        let name = newRuleAppName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        model.setAppTilingBehavior(newRuleBehavior, for: name)
        newRuleAppName = ""
    }

    /// Apps with a rule first, so a rule never hides among the other open apps.
    private var appRuleRows: [AppRuleRowState] {
        let rows = model.appNamesForBehaviorEditor.map { appName in
            AppRuleRowState(
                appName: appName,
                tilingBehavior: model.appTilingBehavior(for: appName),
                foregroundPolicy: model.appForegroundPolicy(for: appName),
                alwaysTileConflictDesktopIndex: model.alwaysTileConflictDesktopIndex(for: appName)
            )
        }
        return rows.filter(\.hasRule) + rows.filter { !$0.hasRule }
    }

    private var toggleFloatShortcutSymbols: String? {
        guard let entry = model.featureControlRow(forID: FeatureControlID(rawValue: "action.toggle-float"))?.shortcutEntry else {
            return nil
        }
        let symbols = model.displayShortcutComboSymbolsSpaced(entry).trimmingCharacters(in: .whitespaces)
        return symbols.isEmpty ? nil : symbols
    }

    // MARK: - Mouse and focus

    private var mouseDraggingCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("Hold the modifier key, then drag anywhere in a window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    behaviorPickerRow("Modifier key", selection: Binding(
                        get: { model.windowBehaviorPolicyDraft.mouseModifier },
                        set: { model.updateMouseModifierDraft($0) }
                    ))
                    behaviorPickerRow("Modifier + left-click drag", selection: Binding(
                        get: { model.windowBehaviorPolicyDraft.mouseAction1 },
                        set: { model.updateMouseAction1Draft($0) }
                    ))
                    behaviorPickerRow("Modifier + right-click drag", selection: Binding(
                        get: { model.windowBehaviorPolicyDraft.mouseAction2 },
                        set: { model.updateMouseAction2Draft($0) }
                    ))
                    behaviorPickerRow("Tiled window dropped on another", selection: Binding(
                        get: { model.windowBehaviorPolicyDraft.mouseDropAction },
                        set: { model.updateMouseDropActionDraft($0) }
                    ))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } label: {
            HelpSectionLabel(title: "Mouse Dragging & Drop", systemImage: "arrow.up.left.and.arrow.down.right", topic: .mouseDragging)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var pointerFocusCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("Focus can follow the pointer, or the pointer can follow focus.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        Text("Hover focus")
                        Picker("Hover focus", selection: Binding(
                            get: { model.windowBehaviorPolicyDraft.hoverFocusMode },
                            set: { model.updateHoverFocusModeDraft($0) }
                        )) {
                            ForEach(HoverFocusMode.allCases, id: \.self) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .fixedSize()
                    }
                    GridRow {
                        Text("Pointer jumps to focused window")
                        Toggle("Pointer jumps to focused window", isOn: Binding(
                            get: { model.windowBehaviorPolicyDraft.mouseFollowsFocusEnabled },
                            set: { model.updateMouseFollowsFocusDraft($0) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                    }
                }
                if model.windowBehaviorPolicyDraft.hoverFocusMode != .off {
                    Label("Hover focus can get in the way when you reach for the menu bar.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } label: {
            HelpSectionLabel(title: "Focus & Cursor", systemImage: "cursorarrow.motionlines", topic: .focusAndCursor)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func behaviorPickerRow<Value: CaseIterable & Hashable & BehaviorOptionDisplayable>(
        _ title: String,
        selection: Binding<Value>
    ) -> some View where Value.AllCases: RandomAccessCollection {
        GridRow {
            Text(title)
            Picker(title, selection: selection) {
                ForEach(Array(Value.allCases), id: \.self) { value in
                    Text(value.pickerDisplayName).tag(value)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        }
    }

    // MARK: - Desktop scrub

    private var desktopScrubCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("Hold \(model.desktopScrubTriggerSummaryText) and move the mouse left or right to switch desktops.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                    GridRow {
                        Text("Use Desktop Scrub")
                        Toggle("Use Desktop Scrub", isOn: Binding(
                            get: { model.desktopScrubEnabled },
                            set: { model.setDesktopScrubEnabled($0) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                    }
                    GridRow {
                        Text("Trigger keys")
                        HStack(spacing: 8) {
                            ForEach(DesktopScrubModifier.allCases) { modifier in
                                desktopScrubModifierButton(modifier)
                            }
                            Text("+")
                                .foregroundStyle(.secondary)
                            desktopScrubCharacterKeyPicker
                        }
                        .help("Pick at least two modifier keys. An extra letter or number key is optional.")
                    }
                    GridRow {
                        Text("Sensitivity")
                        HStack(spacing: 8) {
                            Slider(
                                value: $desktopScrubSensitivityDraft,
                                in: 0.4 ... 5.0,
                                step: 0.1,
                                onEditingChanged: handleDesktopScrubSensitivityEditingChanged
                            )
                            .frame(width: 200)
                            Text(String(format: "%.1f×", desktopScrubSensitivityDraft))
                                .font(.caption.monospacedDigit().weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 42, alignment: .leading)
                        }
                        .help("Higher sensitivity moves through more desktops with the same mouse movement.")
                    }
                    GridRow {
                        Text("Reverse direction")
                        Toggle("Reverse direction", isOn: Binding(
                            get: { model.desktopScrubInvertDirection },
                            set: { model.setDesktopScrubInvertDirection($0) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                    }
                }

                if let statusMessage = model.desktopScrubStatusMessage {
                    Text(statusMessage)
                        .font(.caption2)
                        .foregroundStyle(model.desktopScrubStatusIsError ? .orange : .secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HelpSectionLabel(title: "Desktop Scrub", systemImage: "arrow.left.arrow.right.circle", topic: .desktopScrub)
        }
    }

    private var desktopScrubCharacterKeyPicker: some View {
        Picker("Extra key", selection: Binding(
            get: { model.desktopScrubTriggerCharacter },
            set: { model.setDesktopScrubTriggerCharacter($0) }
        )) {
            ForEach(DesktopScrubCharacterKey.allCases) { key in
                Text(key.displayName).tag(key)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(width: 84, alignment: .leading)
    }

    private func desktopScrubModifierButton(_ modifier: DesktopScrubModifier) -> some View {
        let isSelected = model.desktopScrubTriggerModifiers.contains(modifier)

        return Button {
            model.toggleDesktopScrubModifier(modifier)
        } label: {
            Text(modifier.chipLabel)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(isSelected ? Color.accentColor : Color.secondary.opacity(0.12))
                )
                .overlay(
                    Capsule()
                        .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.18), lineWidth: 1)
                )
                .foregroundStyle(isSelected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func syncDesktopScrubDraftsFromModel() {
        desktopScrubSensitivityDraft = model.desktopScrubSensitivity
    }

    private func handleDesktopScrubSensitivityEditingChanged(_ isEditing: Bool) {
        isEditingDesktopScrubSensitivity = isEditing
        guard !isEditing else { return }
        model.setDesktopScrubSensitivity(desktopScrubSensitivityDraft)
    }
}

private struct AppRuleRowState: Identifiable, Hashable {
    let appName: String
    let tilingBehavior: AppTilingBehavior
    let foregroundPolicy: AppForegroundPolicy
    let alwaysTileConflictDesktopIndex: Int?

    var id: String { appName }

    var hasRule: Bool {
        tilingBehavior != .useDefault || foregroundPolicy != .useDefault
    }
}
