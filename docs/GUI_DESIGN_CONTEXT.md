# TilePilot GUI And Design Context

This document captures the UI and design context that can be derived directly from the current codebase. It is intended as an implementation-facing brief for engineers and coding agents, not as a product marketing document.

This is code-derived context only. It reflects the app as implemented, including historical user-driven wording decisions that now live in source.

## Summary

- TilePilot is a native macOS SwiftUI menu bar app with one main dashboard/settings window and one separate immersive `MegaMap` window.
- The main UI uses a tabbed shell with `NavigationStack` + `ScrollView` + vertically stacked `GroupBox` cards.
- Overlay badges and outline wireframes are drawn outside the main window using `NSPanel` helpers.
- There is no centralized design token or theme system. Most visual decisions are defined inline in feature views.
- The main reusable UI primitives are:
  - map window palette
  - desktop badge and outline overlay system
  - empty state view
  - MegaMap HUD button and notice styling

## Information Architecture

Main shell entry point:

- `Sources/TilePilot/TilePilotApp.swift`

Current top-level tab order:

1. `Overview`
2. `Behaviors`
3. `Actions & Shortcuts`
4. `Templates`
5. `Work Sets`
6. `Appearance`
7. `Config Files`
8. `How It Works`
9. `System`

Main screen roles:

- `Overview`
  - file: `Sources/TilePilot/Features/Overview/NowDashboardView.swift`
  - purpose: operational dashboard, desktop mini-map, degraded-state messaging, window/app list, quick recovery
- `Behaviors`
  - file: `Sources/TilePilot/Features/Behaviors/WindowBehaviorDashboardView.swift`
  - purpose: yabai behavior controls, precedence rules, desktop tiling, app defaults, focus/cursor, mouse dragging
- `Actions & Shortcuts`
  - file: `Sources/TilePilot/Features/Shortcuts/ShortcutsDashboardView.swift`
  - purpose: searchable control catalog, shortcut recording/testing/editing, right-click menu pinning, ordering, dynamic actions for Templates and Work Sets
- `Templates`
  - file: `Sources/TilePilot/Features/Templates/TemplatesDashboardView.swift`
  - purpose: custom floating slot layouts, current-desktop import, per-slot app allow-lists, z-order control, template actions
- `Work Sets`
  - file: `Sources/TilePilot/Features/WorkSets/WorkSetsDashboardView.swift`
  - purpose: desktop-scoped window groups, board-style membership editing, backdrop controls, layout modes, launch/restore options
- `Appearance`
  - file: `Sources/TilePilot/Features/Appearance/AppearanceDashboardView.swift`
  - purpose: overlay toggles, outline width, global tiling spacing
- `Config Files`
  - file: `Sources/TilePilot/FilesDashboardView.swift`
  - purpose: split-view editor/browser for config and referenced scripts
- `How It Works`
  - file: `Sources/TilePilot/Features/HowItWorks/HowItWorksDashboardView.swift`
  - purpose: compact concept explanations that keep settings screens focused on changing behavior
- `System`
  - file: `Sources/TilePilot/Features/System/SystemDashboardView.swift`
  - purpose: setup summary, guided setup entrypoint, essentials, performance, diagnostics

Supporting modal/window surfaces:

- `Guided Setup`
  - file: `Sources/TilePilot/Features/System/SetupGuideView.swift`
  - presented as a sheet from the main app
- `MegaMap`
  - file: `Sources/TilePilot/Features/Megamap/MegamapWindow.swift`
  - separate `NSWindow`, not another tab
- `Pick Windows to Tile`
  - files:
    - `Sources/TilePilot/RecentWindowTilerWindowController.swift`
    - `Sources/TilePilot/Features/RecentWindowTiler/RecentWindowTilerPickerView.swift`
  - separate picker `NSPanel` opened by the `Pick Windows to Tile...` action
  - shows current-desktop recent windows, a reorderable list, and a reorderable preview grid

