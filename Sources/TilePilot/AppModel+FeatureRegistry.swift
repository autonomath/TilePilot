import Foundation

@MainActor
extension AppModel {
    struct FeatureDefinition: Sendable {
        let id: FeatureControlID
        let group: UnifiedControlGroup
        let title: String
        let description: String
        let backend: FeatureExecutionBackend
        let capabilityGate: FeatureCapabilityGate
        let defaultCombo: String?
        let commandMatchers: [String]
        let matchAllCommandMatchers: Bool
        let preferredCommand: String?
        let actionID: TilePilotActionID?
        let isExperimental: Bool
    }

    func tilePilotFeatureURL(_ featureID: FeatureControlID) -> String {
        "tilepilot://feature/\(featureID.rawValue)"
    }

    func tilePilotFeatureCommand(_ featureID: FeatureControlID) -> String {
        "/usr/bin/open -g \"\(tilePilotFeatureURL(featureID))\""
    }

    var featureDefinitions: [FeatureDefinition] {
        var definitions: [FeatureDefinition] = [
            FeatureDefinition(
                id: "screen.set-floating-all-visible",
                group: .tilingLayout,
                title: "Float All Windows on This Desktop",
                description: "Stops tiling the windows on this desktop so you can move and overlap them freely.",
                backend: .tilePilotAction,
                capabilityGate: .yabaiRuntime,
                defaultCombo: "ctrl + shift + alt - d",
                commandMatchers: [
                    tilePilotFeatureURL("screen.set-floating-all-visible"),
                    "tilepilot:/feature/screen.set-floating-all-visible",
                    "/.config/yabai/scripts/disable-tiling-all-visible.sh",
                ],
                matchAllCommandMatchers: false,
                preferredCommand: tilePilotFeatureCommand("screen.set-floating-all-visible"),
                actionID: nil,
                isExperimental: false
            ),
            FeatureDefinition(
                id: "screen.set-tiled-all-visible",
                group: .tilingLayout,
                title: "Tile All Windows on This Desktop",
                description: "Puts eligible windows on this desktop back into tiles and leaves Never Auto-Tile apps floating.",
                backend: .tilePilotAction,
                capabilityGate: .yabaiRuntime,
                defaultCombo: "ctrl + shift + alt - e",
                commandMatchers: [
                    tilePilotFeatureURL("screen.set-tiled-all-visible"),
                    "tilepilot:/feature/screen.set-tiled-all-visible",
                    "/.config/yabai/scripts/enable-tiling-all-visible.sh",
                ],
                matchAllCommandMatchers: false,
                preferredCommand: tilePilotFeatureCommand("screen.set-tiled-all-visible"),
                actionID: nil,
                isExperimental: false
            ),
            FeatureDefinition(
                id: "screen.bring-floating-front",
                group: .tilingLayout,
                title: "Bring Floating Windows to Front",
                description: "Raises floating windows above the other windows on this desktop.",
                backend: .tilePilotAction,
                capabilityGate: .yabaiRuntime,
                defaultCombo: nil,
                commandMatchers: [
                    tilePilotFeatureURL("screen.bring-floating-front"),
                    "tilepilot:/feature/screen.bring-floating-front",
                ],
                matchAllCommandMatchers: false,
                preferredCommand: "/usr/bin/open -g \"tilepilot://feature/screen.bring-floating-front\"",
                actionID: nil,
                isExperimental: false
            ),
            FeatureDefinition(
                id: "screen.current-desktop-tiling-on",
                group: .tilingLayout,
                title: "Desktop Tiling On",
                description: "Turns tiling on for the current desktop.",
                backend: .shortcutCommand,
                capabilityGate: .yabaiRuntime,
                defaultCombo: nil,
                commandMatchers: ["yabai -m space --layout bsp"],
                matchAllCommandMatchers: false,
                preferredCommand: "yabai -m space --layout bsp",
                actionID: nil,
                isExperimental: false
            ),
            FeatureDefinition(
                id: "screen.current-desktop-tiling-off",
                group: .tilingLayout,
                title: "Desktop Tiling Off",
                description: "Turns tiling off for the current desktop (floating layout).",
                backend: .shortcutCommand,
                capabilityGate: .yabaiRuntime,
                defaultCombo: nil,
                commandMatchers: ["yabai -m space --layout float"],
                matchAllCommandMatchers: false,
                preferredCommand: "yabai -m space --layout float",
                actionID: nil,
                isExperimental: false
            ),
            FeatureDefinition(
                id: "screen.grid-floating",
                group: .tilingLayout,
                title: "Arrange Windows into a Floating Grid",
                description: "Places the windows on this desktop into a simple grid and leaves them floating.",
                backend: .tilePilotAction,
                capabilityGate: .yabaiRuntime,
                defaultCombo: "ctrl + shift + alt - p",
                commandMatchers: [
                    tilePilotFeatureURL("screen.grid-floating"),
                    "tilepilot:/feature/screen.grid-floating",
                    "/.config/yabai/scripts/grid-tiling-floating.sh",
                    "/.config/yabai/scripts/grid-pack-toggle.sh",
                    "/.config/yabai/scripts/auto-layout-current-desktop.sh",
                    "/.config/yabai/scripts/readable-current-space.sh",
                ],
                matchAllCommandMatchers: false,
                preferredCommand: tilePilotFeatureCommand("screen.grid-floating"),
                actionID: nil,
                isExperimental: false
            ),
            FeatureDefinition(
                id: "screen.grid-auto-tiled",
                group: .tilingLayout,
                title: "Retile Windows into a Balanced Tiled Layout",
                description: "Retiles eligible windows on this desktop into a balanced layout and leaves Never Auto-Tile apps floating.",
                backend: .tilePilotAction,
                capabilityGate: .yabaiRuntime,
                defaultCombo: "ctrl + shift + alt - o",
                commandMatchers: [
                    tilePilotFeatureURL("screen.grid-auto-tiled"),
                    "tilepilot:/feature/screen.grid-auto-tiled",
                    "/.config/yabai/scripts/rebuild-balanced-tile-layout.sh",
                    "/.config/yabai/scripts/grid-tiling-auto-tiled.sh"
                ],
                matchAllCommandMatchers: false,
                preferredCommand: tilePilotFeatureCommand("screen.grid-auto-tiled"),
                actionID: nil,
                isExperimental: false
            ),
            FeatureDefinition(
                id: "screen.pick-windows-to-tile",
                group: .tilingLayout,
                title: "Pick Windows to Tile…",
                description: "Choose frontmost windows on this desktop, then tile only those windows.",
                backend: .tilePilotAction,
                capabilityGate: .yabaiRuntime,
                defaultCombo: nil,
                commandMatchers: [tilePilotFeatureURL("screen.pick-windows-to-tile")],
                matchAllCommandMatchers: false,
                preferredCommand: tilePilotFeatureCommand("screen.pick-windows-to-tile"),
                actionID: nil,
                isExperimental: false
            ),
            FeatureDefinition(
                id: "screen.layout-bsp-balance",
                group: .tilingLayout,
                title: "Set This Desktop to Tiled Layout and Rebalance",
                description: "Turns on tiled layout for this desktop and rebalances existing tiles. Floating windows stay floating.",
                backend: .shortcutCommand,
                capabilityGate: .yabaiRuntime,
                defaultCombo: "ctrl + shift + alt - g",
                commandMatchers: ["yabai -m space --layout bsp", "yabai -m space --balance"],
                matchAllCommandMatchers: true,
                preferredCommand: "yabai -m space --layout bsp; yabai -m space --balance",
                actionID: .layoutBSPAndBalance,
                isExperimental: false
            ),
            FeatureDefinition(
                id: "screen.balance-current-desktop",
                group: .tilingLayout,
                title: "Rebalance Tiled Window Sizes",
                description: "Redistributes space so tiled windows on this desktop are closer in size.",
                backend: .shortcutCommand,
                capabilityGate: .yabaiRuntime,
                defaultCombo: "alt - 0",
                commandMatchers: ["yabai -m space --balance"],
                matchAllCommandMatchers: false,
                preferredCommand: "yabai -m space --balance",
                actionID: .balanceSpace,
                isExperimental: false
            ),
            FeatureDefinition(
                id: "action.layout-stack",
                group: .tilingLayout,
                title: "Stack Layout",
                description: "Sets stack layout on the current desktop.",
                backend: .tilePilotAction,
                capabilityGate: .yabaiRuntime,
                defaultCombo: "shift + alt - v",
                commandMatchers: ["yabai -m space --layout stack"],
                matchAllCommandMatchers: false,
                preferredCommand: "yabai -m space --layout stack",
                actionID: .layoutStack,
                isExperimental: false
            ),
            FeatureDefinition(
                id: "screen.rotate-layout",
                group: .tilingLayout,
                title: "Rotate Layout",
                description: "Rotates layout by 90 degrees on the current desktop.",
                backend: .shortcutCommand,
                capabilityGate: .yabaiRuntime,
                defaultCombo: "shift + alt - r",
                commandMatchers: [
                    tilePilotFeatureURL("screen.rotate-layout"),
                    "tilepilot:/feature/screen.rotate-layout",
                    "yabai -m space --rotate"
                ],
                matchAllCommandMatchers: false,
                preferredCommand: "yabai -m space --rotate 90",
                actionID: nil,
                isExperimental: false
            ),
            FeatureDefinition(
                id: "action.toggle-float",
                group: .tilingLayout,
                title: "Toggle Floating/Tiled",
                description: "Toggles the focused window between floating and tiled.",
                backend: .tilePilotAction,
                capabilityGate: .yabaiRuntime,
                defaultCombo: "ctrl + shift + alt - ~",
                commandMatchers: ["yabai -m window --toggle float"],
                matchAllCommandMatchers: false,
                preferredCommand: "yabai -m window --toggle float",
                actionID: .toggleFloat,
                isExperimental: false
            ),
            FeatureDefinition(
                id: "app.open-tilepilot",
                group: .apps,
                title: "Open TilePilot",
                description: "Brings TilePilot to the front so you can access the mini-map fast.",
                backend: .shortcutCommand,
                capabilityGate: .none,
                defaultCombo: "ctrl + shift + alt - return",
                commandMatchers: [
                    "open -a tilepilot",
                    "open -a \"tilepilot\"",
                    "/contents/macos/tilepilot",
                ],
                matchAllCommandMatchers: false,
                preferredCommand: "/usr/bin/open -a \"TilePilot\"",
                actionID: nil,
                isExperimental: false
            ),
            FeatureDefinition(
                id: "app.open-megamap",
                group: .desktops,
                title: "Open MegaMap",
                description: "Opens the large screenshot-based view of all desktops.",
                backend: .tilePilotAction,
                capabilityGate: .none,
                defaultCombo: nil,
                commandMatchers: [tilePilotFeatureURL("app.open-megamap")],
                matchAllCommandMatchers: false,
                preferredCommand: tilePilotFeatureCommand("app.open-megamap"),
                actionID: nil,
                isExperimental: false
            ),
            FeatureDefinition(
                id: "app.run-guided-setup",
                group: .apps,
                title: "Run Guided Setup",
                description: "Opens the step-by-step setup assistant for window control, shortcuts, and optional permissions.",
                backend: .tilePilotAction,
                capabilityGate: .none,
                defaultCombo: nil,
                commandMatchers: [tilePilotFeatureURL("app.run-guided-setup")],
                matchAllCommandMatchers: false,
                preferredCommand: tilePilotFeatureCommand("app.run-guided-setup"),
                actionID: nil,
                isExperimental: false
            ),
            FeatureDefinition(
                id: "app.refresh-megamap",
                group: .desktops,
                title: "Refresh MegaMap",
                description: "Visibly sweeps desktops and captures fresh MegaMap screenshots.",
                backend: .tilePilotAction,
                capabilityGate: .none,
                defaultCombo: nil,
                commandMatchers: [tilePilotFeatureURL("app.refresh-megamap")],
                matchAllCommandMatchers: false,
                preferredCommand: tilePilotFeatureCommand("app.refresh-megamap"),
                actionID: nil,
                isExperimental: false
            ),
            FeatureDefinition(
                id: "app.keep-on-top-when-floating",
                group: .apps,
                title: "Keep App on Top",
                description: "Toggles keep-on-top for the focused app (or the badge app from a window badge).",
                backend: .tilePilotAction,
                capabilityGate: .yabaiRuntime,
                defaultCombo: nil,
                commandMatchers: [tilePilotFeatureURL("app.keep-on-top-when-floating")],
                matchAllCommandMatchers: false,
                preferredCommand: tilePilotFeatureCommand("app.keep-on-top-when-floating"),
                actionID: nil,
                isExperimental: false
            ),
            FeatureDefinition(
                id: "app.never-auto-tile",
                group: .apps,
                title: "Never Auto-Tile App",
                description: "Keeps the focused app (or the badge app from a window menu) out of tiled layouts.",
                backend: .tilePilotAction,
                capabilityGate: .none,
                defaultCombo: nil,
                commandMatchers: [tilePilotFeatureURL("app.never-auto-tile")],
                matchAllCommandMatchers: false,
                preferredCommand: tilePilotFeatureCommand("app.never-auto-tile"),
                actionID: nil,
                isExperimental: false
            ),
            FeatureDefinition(
                id: "action.focus-left",
                group: .focus,
                title: "Focus Left",
                description: "Moves focus to the window on the left.",
                backend: .tilePilotAction,
                capabilityGate: .yabaiRuntime,
                defaultCombo: "alt - j",
                commandMatchers: ["yabai -m window --focus west"],
                matchAllCommandMatchers: false,
                preferredCommand: "yabai -m window --focus west",
                actionID: .focusWest,
                isExperimental: false
            ),
            FeatureDefinition(
                id: "action.focus-right",
                group: .focus,
                title: "Focus Right",
                description: "Moves focus to the window on the right.",
                backend: .tilePilotAction,
                capabilityGate: .yabaiRuntime,
                defaultCombo: "alt - l",
                commandMatchers: ["yabai -m window --focus east"],
                matchAllCommandMatchers: false,
                preferredCommand: "yabai -m window --focus east",
                actionID: .focusEast,
                isExperimental: false
            ),
            FeatureDefinition(
                id: "action.focus-up",
                group: .focus,
                title: "Focus Up",
                description: "Moves focus to the window above.",
                backend: .tilePilotAction,
                capabilityGate: .yabaiRuntime,
                defaultCombo: "alt - i",
                commandMatchers: ["yabai -m window --focus north"],
                matchAllCommandMatchers: false,
                preferredCommand: "yabai -m window --focus north",
                actionID: .focusNorth,
                isExperimental: false
            ),
            FeatureDefinition(
                id: "action.focus-down",
                group: .focus,
                title: "Focus Down",
                description: "Moves focus to the window below.",
                backend: .tilePilotAction,
                capabilityGate: .yabaiRuntime,
                defaultCombo: "alt - k",
                commandMatchers: ["yabai -m window --focus south"],
                matchAllCommandMatchers: false,
                preferredCommand: "yabai -m window --focus south",
                actionID: .focusSouth,
                isExperimental: false
            ),
        ]
        definitions.append(
            FeatureDefinition(
                id: Self.cycleWorkSetsFeatureID,
                group: .workSets,
                title: "Cycle Work Sets on This Desktop",
                description: "Activates the next Work Set on the current desktop and wraps back to the first one.",
                backend: .tilePilotAction,
                capabilityGate: .yabaiRuntime,
                defaultCombo: nil,
                commandMatchers: [tilePilotFeatureURL(Self.cycleWorkSetsFeatureID)],
                matchAllCommandMatchers: false,
                preferredCommand: tilePilotFeatureCommand(Self.cycleWorkSetsFeatureID),
                actionID: nil,
                isExperimental: false
            )
        )
        definitions.append(contentsOf: windowLayoutTemplates.map(templateFeatureDefinition))
        definitions.append(contentsOf: workSets.map(workSetFeatureDefinition))
        definitions.append(contentsOf: workSets.map(workSetAssignWindowFeatureDefinition))
        return definitions
    }

