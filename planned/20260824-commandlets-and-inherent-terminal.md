# Commandlets & the inherent terminal (Deck runner)

Status: **Proposed** — design locked with the author; P1a is implement-ready, later
phases are roadmap-level pending their own plans. Not yet implemented.

Anchored against `main` @ `18ce97b` (2026-08-24). Note: at time of writing the main
working tree also carries an **uncommitted, observe-only** AX main-window diagnostic
(subscribes each per-app observer to `kAXMainWindowChangedNotification` and logs it;
touches `Sources/Nehir/Core/Ax/AppAXContext.swift`,
`Sources/Nehir/Core/Controller/ServiceLifecycleManager.swift`,
`Sources/Nehir/Core/Controller/AXEventHandler.swift`). That diagnostic is unrelated to
this feature and must not be folded into it — see the do-not-touch fence in P1a.

## Motivation

Nehir's vision is "shell as a first-class tool": the Deck (⌘D) is a full desktop shell,
not just a window manager. This feature turns the Deck into a **launcher/runner** — a
persistent embedded terminal plus saved, one-keystroke **commandlets** ("run *this body*,
in *this shell*, from *this folder*"). A commandlet with a cwd, an interpreter, and a
launcher key is, literally, a shell built on top of the Deck.

North star for the terminal feel: an **iTerm hotkey window** (a warm Quake-style dropdown
terminal that toggles into view with a keystroke, keeps its session and scrollback, and
dismisses back). The author currently drives that via iTerm's ⌘\` hotkey window and wants
to try a Deck-native equivalent; if the Deck-native feel does not win, the same persistent
session gains an iTerm-style global toggle as a second trigger (no rework).

## Current state (observed against `main` @ 18ce97b)

Verified against the main Nehir source tree. Three facts differ from prior memory and
reshape the scope:

1. **The embedded terminal is one-shot, not persistent.** `OverlayTerminalController`
   (`Sources/NehirShell/Overlays/OverlayTerminalController.swift:27`) builds a fresh
   SwiftTerm `LocalProcessTerminalView` per run and calls
   `terminal.startProcess(executable: shell, args: ["-lic", command], …)` where `shell`
   = `$SHELL` else `/bin/zsh` (`OverlayTerminalController.swift:64`). The shell runs **one**
   command and exits; the panel then shows a "process exited" line and waits for ⌘W /
   click-away. It is a floating `OverlayKeyPanel` (not inside the Deck) that **activates
   the app and becomes key** (steals focus). `cwd` is **not** set (child inherits the app
   cwd); SwiftTerm 1.11.2 supports `currentDirectory:` on `startProcess`
   (`Package.swift:43` declares SwiftTerm). There is **no** API to write further input into
   a live session — SwiftTerm's `terminalView.send(...)` → child stdin exists but the
   controller never calls it.

2. **The terminal is reached via ⌘D → x, not backtick.** The Deck key resolver only
   returns a key for letters/digits (`Sources/NehirShell/ControlDeck/ControlDeckController+KeyResolution.swift:24`);
   backtick is punctuation and is silently swallowed
   (`Sources/NehirShell/ControlDeck/ControlDeckController.swift:603`). The only backtick
   binding anywhere is Control+Command+Grave = `focusMonitorLast`
   (`Sources/Nehir/Core/Input/ActionCatalog.swift:472`), unrelated. The actual path is:
   ⌘D → `x` (the built-in "Tools" retold-tool-manager command-builder webview, registered
   with OSD key `x` at `Sources/NehirShell/Overlays/OverlayController.swift:519`) → the
   `tool-runner.html` webview posts `{action:"run", command, target:"embedded"}` →
   `handleWebAction` (`OverlayController.swift:523`) → `runWebCommand`
   (`OverlayController.swift:538`) → the `"embedded"` case → `presentTerminal`
   (`OverlayController.swift:572`). (Prior "⌘D→c" memory is stale; `c` is Columns.)

3. **No save/export exists; the bridge only knows `action:"run"`.** `runWebCommand`
   targets are `clipboard` (copy), `terminal` (Terminal.app via AppleScript,
   `OverlayController.swift:552`), and `embedded` (the SwiftTerm panel). Nothing persists a
   built command.

Supporting substrate:

- **Deck routing** is a four-layer state machine under
  `Sources/NehirShell/ControlDeck/`: `DeckModeID` enum
  (`DeckTypes.swift:74`), `DeckActionKind` (`DeckTypes.swift:40`, includes
  `.enterMode` and `.showOverlay`), `DeckCatalog.mode(_:)` (`DeckCatalog.swift:13`) with
  root-key→mode entries in the `root` actions array (`DeckCatalog.swift:51`),
  `DeckModel.handle(key:)` router (`DeckModel.swift:287`, mode switch at `:292`) with
  per-mode handlers, `setMode(_:)` seeding live data (`DeckModel.swift:415`), and
  `DeckView.content` (`DeckView.swift:30`). Numbered-list primitives already exist:
  `DeckPickItem` (`DeckTypes.swift:121`), `handleListPick` (`DeckModel.swift:367`),
  `handleInternals` (`DeckModel.swift:348`), `columnJumpActions()` (`DeckCatalog.swift:288`).
  Dynamic OSD/overlay entries (Tools is one) are appended to root by
  `refreshExtensionEntries()` (`Sources/NehirShell/ControlDeck/ControlDeckController.swift:345`).
- **The command builder** is the `retold-tool-manager` package (published as
  `retold-tool-manager`), bundled into `Sources/NehirShell/Resources/` as
  `retold-tool-manager.min.js` and hosted by `tool-runner.html`. It is a **pure compiler**:
  `Tool.compile` (`source/Tool.js:70`) turns a manifest + values into a canonical `argv`
  array; `Shell-Render.render` (`source/Shell-Render.js:41`) is the only quoting site and
  is display/copy-only; the runner executes `argv`, never the string. `cwd`/`shell`/`env`
  exist **only** as ephemeral runner options (`source/runners/Node-Runner.js:49`,
  `source/Recipe.js:197`), never modeled or serialized. A **Shape**
  (`source/Tool-Manager.js:176`) is a saved parameterized recipe — the closest existing
  reuse unit, but it stores topology + promoted-parameter definitions, not a concrete run,
  and has no interpreter/cwd/env/body. `BrowserToolManager`
  (`source/Tool-Manager-Browser.js:54`) is the fs-free compile-only bundle nehir uses.

## Design decisions (locked with the author, 2026-08-24)

- **Inherent terminal** = one warm persistent session (`$SHELL -li`, no `-c`), scrollback
  kept, alive across Deck open/close; **visible (peek, non-key) while ⌘D is up**; **backtick
  focuses it** to type (a new Deck key-resolver action); explicit close (⌘W / click-away)
  kills it. An **iTerm-style global toggle** (show + focus in one gesture, independent of
  the Deck) is an optional second trigger on the same session.
- **Commandlets run in the inherent terminal by default.**
- **Commandlet model lives nehir-side** (tool-manager stays the compiler). Record:
  `{ name, interpreter, body, cwd, env?, slot? }`, where `interpreter` is one of
  `bash | zsh | sh | node | python3 | … | argv` and **a shebang in the body overrides it**;
  `interpreter: "argv"` means the body is a pre-resolved one-liner run as-is. **`body` is
  either** free-form `Script` text **or** a compiled-config reference
  `{ Tool | Shape | Recipe, Values }` recompiled per-platform through tool-manager's
  `compile` paths (stays portable — store intent, not a frozen string).
- **Load vs run**: *run* = write the line + Enter; *load* = write the line, leave the
  cursor (author edits, then Enter).
- **Invocation**: reorganize ⌘D `x` from "show Tools webview" into a native **Commandlets**
  mode — numbered slots (digit = run, ⌥digit = load), a searchable list, and a "builder"
  row that opens the existing webview.
- **Export**: a "Save → commandlet" button in `tool-runner.html` posts `action:"save"`;
  Swift gains a `case "save"` in `handleWebAction`.
- **env**: store `cwd` + `interpreter`; reference env vars by **name**, not value, to avoid
  baking secrets/PATH into the store.

## Commandlet record (nehir-side JSON store)

```json
{
  "id": "deploy-docs",
  "name": "Deploy docs",
  "interpreter": "bash",
  "body": "npm run build && ./deploy.sh",
  "cwd": "~/Code/retold/docs",
  "env": ["NODE_ENV"],
  "slot": 1
}
```

Body-as-config-reference variant:

```json
{
  "id": "tunnel-prod",
  "name": "Reverse tunnel (prod)",
  "interpreter": "argv",
  "body": { "kind": "Shape", "shape": "ssh-reverse-tunnel", "values": { "host": "prod" } },
  "cwd": "~",
  "slot": 2
}
```

Runner: reveal the terminal, then — `bash`/`zsh`/`sh`/`argv` → `cd <cwd> && <body>`;
program interpreters (`node`/`python3`/…) → write the body to a temp file with the right
extension, then `cd <cwd> && <interp> <file>`; shebang → temp file, `chmod +x`, run direct.
"run" appends a newline; "load" does not.

## Phased plan

Build order is P1a → P2 → P3 → P4 (each targets the P1 terminal). P1b and P5 are
independent tracks. Each phase past P1a gets its own `planned/` doc when reached.

### P1a — persistent peekable inherent terminal (implement-ready)

Goal: convert the one-shot terminal into a warm, peekable session that backtick focuses,
so the author can A/B it against the iTerm hotkey window.

Files to touch (main Nehir repo, repo-relative):

- `Sources/NehirShell/Overlays/OverlayTerminalController.swift` — launch `$SHELL -li`
  (drop `-c`), retain and reuse the session across shows (do not tear down the
  `LocalProcessTerminalView` on hide), add `currentDirectory:` support, add a
  `send(_:)` / `sendLine(_:)` wrapper over `terminalView` (SwiftTerm send API), and split
  "show/hide/peek" from "become key" so peek can be non-activating.
- `Sources/NehirShell/Overlays/OverlayController.swift` — own the persistent terminal
  lifecycle (present as peek vs focus), and expose a controller-level entry so a command
  can be run in the terminal independent of the webview `run` path (`presentTerminal` at
  `:572` is the current single entry).
- `Sources/NehirShell/ControlDeck/ControlDeckController+KeyResolution.swift` +
  `Sources/NehirShell/ControlDeck/ControlDeckController.swift` — teach the resolver a
  backtick → "focus inherent terminal" action (punctuation is currently rejected at
  `ControlDeckController+KeyResolution.swift:24` / `ControlDeckController.swift:603`).
- Deck presentation glue so the terminal pane is shown when the Deck opens (peek) and
  hidden when it closes, with the session kept warm.

New mechanisms: warm session + scrollback retention; `send`/`sendLine` into a live PTY;
backtick key-resolution; non-activating peek vs key-on-backtick.

Do-not-touch fences:

- The AX focus/reveal/activation core (`Sources/Nehir/Core/Controller/AXEventHandler.swift`,
  `handleAppActivation` / `confirmManagedFocus` and the reveal path) — delicate
  focus-arbitration; a peeking, sometimes-key terminal panel interacts with the Deck's
  non-activating invariant and must not perturb managed-window focus arbitration.
- The uncommitted observe-only main-window diagnostic already in the working tree
  (`AppAXContext.swift`, `ServiceLifecycleManager.swift`, `AXEventHandler.swift`) — leave
  it separable; it belongs to a different investigation.

Gate: `mise run build` between steps; `mise run test` once at the end. Per repo policy,
**no test additions/edits** until the author confirms the terminal behaves in a real run or
explicitly asks for tests.

Commit message shape (plain English, no Conventional Commits, no upstream `#nnn`):
`Persist the inherent terminal and focus it with backtick`.

### P1b — optional iTerm-style global toggle (independent)

A standalone global hotkey (⌘\`-style) that shows **and** focuses the same persistent
session in one gesture, no ⌘D first. Registered as a standalone overlay/hotkey (shell.d
`[[overlay]]` or a HotkeyCommand), reusing the P1a session. Lets the author compare the
Deck-native peek against the iTerm feel with zero rework.

### P2 — commandlet model + store + runner

nehir-side record (above) + a JSON store (hand- and UI-editable) + a runner that
materializes the body (temp file for program interpreters, shebang honored), sets `cwd`,
and `sendLine` (run) / `send` (load) into the P1 terminal. tool-manager provides the
compiled-config body kinds via its existing `compile` paths (`source/Tool.js:70`,
`source/Recipe.js:71`, `source/Tool-Manager.js:116`).

### P3 — ⌘D x native Commandlets mode + slots

Add `case commandlets` to `DeckModeID` (`DeckTypes.swift:74`); a `DeckMode` +
root entry in `DeckCatalog` (`DeckCatalog.swift:13`, `:51`); `handleCommandlets` in
`DeckModel` modeled on `handleListPick` (`DeckModel.swift:367`) / `handleInternals`
(`DeckModel.swift:348`) with digit = run and ⌥digit = load; a seeding case in `setMode`
(`DeckModel.swift:415`) fed by injected `readCommandletRows` / `runCommandlet` closures;
`DeckCommandletsView` in `DeckView.content` (`DeckView.swift:30`) copied from
`DeckInternalsView` / `DeckLayoutView`. The mode's rows are the slots + a searchable list +
a "builder" row that opens the existing Tools webview (preserving builder access as the
`x` key is repurposed from "show webview" to "enter mode").

### P4 — builder "Save → commandlet"

JS: a "Save" button in `Sources/NehirShell/Resources/tool-runner.html` (near the existing
dispatch at `:117` / `:268` / `:311`) posting `{action:"save", command, spec, label}`.
Swift: a `case "save"` in `handleWebAction` (`OverlayController.swift:523`) that writes a
commandlet (interpreter `argv`, body = the compiled-config ref, prompt for name/cwd/slot).

### P5 — tool-manager extensions (independent track)

More tools, more parameters on existing tools, examples, and docs in the
`retold-tool-manager` package. Feeds P4 (richer builds to save as commandlets). Tracked
separately; not on the terminal/commandlet critical path.

## Open questions / risks

- **Focus vs the non-activating Deck invariant.** Peek must be non-key; backtick makes the
  terminal key. Decide what happens to the Deck when focus enters the terminal (Deck stays
  up vs dismisses) and how focus returns to the previously-focused window on close. This is
  the crux of P1a.
- **Terminal geometry.** Centered panel (current) vs an edge/dropdown placement closer to
  the iTerm hotkey window. Defer; not blocking P1a.
- **Temp-file lifecycle** for script bodies (nehir-owned dir, named by id, periodic
  cleanup).
- **Per-platform recompile** for config-reference bodies — store intent (tool/shape id +
  values), never a frozen platform-specific string.
- **Repurposing ⌘D x** from "show Tools webview" to native mode must keep the builder one
  keystroke away inside the mode.

## Non-goals (for now)

- Full iTerm feature parity (splits, profiles, tmux integration).
- Sandboxing commandlets — they are the author's own scripts, run with the author's
  privileges; export-from-builder never auto-runs.
- Multiple concurrent terminal sessions / tabs — one warm session to start.

## Provenance

Design co-developed with the author on 2026-08-24. Current-state facts verified against the
main Nehir source tree at `main` @ `18ce97b` via a source map of the terminal, tools
overlay, Deck routing, and tool-manager command model. Related tracking lives on the Nehir
plansheet (IDCustomer 29).