## Visual Language

### Typography

- Typography is fully system-based.
- No custom font family is used.
- Common hierarchy:
  - titles: `.title2`, `.title3`, `.headline`
  - row and card labels: `.subheadline.weight(.semibold)` or `.caption.weight(.semibold)`
  - support and explanation text: `.caption`, `.caption2`, `.body` with `.foregroundStyle(.secondary)`
  - config and diff content: monospaced system fonts

### Layout And Containers

- `GroupBox` is the default containment pattern for settings and dashboard cards.
- There is no shared spacing constant layer. Repeated values appear inline:
  - outer vertical rhythm is usually `16`
  - internal card spacing is usually `8`, `10`, or `12`
  - rounded corners are usually `8` or `10`
- Secondary surfaces usually use:
  - `Color.secondary.opacity(0.035 ... 0.08)`
  - `RoundedRectangle(cornerRadius: 8 or 10)`
- Small status chips use `Capsule()` with low-opacity tinted fills.

### Buttons And Controls

- Buttons are intentionally compact.
- Common button styles:
  - primary CTAs: `.buttonStyle(.borderedProminent)`
  - secondary actions: `.buttonStyle(.bordered)`
  - contextual inline actions: `.buttonStyle(.borderless)` or `.plain`
- Dense settings controls often use `.controlSize(.small)` or `.mini`.
- Numeric settings prefer:
  - compact `TextField`
  - explicit unit label
  - adjacent `Stepper`

### Semantic Color Mapping

- Blue means:
  - tiled
  - selected
  - focused
  - primary action
- Orange means:
  - floating
  - warning
  - fallback
  - transient attention
- Gray or warm brown means:
  - limited-control windows
- Green and red mean:
  - success
  - error

## Shared UI Primitives

- Empty state:
  - file: `Sources/TilePilot/Shared/EmptyStateView.swift`
  - centered SF Symbol, title, secondary message, no decorative flourish
- App name with icon:
  - file: `Sources/TilePilot/Shared/AppNameWithIconView.swift`
  - 16px app icon plus app name
- Map window palette:
  - file: `Sources/TilePilot/MapWindowPalette.swift`
  - tiled windows use one blue family
  - floating and limited windows use warm per-window families derived from window ID
- Desktop badge and outline overlays:
  - files:
    - `Sources/TilePilot/WindowBadgeView.swift`
    - `Sources/TilePilot/WindowBadgeOverlayController.swift`
- MegaMap HUD styling:
  - file: `Sources/TilePilot/Features/Megamap/MegamapWindow.swift`

## Screen-Specific Notes

### Overview

- Light dashboard surface.
- Desktop mini-map uses white cards with thin black borders and tiny wireframes.
- Desktop cards include state pills like `Focused` and `Visible`.
- Degraded or stale states use orange-tinted banners with explicit recovery actions.
- Primary operational CTA is opening `MegaMap`.

Mini-map details:

- desktop chrome uses white fill around `0.94` opacity with black `0.12` stroke
- hover title bubble is almost-black with rounded corners, white text, and subtle white stroke
- per-desktop tiling control is a capsule split toggle with blue selected state and white text
- there is a literal `Jump` button next to desktop number

### Behaviors

- Dense, form-like settings layout.
- Starts with precedence and behavior-order framing because control order is conceptually important.
- App-rule editing is operational and text-heavy rather than visual.
- Mouse dragging copy is intentionally plain-language and gesture-based.
- Pending list changes create a bottom apply bar using `.safeAreaInset(...).background(.ultraThinMaterial)`.

### Actions & Shortcuts

- More table-like than form-like.
- Uses fixed columns, search, inline row actions, and reorder mode.
- The top pinned section mirrors the right-click menu and is explicitly named `Right-Click Menu`.
- Many rows use small semantic chips for state such as pinned or default.
- First-class actions include dynamic template apply actions and Work Set actions.
- `Pick Windows to Tile...` belongs with layout actions and should stay discoverable from this surface.

