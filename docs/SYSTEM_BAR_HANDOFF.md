# System Bar and Notification Mirror — Handoff Plan

Status on 2026-10-21: **Phase 0 (S1–S3, S6) and Phase 1 implemented, installed, uncommitted.** Phases 2–4 are open. Results, measurements, and the icon-position problem found on this Mac are in `docs/research/SYSTEM_BAR_FEASIBILITY.md`; Phase 1 notes are in section 13. This builds on the Work Area feature, which is implemented and running in this worktree but not committed. Everything below was written so another agent can continue without the original chat.

## 1. What the user wants

The user's external monitor (SAMSUNG, 3840 × 2160 at 1× scaling) is too large to use comfortably. Custom resolutions through BetterDisplay were not reliable. The first answer was the **Work Area**: a smaller per-display rectangle where TilePilot keeps windows. That part is done (section 3).

The user then asked, in their words: *"For the top notifications and status bars, what if we replicate their view and click-aim in the constrained work area?"* After v1 was scoped to the Work Area alone, they asked: *"Plan the top menu and notification area. No idea why you dropped this entirely."* It was deferred, not rejected. It is the next feature.

**Goal:** everything the user normally reaches at the top of the real screen is available at the edge of the Work Area — the app menus, the menu bar icons, and notification banners — and clicks act on the real thing.

**Success criteria (what the user should observe):**

1. A bar that looks like the real menu bar sits directly above the Work Area on the Samsung.
2. Clicking an app menu title opens that app's real menu contents right there. Choosing an item does what the real menu does. The frontmost app does not change.
3. Menu bar icons look like the real ones. Clicking one opens its menu or panel next to the bar, inside the Work Area, and the menu or panel works.
4. Notification banners appear at the top-right of the Work Area as well. On this Mac they normally appear on the laptop display, far from the Samsung. Clicking a mirrored banner acts on the original, and closing it closes the original.
5. No Work Area regressions, nothing captured is written to disk, and no permission prompt appears without an explicit user click.

**Out of scope by user decision:** native full screen support, permanently ("Leave full screen support for another time - ever"). The user resizes windows by double-clicking the title bar instead, and Work Area containment shrinks the window to the area. Dimming outside the Work Area is a separate later item. Hiding or moving the real menu bar or the real banners is impossible with public APIs, so the mirror adds to them.

## 2. Decisions already made

| Decision | Source |
|---|---|
| Work Area v1 shipped without the bar; the bar is the next feature | User picked "Work Area only" for v1, then asked for this plan |
| Work Area has its own tab | User |
| Floating windows are kept inside automatically after a drag ends | User |
| Native full screen is never supported | User |
| Title-bar double-click → window fills the screen → TilePilot fits it to the Work Area | User; implemented |
| Hybrid design: semantic Accessibility actions first, pixel mirroring only where needed | Proposed in the first answer, not contested |

Defaults this plan chooses where the user has not answered are listed in section 10. Use them unless the user overrides them.

## 3. Current state of the codebase

### 3.1 Work Area (implemented, installed, uncommitted)

New files:

- `Sources/TilePilot/Models/WorkAreaModels.swift` — `WorkAreaConfiguration` (per display, keyed by display UUID with a same-size fallback, normalized rect, `enabled`, `containmentEnabled`, `excludedApps`), presets, `WorkAreaPadding`, `WorkAreaUnfitWindow`, `WorkAreaFitBatch`.
- `Sources/TilePilot/Models/WorkAreaGeometry.swift` — pure math: `resolve`, `yabaiPadding`, `containedFrame`, `isContained`, `fillFrame`, `topLeftRect(fromAppKit:primaryScreenMaxY:)`, `clampedNormalizedRect`, `suggestedNormalizedRect`.
- `Sources/TilePilot/AppModel+WorkArea.swift` — lookup (`workAreaConfiguration(for:)`, `workAreaVisibleFrame(for:)`, `resolvedWorkArea(for:)` line ~101, `placementFrame(for:)` line ~116), editing APIs, runtime (`applyWorkAreaRuntimeIfNeeded` line ~261, `applyWorkAreaPaddingIfNeeded` line ~287), `moveWindowForWorkArea` (yabai resize+move with readback, AX fallback), undo, `fillFocusedWindowToWorkArea`, template capture helper.
- `Sources/TilePilot/Infrastructure/WorkAreaContainmentCoordinator.swift` — floating-window containment, candidate rules (`isCandidate`), a 30 s cooldown after two failed fits, and a global mouse monitor that checks after drags, long presses, and double-clicks.
- `Sources/TilePilot/Features/WorkArea/WorkAreaDashboardView.swift` — the tab: display picker, a canvas where you drag, resize, or draw the area, point fields, presets, behavior card, exceptions.
- Tests: `Tests/TilePilotTests/WorkAreaGeometryTests.swift` and `WorkAreaModelsTests.swift`.

Edited files: `AppModel.swift` (stored properties, `workAreasDefaultsKey = "TilePilot.workAreas"`, `TilePilotActionID.fillWorkArea`, and the hook in `refreshLiveState()` at line ~802), `AppModel+RuntimeWindowDesktopActions.swift` (Floating Grid, Templates, Work Set moves, and the window picker use `placementFrame(for:)`; `setWindowFrameUsingAccessibility` is now internal), `AppModel+BehaviorConfig.swift` (saving behavior resets global padding, so the padding cache is invalidated), `AppModel+SystemStatus.swift` (3 s idle polling while containment is active), feature registry and shortcut execution (`screen.fill-work-area`, `app.toggle-work-area`), `TilePilotActionCatalog.swift`, `StatusBarController.swift` (Work Area menu items and the `tilepilot://internal/open-tab/work-area` route), `TilePilotApp.swift` (tab), `YabaiStateService.swift` and `LiveStateModels.swift` (`DisplayState.uuid`, `WindowState.isNativeFullscreen`), release-defaults models/service (resetting clears Work Areas), `AppModel+Templates.swift` (captured slots are relative to the Work Area), `HowItWorksDashboardView.swift`, and `AGENTS.md`.

