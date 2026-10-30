import SwiftUI

struct SystemDashboardView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showManagedShortcuts = false
    @State private var showCommandLog = false
    @State private var showEssentialDetails = false
    @State private var showFineTuning = false
    @State private var showMeasurements = false
    @State private var showResetDefaultsConfirm = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    summaryCard
                    essentialsCard
                    appUpdateCard
                    performanceCard
                    advancedPanelsCard
                }
                .padding()
            }
            .navigationTitle("TilePilot")
            .task {
                if model.bootstrapSnapshot == nil {
                    await model.refreshBootstrapSetup()
                }
                if model.doctorSnapshot == nil {
                    await model.refreshDoctor()
                }
                model.publishRuntimeDiagnosticsIfNeeded(force: true)
                applyRequestedSectionIfNeeded()
            }
            .onAppear {
                model.publishRuntimeDiagnosticsIfNeeded(force: true)
            }
            .onChange(of: model.requestedSystemPanelSection) { _ in
                applyRequestedSectionIfNeeded()
            }
            .alert("Restore All Default Settings?", isPresented: $showResetDefaultsConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Restore", role: .destructive) {
                    model.resetToReleaseDefaults()
                }
            } message: {
                Text("This restores TilePilot app settings and the TilePilot-managed sections of skhdrc and yabairc to their default values. Any non-managed lines stay unchanged.")
            }
            .confirmationDialog(
                model.helperMigrationPrompt?.title ?? "Existing Helper Install Detected",
                isPresented: Binding(
                    get: { model.helperMigrationPrompt != nil },
                    set: { isPresented in
                        if !isPresented {
                            model.dismissHelperMigrationPrompt()
                        }
                    }
                ),
                titleVisibility: .visible
            ) {
                Button("Use Existing Install") {
                    model.keepExistingHelperInstall()
                }
                Button("Replace With TilePilot Components", role: .destructive) {
                    model.replaceWithManagedHelpers()
                }
                Button("Cancel", role: .cancel) {
                    model.dismissHelperMigrationPrompt()
                }
            } message: {
                Text(model.helperMigrationPrompt?.message ?? "")
            }
        }
    }

    // MARK: - Status summary

    private var summaryCard: some View {
        let needsAttention = model.setupStateNeedsAttention
        return GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: needsAttention ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                        .font(.title2)
                        .foregroundStyle(needsAttention ? Color.orange : Color.green)
                        .frame(width: 28)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.systemSummaryLine)
                            .font(.headline)
                        Text(model.setupGuideCompletionDetail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 12)

                    Button("Recheck") {
                        model.performSetupAction(.recheck)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    guidedSetupButton(prominent: needsAttention)
                }

                if let error = model.lastErrorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                }
                if let message = model.lastActionMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.green)
                        .lineLimit(3)
                }
            }
            .padding(4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func guidedSetupButton(prominent: Bool) -> some View {
        if prominent {
            Button("Run Guided Setup") {
                model.presentSetupGuide()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        } else {
            Button("Run Guided Setup") {
                model.presentSetupGuide()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    // MARK: - Essentials

    private var essentialsCard: some View {
        let rows = model.systemCheckRows
        // Warnings and errors need action. Notices (optional permissions, settings TilePilot
        // can't verify) stay visible as notes without making the setup look broken.
        let attentionRows = rows.filter { $0.status == .warning || $0.status == .error }
        let noteRows = rows.filter { $0.status == .notice }
        let readyRows = rows.filter { $0.status == .good }

        return GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                if attentionRows.isEmpty && noteRows.isEmpty {
                    Label("All \(rows.count) essentials are ready.", systemImage: "checkmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.green)
                } else if attentionRows.isEmpty {
                    Label("Everything required is ready. \(noteRows.count == 1 ? "One item has" : "\(noteRows.count) items have") a note.", systemImage: "checkmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.green)
                } else {
                    Label(attentionRows.count == 1 ? "One item needs attention." : "\(attentionRows.count) items need attention.", systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                }

                ForEach(attentionRows + noteRows) { row in
                    essentialRow(row)
                }

                if !readyRows.isEmpty {
                    DisclosureGroup("Details", isExpanded: $showEssentialDetails) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(readyRows) { row in
                                essentialRow(row)
                            }
                        }
                        .padding(.top, 6)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Essentials", systemImage: "checklist")
        }
    }

    private func essentialRow(_ row: SystemCheckRow) -> some View {
        // The status card already has Recheck, so rows only keep actions that do something else.
        let actions = row.actions.filter { $0 != .recheck }
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: row.status.symbolName)
                .foregroundStyle(color(for: row.status))
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 3) {
                Text(row.title)
                    .font(.subheadline.weight(.semibold))
                Text(row.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if row.id == "mission-control" {
                    MissionControlChecklistView(items: model.missionControlChecklistItems)
                        .padding(.top, 6)
                }
                if !actions.isEmpty {
                    HStack(spacing: 10) {
                        ForEach(actions, id: \.self) { action in
                            Button(action.label) {
                                model.performSystemCheckAction(action)
                            }
                            .buttonStyle(.borderless)
                            .font(.caption)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }

    // MARK: - App Update

    private var appUpdateCard: some View {
        GroupBox {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("Version \(model.currentAppVersion)")
                            .font(.subheadline.monospacedDigit())
                        Text("·")
                            .foregroundStyle(.secondary)
                        Text(model.appUpdateStatusTitle)
                            .font(.subheadline.weight(.semibold))
                    }
                    Text(model.appUpdateStatusDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                Button("Check for Updates") {
                    model.checkForAppUpdates(manual: true)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.appUpdateStatus.isChecking)

                if model.availableAppUpdateRelease != nil {
                    Button("Open Release Page") {
                        model.openLatestReleasePage()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack(spacing: 6) {
                Label("App Update", systemImage: "arrow.down.app")
                if model.appUpdateStatus.isChecking {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
    }

    // MARK: - Performance

    private var performanceCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 10) {
                    Picker("Preset", selection: Binding(
                        get: { model.effectivePerformancePreset },
                        set: { preset in
                            guard preset != .custom else { return }
                            model.applyPerformancePreset(preset)
                        }
                    )) {
                        ForEach(PerformancePreset.selectableCases, id: \.self) { preset in
                            Text(preset.title).tag(preset)
                        }
                        Text("Custom").tag(PerformancePreset.custom)
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 220, alignment: .leading)
                    .help("Pick a preset for quick tuning, or change single settings under Fine-Tuning.")

                    Spacer()

                    Button("Refresh Live State") {
                        Task { await model.refreshLiveState() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("Reset Performance Settings") {
                        model.resetPerformanceSettings()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if model.performanceDegradationMode != .full {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Performance Mode: \(model.performanceDegradationMode.title)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                        if let detail = model.performanceDegradationMode.detail {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Text(model.performanceStatusLine)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help("Current preset, refresh mode, foreground and background refresh intervals, and active window helpers.")

                DisclosureGroup("Fine-Tuning", isExpanded: $showFineTuning) {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Keep on Top Enforcement", isOn: Binding(
                            get: { model.keepOnTopEnforcementEnabled },
                            set: { model.setKeepOnTopEnforcementEnabled($0) }
                        ))

                        Toggle("Mini-map Hover Titles", isOn: Binding(
                            get: { model.miniMapHoverTitlesEnabled },
                            set: { model.setMiniMapHoverTitlesEnabled($0) }
                        ))

                        Toggle("Hide Limited/Minimized Windows in Maps", isOn: Binding(
                            get: { model.hideMinimizedHelperWindowsInMaps },
                            set: { model.setHideMinimizedHelperWindowsInMaps($0) }
                        ))
                        .help("Hide limited windows, minimized windows, app-hidden windows, and stale helper or backdrop surfaces so the mini-map and MegaMap stay focused on usable windows.")

                        Toggle("Fast Live Refresh", isOn: Binding(
                            get: { model.performanceFastLiveRefreshEnabled },
                            set: { model.setPerformanceFastLiveRefreshEnabled($0) }
                        ))

                        Divider()

                        intervalControl(
                            title: "Foreground Polling",
                            value: model.performanceForegroundPollingSeconds,
                            step: 0.5,
                            setter: model.updatePerformanceForegroundPollingSeconds
                        )

                        intervalControl(
                            title: "Background Polling",
                            value: model.performanceBackgroundPollingSeconds,
                            step: 0.5,
                            setter: model.updatePerformanceBackgroundPollingSeconds
                        )

                        intervalControl(
                            title: "Keep-on-Top Enforcement",
                            value: model.performanceKeepOnTopEnforcementSeconds,
                            step: 0.5,
                            setter: model.updatePerformanceKeepOnTopEnforcementSeconds
                        )
                    }
                    .padding(.top, 6)
                }

                DisclosureGroup("Measurements", isExpanded: $showMeasurements) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(model.performanceDiagnosticsRows.enumerated()), id: \.offset) { item in
                            HStack {
                                Text(item.element.label)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(item.element.value)
                                    .font(.caption.monospacedDigit())
                            }
                        }
                    }
                    .padding(.top, 6)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Performance", systemImage: "speedometer")
        }
    }

    // MARK: - Advanced

    private var advancedPanelsCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                DisclosureGroup("Managed Shortcut Section (skhdrc)", isExpanded: $showManagedShortcuts) {
                    ConfigDashboardView(showNavigationContainer: false)
                        .frame(minHeight: 380)
                        .padding(.top, 6)
                }

                DisclosureGroup("Command Log", isExpanded: $showCommandLog) {
                    CommandLogView(showNavigationContainer: false)
                        .frame(minHeight: 280)
                        .padding(.top, 6)
                }

                Divider()

                HStack(spacing: 10) {
                    Button(model.releaseDefaultsResetButtonTitle) {
                        showResetDefaultsConfirm = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Text("Resets TilePilot settings and its managed sections of skhdrc and yabairc.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Advanced", systemImage: "slider.horizontal.3")
        }
    }

    // MARK: - Helpers

    private func color(for status: SystemCheckStatus) -> Color {
        switch status {
        case .good: return .green
        case .notice: return .yellow
        case .warning: return .orange
        case .error: return .red
        }
    }

    private func intervalControl(title: String, value: Double, step: Double, setter: @escaping (Double) -> Void) -> some View {
        HStack {
            Text(title)
            Spacer()
            Button {
                setter(value - step)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.plain)

            Text(model.formattedSeconds(value))
                .font(.caption.monospacedDigit())
                .frame(width: 52, alignment: .trailing)

            Button {
                setter(value + step)
            } label: {
                Image(systemName: "plus.circle")
            }
            .buttonStyle(.plain)
        }
        .font(.caption)
        .help(intervalDescription(for: title))
    }

    private func intervalDescription(for title: String) -> String {
        switch title {
        case "Foreground Polling":
            return "How often TilePilot refreshes live window and desktop state while the app UI, overlays, or keep-on-top work are active."
        case "Background Polling":
            return "How often TilePilot refreshes state while the app window is closed or otherwise idle."
        case "Keep-on-Top Enforcement":
            return "How often TilePilot rechecks apps marked Keep on Top when a floating window may need to be raised again."
        default:
            return ""
        }
    }

    private func applyRequestedSectionIfNeeded() {
        guard let section = model.consumeRequestedSystemPanelSection() else { return }
        switch section {
        case .essentials:
            showEssentialDetails = true
        case .files:
            model.requestOpenTilePilotTab(.files)
        case .managedConfig:
            showManagedShortcuts = true
        case .diagnostics:
            showCommandLog = true
        }
    }
}
