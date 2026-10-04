import SwiftUI

struct CommandLogView: View {
    @EnvironmentObject private var model: AppModel
    let showNavigationContainer: Bool

    init(showNavigationContainer: Bool = true) {
        self.showNavigationContainer = showNavigationContainer
    }

    var body: some View {
        Group {
            if showNavigationContainer {
                NavigationStack {
                    listBody
                        .navigationTitle("TilePilot")
                }
            } else {
                listBody
            }
        }
    }

    private var listBody: some View {
        List(model.commandLogs) { entry in
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(entry.command)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                    Spacer()
                    Text(statusLabel(entry))
                        .font(.caption)
                        .foregroundStyle(statusColor(entry))
                }

                Text("\(entry.startedAt.formatted(date: .omitted, time: .standard)) · \(entry.durationMs) ms")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !entry.stderrSnippet.isEmpty {
                    Text(entry.stderrSnippet)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                    if let hint = hint(for: entry) {
                        Text(hint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                } else if !entry.stdoutSnippet.isEmpty {
                    Text(entry.stdoutSnippet)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .padding(.vertical, 2)
        }
        .overlay {
            if model.commandLogs.isEmpty {
                EmptyStateView(
                    title: "No Command Logs",
                    systemImage: "list.bullet.rectangle",
                    message: "Run System Recheck to populate diagnostics."
                )
            }
        }
    }

    private func statusLabel(_ entry: CommandLogEntry) -> String {
        if entry.errorType == .none, entry.exitStatus == 0 {
            return "OK"
        }
        return entry.errorType.rawValue
    }

    private func statusColor(_ entry: CommandLogEntry) -> Color {
        entry.errorType == .none ? .green : .orange
    }

    private func hint(for entry: CommandLogEntry) -> String? {
        let stderr = entry.stderrSnippet.lowercased()
        let command = entry.command.lowercased()

        if command.contains("--check-sa"),
           stderr.contains("not a valid option") || stderr.contains("unknown option") || stderr.contains("unrecognized option") {
            return "Optional compatibility check not supported by this yabai version. Safe to ignore."
        }

        if command.contains("yabai"), stderr.contains("no such file or directory") {
            return "yabai is not installed yet. Use Guided Setup so TilePilot can prepare its local yabai/skhd components."
        }

        if command.contains("yabai"), stderr.contains("could not connect") {
            return "yabai is installed but not running. Start Window Control from Guided Setup."
        }

        return nil
    }
}
