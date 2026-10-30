# TilePilot
Native macOS window-workflow app that makes yabai/skhd tiling, floating layouts, shortcuts, templates, and same-desktop Work Sets approachable through a GUI.

## Stack
- Swift tools 6.2; verified with Apple Swift 6.2.3.
- SwiftUI application with AppKit, ApplicationServices/Accessibility, CoreGraphics, and Combine.
- macOS 13+; Swift Package Manager; no third-party Swift package dependencies or lockfile.
- Packaged helpers: yabai 7.1.17 and skhd 0.3.9, fetched from pinned checksummed sources.

## Setup
```bash
swift --version                  # require Swift 6.2+
swift package resolve
swift build
```

Packaging also requires `curl`, `tar`, `shasum`, `make`, `clang`, `codesign`, `sips`, and `iconutil`; the packaging script checks or conditionally uses them.

## Commands
```bash
swift build

# Build a disposable app without installing, opening, or using a Developer ID.
scripts/package_dev_app.sh --no-install --no-open --no-sign

# Build, sign or ad-hoc sign, replace /Applications/TilePilot.app, and relaunch it.
scripts/package_dev_app.sh

# Build a local release DMG without signing the DMG itself.
scripts/build_release_dmg.sh --version v0.0.0 --no-sign-dmg

git diff --check

# Use the existing code graph before broad source searches; update it after code changes.
graphify query "<codebase question>"
graphify update .
```

## Conventions
- Public releases and the website use `autonomath/TilePilot` on `main`; `origin` may still point to legacy private `nostitos/TilePilot` on `master`. Fetch the public branch and check its latest release before choosing a version or preparing release source.
- Keep app/UI/runtime state on `@MainActor`; use async `Task` work for helper and OS calls.
- The main window is found by its title (`hasOnScreenTilePilotWindow` looks for "TilePilot"). Every tab that shows live window data must keep `.navigationTitle("TilePilot")`, or its live state stops updating.
- Run yabai/skhd through the managed helper command wrappers with explicit timeouts; report command failures instead of assuming state changed.
- Treat yabai, WindowServer, and Accessibility as complementary sources. Verify live postconditions for limited/AX-only windows; yabai frame and resize flags can lag or disagree.
- Mission Control, App Exposé, Show Desktop, and their animations move and scale window-server bounds (`CGWindowListCopyWindowInfo`) while Accessibility frames stay put. Never move or resize a window from window-server bounds alone; containment re-reads the real frame by window ID (`AccessibilityWindowFrames`) first.
- Keep settings copy short and outcome-based. Say whether windows end tiled or floating; put teaching material in the section's ⓘ help (`ContextHelpTopic` in `Shared/ContextHelp.swift`, shown with `HelpSectionLabel` or `ContextHelpButton`), not in settings cards. There is no separate help tab.
- Preserve existing user behavior by default. Defaults changes require a release-default profile version bump and reset-flow coverage.
- Present Guided Setup immediately on a genuine first launch; startup readiness grace applies only to existing installations recovering after launch or login.
- Add focused XCTest coverage for pure models/planners and regressions when the test runner is available.
- Use commit subjects such as `feat:`, `fix:`, `perf:`, `build:`, `docs:`, or `release:` followed by a concise imperative summary.
- After app code changes, run the package/install command and verify the new `/Applications` process is running; a successful Swift build is not a live-app update.

