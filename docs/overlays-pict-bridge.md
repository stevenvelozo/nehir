# Overlays — the pict→native shell UI primitive

## Status

**Proposed; design agreed.** No implementation has landed yet. This document is
the design of record for the "pict bridge" overlay work. The first registered
consumer is a Desktop-screenshots popup (hotkey → native grid → drag a file
out).

## Goal and ethos

Let a small piece of JavaScript decide *what* the shell should show, and let
Swift render it natively and fast. The north star is a general **Overlays**
primitive — OSD-like surfaces, but useful UI that pict apps drive — with the
folder popups (Desktop, later Downloads and other oft-used folders) as the first
overlays. The authoring loop is deliberately LiteStep-in-JavaScript: drop a
small script in a config directory and bind it to a hotkey.

Three eventual roles for pict in the shell, in build order:

1. **pict→native UI (this document).** pict decides *what*; Swift renders and
   owns every native affordance (thumbnails, drag-out, layout). Trickiest of the
   three because it crosses the JS→native boundary with real drag semantics, so
   it goes first.
2. **Script host.** The same registry, driven by timers and hotkeys, where
   providers call shell capabilities (e.g. set a border color by time of day).
   Built on the same `evaluate` entry point.
3. **Embedded webview.** A performance-guarded `WKWebView` overlay kind,
   summonable, same lifecycle.

A later back end connects scripts to Exordium through the out-of-process runtime.

## Substrate reused (no base window-manager edits)

Every piece below already exists; the overlay work wires new surface onto it and
stays inside `Sources/NehirShell/` and `Sources/FableCore/` (both marked
`NEHIR-SHELL SEAM` in `Package.swift`), so `git merge upstream/main` never
touches it.

- **`FableCore`** — `pict.min.js` hosted in JavaScriptCore, in-process
  ([FableCore.swift:26](../Sources/FableCore/FableCore.swift)). Surface used:
  `render`, `solve`, `callService`, `evaluate(js)` (with the pict `app` as a JS
  global), `setSetting`, `log`. This is the "pict brain."
- **`FableRuntime`** — a unified `invoke(method, params) async -> JSONValue`
  protocol implemented by both `FableCore` (in-process) and `NodeSidecar`
  (out-of-process `node`, real fs/network/npm)
  ([FableRuntime.swift:17](../Sources/FableCore/FableRuntime.swift),
  [NodeSidecar.swift:15](../Sources/NodeSidecar/NodeSidecar.swift)). This is the
  seam for the hybrid contract: the declarative query resolves in Swift now; the
  explicit item-list path routes through `NodeSidecar` later.
- **`JSRuntime`** — owns the single `JSContext`
  ([JSRuntime.swift:19](../Sources/FableCore/JSRuntime.swift)). Home of the
  execution-time-limit safeguard (below).
- **Panel family** — non-activating `NSPanel`s (Control Deck, column badges,
  off-edge indicators) created through `NehirBadgePanel.make()`. Overlay panels
  join this family so they float without stealing focus.
- **`DeckHotkey`** — a global chord via Carbon `RegisterEventHotKey`, but wired
  for a *single* hotkey (`signature 'NSHK', id 1`)
  ([DeckHotkey.swift:75](../Sources/NehirShell/ControlDeck/DeckHotkey.swift)).
  Overlays need this generalized to one id per registered overlay.
- **`ShellCommandRouter`** — JSON-line command dispatch over the control socket
  ([ShellCommandRouter.swift:15](../Sources/NehirShell/Control/ShellCommandRouter.swift)).
  The external / iPad-remote control surface; overlays add `overlay.show/hide/list`.
- **TOML `shell.d/`** config — typed core plus a `custom` string map, merged in
  filename order, with a seeded sample
  ([ShellConfig.swift:98](../Sources/NehirShell/Config/ShellConfig.swift)).

## Architecture

Three layers plus a capability surface.

### 1. `OverlaySpec` — the pict→native contract (JSON)

A content query plus presentation *intent*. It never carries pixels; Swift owns
the visual execution.

```
{
  source:  { kind: "fileQuery",
             roots: ["~/Desktop"],
             filter: { uti: ["public.image"], nameGlob: "Screenshot*.png" },
             sort: "modifiedDesc", limit: 24 },
  present: { anchor: "activeMonitorCenter", sizeClass: "medium",
             layout: "grid", thumb: "large" },
  item:    { drag: "fileURL", click: "reveal" },
  dismiss: { on: ["esc", "clickAway", "retrigger"], autoAfter: null }
}
```

`source.kind` is the discriminator that keeps the primitive general:

- `"fileQuery"` (this phase) — a declarative directory query resolved natively.
- `"items"` (later) — an explicit resolved list the provider built itself (via
  `NodeSidecar` fs), for logic a query cannot express (recency across multiple
  roots, dedup, arbitrary ranking). Same panel, no schema change.
- `"webview"` (later) — a URL/`WKWebView` surface.

`present` is intent only — `anchor`, `sizeClass`, `layout`, `thumb`. Swift picks
exact geometry and column counts per monitor.

### 2. `OverlayRegistry` (Swift)

Holds registered overlays. Each descriptor is
`{ id, trigger, specProvider, presentationDefaults }` where:

- `trigger` is a hotkey chord (this phase) or, later, a timer or manual/socket
  invocation.
