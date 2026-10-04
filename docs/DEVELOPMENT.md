# TilePilot Development Notes

## Related Docs

- GUI and design context: `docs/GUI_DESIGN_CONTEXT.md`
- Product requirements: `PRD.md`

## Breaking Shortcut Change (Directional Cluster)

As of 2026-02-26, TilePilot's recommended directional shortcut layout is `IJKL` (instead of `HJKL`) for focus/move/resize patterns.

If you are testing against an older local setup that still uses `HJKL`, expect mismatches in screenshots, docs, and shortcut-learning UI until `skhdrc` is updated.

## Build

```bash
swift build
```

## Recent Window Picker Notes

The `Pick Windows to Tile...` feature is a first-class action backed by:

- model/state: `Sources/TilePilot/Models/RecentWindowTilerModels.swift`
- runtime/apply logic: `Sources/TilePilot/AppModel+RuntimeWindowDesktopActions.swift`
- panel controller: `Sources/TilePilot/RecentWindowTilerWindowController.swift`
- SwiftUI panel: `Sources/TilePilot/Features/RecentWindowTiler/RecentWindowTilerPickerView.swift`
- regression tests: `Tests/TilePilotTests/RecentWindowGridPlannerTests.swift`

Important behavior:

- first open selects 4 windows
- later opens select the last chosen count from `UserDefaults`
- picker order is placement order
- `Floating Grid` is the default mode
- spare grid cells are filled with vertical spans where possible
- AX-only windows can be placed by Floating Grid when Accessibility can move and resize them
- `Auto-Tiled` remains real yabai tiling and cannot include AX-only windows that yabai cannot manage

Run the focused picker/grid tests with:

```bash
swift test --filter RecentWindowGridPlannerTests
```

## Run (SwiftPM executable)

```bash
swift run TilePilot
```

Note: for Accessibility/TCC behavior, prefer running the packaged app from `/Applications/TilePilot.app`.

## Package / Install / Relaunch

```bash
scripts/package_dev_app.sh
```

Default behavior:
- installs to `/Applications/TilePilot.app`
- relaunches the installed app

## Release DMG

Build a release app bundle and package a drag-and-drop DMG:

```bash
scripts/build_release_dmg.sh --version v0.2.11
```

Output artifact:

- `dist/TilePilot-v0.2.11.dmg`

To notarize the release DMG, first store a `notarytool` keychain profile, then run:

```bash
xcrun notarytool store-credentials TilePilot \
  --apple-id "<apple-id>" \
  --team-id "RJL9XWBZ9L" \
  --password "<app-specific-password>" \
  --keychain "$HOME/Library/Keychains/login.keychain-db"

TILEPILOT_NOTARY_PROFILE=TilePilot \
TILEPILOT_NOTARY_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db" \
scripts/build_release_dmg.sh --version v0.2.11 --notarize
```

That will:
- submit the DMG to Apple notarization
- wait for the result
- staple the notarization ticket to the DMG
- run a Gatekeeper assessment afterward

The DMG uses:

- custom background image: `assets/dmg/dmg-background.png`
- icon layout generated via Finder scripting in `scripts/build_release_dmg.sh`

Regenerate DMG background art:

```bash
scripts/generate_dmg_background.sh
```

## Signing

Use a local `Developer ID Application` certificate installed in your keychain.

Verify identities:

```bash
security find-identity -v -p codesigning
```

Developer ID signing alone is not enough to avoid Gatekeeper warnings. Release artifacts must also be notarized.

## Config Markers

TilePilot-managed blocks use:
- `TILEPILOT MANAGED ...` in `skhdrc`
- `TILEPILOT YABAI CONFIG ...` in `yabairc`

## Release Defaults Checklist

For each release that changes defaults:

1. Bump `ReleaseDefaultsService.currentProfileVersion`.
2. Update `ReleaseDefaultsService.currentProfile()` content (pins/toggles/managed defaults).
3. Launch the packaged app once and verify snapshot files are written under:
   - `~/Library/Application Support/TilePilot/Defaults/`
4. Verify:
   - fresh install applies profile on first launch,
   - existing install does not auto-overwrite,
   - `Reset to Release Defaults` reapplies latest profile.
5. Put behavior-impacting defaults changes in release notes.

## Scripting Addition / SIP Support Notes (for TilePilot UX)

Desktop shortcuts that feel "basic" to users often depend on `yabai`'s scripting addition, including:
- desktop switching (e.g. `Option + 1`)
- moving a window to another desktop (e.g. `Shift + Option + 1`)

If those shortcuts fail but `skhd` is clearly firing, check for errors like:
- `cannot focus space due to an error with the scripting-addition.`

### Why TilePilot treats this as core UX now

Even though scripting-addition setup is technically an advanced `yabai` capability, the user-visible features it unlocks (switching desktops / moving windows between desktops) are common workflows. TilePilot Health/Setup should surface this as a core capability, not hide it behind "advanced features" wording.

### Version-specific command reality

Do not assume a single scripting-addition install command exists across all `yabai` versions.

Examples:
- `yabai v7.1.17` exposes `--load-sa` and `--uninstall-sa`
- some guides/versions reference separate `--install-sa` and `--load-sa`

TilePilot's repair script should inspect `yabai --help` and choose the supported command automatically.

### SIP guidance in docs/UI

When documenting or surfacing fixes:
- explain that SIP changes are a security tradeoff
- explain that TilePilot cannot modify SIP itself
- point users to Recovery Mode + official yabai documentation
- explain that macOS updates may break scripting-addition support
