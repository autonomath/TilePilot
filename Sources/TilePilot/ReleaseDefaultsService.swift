import Foundation

final class ReleaseDefaultsService: @unchecked Sendable {
    static let currentProfileVersion = "v0.4.24-defaults.3"

    private let fileManager = FileManager.default

    func currentProfile() -> ReleaseDefaultsProfile {
        ReleaseDefaultsProfile(
            profileVersion: Self.currentProfileVersion,
            userState: ReleaseDefaultsUserState(
                pinnedFeatureControlIDs: [
                    "app.keep-on-top-when-floating",
                    "app.never-auto-tile",
                    "screen.set-floating-all-visible",
                    "screen.grid-auto-tiled",
                    "screen.grid-floating",
                    "screen.rotate-layout",
                    "screen.balance-current-desktop",
                    "screen.bring-floating-front",
                ],
                pinnedDirectionalGroupIDs: [],
                shortcutsCustomOrderIDs: [
                    "directional.moveWindow",
                    "directional.resizeWindow",
                    "directional.focusWindow",
                ],
                windowLayoutTemplates: defaultWindowLayoutTemplates(),
                workSets: [],
                activeWorkSetIDsByScope: [:],
                showWindowBadgeOverlay: true,
                showWindowOutlineOverlay: true,
                windowOutlineOverlayBaseWidth: 1.0,
                tiledOverlayAccentColor: .tiledDefault,
                floatingOverlayAccentColor: .floatingDefault,
                desktopScrubEnabled: true,
                desktopScrubTriggerModifiers: DesktopScrubModifier.defaultSelection,
                desktopScrubTriggerCharacter: .none,
                desktopScrubSensitivity: 1.0,
                desktopScrubInvertDirection: true,
                raiseOnFloatToggleEnabled: true,
                appForegroundPolicyByName: [:],
                performanceSettings: .responsive
            ),
            configState: ReleaseDefaultsConfigState(
                managedSkhdSectionBody: defaultManagedSkhdSectionBody(),
                windowBehaviorPolicy: ManagedWindowBehaviorPolicy(
                    manualTilingModeEnabled: true,
                    hoverFocusMode: .off,
                    mouseFollowsFocusEnabled: false,
                    outerPadding: 0,
                    windowGap: 0,
                    mouseModifier: .alt,
                    mouseAction1: .move,
                    mouseAction2: .resize,
                    mouseDropAction: .swap,
                    neverTileApps: [],
                    alwaysTileApps: []
                )
            )
        )
    }

    func writeProfileSnapshotToDisk(_ profile: ReleaseDefaultsProfile) throws {
        let directory = defaultsDirectoryURL()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let data = try encoder.encode(profile)
        let versionFile = directory.appendingPathComponent("release-defaults-\(profile.profileVersion).json")
        let currentAlias = directory.appendingPathComponent("release-defaults-current.json")
        try data.write(to: versionFile, options: .atomic)
        try data.write(to: currentAlias, options: .atomic)
    }

    func hasLegacyUserDefaultsFootprint(_ defaults: UserDefaults = .standard) -> Bool {
        let keys = [
            "TilePilot.windowLayoutTemplates",
            "TilePilot.workSets",
            "TilePilot.activeWorkSetIDsByScope",
            "TilePilot.pinnedShortcutKeys",
            "TilePilot.pinnedDirectionalGroupIDs",
            "TilePilot.pinnedFeatureControlIDs",
            "TilePilot.shortcutsCustomOrderIDs",
            "TilePilot.showWindowBadgeOverlay",
            "TilePilot.showWindowOutlineOverlay",
            "TilePilot.windowOutlineOverlayBaseWidth",
            "TilePilot.tiledOverlayAccentColor",
            "TilePilot.floatingOverlayAccentColor",
            "TilePilot.desktopScrubEnabled",
            "TilePilot.desktopScrubTriggerModifiers",
            "TilePilot.desktopScrubTriggerCharacter",
            "TilePilot.desktopScrubSensitivity",
            "TilePilot.desktopScrubInvertDirection",
            "TilePilot.raiseOnFloatToggle",
            "TilePilot.appForegroundPolicyByName",
            "TilePilot.desktopTilingPreferencesBySpaceIndex",
            "TilePilot.performanceHideMinimizedHelperWindowsInMaps",
            "TilePilot.workAreas",
        ]
        return keys.contains { defaults.object(forKey: $0) != nil }
    }

    private func defaultManagedSkhdSectionBody() -> String {
        DefaultShortcutProfile.managedSkhdSectionBody()
    }

    private func defaultsDirectoryURL() -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/TilePilot/Defaults", isDirectory: true)
    }
}