How it works: tiled windows stay inside through per-Space yabai padding applied at runtime. It is never written to `yabairc`. Floating windows are moved back after a drag ends, a long press, or a double-click, and on each refresh. Candidates are standard windows on visible Spaces, excluding dialogs, TilePilot's own windows, excluded apps, and windows on the session allow list. `placementFrame(for:)` is the shared bound for every placement feature.

Live evidence on the Samsung, where the Work Area is 2560 × 1440 in the lower center and resolves to `(-47,-1620,2560,1440)` while the display sits at x = -687:

- **Padding:** desktop 3 shows top 510, bottom 180, left 640, right 640. The top includes a 30 pt menu bar.
- **Containment:** eight windows were pulled inside and the tall ones were shortened. A window pushed out came back within 5 s.
- **Fill Work Area:** produced exactly 2560 × 1440.
- **Floating Grid and the Browsers template:** both landed exactly inside the area.
- **Toggle:** turning it off restored padding 0, and turning it on restored the values above.
- **Simulated zoom:** a 3840 × 2130 window was fitted to the area within 4 s.

Not verified with real input: an actual mouse drag or title-bar double-click, because Computer Use was broken (section 4). The same applies to the tab's controls and the Work Area menu bar items.

Known limitations: padding stays in yabai after TilePilot quits, until yabai restarts or the area is turned off. Native full screen is unsupported; containment can pull a window out of full screen. The user accepted this.

### 3.2 Worktree hygiene

- Branch `master`, HEAD `095aff3`. About 63 dirty or untracked paths, most of them from **other sessions**. Never reset, restore, or revert files you did not change.
- Work Area changes share five files with other sessions' uncommitted work: `AppModel.swift`, `AppModel+RuntimeWindowDesktopActions.swift`, `StatusBarController.swift`, `YabaiStateService.swift`, and `AGENTS.md`. A clean commit needs hunk-level staging. Nothing has been committed. Ask the user before committing anything that is not yours.
- `.playwright-mcp/` in the repo root is a leftover from a preview check. It can be deleted. Note that `rm -rf` style commands are blocked in this harness.

### 3.3 Build, test, install

```bash
swift build                                   # Command Line Tools toolchain; only known warning is TemplatesDashboardView.swift:1463
scripts/package_dev_app.sh                    # installs /Applications/TilePilot.app and relaunches it
pgrep -fl '/Applications/TilePilot.app/Contents/MacOS/TilePilot'
dwarfdump --uuid /Applications/TilePilot.app/Contents/MacOS/TilePilot .build/debug/TilePilot   # UUIDs must match
```

The test target has **pre-existing** problems unrelated to the Work Area. `OverviewPreviewBuilderTests.swift` is stale against the current source. `ManagedHelperLaunchPolicyTests.swift` (untracked) has an unhandled throw. Xcode's compiler rejects `TemplatesDashboardView.swift:1463` in Swift 6 mode. One test, `AppUpdateModelsTests.testVersionComparisonPadsMissingComponents`, fails because of another session's change. Run the suite in a temporary copy:

```bash
TPDIR=$(mktemp -d /tmp/tilepilot-tests.XXXXXX) && rsync -a --exclude .build --exclude graphify-out --exclude dist --exclude .git \
  --exclude Tests/TilePilotTests/OverviewPreviewBuilderTests.swift --exclude Tests/TilePilotTests/ManagedHelperLaunchPolicyTests.swift ./ "$TPDIR"/ \
  && cd "$TPDIR" && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test -Xswiftc -swift-version -Xswiftc 5 -Xswiftc -enable-bare-slash-regex
```

Baseline: **164 tests executed**, with one failure in `AppUpdateModelsTests`. Always report the executed count; Command Line Tools runs zero tests.

After code changes, run `graphify update .`.

### 3.4 Code to reuse

- **Overlay panels:** `WindowBadgeOverlayController.createPanel` (borderless + `.nonactivatingPanel`, clear background, `collectionBehavior` of fullScreenAuxiliary/moveToActiveSpace/ignoresCycle/transient/stationary) and `WorkSetBackdropController.createPanel`.
- **TilePilot is an accessory app:** `LSUIElement` is true, and `StatusBarController` calls `NSApp.setActivationPolicy(.accessory)`. Menus popped from a **non-activating** panel keep the frontmost app frontmost. A popover or normal window would activate TilePilot and end menu tracking. Phase 0 must confirm this.
- **Screen Recording:** `MegamapCaptureService.screenRecordingAuthorized()` and `requestScreenRecordingAccess()`, plus `AppModel.requestScreenRecordingAccessPrompt()` (`AppModel+SystemActions.swift` ~281). Captures stay in memory (`MegamapTransientCaptureStore`). MegaMap uses `CGDisplayCreateImage`; use ScreenCaptureKit for new work.
- **Event taps:** `NativeSpacesScrubSpikeCoordinator` (~line 245, session tap, head insert, default tap, re-enabled on timeout) and `ShortcutRecordingSession` (`MainActor.assumeIsolated` inside callbacks).
- **Spike pattern:** an internal deep link plus a research note. Example: `tilepilot://internal/native-spaces-scrub-spike`, gated by `experimentalNativeSpacesScrubSpikeEnabled`, documented in `docs/research/NATIVE_SPACES_SCRUB_FEASIBILITY.md`. Routing lives in `StatusBarController.handleDeepLink`.
- **Other helpers:** `AppNameWithIconView`; the existing quick menu built in `StatusBarController.presentQuickMenu()`.

## 4. Environment facts on the user's Mac (verified 2026-10-21)

