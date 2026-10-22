# System Bar Feasibility (Phase 0) — results on the user's Mac, 2026-10-21

Context: `docs/SYSTEM_BAR_HANDOFF.md` section 8, Phase 0. Probes were read-only except the presses
listed. Probe sources lived in `/tmp/tp-spike/` and were not kept.

## Environment

- macOS 27.0.1, two displays with separate Spaces. Real menu bars (WindowServer "Menubar", layer 24):
  Samsung `(-687,-2160 3840x30)`, built-in `(0,0 2294x30)`. `CGWindowLevelForKey(.mainMenuWindow)` = 24.
- Menu bar height on both displays: **30 pt**.

## S1 — Non-activating menu from a panel: pass

The bar is a borderless `.nonactivatingPanel` (`canBecomeKey = false`) at `.statusBar` level.
`NSMenu.popUp(positioning:at:in:)` from it opened under the mirrored title with ChatGPT, Telegram,
and Chrome frontmost; the frontmost app never changed. Menus were opened through the internal route
`tilepilot://internal/system-bar/click/<slot>` (it runs the same click handler as a mouse down) and read
back through Accessibility: Window menu at `(-468,-1750)` directly under the "Window" slot. Real
pointer clicks were not tested because Computer Use failed again ("native pipe closed").

## S2 — AXPress on a menu item without opening its menu: pass

- `AXPress` on Window ▸ Bring All to Front succeeded with the menu closed in TilePilot, ChatGPT, and
  Telegram (0 ms); the frontmost app did not change.
- Item attributes are readable without opening the menu: `AXTitle`, `AXEnabled`, `AXMenuItemCmdChar`,
  `AXMenuItemCmdModifiers`, `AXMenuItemCmdGlyph`, `AXMenuItemMarkChar`, children (submenu).
- Modifier mask: 0 = ⌘; bit 0 ⇧, bit 1 ⌥, bit 2 ⌃, bit 3 = no ⌘, bit 4 = Fn. Mask 8 with no character
  means no shortcut (Zoom, Bring All to Front); 10 = ⌥ alternate (Zoom All); 28 = Fn⌃ (Fill).
- `AXMenuItemPrimaryUIElement` exists on every item, so alternates are detected as adjacent items with
  the same character where the second adds ⌥.
- Menu title frames are `0x0` when the frontmost app is an accessory app; TilePilot's own menus come
  from `NSApp.mainMenu` instead (Accessibility cannot serve a process its own menus from a
  background thread while the main thread waits).
- Bug found and fixed: reading a submenu used to start a new element generation, so after two
  submenus loaded the parent menu's items could no longer be pressed. Submenus now join the
  generation of the menu they belong to.

## S3 — Icon classification: pass

Icons with a static `AXMenu` (opened locally, no flash on the real bar): SystemUIServer (Time
Machine), Raycast, TextInputMenuAgent, Hammerspoon ×2, CleanShot X, Lock Anyway, Docker Desktop,
Tailscale, ChatGPT, and several others. Verified: Tailscale and Lock Anyway menus opened under their
mirrored icons.

Without one: the MenuBarAgent system icons, BetterDisplay, CPU Cap, Maccy, TraceBar, Sonos controller,
ChatGPTHelper, Lunar, BetterSnapTool, Claude, TilePilot. Battery: `AXPress` returned in 42 ms
and a Control Centre window (layer 101) appeared about 350 ms later under the real icon; a second press
closed it. The TilePilot icon opens TilePilot's quick menu locally.

### Icon positions: Accessibility frames are not reliable

Each display's menu bar draws its own system icons. Third-party icons were drawn only on the built-in
bar, yet Accessibility reported them on whichever bar is active: after focus moved to the Samsung,
all 22 were reported at Samsung coordinates, overlapping the real system icons there. Hit tests
(`AXUIElementCopyElementAtPosition`, 1.5–6 ms each) are the ground truth. Status item windows do not
appear in `CGWindowListCopyWindowInfo` on macOS 27.

What works (`AccessibilityMirrorReader.confirmedPlacement`): hit-test the reported center. On a miss,
the icon keeps nearly the same distance from the right edge on the other bar (measured offset error
8.5–11 pt), so probe there, then binary-search the edges of the hit area and center the icon in it.
Hit areas include about 7 pt of padding per side. Apps whose two icons are adjacent share one hit
area (Hammerspoon) and use the bar's median correction. Lock Anyway, ChatGPTHelper, and one other app answer
hit tests with an error; at the exact predicted spot that counts as a match when the reported spot
belonged to another app. Results are cached per icon and re-checked with one hit test per scan.
Unconfirmed icons are never cropped and get their own group at the left.