enum DefaultShortcutProfile {
    // One modifier per scope: ⌥ goes, ⇧⌥ moves the window, ⌃⌥ sizes it, ⌃⇧⌥ changes the
    // whole desktop, ⌃⌥⇧⌘ (Hyper) is TilePilot. Hyper + a digit stays free for templates and Work Sets.
    static func managedSkhdSectionBody() -> String {
        """
        # Managed by TilePilot. Unknown lines outside this block are preserved.
        # Release default shortcuts. J K I L = left, down, up, right.
        # Option goes, Shift-Option moves the window, Control-Option sizes it,
        # Control-Shift-Option changes the whole desktop, Hyper opens TilePilot.

        # Focus
        alt - j : yabai -m window --focus west
        alt - l : yabai -m window --focus east
        alt - i : yabai -m window --focus north
        alt - k : yabai -m window --focus south

        # Window Placement
        shift + alt - j : yabai -m window --warp west
        shift + alt - l : yabai -m window --warp east
        shift + alt - i : yabai -m window --warp north
        shift + alt - k : yabai -m window --warp south

        # Window Size
        ctrl + alt - j : yabai -m window --resize left:-80:0
        ctrl + alt - l : yabai -m window --resize right:80:0
        ctrl + alt - i : yabai -m window --resize top:0:-80
        ctrl + alt - k : yabai -m window --resize bottom:0:80

        # Swap
        ctrl + shift + alt - j : yabai -m window --swap west
        ctrl + shift + alt - l : yabai -m window --swap east
        ctrl + shift + alt - i : yabai -m window --swap north
        ctrl + shift + alt - k : yabai -m window --swap south

        # Window
        # TILEPILOT_FEATURE action.toggle-float
        shift + alt - space : yabai -m window --toggle float
        # TILEPILOT_FEATURE screen.fill-work-area
        ctrl + alt - return : \(featureCommand("screen.fill-work-area"))

        # Desktops
        alt - 1 : /usr/bin/open -g "tilepilot://desktop/1"
        alt - 2 : /usr/bin/open -g "tilepilot://desktop/2"
        alt - 3 : /usr/bin/open -g "tilepilot://desktop/3"
        alt - 4 : /usr/bin/open -g "tilepilot://desktop/4"
        alt - 5 : /usr/bin/open -g "tilepilot://desktop/5"
        alt - 6 : /usr/bin/open -g "tilepilot://desktop/6"
        alt - 7 : /usr/bin/open -g "tilepilot://desktop/7"
        alt - 8 : /usr/bin/open -g "tilepilot://desktop/8"
        alt - 9 : /usr/bin/open -g "tilepilot://desktop/9"

        # Displays (O = other display, wrapping around)
        alt - o : yabai -m display --focus next || yabai -m display --focus first
        shift + alt - o : yabai -m window --display next || yabai -m window --display first

        # Whole Desktop
        # TILEPILOT_FEATURE screen.set-tiled-all-visible
        ctrl + shift + alt - t : \(featureCommand("screen.set-tiled-all-visible"))
        # TILEPILOT_FEATURE screen.set-floating-all-visible
        ctrl + shift + alt - f : \(featureCommand("screen.set-floating-all-visible"))
        # TILEPILOT_FEATURE screen.grid-auto-tiled
        ctrl + shift + alt - b : \(featureCommand("screen.grid-auto-tiled"))
        # TILEPILOT_FEATURE screen.grid-floating
        ctrl + shift + alt - g : \(featureCommand("screen.grid-floating"))
        # TILEPILOT_FEATURE screen.rotate-layout
        ctrl + shift + alt - r : yabai -m space --rotate 90
        # TILEPILOT_FEATURE action.layout-stack
        ctrl + shift + alt - s : yabai -m space --layout stack
        # TILEPILOT_FEATURE screen.pick-windows-to-tile
        ctrl + shift + alt - p : \(featureCommand("screen.pick-windows-to-tile"))
        # TILEPILOT_FEATURE screen.bring-floating-front
        ctrl + shift + alt - u : \(featureCommand("screen.bring-floating-front"))
        # TILEPILOT_FEATURE screen.balance-current-desktop
        alt - 0 : yabai -m space --balance

        # TilePilot
        # TILEPILOT_FEATURE app.open-tilepilot
        ctrl + shift + alt + cmd - t : /usr/bin/open -a "TilePilot"
        # TILEPILOT_FEATURE app.open-megamap
        ctrl + shift + alt + cmd - m : \(featureCommand("app.open-megamap"))
        # TILEPILOT_FEATURE app.toggle-work-area
        ctrl + shift + alt + cmd - a : \(featureCommand("app.toggle-work-area"))
        # TILEPILOT_FEATURE workset.cycle-current-desktop
        ctrl + shift + alt + cmd - s : \(featureCommand("workset.cycle-current-desktop"))
        # TILEPILOT_FEATURE app.keep-on-top-when-floating
        ctrl + shift + alt + cmd - k : \(featureCommand("app.keep-on-top-when-floating"))
        # TILEPILOT_FEATURE app.never-auto-tile
        ctrl + shift + alt + cmd - n : \(featureCommand("app.never-auto-tile"))

        # Desktop Move (Experimental)
        shift + alt - 1 : yabai -m window --space 1 --focus
        shift + alt - 2 : yabai -m window --space 2 --focus
        shift + alt - 3 : yabai -m window --space 3 --focus
        shift + alt - 4 : yabai -m window --space 4 --focus
        shift + alt - 5 : yabai -m window --space 5 --focus
        shift + alt - 6 : yabai -m window --space 6 --focus
        shift + alt - 7 : yabai -m window --space 7 --focus
        shift + alt - 8 : yabai -m window --space 8 --focus
        shift + alt - 9 : yabai -m window --space 9 --focus
        """
    }

    private static func featureCommand(_ featureID: String) -> String {
        "/usr/bin/open -g \"tilepilot://feature/\(featureID)\""
    }
}
