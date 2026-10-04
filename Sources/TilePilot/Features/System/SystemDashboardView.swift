import SwiftUI

struct SystemDashboardView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showAdvancedConfig = false
    @State private var showAdvancedDiagnostics = false
    @State private var showPerformanceAdvanced = false
    @State private var showPerformanceDiagnostics = false
    @State private var showResetDefaultsConfirm = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    summaryCard
                    appUpdateCard
                    performanceCard
                    essentialsCard
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

    private var summaryCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Label("System Overview", systemImage: "gearshape.2")
                    .font(.headline)

                Text(model.systemSummaryLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Text(model.setupGuideCompletionDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    if model.setupStateNeedsAttention {
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

                    Spacer()

                    Button("Recheck") {
                        model.performSetupAction(.recheck)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Button(model.releaseDefaultsResetButtonTitle) {
                        showResetDefaultsConfirm = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
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
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var essentialsCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(model.systemCheckRows) { row in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: row.status.symbolName)
                            .foregroundStyle(color(for: row.status))
                            .frame(width: 16)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.title)
                                .font(.subheadline.weight(.semibold))
                            Text(row.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if row.id == "mission-control" {
                                MissionControlChecklistView(items: model.missionControlChecklistItems)
                                    .padding(.top, 6)
                            }
                            HStack(spacing: 8) {
                                ForEach(row.actions, id: \.self) { action in
                                    Button(action.label) {
                                        model.performSystemCheckAction(action)
                                    }
                                    .buttonStyle(.borderless)
                                    .font(.caption)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Essentials", systemImage: "checklist")
        }
    }

    private var appUpdateCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 8) {
                    Label("App Update", systemImage: "arrow.down.app")
                        .font(.headline)
                    Spacer()
                    if model.appUpdateStatus.isChecking {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                Text(model.appUpdateStatusTitle)
                    .font(.subheadline.weight(.semibold))

                HStack(spacing: 8) {
                    Text("Current version")
                        .font(.caption.weight(.semibold))
                    Text(model.currentAppVersion)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)

                    if let release = model.availableAppUpdateRelease {
                        Spacer(minLength: 0)
                        Text("Latest")
                            .font(.caption.weight(.semibold))
                        Text(release.tagName)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }

                Text(model.appUpdateStatusDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Button("Check for Updates") {
                        model.checkForAppUpdates(manual: true)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    if model.availableAppUpdateRelease != nil {
                        Button("Open Release Page") {
                            model.openLatestReleasePage()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var performanceCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.performanceStatusLine)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Performance Mode: \(model.performanceDegradationMode.title)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(model.performanceDegradationMode == .full ? Color.secondary : Color.orange)
                    if let detail = model.performanceDegradationMode.detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("Use presets for quick tuning, or disable expensive features one by one.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

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

                    if model.effectivePerformancePreset == .custom {
                        Text("Custom")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                    }

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

                DisclosureGroup("Advanced", isExpanded: $showPerformanceAdvanced) {
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

                        Divider()

                        HStack(spacing: 8) {
                            Button("Disable Keep on Top") {
                                model.setKeepOnTopEnforcementEnabled(false)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Button("Disable Mini-map Hover Titles") {
                                model.setMiniMapHoverTitlesEnabled(false)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Button("Switch to Passive Baseline") {
                                model.applyPerformancePreset(.passiveBaseline)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Button("Switch to Low CPU Preset") {
                                model.applyPerformancePreset(.lowCPU)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    }
                    .padding(.top, 6)
                }

                DisclosureGroup("Advanced Diagnostics", isExpanded: $showPerformanceDiagnostics) {
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

    private var advancedPanelsCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                DisclosureGroup("Advanced: Managed skhd Section (Safe Editor)", isExpanded: $showAdvancedConfig) {
                    ConfigDashboardView(showNavigationContainer: false)
                        .frame(minHeight: 380)
                        .padding(.top, 6)
                }

                DisclosureGroup("Advanced: Diagnostics", isExpanded: $showAdvancedDiagnostics) {
                    CommandLogView(showNavigationContainer: false)
                        .frame(minHeight: 280)
                        .padding(.top, 6)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Advanced", systemImage: "slider.horizontal.3")
        }
    }

    private func color(for status: SystemCheckStatus) -> Color {
        switch status {
        case .good: return .green
        case .notice: return .yellow
        case .warning: return .orange
        case .error: return .red
        }
    }

    private func intervalControl(title: String, value: Double, step: Double, setter: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 3) {
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

            Text(intervalDescription(for: title))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .font(.caption)
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
            break
        case .files:
            model.requestOpenTilePilotTab(.files)
        case .managedConfig:
            showAdvancedConfig = true
        case .diagnostics:
            showAdvancedDiagnostics = true
        }
    }
}