### Pick Windows to Tile

- Separate compact panel, not a full tab.
- Default mode is `Floating Grid`.
- List rows:
  - numbered by placement order
  - click toggles selection
  - drag changes placement order
  - useful window title is primary text; app name becomes secondary text
  - app/title duplicates should not render as repeated labels
- Preview:
  - shows the exact grid shape
  - uses app icons and placement numbers
  - preview tiles are draggable to change order
  - spare grid cells are represented by vertical spans rather than blank holes
- Primary button should stay visually primary even when the panel loses focus.
- The picker remembers selected count, not selected window identity.

### Templates

- Management surface has a left-side template list and a right-side editor canvas.
- Import Current Desktop is a first-class action in the Templates tab.
- Canvas slots can overlap and have z-order.
- Slots display allowed app icons where configured.
- Slot app allow-lists are edited visually through app icons and exact app names.
- Applying a template is a floating layout operation, not a yabai tiled layout.

### Work Sets

- Board-style layout with one lane per Work Set for the selected desktop scope.
- Scope selection must stay understandable when displays are renamed, reordered, or primary display changes.
- Lane headers are dense; avoid cramming too many controls into a single row.
- Work Set member rows emphasize:
  - app icon
  - app name
  - window title
  - actionable status only when something needs attention
- Work Set controls include:
  - activate
  - layout mode: Floating, Tile Work Set, Apply Template
  - optional backdrop
  - optional Launch Missing Apps
- Live Layout previews should help users understand what activation will bring forward or place.

### Appearance

- Intentionally sparse.
- Split into two cards only:
  - overlays
  - tiling layout
- Units are explicit, currently `px` and `pt`.
- Compact numeric controls are preferred over long sliders for small integer-like settings.

### Config Files

- Only screen using `HSplitView`.
- Left pane is a searchable file browser.
- Right pane is the active editor and detail surface.
- Selected file rows use `accentColor.opacity(0.12)`.
- Editor and diff surfaces use monospaced text on subtle rounded gray backgrounds.

### System

- Summary and status dashboard.
- Emphasizes direct next-step actions.
- `Run Guided Setup` becomes prominent when setup needs attention.
- Advanced areas are disclosure groups rather than separate screens.

### Guided Setup

- Two-column wizard layout.
- Left side is step list, right side is detail and actions.
- Fixed window-like size, not a narrow single-column sheet.
- Status is shown through both icons and labeled color chips.
- Primary, secondary, and skip actions are visually separated.

### MegaMap

- Only intentionally dark, immersive screen.
- Black overall background.
- Screenshot or synthetic tiles sit on light gray canvases.
- Top-left HUD notices use dark or tinted rounded pills.
- Inline controls use a custom dark/blue rounded HUD button style.
- Refresh affordance is a black translucent circular button at the bottom-right of a tile.
- Focused desktop gets a solid blue top stripe.
- Hover messaging appears as a black translucent capsule overlay.

## Window, Map, And Overlay Semantics

- Window state semantics are visually encoded consistently across maps and overlays:
  - tiled window = blue
  - floating window = orange
  - limited-control window = gray in desktop overlays, warm brown family in maps
- Mini-map and MegaMap wireframes are intentionally not affected by the desktop outline-width setting.
- Hover emphasis is intentionally strong and uses line-width multiplication rather than only subtle color changes.
- Window title fallback policy for maps:
  - prefer app name when title is blank
  - avoid filler like `Untitled`
- Maps and overlays are filtered to avoid junk surfaces:
  - fullscreen backdrop or dialog surfaces
  - limited, minimized, or helper windows when cleanup is enabled
  - transient dialog siblings such as small popup or modal surfaces attached to a larger real app window

Overlay behavior:

