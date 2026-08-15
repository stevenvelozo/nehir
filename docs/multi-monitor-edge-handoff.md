# Multi-Monitor Support via Coupled Edge-Handoff

Status: **proposed / implemented-but-unconfirmed** (no runtime confirmation yet).
Use `fixed` / `works` only after confirmation on real hardware across the
acceptance matrix below.

This document is self-contained: it inlines the evidence and cites durable
source locations (file:line) rather than any runtime trace.

## 1. Problem

Nehir is a niri-style scrolling window manager. Each display hosts its own
horizontally (or vertically) scrolling strip of columns. Side-by-side display
arrangements — specifically a **second display arranged to the right** — do not
work: columns scrolled/laid out past the primary's inner edge collide with the
neighboring display, and windows either vanish or fail to composite. The config
UI currently declares this arrangement unsupported
(`DisplayEnvironmentDiagnostics.swift:42`, title *"Unsupported vertical display
overlap detected"*).

Target environment: a real external monitor **and** an iPad used as a secondary
display over Sidecar, in every arrangement (left / right / above / below).

## 2. Root cause — two macOS constraints, not nehir's coordinate math alone

The naive framing ("nehir parks off-screen columns past the primary's right
edge") is directionally correct but incomplete. The deeper blockers are two
macOS WindowServer behaviors, both confirmed in `docs/offscreen-clamp-fix.md`:

- **Clamp.** macOS will not move a full-size external app window truly
  off-screen. A request to park at, e.g., `y = -10000` is clamped back to
  `y ≈ -1034`, leaving a visible remnant. The same clamp applies on X. And *no
  tested API can order out external app windows* — there is no true "hide" for
  another app's window short of `AXMinimize` (which animates to the Dock and
  discards the tiled position).
- **Straddle.** A window whose center lies on display 2 does not composite its
  display-1 sliver (worse over AirPlay/Sidecar). So a window cannot visually
  straddle the bezel.

Jointly these rule out both "hide the column in empty space past all displays"
**and** "let the column straddle the bezel."

### Code mechanics (durable citations)

- **Absolute column X is unbounded.** A column's rendered origin is
  `renderedX(idx) = monitor.visibleFrame.minX + (containerPositions[idx] −
  containerPositions[activeIdx]) − viewOffset`
  (`NiriLayout.swift:342`, `:358–372`; strip-local sum at
  `ViewportState+Geometry.swift:321`). No clamp to monitor bounds is applied, so
  a column to the right of the viewport is laid out at X past
  `monitor.frame.maxX` — physically where a right-side display sits.
- **Two hide gates** (`containerVisibilityState`, `NiriLayout.swift:382`):
  - Gate A `containerIntersectsViewport` (`:420`, horizontal at `:427`) hides a
    fully off-screen column.
  - Gate B `overflowEdgeIntersectingNeighboringMonitor` (`:436`) hides a
    *partially visible* column whose overflow sub-region intersects a neighbor
    CGDisplay's `frame`. This is the "windows vanish near the inner edge" case.
- **Naive park collision.** When no `hiddenPlacementMonitor` is threaded
  through, a hidden column falls to `hiddenColumnRect` (`NiriLayout.swift:1240`),
  which parks flush at `viewFrame.maxX − edgeReveal` (`:1253`) — directly
  overlapping a right neighbor. The neighbor-aware resolver
  `HiddenWindowPlacementResolver.placement` (`SideHiding.swift:161`) *does*
  minimize overlap against other monitors' frames (`overlapArea`, `:317`) and
  tries the opposite edge (`candidateEdges`, `:222`), but only its two
  *owning-monitor* edges are candidate X positions — it never synthesizes a
  guaranteed-clear zone, and the naive fallback bypasses it entirely.
- **Per-display independence exists.** `ViewportState` is per-workspace
  (`WorkspaceManager.swift:154`); workspace→monitor is 1:1
  (`NiriLayoutEngine.workspaceMonitorIndex`, `NiriLayoutEngine.swift:173`). There
  is no shared cross-display coordinate line. This 1:1 model is load-bearing and
  is **preserved** by the chosen design.
- **Drag across the bezel is never re-admitted.** Frame changes are observed via
  the private SkyLight `CGSEventObserver` (`AXEventHandler.swift:1470`) →
  `handleFrameChanged` (`:2058`). The `.tiling` branch (`:2081–2117`) requests a
  relayout of the *source* workspace only; it never resolves which monitor the
  new frame landed on. The full resolve-and-rebind pattern already exists —
  `reanchorStickyWindowsToActiveWorkspaces` (`LayoutRefreshController.swift:2591`)
  does `monitorApproximation` → `activeWorkspaceId(on:)` → `setWorkspace` — but is
  gated to *sticky* windows.

### Upstream `#198`

`f097f35` ("Invalidate cached column spans when the monitor set changes") is
synced (cherry-picked onto this branch). It fixes column-*width* rescaling on
dock/undock when the monitor set changes (cache keyed by `CGDirectDisplayID`);
it does **not** address the park-collision or straddle problems. Partial, clean,
independent.

## 3. Chosen model — Coupled Edge-Handoff

Decision (with the repo owner): keep independent per-monitor strips and the 1:1
workspace↔monitor model, and make the shared inner edge robust by handing
columns off to the neighbor's strip discretely, rather than parking them
off-screen (defeated by the clamp) or straddling (defeated by compositing).

Net model = **independent per-monitor strips + snap-clamped inner bezel +
intentional column handoff + cross-display focus crossing.** Smallest blast
radius; delivers the "windows march onto the next monitor" feel.

### Three cases

- **Case 1 — fully off-screen columns.** Park on the **outer** edge (the edge
  away from any neighbor), which cannot bleed. Fix: always thread
  `hiddenPlacementMonitor` through, and bias `HiddenWindowPlacementResolver`
  toward the neighbor-free edge; remove the neighbor-unaware
  `hiddenColumnRect` fallback path for multi-monitor. *Low risk — the
  neighbor-aware resolver largely exists.*
- **Case 2 — a column mid-crossing the inner bezel.** Snap-clamp the viewport so
  a column is never left straddling the inner edge — it is either fully on this
  display or handed off. Hook: per-monitor inner-edge-aware clamp in
  `boundedViewportStart` / snap logic (`ViewportState+Geometry.swift`).
- **Case 3 — a column pushed past the inner edge → hand off.** Reassign to the
  neighbor display's workspace, inserted at that strip's near edge. Reuses the
  Q3 machinery (`monitorApproximation` → `activeWorkspaceId(on:)` →
  `setWorkspace`). The **same** hook re-admits a manual mouse-drag across the
  bezel (fixes the drag-desync bug).

### Confirmed sub-decisions

1. **Passive scroll never migrates windows.** Scrolling pans/reveals within a
   display only; a window changes monitors solely via an explicit
   move-column-to-neighbor command or a mouse drag. Handoff is intentional.
2. **Cross-display focus crossing: yes.** Focus-toward-neighbor from the
   edge-most column jumps focus to the neighbor's near column (no window moves).
   This provides the continuous feel without coupling window layouts.
3. **Outer edges unchanged.** The far side of the leftmost/rightmost display
   parks off-screen exactly as single-display does today (no wrap-around).

### Inner-edge detent scroll (Phase 2 — proposed, replaces Case 1/2 at the inner edge)

Observed symptom (user repro, code-cited): with two 50%% tiled columns, focusing
the left column and resizing it to 75%% leaves the right column laid out at
`1536..2560` — straddling the inner bezel (`2048`). `overflowEdgeIntersecting-
NeighboringMonitor` (`NiriLayout.swift:431`) culls the whole column, so a
background gap shows where the user expected the column's on-monitor-1 portion.
Showing that portion is blocked by the macOS straddle/compositing limit (a window
centered at/past the bezel will not composite its near sliver — the same limit the
`crossMonitorOverflow` fork toggle hit, worst over Sidecar).

Decision (with repo owner): make the inner (neighbor-facing) edge a **detented
page edge**, applied ONLY to an edge that abuts a neighbor display; outer edges
keep normal niri smooth-scroll-and-peek.

- The rightmost column **rests flush at the bezel, fully visible** — the viewport
  resting bound is clamped so no column rests straddling the inner edge.
- Scrolling further toward the neighbor **resists** (overscroll rubber-band) and
  only **commits** to advancing the next column fully into view once the pull
  passes a threshold — a discrete step, never a straddle.
- A **chevron / count indicator** at the inner edge signals there are N more
  columns off-screen, brightening as the user pulls.

Build stages: (2a) resting snap-clamp + overscroll-commit mechanics, threshold
feel-tuned on real hardware; (2b) the chevron/count affordance. Threshold and
animation constants are tunable and MUST be tuned live, not fixed from reasoning.

### iPad / Sidecar — decide live

Treatment (fully-managed vs present-only) is deferred to live testing on the
actual iPad, because AirPlay adds compositing/latency quirks on top of the above.
Test both early; lock based on what holds up.

## 4. Acceptance matrix

Second display ∈ {left, right, above, below} × transport ∈ {real HDMI/DP, iPad
Sidecar} × behavior ∈ {tiling correct, drag-across works, no windows lost}.

Each cell must be confirmed live before being marked `works`. The historically
broken cell is **right / real + Sidecar**; left/above/below are reported working
and are regression targets.

## 5. Verification tooling

Set `ipcEnabled = true` in `~/.config/nehir/settings.toml`, then use
`nehirctl query displays | windows | reconcile-debug | focused-window-decision`.
Follow the repo's `/nehir-bug-discovery` flow. Confirm live before any `works`
claim.

## 6. Implementation status

- [x] `#198` cherry-picked, builds.
- [x] Case 3 — drag re-admission. **User-confirmed working on real hardware
      (2nd display = right-side Sidecar iPad):** a manually-dragged tiled window
      transfers into the target display's engine tree as a real tiled column and
      reveals + focuses where dropped. Implementation: debounced (`120ms`)
      drag-settle handler in `AXEventHandler.handleFrameChanged` →
      `readmitDraggedWindow` (`WorkspaceNavigationHandler`) using a new
      `.followTarget` focus policy (transfer + reveal + focus; reveals in place if
      a native path already moved but parked it). Earlier reconcile-cadence
      approach was removed — it raced the hide/focus passes into a
      non-deterministic float. Temporary runtime-trace markers
      (`seam_readmit_scheduled` / `seam_readmit_fired`) remain for diagnosis.
- Case 1 / Case 2 — **superseded by the inner-edge detent-scroll design below.**
  - [x] Resize-path resting-flush clamp. **User-confirmed working on real
        hardware (right-side Sidecar iPad).** In an overflowing strip against the
        neighbor, resizing a column no longer leaves the rightmost column
        straddling (culled to a black gap) AND no longer snaps back to the old
        width every other keypress — both were the fit/reveal thrashing against
        the straddle. Implementation: `ViewportSnapContext.rightEdgeHasNeighbor`
        + `viewStartAvoidingRightStraddle` (semantic A: rightmost flush at bezel,
        earlier columns clip the outer edge), computed in `makeViewportSnapContext`
        and applied in the resize reveal (`NiriLayoutEngine+Sizing.swift`).
  - [ ] Navigation-path clamp (`scrollToReveal`) — deferred; needs an
        active-column-preservation guard so flushing a right straddler cannot push
        the column being revealed off-screen.
  - [ ] Trackpad-scroll overscroll detent + pull-to-commit (tunable threshold).
  - [ ] Chevron / count affordance at the inner edge (Phase 2b).
- [ ] Cross-display focus crossing.
- [ ] Config `horizontalDisplayArrangement` messaging updated once side-by-side
      is supported.
- [ ] Real-hardware verification across the full acceptance matrix (other
      arrangements {left, above, below} × {real HDMI, Sidecar}; only right +
      Sidecar confirmed so far).

All feature edits are fenced with `NEHIR-SHELL SEAM` markers and kept minimal
against the upstream-derived base.
