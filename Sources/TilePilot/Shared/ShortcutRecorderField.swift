import AppKit
import SwiftUI

/// A macOS-style shortcut recorder: one rounded field that shows the current shortcut, starts
/// recording when clicked, and offers clear and cancel buttons at its trailing edge.
struct ShortcutRecorderField: View {
    let symbols: String            // e.g. "⌃⇧⌥D"; empty when no shortcut is set
    let spelledOut: String?        // e.g. "Control + Shift + Option + D", shown as a tooltip
    let isRecording: Bool
    let onRecord: () -> Void
    let onCancelRecording: () -> Void
    var onClear: (() -> Void)? = nil   // nil hides the clear button
    var width: CGFloat = 196

    @State private var isHovering = false

    private let height: CGFloat = 24
    private let cornerRadius: CGFloat = 6
    private let accessoryInset: CGFloat = 22

    private var trimmedSymbols: String {
        symbols.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasShortcut: Bool {
        !trimmedSymbols.isEmpty
    }

    private var showsClearButton: Bool {
        !isRecording && hasShortcut && onClear != nil
    }

    private var showsAccessory: Bool {
        isRecording || showsClearButton
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            fieldButton
            accessoryButton
        }
        .frame(width: width, height: height)
        .background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(fieldFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(borderColor, lineWidth: isRecording ? 1.5 : 1)
        )
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isRecording)
    }

    private var fieldButton: some View {
        Button {
            if !isRecording {
                onRecord()
            }
        } label: {
            fieldLabel
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, showsAccessory ? accessoryInset : 8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(fieldHelp)
        .accessibilityLabel(fieldAccessibilityLabel)
        .accessibilityHint(isRecording ? "Press a key combination. Escape cancels." : "Records a new shortcut.")
    }

    @ViewBuilder
    private var fieldLabel: some View {
        if isRecording {
            Text("Type shortcut…")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .lineLimit(1)
        } else if hasShortcut {
            Text(trimmedSymbols)
                .font(.system(size: 13, weight: .semibold))
                .tracking(1.5)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        } else {
            Text("Record Shortcut")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var accessoryButton: some View {
        if isRecording {
            Button(action: onCancelRecording) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 4)
            .help("Cancel recording")
            .accessibilityLabel("Cancel recording")
        } else if showsClearButton, let onClear {
            Button(action: onClear) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 4)
            .help("Clear shortcut")
            .accessibilityLabel("Clear shortcut")
        }
    }

    private var fieldHelp: String {
        if isRecording {
            return "Press a key combination. Escape cancels."
        }
        if hasShortcut {
            if let spelledOut, !spelledOut.isEmpty {
                return spelledOut
            }
            return trimmedSymbols
        }
        return "Click to record a shortcut"
    }

    private var fieldAccessibilityLabel: String {
        if isRecording {
            return "Recording shortcut"
        }
        if hasShortcut {
            let spoken = (spelledOut?.isEmpty == false) ? spelledOut! : trimmedSymbols
            return "Shortcut: \(spoken)"
        }
        return "No shortcut. Record Shortcut"
    }

    private var fieldFill: Color {
        if isRecording {
            return Color.accentColor.opacity(0.08)
        }
        return Color(nsColor: .controlBackgroundColor).opacity(isHovering ? 1 : 0.85)
    }

    private var borderColor: Color {
        if isRecording {
            return Color.accentColor.opacity(0.75)
        }
        return Color(nsColor: .separatorColor).opacity(isHovering ? 1.0 : 0.8)
    }
}
