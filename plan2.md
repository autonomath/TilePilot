# plan2.md — Auto Layout Rename + Grid Behavior

## Update — Unified Feature Shortcuts

1. Screen-wide controls are treated as first-class shortcut features in `Actions & Shortcuts`.
2. Right-click menu label is `Open Shortcuts` (replacing `Open Controls`).
3. Screen-wide controls are no longer injected as a hardcoded always-on block in the menu.
4. Pinning now supports feature IDs, so pinned items stay stable across command text drift.
5. Shortcut assignment for unified features is written to the TilePilot-managed `skhdrc` section.
6. Shortcut conflicts are blocked with suggested alternatives.

## Update — Release Defaults System

1. Added a versioned release defaults profile (app state + managed config defaults).
2. Fresh install applies release defaults once.
3. Upgrades keep user settings unchanged.
4. Added `Reset to Release Defaults` action in `System` (and secondary access in `Config Files`).
5. Release-default snapshots are written to:
   - `~/Library/Application Support/TilePilot/Defaults/`

## What changed

1. Replaced `readable-current-space.sh` behavior with a grid-first implementation under:
   - `~/.config/yabai/scripts/auto-layout-current-desktop.sh`
2. Updated `Shift + Option + M` in `skhdrc` to call the new script.
3. Kept backward compatibility:
   - `~/.config/yabai/scripts/readable-current-space.sh` is now a wrapper alias to the new script.
4. Updated TilePilot shortcut title mapping:
   - `Auto Layout (Current Desktop)`

## Behavior contract

- Uses visible, non-minimized, non-hidden windows from current desktop.
- Filters to packable windows (`can-move`, `can-resize`, non-native-fullscreen).
- Applies deterministic near-square grid placement.
- Leaves packed windows floating.
- Never switches to stack layout.

## Rationale

The previous `>4 => stack` behavior is not appropriate for large displays and produces low-utility single-window emphasis. The new behavior is density-oriented and monitor-size friendly.