- **System:** macOS 27.0.1 (26A434). Xcode is installed with its license accepted; Command Line Tools is the selected toolchain.
- **Displays:** built-in `(0,0,2294×1432)`, which is the main display, with the Dock at the bottom. SAMSUNG is 3840×2160, positioned above it, at `(-687,-2160)` in yabai's top-left coordinates.
- **Separate Spaces is on** (`spans-displays = 0`), so there are **two menu bars**: WindowServer windows named `Menubar` at layer 24, Samsung `(-687,-2160,3840×30)` and built-in `(0,0,2294×30)`. TilePilot sees the Samsung's visible frame as 30 pt shorter at the top. A command-line `NSScreen` probe reported no menu bar there; trust the app.
- **The Samsung switches identities.** During testing it alternated between two display UUIDs, one at x = -687 and one at x = -614. Once, macOS moved its windows to the laptop. BetterDisplay and Lunar, which restarted during testing, are running and are the likely cause. Re-resolve geometry on every refresh and on `NSApplication.didChangeScreenParametersNotification`. The Work Area follows through its same-size fallback match.
- **Notification banners appear on the built-in display, top-right**, owned by `com.apple.notificationcenterui`. The window owner name is localized ("Notification Centre"); the AX title is "Notification Center". Match by bundle ID.
- **Notification testing:** a Focus menu bar item exists, and Focus may suppress banners. A test `osascript -e 'display notification …'` never appeared, probably because Script Editor lacks notification permission or Focus was on.
- **yabai** is the Homebrew/asmvik build at `/opt/homebrew/bin/yabai`, run by the launch agent `com.asmvik.yabai`, not TilePilot's managed helper.
  - It **hung once** after `yabai -m window --toggle native-fullscreen` and recovered with `yabai --restart-service`. Never toggle native full screen.
  - Wrap queries so they cannot hang the shell: `perl -e 'alarm 5; exec @ARGV' yabai -m query …`.
- **Computer Use fails** with "Sky Computer Use native pipe closed before response". This also happened in September. Try it once; if it fails, verify with yabai, Accessibility probes, and screenshots, and ask the user to make real clicks.
  - Screenshot command: `python3 ~/.codex/skills/screenshot/scripts/take_screenshot.py --app TilePilot --path <abs.png>`.
  - Display capture: `screencapture -x -D 2 <abs.png>`.
- **Permissions:** the Codex shell is **Accessibility-trusted and has Screen Recording**, so standalone Swift probes compiled with `swiftc` can read Accessibility and capture the screen. Event taps from such binaries are unverified. TilePilot itself has Accessibility, and Screen Recording is already authorized for MegaMap.

## 5. What macOS exposes (read-only probes on this Mac)

### 5.1 App menus

The frontmost app is `AXUIElementCreateApplication(pid)` → `kAXMenuBarAttribute` → `AXMenuBarItem` children. Each item has a title, a frame on the active menu bar, and actions `AXPress`, `AXCancel`, and `AXPick`. Its `AXMenu` child lists `AXMenuItem`s **without opening the menu**. Sample from Chrome:

| Menu | Frame | Items | First items |
|---|---|---|---|
| Apple | (-677,-2160 34×30) | 21 | About This Mac, System Information, —, System Settings… |
| Chrome | (-644,-2160 72×30) | 16 | About Google Chrome, —, Settings… ⌘, |
| File | (-573,-2160 42×30) | 16 | New Tab ⌘T, New Window ⌘N, New Incognito Window ⇧⌘N |
| Bookmarks | (-376,-2160 88×30) | 71 | … |

Per item: `AXTitle`, `AXEnabled`, `AXMenuItemCmdChar`, `AXMenuItemCmdModifiers` (0 = ⌘; bit 0 ⇧, bit 1 ⌥, bit 2 ⌃, bit 3 = no ⌘), and `AXMenuItemMarkChar`. A separator is an `AXMenuItem` with an empty title, `AXEnabled = false`, and no children. Submenus are an `AXMenu` child of the item. The app menus spanned about 613 pt on the Samsung.

### 5.2 Menu bar icons ("extras")

Each running app's `AXExtrasMenuBar` attribute lists its icons. On the Samsung there were 31, between x ≈ 1713 and 3133, or about 1420 pt.

- **macOS 27 system icons** are owned by `com.apple.MenuBarAgent`. Each `AXMenuBarItem` (subrole `AXMenuExtra`) is wrapped in an `AXGroup`/`AXHostingView`, so descend one level. They have stable IDs and readable values:
  - `com.apple.menuextra.now-playing` — desc "Now Playing"
  - `com.apple.menuextra.focusmode` — "Focus"
  - `com.apple.menuextra.battery` — "Battery", value "100%, charging"
  - `com.apple.menuextra.wifi` — "Wi‑Fi, connected, 3 bars"
  - `com.apple.menuextra.controlcenter` — "Control Centre"
  - `com.apple.menuextra.clock` — "Clock", value "Wed Oct 21  10:32 AM"
  - Actions are `AXPress` and `AXShowMenu`, plus "Name:Remove from Menu Bar" on some. They have no `AXMenu` child; they open SwiftUI panels. The Control Center process exposes no extras on macOS 27.
- **Static menus readable without opening:** SystemUIServer (Time Machine: "Back Up Now", "Browse Time Machine Backups"), Raycast, Hammerspoon, Docker Desktop, Tailscale, and others.
- **No AX menu child,** meaning a custom popover or a menu built on click: BetterDisplay, Lunar, Maccy, Claude, ChatGPTHelper, BetterSnapTool, CPU Cap (title "22%"), TraceBar, **TilePilot itself**, and Menu Bar Controller for Sonos (desc "Right-click to play/pause. Left-click to open the control window.").
- Third-party frames are 24 pt tall at y = -2153; system ones are 22 pt at y = -2156.

### 5.3 Notification Center