    func templateFeatureDefinition(_ template: WindowLayoutTemplate) -> FeatureDefinition {
        let featureID = templateFeatureID(for: template)
        return FeatureDefinition(
            id: featureID,
            group: .templates,
            title: "Apply Template: \(template.name)",
            description: "Applies this floating window template to the current desktop and auto-fits it when the display shape is slightly different.",
            backend: .tilePilotAction,
            capabilityGate: .yabaiRuntime,
            defaultCombo: nil,
            commandMatchers: [tilePilotFeatureURL(featureID)],
            matchAllCommandMatchers: false,
            preferredCommand: tilePilotFeatureCommand(featureID),
            actionID: nil,
            isExperimental: false
        )
    }

    func workSetFeatureDefinition(_ workSet: WorkSet) -> FeatureDefinition {
        let featureID = workSetFeatureID(for: workSet)
        let description: String
        switch workSet.layoutMode {
        case .stackOnly:
            description = "Activates this Work Set and brings its windows forward without changing their current positions."
        case .tiled:
            description = "Activates this Work Set and tiles only its windows on that desktop."
        case .template:
            description = "Activates this Work Set and places its matched windows into the linked template layout."
        }
        return FeatureDefinition(
            id: featureID,
            group: .workSets,
            title: "Activate Work Set: \(workSet.name)",
            description: description,
            backend: .tilePilotAction,
            capabilityGate: .yabaiRuntime,
            defaultCombo: nil,
            commandMatchers: [tilePilotFeatureURL(featureID)],
            matchAllCommandMatchers: false,
            preferredCommand: tilePilotFeatureCommand(featureID),
            actionID: nil,
            isExperimental: false
        )
    }