### Which icons each display's bar draws (measured 2026-10-21, after the first build)

Settings on this Mac: "Displays have separate Spaces" on (`spans-displays = 0`), menu bar auto-hide
off, Reduce Transparency off, light appearance, the built-in display is the main display.

| Focus on | Accessibility reports the 27 third-party icons on | Drawn on the Samsung | Drawn on the laptop |
|---|---|---|---|
| Samsung (ChatGPT) | Samsung bar | 3 (TilePilot, CPU Cap, ChatGPT) | 21 + 3 that answer hit tests with errors |
| Laptop (Spotify) | laptop bar | 1 | all 27 |

Each display draws its own system icons; the Samsung shows 7 while active and about 5 while
inactive. macOS dims the inactive display's bar. Accessibility reports every icon, system icons
included, on the active display's bar.

Hit-test matching must compare the element, not just the process: all system icons belong to
MenuBarAgent, and an empty stretch of a bar answers with the menu bar of the app that owns it (the
frontmost app on the active bar). `hitTest` now classifies hits as a status item (process +
`AXIdentifier`), an app's icon container (`AXExtrasMenuBar`, which answers for icons on an inactive
bar), something else, or no element.

What the mirror does with this (default):

- Shows the mirrored display's own icon set. Icons are remembered with their place on that bar
  (`stickyIcons`), so the set and order stay the same when macOS draws fewer icons there while
  another display is active. If TilePilot starts while the other display is active, the set grows
  once, the first time the mirrored display becomes active.
- Copies each icon from the bar where it is drawn bright (the active bar when it is drawn there).
  A scan runs 250 ms after every app activation; until it lands, the previous copy stays.
- Paints one solid background color, sampled from the active bar's empty stretch, adopted only after
  it holds for 1.5 s.
- "Also show icons from other displays" (off) adds the icons macOS draws only on other bars.
- An app that had icons last scan is never put on the 30-second "no icons" skip list; an icon missing
  from one scan stays for 10 s. Without this, all system icons vanished after a display switch.

### Right click (fixed 2026-10-21)

Accessibility offers `AXShowMenu` only on the system icons; third-party icons expose just `AXPress`,
which behaves like a left click. Apps decide what a right click does (Menu Bar Controller for Sonos:
"Right-click to play/pause. Left-click to open the control window."), so the mirror now acts on
release of a right click or Control-click: system icons get `AXShowMenu`; other icons get a real
right mouse down/up posted at the icon's confirmed position, then the pointer moves back. A menu that
opens there is read, closed, and shown under the mirrored icon. Verified with Tailscale: its menu
opened under the mirrored icon, the pointer returned to the same spot, the frontmost app did not
change, and no menu window was left open. Not verified: Sonos play/pause itself (left for the user,
to avoid starting their music), and right-clicking an icon drawn on the inactive display's bar.

After the screen locked and unlocked, macOS drew all 33 icons on the Samsung's own bar again, so which
display carries the third-party icons changes over time; the mirror follows it.

## S4 — Panel mirror and input (Phase 2): not run

Phase 1 presses panel-style icons and leaves the panel where macOS opens it.

## S5 — Notifications (Phase 3): not run

Needs a real banner triggered by the user.

## S6 — Menu bar capture: pass

`MenuBarStripCapture`: one ScreenCaptureKit stream per display that has visible icons, `sourceRect` =
that display's real bar, 1 fps, BGRA, memory only. Only started when `CGPreflightScreenCaptureAccess()`
is true, so no prompt appears. The controller registers one region per icon plus a background sample
(the empty stretch between the real bar's titles and icons); each new frame hashes the regions and
converts only the changed ones into plain 8-bit images in the bar's color space. The bar redraws only
the changed icons. Icons copy the real bar's look exactly, including the dimmed icons of an inactive
display.

CPU, measured as accumulated process CPU time over 20–30 s with the settings window closed: TilePilot
1.4% with the bar off and 2.05% with it on, so the bar costs about 0.65% of one core. Samples put the
bar's own code at about 0.35%; the rest is Core Animation committing the redrawn icons. Earlier
versions cost 3–4%: rebuilding the running-app list every scan (LaunchServices lookups on the main
thread), re-reading the window list every scan, and redrawing and color-converting the full strip on
every frame.

The hidden-bar case (menu bar auto-hide) is not tested; icons outside any on-screen menu bar window
are skipped, and the bar falls back to symbols and app icons when capture is unavailable.
