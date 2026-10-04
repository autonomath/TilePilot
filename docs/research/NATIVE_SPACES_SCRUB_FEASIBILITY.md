# Native Spaces Scrub Feasibility

## Goal

Investigate whether TilePilot can drive a **native-feeling macOS Spaces scrub**:

- hold a trigger
- move horizontally
- let macOS own the real Spaces transition
- release to let macOS commit the destination

This is intentionally **not** a TilePilot-owned fake desktop scrubber and **not** a normal previous/next desktop jump.

## Scope Of The Spike

- isolated internal trigger only
- no user-facing settings
- no default shortcut
- no right-click menu entry
- no integration into normal desktop navigation paths

Internal trigger path:

- `tilepilot://internal/native-spaces-scrub-spike`

## What Was Tested

### 1. Public CGEvent synthetic horizontal scroll probe

Mechanism:

- create continuous two-axis scroll-wheel CGEvents
- set scroll phases (`mayBegin`, `began`, `changed`, `ended`)
- post them to `.cghidEventTap`
- query the current Space before and after using yabai

Observed result on the dev machine:

- `before = 2`
- `after = 2`

Conclusion:

- supported synthetic horizontal scroll events did **not** move Spaces
- this did **not** produce true native Spaces motion
- this did **not** leave commit behavior under macOS control, because no native transition started at all

### 2. Public AppKit swipe tracking review

Relevant surface:

- `NSEvent.trackSwipeEvent(with:...)`

Conclusion:

- AppKit swipe tracking is for handling swipe/scroll events inside an app responder
- it is **not** a supported API for driving Mission Control or setting Spaces transition progress globally

### 3. Dock / Mission Control private surface inspection

Evidence extracted from Dock:

- `SpaceSwitchTransition`
- `Mission Control switch to previous space`
- `Mission Control switch to next space`
- `currentSpaceID`
- `Changing from mode ... with fluid gesture`

Conclusion:

- real native Spaces switching clearly lives in Dock / Mission Control private machinery
- this is private and undocumented
- private-only viability is not a supportable shipping path

## Viability Assessment

| Path | Public / Private | Produced native Spaces motion | Shipping recommendation |
| --- | --- | --- | --- |
| Synthetic CGEvent horizontal scroll | Public | No | No-go |
| AppKit swipe tracking | Public | No | No-go |
| Dock / Mission Control internals | Private | Private surface exists, but not supportable | Do not ship |

## Recommendation

Current recommendation: **do not build** this as a shipping native Spaces scrub feature on the current approach.

Reason:

- the supported path did not move Spaces at all
- the promising surface area appears to be private Mission Control / Dock machinery
- relying on that would make the feature brittle and unsupported

## What The Internal Spike Still Adds

The spike is still useful because it gives TilePilot:

- a rerunnable internal feasibility action
- a saved diagnostics report under `~/Library/Application Support/TilePilot/Diagnostics`
- a concrete record of why the answer is currently “no-go”

## Boundary

This research deliberately does **not** implement:

- a TilePilot-owned overlay scrubber
- a user-facing shortcut
- mouse capture UI
- a fake desktop carousel fallback

If a future phase explores a TilePilot-owned scrubber, that should be a new feature proposal, not an extension of this spike.