    func workSetAssignWindowFeatureDefinition(_ workSet: WorkSet) -> FeatureDefinition {
        let featureID = workSetAssignWindowFeatureID(for: workSet)
        return FeatureDefinition(
            id: featureID,
            group: .workSets,
            title: "Assign Focused Window to Work Set: \(workSet.name)",
            description: "Adds the focused window to this Work Set. From a window badge, it adds the clicked window instead.",
            backend: .tilePilotAction,
            capabilityGate: .none,
            defaultCombo: nil,
            commandMatchers: [tilePilotFeatureURL(featureID)],
            matchAllCommandMatchers: false,
            preferredCommand: tilePilotFeatureCommand(featureID),
            actionID: nil,
            isExperimental: false
        )
    }

    func featureDefinition(for entry: ShortcutEntry) -> FeatureDefinition? {
        let command = normalizedFeatureMatchCommand(entry.command.lowercased())
        return featureDefinitions.first { definition in
            guard !definition.commandMatchers.isEmpty else { return false }
            if definition.matchAllCommandMatchers {
                return definition.commandMatchers.allSatisfy { command.contains($0) }
            }
            return definition.commandMatchers.contains(where: { command.contains($0) })
        }
    }

    func normalizedFeatureMatchCommand(_ raw: String) -> String {
        FeatureCommandNormalizer.normalize(raw)
    }
}
