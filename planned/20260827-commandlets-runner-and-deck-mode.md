# Commandlets: runner, store, ⌘D→x mode, and history-picker manager (P2 + P3)

Status: **Proposed** — design locked with the author (2026-08-27). Implement-ready
after its do-not-touch fences are respected. Follows
`planned/20260824-commandlets-and-inherent-terminal.md`, whose **P1a (persistent
peekable inherent terminal) shipped in v1.7.1**; this doc is that parent's **P2 + P3**,
now that the terminal substrate exists.

Anchored against `main` post-v1.7.1 (the shipped inherent terminal). All source paths
are repo-relative to the main Nehir repository; line numbers verified against that tree.

## What already exists (the P1a substrate we build on)

`Sources/NehirShell/Overlays/OverlayTerminalController.swift` is now a **warm, persistent**
session with exactly the primitives a runner needs:

- `showPeek(frame:)` (`:46`), `focus()` (`:52`), `hide()` (`:64`), `close()` (`:70`) —
  peek vs. focus vs. teardown are already split.
- `runCommand(_:frame:)` (`:81`) — reveal + run entry.
- **`sendLine(_:)` (`:88`)** → `terminalView?.send(txt: text + "\n")` — write a line **and
  run it** (this is *run*).
- **`send(_:)` (`:93`)** → `terminalView?.send(txt:)` — write a line **without** the
  newline (this is *load*: leave the cursor for the author to edit, then Enter).
- `buildSession` launches `$SHELL -li` with `currentDirectory:` (`:159`); the child is a
  real login+interactive shell (its history file is the one we read).

`OverlayController` owns the terminal and the webview bridge, and the **Settings** feature
we just shipped is the exact template for the manager UI:

- `shell.overlay.register("settings", …)` → `nehir-resource://settings.html`
  (`Sources/NehirShell/Overlays/OverlayController.swift:530`), reached from the menu bar via
  `overlays?.show("settings")` (`ControlDeckController+MenuBar.swift:57`).
- `handleWebAction(_:)` (`OverlayController.swift:540`) dispatches bridge messages;
  existing cases include `settingsGet` (`:547`), `fontsGet` (`:549`), `settingsSet`
  (`:551`), `overlayClose` (`:553`).
- **`sendAvailableFonts()` (`OverlayController.swift:627`)** is the canonical *host-data
  bridge*: it reads a host resource (installed fonts), normalizes it, and pushes it into
  the webview with `evaluateJavaScript("window.applyHostFonts([...])")`. **The history
  picker is the same pattern with the shell history as the source.**

`x` is currently the **Tools** command-builder webview, registered as a dynamic OSD
extension: `shell.overlay.osd("tools", { group: "Extensions", key: "x", label: "Tools" }, …)`
(`OverlayController.swift:523`), appended to the Deck root by `refreshExtensionEntries()` as
a `.showOverlay` action (`ControlDeckController.swift:345`, kind at `:353`). P3 repurposes
`x` from "show that webview" into a native **Commandlets** mode, and keeps the builder one
keystroke away *inside* the mode.

The Deck router is a four-layer state machine under `Sources/NehirShell/ControlDeck/`:
`DeckKey` / `DeckActionKind` (`DeckTypes.swift`: `.enterMode` `:51`, `.showOverlay` `:55`),
`DeckModeID` enum (`DeckTypes.swift:74`), `DeckCatalog.mode(_:)` (`DeckCatalog.swift:13`) +
the `root` mode (`:51`), `DeckModel.handle(key:)` (`DeckModel.swift:287`) with per-mode
handlers, `setMode(_:)` seeding live data (`DeckModel.swift:415`), and `DeckView.content`
(`DeckView.swift:30`). The commandlets mode is modeled on the existing numbered-list
handlers: `handleListPick` (`DeckModel.swift:367`, used by the `columns` mode) and
`handleInternals` (`DeckModel.swift:348`), with `DeckInternalsView` (`DeckView.swift:46`)
as the view template.

