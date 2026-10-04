import SwiftUI

struct ConfigDashboardView: View {
    @EnvironmentObject private var model: AppModel
    let showNavigationContainer: Bool

    init(showNavigationContainer: Bool = true) {
        self.showNavigationContainer = showNavigationContainer
    }

    private var draftBinding: Binding<String> {
        Binding(
            get: { model.managedConfigDraft },
            set: { model.updateManagedConfigDraft($0) }
        )
    }

    var body: some View {
        Group {
            if showNavigationContainer {
                NavigationStack {
                    dashboardBody
                        .navigationTitle("TilePilot")
                }
            } else {
                dashboardBody
            }
        }
    }

    private var dashboardBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerCard
                editorCard
                diffCard
                backupsCard
            }
            .padding()
        }
        .task {
            if model.configFilePath == nil && !model.isRefreshingConfig {
                await model.refreshConfig()
            }
        }
    }

    private var cardHeaderLabel: some View {
        Label("Config", systemImage: "slider.horizontal.3")
    }

    private var headerCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Managed `skhdrc` Section", systemImage: "doc.badge.gearshape")
                        .font(.headline)
                    Spacer()
                    if model.isRefreshingConfig || model.isSavingConfig || model.isRestoringConfig {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                Text("Edits only the TilePilot managed marker block. Unknown lines outside the markers are preserved.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if let path = model.configFilePath {
                    Text(path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                HStack(spacing: 12) {
                    Label(model.configFileExists ? "skhdrc exists" : "skhdrc will be created", systemImage: model.configFileExists ? "checkmark.circle" : "plus.circle")
                        .font(.caption)
                        .foregroundStyle(model.configFileExists ? .green : .orange)
                    Label(model.configHasManagedSection ? "managed section found" : "managed section will be inserted", systemImage: model.configHasManagedSection ? "square.and.pencil" : "square.badge.plus")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Label(model.isManagedConfigDraftDirty ? "unsaved changes" : "saved draft", systemImage: model.isManagedConfigDraftDirty ? "pencil.circle" : "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(model.isManagedConfigDraftDirty ? .orange : .green)
                }

                HStack(spacing: 10) {
                    Button(model.isRefreshingConfig ? "Reloading..." : "Reload From skhdrc") {
                        Task { await model.refreshConfig() }
                    }
                    .disabled(model.isRefreshingConfig || model.isSavingConfig || model.isRestoringConfig)

                    Button("Discard Unsaved Edits") {
                        model.resetManagedConfigDraft()
                    }
                    .disabled(!model.isManagedConfigDraftDirty || model.isSavingConfig || model.isRestoringConfig)

                    Button(model.isSavingConfig ? "Saving..." : "Save skhd Shortcuts") {
                        model.saveManagedConfigSection()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isSavingConfig || model.isRestoringConfig)
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
        } label: { cardHeaderLabel }
    }

    private var editorCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text("Managed Section Editor")
                    .font(.headline)
                Text("Basic validation checks for malformed lines (heuristic). The app attempts a best-effort `skhd` restart after save.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: draftBinding)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 220)
                    .padding(6)
                    .background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Editor", systemImage: "pencil.and.outline")
        }
    }

    private var diffCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text("Managed Section Diff Preview")
                    .font(.headline)
                ScrollView {
                    Text(model.configDiffPreviewText)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(minHeight: 140, maxHeight: 220)
                .background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Preview", systemImage: "doc.text.magnifyingglass")
        }
    }

    private var backupsCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Backups")
                        .font(.headline)
                    Spacer()
                    Button("Restore Latest") {
                        model.restoreLatestConfigBackup()
                    }
                    .disabled(model.configBackups.isEmpty || model.isRestoringConfig || model.isSavingConfig)
                }

                if model.configBackups.isEmpty {
                    Text("No backups yet. A backup is created before each save when `skhdrc` already exists.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(model.configBackups.prefix(8))) { backup in
                        HStack(alignment: .top, spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(URL(fileURLWithPath: backup.path).lastPathComponent)
                                    .font(.caption.weight(.semibold))
                                Text(backup.createdAt.formatted())
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text("\(backup.sizeBytes) bytes")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Restore") {
                                model.restoreConfigBackup(backup)
                            }
                            .disabled(model.isRestoringConfig || model.isSavingConfig)
                        }
                        .padding(8)
                        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Backup / Restore", systemImage: "clock.arrow.circlepath")
        }
    }
}
