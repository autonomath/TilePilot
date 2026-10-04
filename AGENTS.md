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
- Keep app/UI/runtime state on `@MainActor`; use async `Task` work for helper and OS calls.
- Run yabai/skhd through the managed helper command wrappers with explicit timeouts; report command failures instead of assuming state changed.
- Treat yabai, WindowServer, and Accessibility as complementary sources. Verify live postconditions for limited/AX-only windows; yabai frame and resize flags can lag or disagree.
- Keep settings copy short and outcome-based. Say whether windows end tiled or floating; put teaching material in `How It Works`, not settings cards.
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
- UNVERIFIED: the current Command Line Tools-only environment compiles XCTest bundles but `swift test`, `swift test list`, and filtered tests execute/list zero tests. Select a full Xcode toolchain, then verify `swift test` and `swift test --filter RecentWindowGridPlannerTests` before claiming tests passed.
- UNVERIFIED: no project SwiftFormat/SwiftLint configuration or CI workflow exists. Repo-wide `swift format lint` emits thousands of default-style warnings and is not a usable gate.
- Release builds currently emit a Swift 6 Sendable-capture warning in the Templates drag/drop provider.
- Bundled skhd 0.3.9 builds with an existing deprecated FSEvents warning and an unused-function warning.
- Development notes still mention a user-facing Auto-Tiled picker mode; the current picker exposes Floating Grid and Template only.

## Maintenance
When you complete a task and discover this file is wrong or missing something an agent would need, update it. Keep it under 150 lines: prefer correcting existing lines over adding new ones. Do not add one-off fixes, task-specific notes, or anything already obvious from the code.