- `specProvider` is a reference to the registered JS callback that returns an
  `OverlaySpec` when pulled.

### 3. `OverlayPanel` (Swift, non-activating `NSPanel`)

Resolves a spec against the real filesystem *natively*: enumerate → filter →
sort → QuickLook thumbnails → native grid. Each cell is an `NSDraggingSource`
carrying the file URL, so a screenshot drags straight into any
nehir-managed window. Reuses the OSD-style timed fade already built for the
off-edge indicators. One panel is on screen at a time this phase.

### 4. Capability surface

- **JS (pict side):** `shell.overlay.register(id, provider)`, `.show(id)`,
  `.hide(id)`, `.update(id, spec)`. `register`/`update` are the push path
  reserved for the script-host phase; this phase uses `register` + pull.
- **Socket (external / iPad-remote):** `overlay.show`, `overlay.hide`,
  `overlay.list` added to `ShellCommandRouter`.

## Decisions (agreed)

1. **Registration model: both.** A scripts directory under the shell config
   (e.g. `~/.config/nehir/overlays/*.js`) is auto-loaded into `FableCore` at
   activation, and each script registers overlays imperatively via
   `shell.overlay.register`. TOML may also declare/enable an overlay and bind its
   hotkey. The scripts directory is the primary "hack in JS" loop; TOML is the
   declarative binding layer.
2. **Spec delivery: pull-on-trigger, with a hard execution-time safeguard.** On
   each trigger Swift pulls the spec synchronously from the provider
   (`evaluate` / `callService`). Because that runs provider JS on the main actor,
   a runaway provider (`while (true)`) would hang the shell. Guard it with
   `JSContextGroupSetExecutionTimeLimit` on `JSRuntime`'s context group
   ([JSRuntime.swift:19](../Sources/FableCore/JSRuntime.swift)): a provider that
   overruns a small wall-clock budget is aborted, the overlay declines to show,
   the error is logged, and the shell stays responsive. Push delivery
   (`update`) is deferred to the script-host phase.
3. **Presentation is intent-only; Swift executes the visualization.** The spec
   expresses anchor, size class, layout, and thumbnail size; Swift owns exact
   pixels, columns, and rendering. Keeps pict off pixel math and keeps native
   layout crisp per monitor.

## Defaults and non-goals (this phase)

- **One overlay on screen at a time.** A new trigger dismisses the current
  overlay. A future multi-overlay "on-screen display" mode is anticipated but
  explicitly out of scope now.
- **Drag = file URLs only.** File-promise / generated-item drags are deferred to
  the `"items"` and virtual-content work.
- **Hotkeys via a generalized `DeckHotkey` registry** — one Carbon hotkey id per
  registered overlay, replacing the single hardcoded id.

## First consumer — the Desktop-screenshots popup

A script such as `~/.config/nehir/overlays/desktop-shots.js`:

```js
shell.overlay.register("desktop-shots", () => ({
  source: { kind: "fileQuery", roots: ["~/Desktop"],
            filter: { nameGlob: "Screenshot*.png" },
            sort: "modifiedDesc", limit: 24 },
  present: { anchor: "activeMonitorCenter", sizeClass: "medium",
             layout: "grid", thumb: "large" },
  item: { drag: "fileURL", click: "reveal" },
}));
```

Press the bound hotkey → Swift pulls that spec → resolves `~/Desktop` for recent
screenshots → renders a native grid → drag one out into any window. pict never
touches a file; it only decides *what*.

## How this feeds the later rungs

- **Script host:** a `timer` trigger calls the provider on an interval and
  providers call shell capabilities; border-color-by-time-of-day falls out with
  no new primitive. Adds the push path (`update`).
- **Item-list escape hatch:** provider returns `source.kind: "items"` built via
  `NodeSidecar` fs (recent across Desktop + Downloads, dedup). Panel unchanged.
- **Webview overlay:** `present.layout: "webview"` hosting a `WKWebView`, same
  lifecycle.
- **Exordium:** a `NodeSidecar` operation the script host invokes.

## Phased build plan

- **Phase 1 — Overlay core + first consumer.** `OverlaySpec` types,
  `OverlayRegistry`, `OverlayPanel` (fileQuery resolver + native grid +
  file-URL drag-out), generalized hotkey registry, the JS capability surface
  (`register`/`show`/`hide`) via `evaluate`, scripts-directory auto-load + TOML
  binding, and the execution-time-limit safeguard. Ship the Desktop-screenshots
  popup. Verify live on real hardware: hotkey summons, grid renders, drag-out
  lands in another window, bad-JS provider is aborted without hanging the shell.
- **Phase 2 — Script host.** Timer triggers, `update` push delivery, visual
  capabilities (border color and friends), authoring-loop polish.
- **Phase 3 — Item-list escape hatch.** Wire `NodeSidecar` into the shell,
  implement `source.kind: "items"`, fs enumeration in Node.
- **Phase 4 — Webview overlay kind and the Exordium connection.**

## Fork safety

All new code lives under `Sources/NehirShell/` and `Sources/FableCore/`, both
already `NEHIR-SHELL SEAM` targets with no upstream counterpart, so upstream
merges never touch it. The only base-manager contact is reading window/monitor
state to anchor and place the panel, through the same APIs the Control Deck and
badge overlays already use.