- badges and outlines are separate `NSPanel` layers
- outlines use full-precision rects and `strokeBorder`
- outlines are shown for all visible spaces, not only the focused display
- badge behavior is focused-window-oriented
- outline behavior is broader

Badge behavior:

- small capsule with semi-transparent fill
- left-click toggles float/tile when supported
- right-click opens pinned actions plus navigation items
- help text is product-language, not internal jargon
- badge colors:
  - focused floating = orange
  - focused tiled = blue
  - limited = gray

## Interaction And Copy Conventions

- Copy is direct, literal, and action-oriented.
- Labels avoid internal jargon when reasonable.
- UI language usually explains:
  - what the user can do
  - what the user will see happen
  - what to do next when something is wrong
- Preferred product phrasing patterns include:
  - `Run Guided Setup`
  - `Enable Screen Recording`
  - `Pin More Shortcuts...`
  - `Float Windows on This Desktop`
  - `Pick Windows to Tile...`
  - `Floating Grid`
  - `Tile Work Set`
  - `Apply Template`
  - `Launch Missing Apps`
  - `Never Auto-Tile App`
  - `Retile and Rebalance Windows`
- When scope matters, labels use `on This Desktop` rather than abstract terms like `visible`.
- Important buttons are expected to be visibly prominent. Tiny faint CTA text is contrary to the current direction.
- If a feature may be hard to discover, the UI names the entry literally:
  - `Right-Click Menu`
  - `right-click the TilePilot menu bar icon`
- Setup and recovery copy should answer:
  - what is missing
  - why it matters
  - what to do now
- Unsupported advanced system dependencies are intentionally de-emphasized in normal UX flows.

## Important UI-Facing Types

App shell:

- `TilePilotTab`

Overview, map, and window state:

- `OverviewDisplayPreview`
- `OverviewDesktopPreview`
- `OverviewWindowPreview`
- `WindowState`
- `WindowBadgeState`

These are centered around:

- `Sources/TilePilot/Models/LiveStateModels.swift`

Setup:

- `SetupGuideStep`
- related status, category, and action model used by `SetupGuideView`

Shortcuts and right-click menu:

- `ShortcutsDisplayItem`
- `PinnedShortcutContextItem`

Visual primitives:

- `MapWindowPalette`
- `MegamapHudButtonStyle`
- `EmptyStateView`
- `AppNameWithIconView`

## High-Value Validation Scenarios

- Main IA:
  - tab order must remain `Overview`, `Behaviors`, `Actions & Shortcuts`, `Appearance`, `Config Files`, `System`
- Overview:
  - degraded state should surface obvious recovery actions
  - mini-map should preserve real vertical display stacking
  - `Jump` and `Tiling On/Off` should remain directly visible at desktop-card level
- Maps:
  - blank-title or transient helper windows should not pollute maps
  - fullscreen dialog or backdrop junk should not create giant overlays
  - hovering app icons should visibly strengthen window outlines
- Shortcuts:
  - pinned right-click menu items and `Actions & Shortcuts` names and order should stay aligned
  - the `Right-Click Menu` section should remain part of the same page scroll as the full catalog
- Setup:
  - guided setup should remain the primary recovery path when essentials are missing
  - optional permissions should be explained but not necessarily block readiness
- Appearance and Behaviors:
  - dense numeric and picker controls should stay visually close to their labels
  - control wording should stay gesture-oriented and result-oriented rather than internal-jargon driven

## Assumptions

- This document is code-derived only. It is not a substitute for explicit product decisions that are not represented in source.
- There is no evidence of a deeper tokenized design system today. Repeated conventions are local patterns, not enforced global primitives.
- Some historical wording and layout choices came from iterative product feedback and now live directly in view code. They should be treated as part of the current design context unless deliberately changed.
- The strongest top-level visual split in the app is:
  - light, card-based operational and settings UI in the main window
  - dark, immersive, canvas-like `MegaMap`
