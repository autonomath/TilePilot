import SwiftUI

struct SettingsPlaceholderView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("TilePilot Settings")
                .font(.title2.bold())
            Text("Phase 1 ships the foundation and setup/health shell. App settings will expand in later phases.")
                .foregroundStyle(.secondary)
            Text("Phase 2 adds setup/recovery checklist and guided actions in the Health tab.")
                .foregroundStyle(.secondary)
            Text("Current Health: \(model.healthBadgeTitle)")
            Spacer()
        }
        .padding()
        .frame(minWidth: 420, minHeight: 240)
        .task {
            model.startIfNeeded()
        }
    }
}
