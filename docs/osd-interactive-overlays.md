---
title: Interactive OSD Overlays
---

# Interactive OSD Overlays

How to build **interactive** primitives on top of the ⌘D Deck / OSD layer —
things the user clicks, drags, or otherwise manipulates directly on the overlay
(the drag-to-reorder window list is the first of these). It documents the
constraints that AppKit + Nehir's agent-app model impose, and one covering bug
that was misdiagnosed many times before it was measured. Read this before adding
a new interactive overlay; most of the failure modes below are not obvious from
the symptom.

## The environment you are building in

Nehir runs as an `LSUIElement` agent app. Two consequences shape every
interactive overlay:

1. **It cannot become the foreground/active app.** Under macOS Sonoma's
   cooperative activation, `NSApp.activate` is refused for an agent app, so an
   overlay panel can never be the key or main window. Design for this — do not
   build a primitive that needs first-responder text focus, menu-key handling,
   or any behavior that assumes an active app.
2. **Overlay panels must be non-activating.** Use `.nonactivatingPanel` at
   `.floating` level. An activating panel would try (and fail) to pull the app
   forward, and would fight the window it is drawn over.

Within those limits, mouse interaction *does* work — but only if you wire it the
AppKit way, not the SwiftUI way.

## The covering bug (misdiagnosed repeatedly)

**Symptom:** an interactive drag worked exactly once. The overlay stayed on
screen, but the second drag did nothing — no `mouseDown`, no gesture, dead.

**Wrong theories** (each cost a build cycle): macOS mouse-eligibility / HID
gating of a non-activating panel; the panel losing key status mid-gesture;
SwiftUI tearing down the gesture recognizer after one recognition; the app
needing to activate. All plausible, all wrong.

**Actual cause, found by measuring instead of inferring:** dumping the
front-to-back window stack at the cursor (via `CGWindowListCopyWindowInfo` /
`NSWindow.windowNumber(at:)`) *after* the failing second drag named the covering
window — it was **Nehir's own off-edge indicator panel**. That panel
(`OffEdgeIndicator.swift`) is full-screen, is mouse-accepting whenever the Deck
is open (`ignoresMouseEvents = !deckOpen`), and calls `orderFrontRegardless()`
on **every layout update**. A reorder move triggers a layout update, which
re-fronted the off-edge panel on top of the reorder list, where its
transparent-but-hit-testing body swallowed the next drag.

**Fix — keep the covering panel click-through while an interactive overlay is
up.** `OffEdgeIndicator.swift:257`:

```swift
panel.ignoresMouseEvents = !deckOpen || NehirShell.showFullWindowList
```

The interactive reorder list is gated by `NehirShell.showFullWindowList`
(`NehirShell.swift:55`), so the off-edge panel goes click-through for exactly as
long as that list is on screen, and reverts afterward.

**Second covering path — a managed window raised over the overlay.** When a
reorder moves a column, the layout refresh's reveal step would raise that window
to absolute front with the SkyLight `orderWindow` call — on top of the
non-activating overlay, which then loses the mouse (and macOS will not hand it
back without a fresh user key event the agent app can't synthesize). This is
suppressed for the duration of the list via `NehirShellHook.suppressRevealRaise`
(`NehirShellHook.swift:71`), gated at the raise site
(`LayoutRefreshController.swift:4732`), and set/cleared around the list's
present/hide in `ControlDeckController.swift` (`:377`, `:393`, `:407`).

**The general lesson:** "the input stopped arriving" is *not* evidence of an
input-eligibility problem. Before theorizing about HID gating or activation,
measure whether something is simply on top of your overlay. In an agent app that
paints several full-screen overlay panels and re-fronts them on layout ticks,
the answer is often yes.

## The invariant for any interactive overlay

> While an interactive overlay is on screen, nothing Nehir controls may cover
> it.

Two paths let something sneak on top; audit **both** whenever you add a new
interactive primitive:

1. **Another decorative overlay panel that re-fronts on a layout tick** —
   off-edge indicators, column badges, any panel that calls
   `orderFrontRegardless()` from a layout-applied hook. Make it click-through
   (`ignoresMouseEvents = true`) while your overlay is active, keyed off the same
   flag that gates your overlay's visibility.
2. **A managed window raised to absolute front** by the reveal-raise
   (`SkyLight.orderWindow`). Suppress it via `NehirShellHook.suppressRevealRaise`
   while your overlay is up.

If a future primitive introduces a *third* overlay that also re-fronts, this
invariant is what it must not break.

## Patterns that work

- **Non-activating panel, plain `NSPanel`.** Not activating, not forced-key. The
  reorder list uses a plain non-activating panel — no `makeKey`, no activation.
- **Opt the content view into first-mouse.** A non-activating panel drops the
  first click as an activation attempt unless its view returns
  `acceptsFirstMouse == true` (`ColumnBadgeOverlay.swift:423`,
  `ControlDeckController.swift:24`). Without this, every interaction "misses" its
  first click.
- **Drags: use an AppKit mouse layer, not SwiftUI `DragGesture`.** Inside a
  non-key panel a SwiftUI `DragGesture` recognizes once and then stops firing —
  this is the trap that masquerades as the covering bug above. A dedicated NSView
  overriding `mouseDown`/`mouseDragged`/`mouseUp` keeps delivering across
  repeated drags with no rebuild. See `RowDragCatcher`
  (`ColumnBadgeOverlay.swift:337`) and the rationale comment at
  `ColumnBadgeOverlay.swift:389`.
- **Full-screen containers must hit-test passthrough.** A container that fills
  the display has to return `nil` from hit-testing everywhere except its actual
  interactive content, so clicks reach the windows below *and* any other overlay.
  Two mechanisms in use: the AppKit `ReorderPassthroughView`
  (`ColumnBadgeOverlay.swift:591`), and, on the SwiftUI side, the
  `.allowsHitTesting(model.clickable)` gate with transparent regions that never
  capture (`OffEdgeIndicator.swift:81`).
- **Keep interactive state local to the view, commit on drop.** The reorder list
  reorders its own `@State` order optimistically during the drag
  (`ReorderableWindowListView`, `ColumnBadgeOverlay.swift:265`) and only issues
  the real layout move (`reorderColumn`, `ControlDeckController.swift:210`) on
  release. The overlay feels live without waiting on a layout round-trip.

## Diagnosing the next one

When an interactive overlay misbehaves, prefer measurement over theory:

- **Is something covering it?** Dump the window stack at the cursor
  (`CGWindowListCopyWindowInfo` front-to-back, or `NSWindow.windowNumber(at:)`)
  right after the failing interaction and read off what is actually on top. This
  is the single check that would have short-circuited the entire saga above.
- **Is the mouse event even arriving?** A temporary `mouseDown` log in the AppKit
  layer distinguishes "event never arrived" (a covering / eligibility problem)
  from "event arrived, handler wrong" (a logic problem). Keep such
  instrumentation unconditional and strip it before finalizing (see
  `AGENTS.md` → *Temporary bug-tracing instrumentation*).
- **Did a layout tick re-front a panel?** If the overlay works until the first
  layout change and then dies, suspect a re-fronting decorative panel or a
  reveal-raise before suspecting AppKit.

## Status

The reorder overlay and both covering fixes above are confirmed working at
runtime by the fork author (repeated drags across multiple columns, with the
overlay staying live between drags). The covering diagnosis is grounded in the
window-stack dump that named the off-edge panel, not inference.