## Converged design (locked with the author, 2026-08-27)

- **`⌘D → x` is a pure runner palette.** It shows slots **1–9** with their labels (empty
  slots dimmed, so the palette always reads as a map of what's bound). `digit` = **run** the
  slot in the inherent terminal; `⌥digit` = **load** it. A **Manage…** row opens the editor;
  a **Builder** row opens the existing Tools webview (preserving builder access). No pinning
  or history interaction happens in the palette.
- **All assignment happens in the pict manager** (a webview, like Settings; reached from the
  menu bar and from the palette's Manage… row). Slots on the left; a shell-history picker on
  the right with a **Recent ⇄ Frequent** toggle, type-to-filter search, and a **Refresh**
  button. Clicking a history line drops it into the selected slot; the author sets the label,
  the **pinned-folder / floating** cwd toggle, and (later) the interpreter. Persists to
  `~/.config/nehir/commandlets.json`.
- **Per-slot cwd is a toggle.** A slot is either *pinned* to a folder (run does
  `cd <cwd> && <body>`) or *floating* (run writes the body bare, wherever the terminal is).
  Saving from history defaults to *pinned* at the terminal's **live cwd**, one click flips
  it to floating.
- **History picker offers both orderings**, toggled: *Recent* (deduped, newest-first) and
  *Frequent* (by run count). One host read hands the webview a normalized, deduped list
  `[{ command, lastUsed, count }]`; the toggle just re-sorts.
- **Refresh is a manual button** (no auto-flush, no touch to the author's shell rc). It
  nudges the inherent session to write its in-memory history, then re-reads the file — so it
  catches what was just run in our terminal *and* anything other terminals have written.
- **Run vs. load**: run = `sendLine` (write + Enter); load = `send` (write, leave cursor).

## Commandlet record (nehir-side JSON store)

`~/.config/nehir/commandlets.json` — one array, hand- and UI-editable. Location anchored on
`ShellPaths.configDirectory(environment:)` (`Sources/NehirShell/Config/ShellConfig.swift:144`),
the same dir that already holds `shell.d/` and the managed `20-terminal.toml`.

```json
[
  { "id": "run-tests", "name": "npm test", "interpreter": "argv",
    "body": "npm test", "cwd": "~/Code/thatrepo", "pinnedCwd": true, "slot": 3 },
  { "id": "deploy-docs", "name": "Deploy docs", "interpreter": "bash",
    "body": "npm run build && ./deploy.sh", "cwd": "~/Code/retold/docs",
    "pinnedCwd": true, "env": ["NODE_ENV"], "slot": 1 }
]
```

- `pinnedCwd: false` → `cwd` is ignored; the body runs floating (no `cd`).
- `interpreter: "argv"` → body is a pre-resolved one-liner run as-is (the default for a line
  picked from history). `bash | zsh | sh` → `cd <cwd> && <body>`. Program interpreters
  (`node | python3 | …`) and shebang bodies follow the parent doc's runner (temp file +
  `cd <cwd> && <interp> <file>`); those matter only for the builder-sourced path (P4), not
  for history-picked commandlets.
- `env` references variable **names**, never values (no secrets/PATH baked into the store) —
  carried forward from the parent doc; not required for the history-picker MVP.
- `slot` is optional; a commandlet can exist unslotted (in the manager list) and be bound to
  a digit later.

## P2 — commandlet model, store, and runner

New file `Sources/NehirShell/Commandlets/CommandletStore.swift` (a plain
`Codable` model + load/save over the JSON file; no Deck or webview coupling):

- `Commandlet` (`Codable`): the record above.
- `CommandletStore`: `load()` / `save(_:)` against
  `ShellPaths.configDirectory().appendingPathComponent("commandlets.json")`; tolerant of a
  missing file (empty array) and of hand edits; stable ordering by `slot` then insertion.
- `run(_:load:)` builder: given a `Commandlet`, produce the exact string to hand the
  terminal — `pinnedCwd ? "cd \(shellQuoted(cwd)) && \(body)" : body` for shell/argv
  interpreters. The controller then calls `terminalController.sendLine(line)` for **run** or
  `terminalController.send(line)` for **load**, after `showPeek`/`focus` reveals the terminal.

Runner wiring lives in `OverlayController` (it already owns `terminalController`): a
controller-level `runCommandlet(_:load:)` that reveals the terminal pane and sends the line,
independent of any webview `run` path.

**Terminal cwd read (for the manager's pinned-cwd default).** SwiftTerm exposes the child
shell pid — `LocalProcess.shellPid` is `public private(set)`
(`.build/checkouts/SwiftTerm/Sources/SwiftTerm/LocalProcess.swift:70`). Add a
`currentWorkingDirectory` accessor on `OverlayTerminalController` that reads the live shell's
pid from the `LocalProcessTerminalView`'s process and resolves its cwd via
`proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, …)`. (If the `process`/`shellPid` accessor is not
public on `LocalProcessTerminalView`, add a one-line passthrough rather than reaching into
SwiftTerm internals.)

Do-not-touch: the tap-lifecycle + focus invariants shipped in v1.7.1
(`ControlDeckController.installKeyTap`/`removeKeyTap`/`hide`, and
`OverlayTerminalController.focus`/`close`) — the runner only *sends text into an existing
session*; it must not re-arm or tear down taps, nor change when the terminal becomes key.

## P3 — native `⌘D → x` Commandlets mode + pict manager

### Native palette (the runner)

- Add `case commandlets` to `DeckModeID` (`DeckTypes.swift:74`).
- Add a `commandlets` `DeckMode` and a `.commandlets:` arm in `DeckCatalog.mode(_:)`
  (`DeckCatalog.swift:13`). Bind root key `x` to `.enterMode(.commandlets)` instead of the
  dynamic Tools `.showOverlay` — either promote `x` to a static root action or special-case
  it in `refreshExtensionEntries` (`ControlDeckController.swift:345`) so the Tools overlay
  stays registered (for the mode's Builder row) but no longer claims the root `x` key.
- Add `handleCommandlets(key:)` to `DeckModel` modeled on `handleListPick`
  (`DeckModel.swift:367`): `digit` → run slot N, `⌥digit` → load slot N, plus rows for
  **Manage…** (`.showOverlay("commandlets")`) and **Builder** (`.showOverlay("tools")`).
  Dispatch it from `handle(key:)` (`DeckModel.swift:287`). Seed the mode's rows in
  `setMode(_:)` (`DeckModel.swift:415`) via injected `readCommandletSlots` / `runCommandlet`
  closures (the model stays UI-only; the controller owns the store + terminal).
- Add `DeckCommandletsView` to `DeckView.content` (`DeckView.swift:30`), copied from
  `DeckInternalsView` (`:46`): the 1–9 slot list with labels, empty slots dimmed, and the
  Manage…/Builder rows.

### Manager webview (assignment + history picker)

- New resource `Sources/NehirShell/Resources/commandlets.html` — a pict app (same shell as
  `settings.html`: `pict.min.js` + `pict-section-form.min.js`, `Pict-Form-Container`,
  `window.webkit.messageHandlers.nehir` bridge). Left: the nine slots (assign / clear /
  reorder). Right: the history picker (Recent ⇄ Frequent toggle, search, **Refresh**), plus
  per-slot editors (label, pinned/floating cwd toggle with the captured default, interpreter).
- Register it in the builtin JS next to Settings: `shell.overlay.register("commandlets", …)`
  → `nehir-resource://commandlets.html` (mirror `OverlayController.swift:530`). Reach it from
  the menu bar with a **Commandlets…** item next to **Settings…**
  (`ControlDeckController+MenuBar.swift:45`/`57`, `overlays?.show("commandlets")`), and from
  the palette's Manage… row.
- New `handleWebAction` cases (`OverlayController.swift:540`), alongside the settings ones:
  - `commandletsGet` → push the current store + slot map to the webview (mirror
    `sendCurrentTerminalSettings`, `:614`).
  - `historyGet` → **the new host-data bridge**: read the shell history file, normalize,
    dedupe to `[{command, lastUsed, count}]`, push via `window.applyHostHistory([...])`
    (mirror `sendAvailableFonts`, `:627`). Shell auto-detected from `$SHELL` (`zsh` →
    `~/.zsh_history`, extended `: <ts>:<elapsed>;<cmd>`; `bash` → `~/.bash_history`, plain
    lines; honor `HISTFILE` when set).
  - `historyRefresh` → nudge the inherent session to append its in-memory history, then
    re-read and re-push (see open question on the nudge mechanism).
  - `commandletSave` / `commandletsSet` → write the store (mirror `applyTerminalSettings`
    + `writeTerminalSettingsFragment`).
  - Reuse `overlayClose` (`:553`).

Do-not-touch: the AX focus/reveal/activation core
(`Sources/Nehir/Core/Controller/AXEventHandler.swift`, `handleAppActivation` /
`confirmManagedFocus` / the reveal path) and the v1.7.1 tap-lifecycle invariants — the mode
and manager only read/write the store and send text into the existing terminal.

## Build order and gate

P2 (store + runner + cwd read) first, then P3 (palette, then manager). `mise run build`
between steps; `mise run test` once at the end. Per repo policy, **no test additions/edits**
until the author confirms the behavior in a real run or explicitly asks for tests.

Commit message shapes (plain English, no Conventional Commits, no upstream `#nnn`):
- `Add the commandlet store and inherent-terminal runner`
- `Add the ⌘D x commandlets palette and the commandlet manager`

A user-visible feature → a `minor` changeset at finalization
(`mise run changeset minor "…"`).

## Open questions / risks

- **`⌥digit` = load — modifier threading.** `DeckKey` carries `.commandDigit(Int)` (⌘+digit,
  `DeckTypes.swift:30`) but bare/option digits arrive through the character path. Confirm how
  the key resolver + `installKeyTap` surface the Option modifier, and thread it into
  `handleCommandlets` (a dedicated key case, or modifiers passed alongside the digit). This is
  the one non-trivial wiring in the palette.
- **Refresh nudge mechanism.** To catch what was *just* run in our terminal, `historyRefresh`
  should make the inherent shell append first (`zsh: fc -AI`, `bash: history -a`). Sending
  that over the PTY echoes a line into scrollback. Options: (a) re-read only (simplest, may
  lag the in-session command); (b) send a space-prefixed flush (relies on ignore-space) and
  accept/scrub the echo; (c) flush at a natural quiet moment (e.g. when the terminal loses
  focus) in addition to the button. Recommend (b) with the echo scrubbed, falling back to (a).
- **cwd accessor surface.** Prefer a one-line passthrough on `OverlayTerminalController` over
  reaching into SwiftTerm internals for `shellPid`.
- **Empty-palette + label defaults.** Empty slots render dimmed "—"; a history-picked slot
  defaults its label to the command (truncated), editable in the manager.

## Non-goals (for now)

- Builder "Save → commandlet" (parent doc P4) and program-interpreter/temp-file bodies —
  the history picker covers shell one-liners; the builder path lands later.
- Multiple concurrent sessions, sandboxing (the author's own scripts, author's privileges),
  and full iTerm parity — unchanged from the parent doc.

## Provenance

Design co-developed with the author on 2026-08-27, building directly on
`planned/20260824-commandlets-and-inherent-terminal.md` (whose P1a shipped in v1.7.1).
Current-state facts verified against the main Nehir source tree post-v1.7.1. Related
tracking lives on the Nehir plansheet (IDCustomer 29).
