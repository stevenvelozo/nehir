# Developing & Releasing Nehir (this fork)

This fork of [Nehir](https://github.com/apphane-dev/nehir) — a Niri-style scrolling
window manager — adds a **fork-safe shell layer** on top of the base window
manager:

- **FableCore** — the retold **fable/pict** ecosystem hosted in JavaScriptCore
  (config, templating, expression solving, logging, service DI), in-process.
- **NodeSidecar** — an out-of-process Node runtime behind the same
  `FableRuntime` protocol, for work JavaScriptCore can't do (network, filesystem,
  DB, full npm modules).
- **NehirShell** — the "modern LiteStep" shell: a config namespace, a Unix
  control socket, and a desktop status panel.
- **nehirshellctl** — a terminal client for the shell control socket.
- **packaging/** — a signed + notarized fleet release pipeline.

Everything above lives in **new targets/files**; only a handful of upstream files
are touched (see [Upstream sync](#upstream-sync)), so `git merge upstream` stays
trivial.

---

## 1. New-machine setup

### Prerequisites

| Tool | Why | Install |
|---|---|---|
| **Xcode** (full app, not just Command Line Tools) | Swift 6.3 toolchain, AppKit/SkyLight SDKs, and `mise run test` all need it | App Store, then `sudo xcode-select -s /Applications/Xcode.app` |
| **mise** | task runner + pinned `swiftlint`/`swiftformat` | `brew install mise` |
| **Node.js** *(optional)* | only for the `NodeSidecar`; the app runs fine without it (the sidecar degrades gracefully) | `brew install node`, or nvm |
| **Git** | — | (with Xcode) |

Confirm the toolchain points at Xcode, not the Command Line Tools:

```bash
xcode-select -p         # must print /Applications/Xcode.app/Contents/Developer
swift --version         # expect Apple Swift 6.3.x
```

> The pinned Swift version lives in `.swift-version`. Swift itself is **not**
> managed by mise (see `.config/mise/conf.d/tools.toml` — `disable_tools = ["swift"]`);
> it comes from Xcode.

### First build

```bash
git clone https://github.com/stevenvelozo/nehir.git
cd nehir
mise trust          # REQUIRED — mise refuses to read .config/mise/ tasks until trusted
mise install        # installs pinned swiftlint + swiftformat
mise run build      # first cold build fetches swift-toml + compiles ~106k LOC (a few minutes)
```

Sanity checks:

```bash
mise run dev                       # launches the app (menu-bar only; see §3)
.build/debug/nehirshellctl ping    # → pong  (proves the shell layer came up)
```

### The vendored fable/pict bundle

FableCore loads a **vendored** copy of the retold pict bundle at
`Sources/FableCore/Resources/pict.min.js` — the repo is self-contained and does
**not** need the retold monorepo to build or run. To pull in a newer pict build:

```bash
# Needs the retold checkout, or set RETOLD_PICT_DIST to a pict.min.js
./Sources/FableCore/Resources/REFRESH.sh
```

---

## 2. Build & dev workflow

| Command | Does |
|---|---|
| `mise run build` | debug build |
| `mise run dev` | build + run (`swift run Nehir`) |
| `mise run build:release` | optimized build |
| `mise run lint` / `mise run lint:fix` | swiftlint |
| `mise run format` / `mise run format:check` | swiftformat |
| `mise run test` | test suite (**needs full Xcode**) |

### Where the code lives

```
Sources/
  Nehir, NehirApp, NehirCtl, NehirIPC   # base window manager (upstream)
  FableCore                             # fable/pict in JavaScriptCore  (fork)
  NodeSidecar                           # Node sidecar runtime          (fork)
  NehirShell                            # shell layer (config/socket/panel) (fork)
  NehirShellWire                        # shared socket path + wire protocol (fork)
  NehirShellCtl                         # nehirshellctl client            (fork)
```

The app entry point (`NehirApp`) installs the shell via a one-line hook
(`NehirShellHook`); the base WM is otherwise untouched.

### The shell layer at runtime

- **Config:** `~/.config/nehir/shell.d/*.toml` — separate from the base manager's
  own `~/.config/nehir/settings.toml`. A documented `00-shell.toml` is seeded on
  first run.
- **Control socket:** `~/Library/Caches/dev.guria.nehir/shell.sock` (override with
  `NEHIR_SHELL_SOCKET`). Talk to it with `nehirshellctl`:
  ```bash
  nehirshellctl ping
  nehirshellctl solve "(2 + 3) * 4"
  nehirshellctl render "Hi {~Data:Record.name~}" name=Steven
  nehirshellctl config dump
  ```
- **Status panel:** off by default; set `enabled = true` under `[panel]` in the
  seeded config (currently applied at launch — live reload is not wired yet).

---

## 3. Running & granting access — the important gotchas

The window manager needs macOS **Accessibility** permission to manage windows and
fire global hotkeys. Two facts cause almost all the pain here:

### Accessibility is tied to code *identity*, not name or path

| Build | Identity | Grant behavior |
|---|---|---|
| `swift run` / ad-hoc-signed `.app` | changes **every build** (cdhash) | grant breaks on every rebuild |
| **Developer ID signed** (release pipeline) | **stable** (tied to the cert) | grant **persists** across rebuilds |

**For daily use, run the Developer-ID-signed build** (installed from the release
pipeline, §4). `mise run dev` is fine for quick iteration but macOS may re-prompt
for Accessibility after many rebuilds.

### ⚠️ Never touch Accessibility while Nehir is running

Running `tccutil reset` — or toggling Nehir's Accessibility switch — **while Nehir
is running** can wedge the WindowServer (Nehir uses private SkyLight APIs) and take
**keyboard + trackpad** down with it, requiring a hard power cycle. **Always fully
quit Nehir first.**

On machines that run the WM, enable **Remote Login** (System Settings → General →
Sharing → Remote Login) as a kill switch — you can then `ssh` in and
`pkill -x Nehir` if input ever wedges.

### Clean re-grant procedure (after changing the signing identity)

```bash
# 1. QUIT Nehir from its menu-bar item first (do not skip this).
tccutil reset Accessibility dev.guria.nehir
# 2. System Settings → Privacy & Security → Accessibility → remove any leftover
#    "Nehir" rows with the − button (stale entries from earlier identities shadow
#    the real one).
# 3. Relaunch the app, grant when prompted.
# 4. If it still reports "not granted", quit and relaunch once — the trust state
#    is read at process start.
```

### Packaged-app resource-bundle gotcha

Every target with SwiftPM `resources:` (FableCore, NodeSidecar, …) produces a
`Nehir_<Target>.bundle`. `Bundle.module` **`fatalError`s on launch** (SIGTRAP,
before the menu-bar icon appears) if that bundle isn't inside the `.app`. The
package task globs **all** `*.bundle` (excluding test fixtures) for this reason —
never hardcode a single bundle name. `mise run dev` is unaffected (bundles sit
next to the `.build` binary).

---

## 4. Releasing (signed + notarized, for fleet deployment)

The full pipeline lives in **`packaging/`** — see
[`packaging/README.md`](packaging/README.md) for the authoritative detail. Summary:

### One-time per build machine

1. **Developer ID Application** certificate (signs the app + CLIs).
2. **Developer ID Installer** certificate (signs the `.pkg`).
   - Both via Xcode → Settings → Accounts → *Manage Certificates* → **+**, or the
     Developer portal. Requires paid Apple Developer Program membership.
3. **Notary credentials** stored once in the Keychain:
   ```bash
   xcrun notarytool store-credentials "nehir-notary" \
     --apple-id "you@example.com" --team-id "<TEAM_ID>" \
     --password "<app-specific password from account.apple.com>"
   ```
   (Or an App Store Connect API key — `--key/--key-id/--issuer`.)
4. `cp packaging/config.example.sh packaging/config.sh` and adjust if your
   identities differ. `config.sh` is git-ignored; identity names/Team ID are not
   secret, the notary password never lives in the repo.

Verify both certs are present:

```bash
security find-identity -v -p codesigning   # expect BOTH Developer ID certs
```

### Build a release

```bash
./packaging/release.sh                  # notarized Nehir.app + notarized Nehir-<ver>.pkg
WITH_DMG=true ./packaging/release.sh    # also a notarized drag-install DMG
VERSION=0.1.0 ./packaging/release.sh    # stamp a real version
```

Artifacts land in `dist/`. Verify they're distributable:

```bash
spctl -a -vv dist/Nehir.app                          # accepted / source=Notarized Developer ID
spctl -a -vv --type install dist/Nehir-<ver>.pkg     # accepted / source=Notarized Developer ID
```

> **Version:** `Info.plist`'s `CFBundleShortVersionString` is the `0.0.0` dev
> placeholder. Bump it (edit `Info.plist` or pass `VERSION=…`) for real releases.

### Installing on a target Mac

- **Manual:** double-click `Nehir-<ver>.pkg` — no Gatekeeper friction (notarized).
- **MDM / Munki / Jamf:** push the `.pkg` for silent install.
- Installs `Nehir.app` → `/Applications` and `nehirctl` + `nehirshellctl` →
  `/usr/local/bin`.
- Each user grants Accessibility **once** (§3). Because every build carries the
  same Developer ID identity, that grant persists across updates.

---

## 5. Upstream sync

Remotes: `origin` = `stevenvelozo/nehir` (this fork), `upstream` =
`apphane-dev/nehir`.

All fork code is in **new files/targets**. The only **existing upstream-tracked
files** this fork edits — each marked with a `NEHIR-SHELL SEAM` comment where it's
code — are:

| File | Edit |
|---|---|
| `Package.swift` | adds the fork targets + products |
| `Sources/Nehir/App/AppDelegate.swift` | one fenced call into the shell hook |
| `Sources/NehirApp/NehirApp.swift` | one fenced line installing the shell layer |
| `.provenance.json` | attributes the fork's new files |
| `.config/mise/tasks/package/release` | copies all `*.bundle` (resource-bundle fix) |

Plus one **new** file under an upstream directory: `Sources/Nehir/App/NehirShellHook.swift`
(the dependency-inversion hook). Everything else — `Sources/FableCore`,
`Sources/NodeSidecar`, `Sources/NehirShell*`, `packaging/`, this file — is in new
paths upstream doesn't have, so a merge only ever re-touches the five files above.

---

## 6. Contribution rules

This repo has strict agent/contributor rules in
[`AGENTS.md`](AGENTS.md) — notably: defer test changes until behavior is
confirmed; git mutations need explicit per-action permission; user-facing changes
get a changeset (`mise run changeset …`); no Conventional Commits formatting.
