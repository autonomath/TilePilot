import Foundation

final class ReleaseDefaultsService: @unchecked Sendable {
    static let currentProfileVersion = "v0.4.9-defaults.1"

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

    func loadLastSnapshotIfPresent() -> ReleaseDefaultsProfile? {
        let currentAlias = defaultsDirectoryURL().appendingPathComponent("release-defaults-current.json")
        guard fileManager.fileExists(atPath: currentAlias.path) else { return nil }
        guard let data = try? Data(contentsOf: currentAlias) else { return nil }
        return try? JSONDecoder().decode(ReleaseDefaultsProfile.self, from: data)
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
    static func managedSkhdSectionBody() -> String {
        """
        # Managed by TilePilot. Unknown lines outside this block are preserved.
        # Release default shortcuts:

        # Desktops
        alt - 1 : yabai -m space --focus 1
        alt - 2 : yabai -m space --focus 2
        alt - 3 : yabai -m space --focus 3
        alt - 4 : yabai -m space --focus 4
        alt - 5 : yabai -m space --focus 5
        alt - 6 : yabai -m space --focus 6
        alt - 7 : yabai -m space --focus 7
        alt - 8 : yabai -m space --focus 8
        alt - 9 : yabai -m space --focus 9

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

        # Tiling & Layout
        # TILEPILOT_FEATURE screen.set-floating-all-visible
        ctrl + shift + alt - d : \(featureCommand("screen.set-floating-all-visible"))
        # TILEPILOT_FEATURE screen.set-tiled-all-visible
        ctrl + shift + alt - e : \(featureCommand("screen.set-tiled-all-visible"))
        # TILEPILOT_FEATURE screen.grid-floating
        ctrl + shift + alt - p : \(featureCommand("screen.grid-floating"))
        # TILEPILOT_FEATURE screen.grid-auto-tiled
        ctrl + shift + alt - o : \(featureCommand("screen.grid-auto-tiled"))
        # TILEPILOT_FEATURE screen.rotate-layout
        shift + alt - r : yabai -m space --rotate 90
        # TILEPILOT_FEATURE action.layout-stack
        shift + alt - v : yabai -m space --layout stack
        # TILEPILOT_FEATURE screen.layout-bsp-balance
        ctrl + shift + alt - g : yabai -m space --layout bsp; yabai -m space --balance
        # TILEPILOT_FEATURE screen.balance-current-desktop
        alt - 0 : yabai -m space --balance
        # TILEPILOT_FEATURE action.toggle-float
        ctrl + shift + alt - ~ : yabai -m window --toggle float

        # Desktop Move (Experimental)
        shift + alt - 1 : yabai -m window --space 1; yabai -m space --focus 1
        shift + alt - 2 : yabai -m window --space 2; yabai -m space --focus 2
        shift + alt - 3 : yabai -m window --space 3; yabai -m space --focus 3
        shift + alt - 4 : yabai -m window --space 4; yabai -m space --focus 4
        shift + alt - 5 : yabai -m window --space 5; yabai -m space --focus 5
        shift + alt - 6 : yabai -m window --space 6; yabai -m space --focus 6
        shift + alt - 7 : yabai -m window --space 7; yabai -m space --focus 7
        shift + alt - 8 : yabai -m window --space 8; yabai -m space --focus 8
        shift + alt - 9 : yabai -m window --space 9; yabai -m space --focus 9
        """
    }

    private static func featureCommand(_ featureID: String) -> String {
        "/usr/bin/open -g \"tilepilot://feature/\(featureID)\""
    }
}