- `com.apple.notificationcenterui` (pid 1242) owns a full-display `AXWindow` with subrole `AXSystemDialog` and title "Notification Center". It sits on the built-in display at CG layer 21 and is always present.
- Inside it: `AXHostingView` → `AXGroup` → `AXScrollArea` → `AXGroup` with identifier `AXNotificationListItems` → items.
- The one observed item had subrole `AXNotificationCenterAlertStack`, identifier `5EE1160B-…` (stable), and frame `(1934,46 344×90)`.
  - Its desc held the full text, app name first: "Login Items, App Background Activity, “env” can run in the background…, stacked".
  - Actions: `AXPress`, `"Name:Show Details\nTarget:0x0\nSelector:(null)"`, and `"Name:Clear All\n…"`. Children were `AXStaticText` with identifiers `title` and `body`.
- Desktop widgets (Mini Player, Screen Time, Batteries) are separate windows of the same process. Ignore them.
- **Unverified:** the subroles and actions of transient banners (expected `AXNotificationCenterBanner` / `AXNotificationCenterAlert` with a "Close" action), and what the tree shows while the full Notification Center panel is open.

### 5.4 Window layers seen

| Owner | Layer | Notes |
|---|---|---|
| Window Server "Menubar" | 24 | One window per display |
| Notification Centre | 21 | Full built-in display |
| Dock | 20 | |
| Lunar "Gamma" | 1000 | 100×100 windows, ignore |
| Lunar | 2147483628 | 2×2 window, ignore |

## 6. Product design

### 6.1 Bar placement and look

- One **System Bar** per display that has an enabled Work Area with "Show the menu bar" turned on.
- **Height H** is the real `Menubar` window height on that display, from `CGWindowListCopyWindowInfo`: owner "Window Server", name "Menubar", layer `CGWindowLevelForKey(.mainMenuWindow)`, intersecting the display. Fall back to 24 pt. On the Samsung, H = 30.
- **Width** equals the Work Area width (2560 on the Samsung).
- **Placement:** if `workArea.minY - visibleFrame.minY >= H`, the bar sits **directly above** the Work Area at `(wa.minX, wa.minY - H, wa.width, H)`. Otherwise it sits **inside** the top of the Work Area, and the window area shrinks by H; tiled padding and containment then use the reduced rectangle.
  - Samsung at x = -687: Work Area `(-47,-1620,2560,1440)` → bar `(-47,-1650,2560,30)`.
  - Samsung at x = -614: bar `(26,-1650,2560,30)`.
- **Panel:** an `NSPanel` subclass, borderless and `.nonactivatingPanel`, at level `.statusBar`.
  - `collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]`; `hidesOnDeactivate = false`; no shadow; excluded from the Windows menu.
  - It never becomes key while showing menus, and the content view accepts the first mouse click.
- **Background:** `NSVisualEffectView` with material `.titlebar`, `.behindWindow`, state `.active`, following system appearance. Phase 4 may refine it.
- **Lay out again** when the Work Area changes, on screen-parameter changes, when `NSWorkspace.activeSpaceDidChangeNotification` fires, on every live-state refresh (display frame or UUID change), and when the visible frame changes.

### 6.2 Left side: app menus

- **Source:** the frontmost app (`NSWorkspace.shared.frontmostApplication`). Refresh on `NSWorkspace.didActivateApplicationNotification` and every 2 s. If TilePilot is frontmost, mirror TilePilot's own menus; Accessibility works on its own pid.
- **Rendering:**
  - The first item is the `apple.logo` symbol, the second (the app name) is bold, and the rest are regular.
  - Font: `NSFont.menuBarFont(ofSize: 0)`.
  - Use **Accessibility widths** for each title so spacing matches the real bar.
  - Show a hover highlight as a rounded rectangle.
- **Click:** build an `NSMenu` from the item's `AXMenu` and show it with `popUp(positioning:at:in:)` under the title. **Never call `NSApp.activate`.**
  - Set `menu.autoenablesItems = false`.
  - Map each item: title; `isEnabled` from `AXEnabled`; state `.on` when a mark character is present; key equivalent and modifier mask from the command fields (display only); separators.
  - Build submenus lazily in `NSMenuDelegate.menuNeedsUpdate` by reading Accessibility at that moment.
  - Mark Option-key alternates with `isAlternate` when two adjacent items share a command character and the second adds ⌥. Phase 0 confirms this; otherwise show both.
- **Choosing an item** runs `AXUIElementPerformAction(originalMenuItem, kAXPressAction)` on the Accessibility queue. If it fails, show a short message in TilePilot.
- Clicking another title closes the current menu and opens the next one. Switching menus by hovering, like the real bar, is Phase 4 polish.
- **Known staleness:** apps that rebuild menus on open (Window lists, History) may show slightly old items. Phase 0 measures this.

### 6.3 Right side: menu bar icons