## Domain concepts
- **Desktop / Space:** a macOS Space. Runtime scope usually combines display identity with Space index; display numbering can change when monitor arrangement changes.
- **Tiled:** yabai manages placement in a BSP/stack layout. **Floating:** TilePilot/yabai moves and resizes windows without adding them to the tiled tree.
- **Never Auto-Tile:** app-level rule excluding an app from tiled-result bulk actions; it does not block floating Templates.
- **Template:** normalized floating slot geometry for a display shape, optionally constrained by app allow-lists and z-order.
- **Work Set:** desktop-scoped exact-window membership and front-to-back order, optionally with a backdrop and Floating, Tile, or Template layout mode. It is not a macOS Space.
- **Work Area:** per-display rectangle (keyed by display UUID, stored as display fractions) that bounds placement. Tiled windows use runtime per-Space yabai padding (never written to `yabairc`); floating windows are moved back after a drag ends. `AppModel.placementFrame(for:)` is the shared bound for Grid, Templates, and Work Sets.
- **System Bar:** optional per-Work-Area mirror of the menu bar (`WorkAreaConfiguration.systemBarEnabled`): a non-activating `NSPanel` above (or inside) the area showing the frontmost app's menu titles and the mirrored display's menu bar icons (other displays' icons are opt-in), read through `AccessibilityMirrorReader`. Menus pop locally; third-party icons get a real click at the real icon because many apps ignore `AXPress`, and their panels open where macOS puts them (Phase 2 would mirror them). Icons crop pixels from `MenuBarStripCapture` (ScreenCaptureKit, memory only) when Screen Recording is on, otherwise draw symbols/app icons; copies from an inactive display's bar are undimmed by `SystemBarIconBrightness`, and icon scans are driven by events and by `SystemBarLayoutSignature` instead of a fast poll. `resolvedWorkArea(for:)` returns the window area under the bar.
- **Limited window:** visible window that cannot be managed reliably through normal yabai state; AX fallback may still support selected operations.
- **MegaMap:** per-display overview of multiple desktops. Captured screenshots are session-memory-only.
- **Managed config:** only content between `TILEPILOT MANAGED` / `TILEPILOT YABAI CONFIG` markers belongs to TilePilot.

## Boundaries
- Never overwrite user `yabairc` or `skhdrc` content outside TilePilot-managed markers.
- Never start yabai/skhd or request a macOS permission before an explained, explicit user action; passive checks must use non-prompting APIs.
- Never persist MegaMap or desktop screenshots to disk.
- Do not hand-edit generated `.build`, `dist`, or `graphify-out` contents; regenerate them with their owning command.
- Do not commit signing passwords, Apple IDs, notary credentials, or local keychain details. Release credentials belong in Keychain profiles/environment variables.
- Do not change SIP, install/load the yabai scripting addition, notarize, publish, tag, or create a GitHub release unless explicitly requested.
- Preserve unrelated dirty-worktree changes. Do not reset or restore files you did not own.

## Known issues
- The selected Command Line Tools compile XCTest bundles but list/execute zero tests. Run XCTest with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test -Xswiftc -swift-version -Xswiftc 5 -Xswiftc -enable-bare-slash-regex` and check the executed count; Xcode's newer compiler turns the Templates drag/drop Sendable warning into an error in Swift 6 mode.
- UNVERIFIED: no project SwiftFormat/SwiftLint configuration or CI workflow exists. Repo-wide `swift format lint` emits thousands of default-style warnings and is not a usable gate.
- Builds currently emit a Swift 6 Sendable-capture warning in the Templates drag/drop provider.
- Bundled skhd 0.3.9 builds with an existing deprecated FSEvents warning and an unused-function warning.
- Development notes still mention a user-facing Auto-Tiled picker mode; the current picker exposes Floating Grid and Template only.
- Native full screen is unsupported with an active Work Area: containment can pull a window out of full screen. The user chose title-bar double-click (zoom, then fit to the Work Area) instead; do not spend effort on full-screen support unless asked.
- Do not restart yabai while the Mac is locked: it comes back without Accessibility references for existing windows (`has-ax-reference` false, empty role, `can-move` false, stale frames). Work Area containment falls back to Accessibility and window-server frames for such windows, but other features degrade until yabai restarts while unlocked.
- Menu bar icon (`AXExtrasMenuBar`) frames point at the active display's bar even when the icon is only drawn on another display (most third-party icons live on the main display's bar). Confirm positions by hit test, matching the hit element's `AXIdentifier` or icon container, never just the pid. On an inactive bar an icon answers with its app's own `AXMenuBar`, the same role empty stretches answer with; see `docs/research/SYSTEM_BAR_FEASIBILITY.md`.

## Maintenance
When you complete a task and discover this file is wrong or missing something an agent would need, update it. Keep it under 150 lines: prefer correcting existing lines over adding new ones. Do not add one-off fixes, task-specific notes, or anything already obvious from the code.
