import SwiftUI

struct MissionControlChecklistView: View {
    let items: [MissionControlChecklistItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(items) { item in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: symbolName(for: item.status))
                        .foregroundStyle(color(for: item.status))
                        .frame(width: 16)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title)
                            .font(.subheadline.weight(.semibold))

                        HStack(spacing: 8) {
                            Text("Expected")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(item.expectedValue)
                                .font(.caption)
                                .foregroundStyle(.primary)

                            Spacer(minLength: 0)

                            Text("Current")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(item.actualValue ?? "Review manually")
                                .font(.caption)
                                .foregroundStyle(item.actualValue == nil ? .secondary : .primary)
                        }

                        Text(item.message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(10)
                .background(rowBackground(for: item.status), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }

    private func symbolName(for status: MissionControlCheckStatus) -> String {
        switch status {
        case .pass:
            return "checkmark.square.fill"
        case .warning:
            return "xmark.square.fill"
        case .unknown:
            return "minus.square.fill"
        }
    }

    private func color(for status: MissionControlCheckStatus) -> Color {
        switch status {
        case .pass:
            return .green
        case .warning:
            return .orange
        case .unknown:
            return .yellow
        }
    }

    private func rowBackground(for status: MissionControlCheckStatus) -> Color {
        switch status {
        case .pass:
            return .green.opacity(0.08)
        case .warning:
            return .orange.opacity(0.08)
        case .unknown:
            return .yellow.opacity(0.08)
        }
    }
}
