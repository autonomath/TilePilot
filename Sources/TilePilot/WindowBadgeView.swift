import SwiftUI

struct WindowBadgeView: View {
    let model: AppModel
    let badge: WindowBadgeState
    var badgeWidth: CGFloat = 52
    var badgeHeight: CGFloat = 11

    private var runtimeEnabled: Bool { model.canRunYabaiRuntimeCommands && badge.isRuntimeManageable }
    private var showsLimitedVisualStyle: Bool { badge.usesLimitedVisualStyle }
    private var runtimeDisabledReason: String {
        if !model.canRunYabaiRuntimeCommands {
            return model.yabaiRuntimeControlDisabledReason ?? "Window controls unavailable"
        }
        if !badge.isRuntimeManageable {
            return "\(badge.app) does not expose move/control hooks for this window right now."
        }
        return "Window controls unavailable"
    }

    private var pinnedContextItems: [PinnedShortcutContextItem] {
        model.pinnedShortcutContextItems
    }

    private var hasPinnedContextActions: Bool {
        !pinnedContextItems.isEmpty
    }

    private var assignableWorkSets: [WorkSet] {
        model.workSetsForWindowAssignment(windowID: badge.windowID)
    }

    private var openTilePilotRow: FeatureControlRow? {
        model.featureControlRow(forID: FeatureControlID(rawValue: "app.open-tilepilot"))
    }

    private var openMegamapRow: FeatureControlRow? {
        model.featureControlRow(forID: FeatureControlID(rawValue: "app.open-megamap"))
    }

    var body: some View {
        Button {
            guard runtimeEnabled else { return }
            model.toggleWindowFloating(windowID: badge.windowID)
        } label: {
            Capsule()
                .fill(fillColor)
                .frame(width: badgeWidth, height: badgeHeight)
                .overlay(
                    Capsule()
                        .stroke(borderColor, lineWidth: badge.isFocused ? 0.9 : 0.6)
                )
                .opacity(0.62)
        }
        .buttonStyle(.plain)
        .help(helpText)
        .contextMenu {
            ForEach(pinnedContextItems, id: \.id) { item in
                switch item {
                case .feature(let row):
                    if let featureID = row.featureID {
                        let title = featureMenuTitle(row)
                        if featureID.rawValue == "app.keep-on-top-when-floating" {
                            Toggle(isOn: Binding(
                                get: {
                                    model.appForegroundPolicy(for: badge.app) == .keepFrontWhenFloating
                                },
                                set: { enabled in
                                    model.setAppForegroundPolicy(enabled ? .keepFrontWhenFloating : .useDefault, for: badge.app)
                                }
                            )) {
                                Text(title)
                            }
                            .disabled(row.disabledReason != nil)
                        } else if featureID.rawValue == "app.never-auto-tile" {
                            Toggle(isOn: Binding(
                                get: {
                                    model.isNeverAutoTileEnabled(for: badge.app)
                                },
                                set: { enabled in
                                    model.setNeverAutoTileEnabled(enabled, for: badge.app)
                                }
                            )) {
                                Text(title)
                            }
                            .disabled(row.disabledReason != nil)
                        } else {
                            Button(title) {
                                model.runFeatureControl(featureID, source: .statusMenu, appContext: badge.app)
                            }
                            .disabled(row.disabledReason != nil)
                        }
                    }
                case .directional(_, let bindings):
                    ForEach(bindings, id: \.id) { binding in
                        let title = shortcutMenuTitle(binding.entry)
                        Button(title) {
                            model.runShortcut(binding.entry)
                        }
                    }
                case .shortcut(let entry):
                    let title = shortcutMenuTitle(entry)
                    Button(title) {
                        model.runShortcut(entry)
                    }
                }
            }

            if hasPinnedContextActions {
                Divider()
            }

            if !assignableWorkSets.isEmpty {
                Menu("Assign to Work Set") {
                    ForEach(assignableWorkSets) { workSet in
                        let alreadyAssigned = model.isWindowAssignedToWorkSet(windowID: badge.windowID, workSet: workSet)
                        let leftTitle = model.workSetAssignmentMenuTitle(for: workSet, windowID: badge.windowID)
                        let featureID = model.workSetAssignWindowFeatureID(for: workSet)
                        let combo = model.featureControlRow(forID: featureID).flatMap { row in
                            row.shortcutEntry.map { model.displayShortcutComboSymbols($0) }
                                ?? row.assignedCombo.map { model.displayShortcutComboSymbols(from: $0) }
                        }
                        let title = menuTitle(left: leftTitle, rightShortcut: spacedSymbols(combo))

                        Button {
                            model.assignWindowToWorkSet(workSetID: workSet.id, windowID: badge.windowID)
                        } label: {
                            Label(title, systemImage: alreadyAssigned ? "checkmark" : "square.stack.3d.up")
                        }
                        .disabled(alreadyAssigned)
                    }
                }

                Divider()
            }

            if let row = openTilePilotRow {
                Button(featureMenuTitle(row)) {
                    model.openTilePilotDashboard()
                }
            } else {
                Button("Open TilePilot") {
                    model.openTilePilotDashboard()
                }
            }

            if let row = openMegamapRow {
                Button(featureMenuTitle(row)) {
                    model.presentMegamap()
                }
            } else {
                Button("Open MegaMap") {
                    model.presentMegamap()
                }
            }

            Button("Pin More Shortcuts") {
                model.openShortcutsDashboard()
            }
        }
    }

    private var borderColor: Color {
        if showsLimitedVisualStyle {
            return Color.gray.opacity(badge.isFocused ? 0.92 : 0.52)
        }
        if badge.isFocused {
            return accentColor.opacity(0.92)
        }
        return Color.white.opacity(0.36)
    }

    private var fillColor: Color {
        if showsLimitedVisualStyle {
            return Color.gray.opacity(0.8)
        }
        return accentColor.opacity(0.95)
    }

    private var accentColor: Color {
        badge.isFloating ? model.floatingOverlayAccentColor.swiftUIColor : model.tiledOverlayAccentColor.swiftUIColor
    }

    private var helpText: String {
        if showsLimitedVisualStyle {
            return "\(badge.app) • Limited control. TilePilot can see this window, but yabai cannot reliably move or retile it right now."
        }

        let state = badge.isFloating ? "Floating" : "Auto-Tiled"
        return "\(badge.app) • \(state). Left-click toggles. Right-click for options."
    }

    private func featureMenuTitle(_ row: FeatureControlRow) -> String {
        let symbols = row.shortcutEntry.map { model.displayShortcutComboSymbols($0) }
            ?? row.assignedCombo.map { model.displayShortcutComboSymbols(from: $0) }
            ?? row.defaultCombo.map { model.displayShortcutComboSymbols(from: $0) }
        return menuTitle(left: row.title, rightShortcut: spacedSymbols(symbols))
    }

    private func shortcutMenuTitle(_ entry: ShortcutEntry) -> String {
        let symbols = model.displayShortcutComboSymbols(entry)
        let combo = symbols.isEmpty ? model.displayShortcutComboWords(entry) : symbols
        return menuTitle(left: model.shortcutTitle(entry), rightShortcut: spacedSymbols(combo))
    }

    private func menuTitle(left: String, rightShortcut: String?) -> String {
        let trimmedRight = rightShortcut?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedRight.isEmpty else { return left }
        return "\(left)\t\(trimmedRight)"
    }

    private func spacedSymbols(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        return raw.map(String.init).joined(separator: " ")
    }
}