- **Enumerate** every running app's `AXExtrasMenuBar`, descending through MenuBarAgent's hosting groups. Sort by x position; the frames lie on the active menu bar. De-duplicate by `(pid, AXIdentifier or index)`.
- **Refresh** with a full enumeration every 3 s and on app launch or quit. While the bar is visible, re-read frames and values every 1 s. Remember which pids have no icons and rescan them only every 30 s.
- **Matching mode** (Screen Recording granted and the real bar on screen): crop each icon's AX frame from a live capture of the real menu bar on the display where the frames lie. Use a ScreenCaptureKit stream with `sourceRect` set to the menu bar, 2 fps, kept in memory, scaled by `backingScaleFactor`.
- **Simplified mode** (no permission, real bar hidden, or the icon's frame is off screen):
  - System icons map to symbols: wifi → `wifi`, battery → `battery.100`, focusmode → `moon.fill`, now-playing → `play.fill`, controlcenter → `switch.2`.
  - The clock shows the text of its `AXValue`.
  - Third-party icons use `AXTitle` when present (CPU Cap "22%"), otherwise the owning app's icon.
- **Tooltip:** `AXDescription`, `AXValue`, or the app name.
- **Click behavior**, decided at click time:
  1. **The icon has an `AXMenu` child now:** show a local menu built the same way as app menus; choosing an item presses the original.
  2. **TilePilot's own icon:** show TilePilot's quick menu (`StatusBarController.presentQuickMenu` logic) at the mirrored icon, with no Accessibility round trip.
  3. **Otherwise:** `AXPress` the original, then classify the result within 600 ms:
     - **An `AXMenu` appeared:** read it, `AXCancel` the real menu, and show it locally. A brief flash at the real bar is acceptable.
     - **A new window appeared:** open the panel mirror (6.4). Until Phase 2 ships, leave the panel where macOS opened it.
     - **Nothing appeared:** the click was the action itself, so do nothing more.
- **Right-click** runs `AXShowMenu` when the icon supports it, then the same classification.

### 6.4 Panel mirror (Phase 2) — for Wi-Fi, Control Centre, BetterDisplay, Lunar, and similar icons

- **Find the source window** by comparing the window list before and after the click. Accept new on-screen windows at layer > 0 owned by the icon's pid; for `com.apple.menuextra.*` icons, also accept MenuBarAgent or Control Center. The window's top must be within 80 pt below the real menu bar and within 800 pt horizontally of the icon. Pick the largest.
- **Mirror window:** a borderless, non-activating `NSPanel` at `.popUpMenu` level with `ignoresMouseEvents = true`. Place it under the mirrored icon, right-aligned to it, and clamp it inside the Work Area. Draw at 1:1, scaling down only if needed to fit.
- **Pixels:** a ScreenCaptureKit stream with `SCContentFilter(desktopIndependentWindow:)` at 30 fps, drawn into a CALayer from the IOSurface. Do not render each frame through SwiftUI.
- **Input:** while a mirror is open, run an **active** `CGEvent` tap at session level, inserted at the head, intercepting left/right/other mouse down, up, and drag events, plus scroll.
  - For an event inside the mirror, map it to `original = source.origin + (p - mirror.origin) / scale`.
  - On mouse down, warp the cursor there (`CGWarpMouseCursorPosition`), rewrite the event location, and let it pass.
  - Drags then happen naturally at the original location. Track the deltas to keep a virtual pointer.
  - On mouse up, warp the cursor back to the matching mirror point.
  - Scroll: warp there, pass the event, warp back.
  - Draw a synthetic arrow at the virtual pointer while the real cursor is away.
  - Never touch events outside the mirror. Keyboard input needs nothing, because the real panel already has key focus.
  - Rewriting the location keeps the real panel from seeing an outside click, which would close transient popovers. Phase 0 must prove this.
- **Close** when the source window disappears (checked at 10 Hz) or on Escape. Remove the tap immediately. Re-enable it if it times out, as the existing coordinators do. Add a watchdog that removes the tap if no mirror is open.
- **Limitations:** hover effects and tooltips inside the real panel don't work, and the cursor visibly jumps during a press.
- **Setting:** "Open icon panels inside the Work Area", on by default once Phase 2 passes. When off, panels open where macOS puts them.

### 6.5 Notification cards (Phase 3)

- **Source:** the Accessibility tree of `com.apple.notificationcenterui` → the window with subrole `AXSystemDialog` → descendants whose subrole starts with `AXNotificationCenter`.
  - Key each card by its `AXIdentifier` (a UUID).
  - Take the app name from the desc text before the first comma. Take title and body from the `AXStaticText` children with identifiers `title`, `subtitle` if present, and `body`.
  - Named actions have the form `Name:<label>\n…`; use the label.
- **Discovery:** an `AXObserver` on the Notification Center app element for created, destroyed, layout-changed, and window-created notifications. Also poll at 1 Hz while idle and 4 Hz while cards are showing. All Accessibility calls run on the Accessibility queue with a 0.25 s messaging timeout.
- Do not mirror while the full Notification Center panel is open (Phase 0 decides how to detect it) or from widget windows.
- **Card UI:** a non-activating panel at `.statusBar` level with a shadow, placed at the top-right of the window area.
  - Position: `x = area.maxX - 344 - 12`; `y` is 12 pt below the bar (or below the area's top).
  - Stack cards downward with an 8 pt gap. Show at most three, then a "N more" pill.
  - Content: app icon (look up the app by name; fall back to a bell symbol), app name, title in bold on one line, and up to three lines of body.
  - Hover reveals × and "…".
- **Actions:**
  - Clicking the card runs `AXPress` on the original, which opens the app.
  - × runs "Close", or "Clear"/"Clear All" for stacks.
  - "…" lists the remaining named actions. Actions that open a real menu far away, such as "Options", are a known v1 limitation.
- A card disappears within 300 ms of the original disappearing. **Screen Recording is not needed.**
- **Privacy:** never log notification text, never write it to disk, and keep it out of TilePilot's command log.

### 6.6 Notification list (Phase 3b)

Clicking the mirrored clock runs `AXPress` on the original clock, which opens the real panel on its display. Read `AXNotificationListItems` and show a scrollable TilePilot list under the right end of the bar, using the same cards and excluding widgets. Clicking outside or pressing Escape presses the clock again to close the real panel. Phase 0 confirms that the list is exposed while the panel is open.

### 6.7 Settings and copy

Add a GroupBox to the Work Area tab titled "Menu Bar and Notifications":

- **Toggles** (per display; stored in `WorkAreaConfiguration`):
  - "Show the menu bar at the top of the Work Area" (`systemBarEnabled`)
  - "Show notifications in the Work Area" (`notificationMirrorEnabled`)
  - "Open icon panels inside the Work Area" (`panelMirrorEnabled`)
- **Status line:** "Menu bar icons: Matching" when Screen Recording is on, otherwise "Simplified". When it is off, add an "Allow Screen Recording…" button that reuses `requestScreenRecordingAccessPrompt()`.
- The canvas preview draws the bar strip above or inside the area.
- Keep copy short and outcome-based. Explanations go in How It Works.

### 6.8 Permissions

- **Accessibility** is already required. It covers reading menus, pressing items, and the event tap.
- **Screen Recording** is optional; it enables Matching icons and the panel mirror.
- Never prompt without an explicit click (AGENTS.md). Keep captures in memory only.

### 6.9 What stays on the real screen

The real menu bar and real banners still appear. If the user turns on macOS menu bar auto-hide, icons fall back to Simplified because the real bar is not on screen to capture. The pointer stays free.

## 7. Architecture

Suggested new files (names are suggestions; keep the existing directory conventions):

- `Models/SystemBarModels.swift` — pure, testable value types:
  - `MirroredMenuItem`: title, enabled, keyEquivalent, modifiers, isOn, isSeparator, isAlternate, hasSubmenu, index path.
  - `StatusItemSnapshot`: id, pid, bundleID, appName, identifier, title, desc, value, frame, hasMenu, actionNames.
  - `NotificationSnapshot`: id, appName, title, subtitle, body, frame, kind, actionNames.
  - `SystemBarLayoutPlanner`: fits menus and icons into the bar width. When they don't fit, the leftmost (third-party) icons move into a "»" overflow menu first, then the rightmost app menus.
  - Parsers: action names, modifier masks, separators and alternates, app name from notification desc.
- `Infrastructure/AccessibilityMirrorReader.swift` — one serial queue or actor that owns every `AXUIElement`. It sets messaging timeouts (`AXUIElementSetMessagingTimeout(app, 0.25)`), returns snapshots with opaque IDs, and performs actions by ID. AX calls never run on the main thread.
- `Infrastructure/MenuBarStripCapture.swift` — a ScreenCaptureKit stream per display: `sourceRect` set to the menu bar, 2 fps, memory only.
- `Features/SystemBar/SystemBarController.swift` (`@MainActor`) — panels per display, layout, click handling, `NSMenu` building (`MenuMirrorBuilder`), and the TilePilot-icon special case.
- `Features/SystemBar/SystemBarView.swift` — prefer an AppKit `NSView` for crisp text and exact hit-testing.
- Phase 2: `PanelMirrorController.swift` and `PanelInputForwarder.swift` (event tap).
- Phase 3: `NotificationMirrorController.swift` and `NotificationCardView.swift`.
- `AppModel+SystemBar.swift` — glue: start and stop from `applyWorkAreaRuntimeIfNeeded`, settings setters, screen-change observers.

Integration points:

- **`WorkAreaConfiguration`:** add `systemBarEnabled`, `notificationMirrorEnabled`, and `panelMirrorEnabled`. Decode with `decodeIfPresent`, defaulting to false, false, and true. No release-defaults version bump is needed, because the default keeps behavior unchanged.
- **Geometry:** add `WorkAreaGeometry.systemBarLayout(workArea:visibleFrame:barHeight:) -> (bar: CGRect, windowArea: CGRect)`. When the bar is enabled, `resolvedWorkArea(for:)` returns `windowArea`, so padding, containment, and placement avoid the bar automatically. Add `resolvedSystemBarFrame(for:)`.
- **Coordinates:** convert yabai's top-left coordinates to AppKit with `appKitY = primaryMaxY - (y + h)`, the inverse of `topLeftRect`.
- **Containment** already skips TilePilot's own pid. Confirm that yabai doesn't manage the new panels; non-standard subroles are not tiled.
- **Threading:** UI state stays on `@MainActor`, as AGENTS.md requires. Run `AXObserver` sources on the main run loop and hop their callbacks to the Accessibility queue.

## 8. Implementation phases

Commit each phase separately and stage only your own hunks. Use subjects like `feat: …`.

### Phase 0 — Feasibility spike (go/no-go)

Build the experiments inside TilePilot behind `tilepilot://internal/system-bar-spike/<test>`, gated like the native-spaces spike. Record results, timings, and screenshots in `docs/research/SYSTEM_BAR_FEASIBILITY.md`. Use only harmless menu items (section 12).

| Test | What to do | Pass |
|---|---|---|
| S1 Non-activating menu | Spike panel at the Work Area's top shows the frontmost app's titles; clicking pops an `NSMenu` built from Accessibility | Frontmost app unchanged before and after; arrow keys work in the menu; chosen item runs (Chrome File > New Tab; Finder Go > Home) |
| S2 Press without opening | `AXPress` on a menu item without opening its menu, in Finder, Chrome, iTerm2, Telegram, Claude (Electron), ChatGPT | ≥ 90% success in native apps; Electron behavior documented; note stale items |
| S3 Icon classification | Raycast and Time Machine (static menus), BetterDisplay and Lunar (none), Wi-Fi, Battery, Clock, and Control Centre (MenuBarAgent): press, observe whether a menu or window appears (owner, layer, frame, delay), and whether Cancel or Escape closes it | Every icon classifies correctly; timings recorded |
| S4 Panel mirror and input | Battery panel, then the Control Centre Sound slider (change the volume slightly, then restore it): mirror plus forwarding through the event tap | Panel stays open while clicking the mirror; clicks land; drag works; cursor returns; no stuck tap |
| S5 Notifications | Ask the user to trigger a real banner (for example, a message to themselves), or have them allow Script Editor notifications and turn Focus off. Dump the banner, alert, and stack structures | Subroles and actions recorded; `AXPress` opens; Close closes; observer latency under 300 ms |
| S6 Menu bar capture | Stream the Samsung menu bar with `sourceRect`; crop icons at 1×; measure CPU; test with menu bar auto-hide | Icons crop correctly; CPU under 1% at 2 fps; hidden-bar case falls back |

Go/no-go: Phase 1 needs S1–S3 and S6 (S6 only for Matching icons). Phase 2 needs S4. Phase 3 needs S5. If S4 fails, keep Phase 2 as press-through and propose reading panels through Accessibility to the user (toggles, sliders, and buttons rebuilt in TilePilot) as a separate project.

### Phase 1 — System Bar: app menus and icons

Tasks: models and planner, geometry and the configuration fields, the Accessibility reader, the bar panel and view, the menu builder, icon enumeration, Matching and Simplified rendering, the three click behaviors from 6.3 (panels press through for now), the TilePilot-icon special case, overflow, the settings card, and How It Works.

Acceptance:

- The bar appears directly above the Work Area on the Samsung, 2560 × 30.
- Titles update within 1 s of switching apps.
- Menus open under their titles, the chosen items run, and the frontmost app never changes.
- Icons appear in order and match the real ones when Screen Recording is on.
- Icons with static menus open local menus. The TilePilot icon opens its quick menu.
- No window overlaps the bar after containment.
- No permission prompt appears unless the user clicks.

Commit: `feat: add a menu bar above the Work Area`.

### Phase 2 — Panel mirror

Generalize S4 to Wi-Fi, Battery, Control Centre, BetterDisplay, and Lunar. Never toggle Wi-Fi or Bluetooth off during tests.

Commit: `feat: open menu bar panels inside the Work Area`.

### Phase 3 — Notification cards; 3b — Notification list

Acceptance:

- A banner is mirrored within 300 ms.
- Clicking the card opens the app; the real banner and the card both disappear.
- × closes the original.
- The stack shows Clear All.
- Widgets are never mirrored.
- 3b: clicking the mirrored clock shows the list, and clicking outside closes both.

Commits: `feat: show notifications in the Work Area`, then `feat: show the notification list from the mirrored clock`.

### Phase 4 — Polish

Hover-to-switch between open menus, overflow refinements, a background closer to the real bar, How It Works and the AGENTS.md domain line, screenshots, and `graphify update .`.

## 9. Test plan

Unit tests (pure code):

- Layout planner: everything fits; icons overflow; menus overflow.
- `systemBarLayout`: above versus inside, the reserved inset, and how it combines with padding.
- Action-name parsing.
- Modifier-mask mapping.
- Separator and alternate detection.
- App name from notification desc, including descs with no comma.
- Lenient decoding of the new configuration fields.
- yabai-to-AppKit conversion.

Live acceptance per phase, as listed above, plus these regressions:

- Work Area padding still reads 510/180/640/640 on desktop 3 when the bar is above (the values change when it is inside).
- Containment, Fill Work Area, Floating Grid, and Templates still land inside the window area.
- The Work Area switch still restores padding 0.

Evidence to report: the executed test count, screenshots at absolute paths of the bar, an open mirrored menu, a mirrored panel, and a notification card, plus yabai and Accessibility readbacks.

## 10. Open questions (defaults used if unanswered)

1. **Bar placement:** attached above the Work Area when there is room (default), or always inside it?
2. **Menu bar auto-hide:** leave macOS settings alone (default), or offer to turn auto-hide on? With it on, icons can only use Simplified mode.
3. **Closing a card closes the original** (default yes). Should TilePilot ever hide a card without touching the original?
4. **Desktops:** show the bar on every desktop of that display (default), or only where the Work Area applies? The Work Area is per display, so these are the same today.

## 11. Risks and mitigations

| Risk | Mitigation |
|---|---|
| Accessibility calls block when an app hangs (default timeout ~6 s) | Messaging timeout 0.25 s; never on the main thread; skip pids that keep timing out for 30 s |
| Stale or dynamic menus; Electron apps ignore `AXPress` without an open menu | Phase 0 measurement; fallback that opens the real menu, presses, then cancels; report failures in the UI |
| A runaway event tap breaks the mouse | Tap only while a mirror is open; watchdog removal; only events inside the mirror are touched; re-enable on timeout; remove on app quit |
| Visible cursor jumps during panel input | Synthetic cursor in the mirror; documented |
| Display identity switches (BetterDisplay/Lunar) | Re-resolve everything on each refresh and screen change; never cache frames |
| Menu bar hidden, or icons pushed off a narrow bar | Simplified rendering |
| Focus mode suppresses banners | Mirror only what macOS shows; document |
| Localized names ("Notification Centre") | Match by bundle ID, subrole, and identifier, never by display name |
| Privacy | Notification text and captures stay in memory only; never logged |
| macOS screen-capture reminders | Matching mode stays optional; Simplified mode needs no permission |

## 12. Rules for the next agent

- Follow `AGENTS.md`:
  - Keep UI state on `@MainActor`.
  - Run helpers with timeouts.
  - Never prompt for permissions without a user action.
  - Never persist screenshots.
  - Preserve unrelated dirty work.
  - After app changes, package and confirm the new `/Applications` process is running.
- **Test safety:** never press Restart, Shut Down, Log Out, Sleep, Lock Screen, Quit, Close Window, Delete, Empty Trash, Force Quit, or Remove from Menu Bar. Never toggle Wi-Fi or Bluetooth off. Use New Tab, About This Mac, Go > Home, and similar items, and close what you open.
- Never send messages or post content on the user's behalf. For notification tests, ask the user to trigger a banner.
- Never toggle native full screen; it hung yabai.
- Verify live behavior and show screenshots. If Computer Use fails, say so and ask the user for the real-click checks.

## 13. Phase 1 as built (2026-10-21)

Files: `Models/SystemBarModels.swift` (items, modifiers, alternates, layout planner), `Infrastructure/AccessibilityMirrorReader.swift` (all Accessibility work on two private queues, 0.25 s timeouts, opaque element IDs, icon placement by hit test), `Infrastructure/MenuBarStripCapture.swift` (per-display ScreenCaptureKit stream with per-icon regions), `Features/SystemBar/SystemBarController.swift` and `SystemBarView.swift` (panels, AppKit drawing, menus, clicks), `AppModel+SystemBar.swift` (geometry, settings, runtime glue). `WorkAreaConfiguration` gained `systemBarEnabled`, `notificationMirrorEnabled`, and `panelMirrorEnabled` (lenient decoding). `resolvedWorkArea(for:)` returns the window area under the bar; `resolvedWorkAreaIgnoringSystemBar(for:)` is the saved rectangle.

Differences from the plan:

- Titles refresh every 2 s and on app activation; icons every 3 s and on app launch or quit. The running-app list is cached between launches; real menu bar frames are cached for 10 s and dropped on display changes.
- The bar shows the mirrored display's own icon set, kept stable across focus changes; "Also show icons from other displays" (`TilePilot.systemBarOtherDisplayIcons`, default off) adds the icons macOS draws only on other bars (the main display holds most third-party icons). See the feasibility note.
- Matching mode paints one solid background color sampled from the active bar (held through focus changes), so text color follows the real bar.
- Setting: "Match the real icons" (global, `TilePilot.systemBarMatchingIcons`, default on). The notification and panel toggles are stored but have no UI yet.
- Right click and Control-click act on release: system icons get `AXShowMenu`, other icons get a real right click at their on-screen position (the pointer returns right after).
- Left click on an icon without a readable menu: system icons get `AXPress`; other icons get a real left click at their on-screen position once the physical button is up, because many apps read the mouse event and ignore `AXPress` while reporting success (TraceBar, BetterDisplay, Lunar, CPU Cap). Both real clicks first hit-test the point (an icon or, on an inactive display's bar, the app's icon container). A panel the click opened is watched at 10 Hz; clicking the same icon while it is open or within 0.25 s of it closing (apps close panels on any outside mouse down) closes it instead of reopening it. Panels taller than the gap above the bar (CPU Cap, BetterDisplay; TraceBar by 17 pt) cover the mirrored icons until they close.
- `system-bar/status` also reports the last icon click and the path it took.
- Development routes (always enabled in this build, like the scrub spike): `tilepilot://internal/system-bar/on|off|toggle`, `system-bar/status` (writes a text description to `/tmp/tilepilot-system-bar/status.txt`; no pixels), and `system-bar/click/<slot>` / `right-click/<slot>` (runs the click handler for a slot of the first bar).

Verified live: bar at `(-687,-1775,3840,30)` above the current full-width Work Area; titles follow the frontmost app; app menus, static icon menus, the TilePilot quick menu, and Battery's panel all open from the mirror with the frontmost app unchanged; choosing Bring All to Front pressed the real item; padding and containment unchanged; about 0.65% CPU. Not verified: real pointer clicks and keyboard navigation in the mirrored menus (Computer Use failed), the settings card visually, the bar-inside-the-area layout live, and menu bar auto-hide.

## Appendix A — Read-only Accessibility probe

Save as `/tmp/tp-probe.swift`, then run `swiftc -O -o /tmp/tp-probe /tmp/tp-probe.swift && /tmp/tp-probe` from the Codex shell, which is Accessibility-trusted. It prints the menu bar windows, the frontmost app's menus, every menu bar icon including MenuBarAgent's nested ones, and the Notification Center tree. It does not press anything.

```swift
import AppKit
import ApplicationServices

func attr(_ e: AXUIElement, _ a: String) -> CFTypeRef? { var v: CFTypeRef?; return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil }
func str(_ e: AXUIElement, _ a: String) -> String { (attr(e, a) as? String) ?? "" }
func kids(_ e: AXUIElement) -> [AXUIElement] { (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
func actions(_ e: AXUIElement) -> [String] { var n: CFArray?; AXUIElementCopyActionNames(e, &n); return ((n as? [String]) ?? []).map { $0.components(separatedBy: "\n").first ?? $0 } }
func frame(_ e: AXUIElement) -> String {
    var p = CGPoint.zero, s = CGSize.zero
    if let v = attr(e, kAXPositionAttribute) { AXValueGetValue(v as! AXValue, .cgPoint, &p) }
    if let v = attr(e, kAXSizeAttribute) { AXValueGetValue(v as! AXValue, .cgSize, &s) }
    return "(\(Int(p.x)),\(Int(p.y)) \(Int(s.width))x\(Int(s.height)))"
}
func dump(_ e: AXUIElement, _ depth: Int, _ maxDepth: Int) {
    guard depth <= maxDepth else { return }
    print(String(repeating: "  ", count: depth) + str(e, kAXRoleAttribute), str(e, kAXSubroleAttribute),
          "title:", str(e, kAXTitleAttribute), "desc:", str(e, kAXDescriptionAttribute).prefix(90),
          "id:", str(e, "AXIdentifier"), "value:", attr(e, kAXValueAttribute).map { "\($0)" } ?? "", frame(e), actions(e))
    for child in kids(e).prefix(10) { dump(child, depth + 1, maxDepth) }
}

print("== Menu bar windows")
for w in (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []) {
    let layer = (w[kCGWindowLayer as String] as? Int) ?? 0
    guard layer >= 20 else { continue }
    print("layer", layer, "owner", w[kCGWindowOwnerName as String] ?? "", "name", w[kCGWindowName as String] ?? "", "bounds", w[kCGWindowBounds as String] ?? "")
}

let front = NSWorkspace.shared.frontmostApplication!
print("\n== Menus of", front.localizedName ?? "?")
if let bar = attr(AXUIElementCreateApplication(front.processIdentifier), kAXMenuBarAttribute) {
    for item in kids(bar as! AXUIElement) {
        let items = kids(item).first.map(kids) ?? []
        print(str(item, kAXTitleAttribute), frame(item), "items", items.count,
              items.prefix(5).map { str($0, kAXTitleAttribute) + " cmd:" + str($0, "AXMenuItemCmdChar") + " mods:" + "\((attr($0, "AXMenuItemCmdModifiers") as? Int) ?? -1)" })
    }
}

print("\n== Menu bar icons")
for app in NSWorkspace.shared.runningApplications {
    guard let extras = attr(AXUIElementCreateApplication(app.processIdentifier), "AXExtrasMenuBar") else { continue }
    print("--", app.localizedName ?? "?", app.bundleIdentifier ?? "?")
    for item in kids(extras as! AXUIElement) { dump(item, 0, 2) }
}

print("\n== Notification Center")
if let nc = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first {
    for w in (attr(AXUIElementCreateApplication(nc.processIdentifier), kAXWindowsAttribute) as? [AXUIElement]) ?? []
    where str(w, kAXSubroleAttribute) == "AXSystemDialog" { dump(w, 0, 8) }
}
```

