#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Steven Velozo
# SPDX-License-Identifier: GPL-2.0-only
#
# Quit the running Nehir, overwrite ~/Applications/Nehir.app with the freshly-built
# dist/Nehir.app, refresh the ~/.local/bin CLIs, and relaunch. Run this AFTER a build
# that produced dist/Nehir.app (e.g. `./packaging/release.sh`) — it does NOT build.
#
# One-shot build + reinstall:  ./packaging/release.sh && ./packaging/reinstall.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

SRC="$DIST_DIR/Nehir.app"
DEST="$HOME/Applications/Nehir.app"

[ -d "$SRC" ] || die "$SRC not found — build it first (e.g. ./packaging/release.sh)."

log "Verifying built app signature…"
codesign --verify --strict "$SRC" || die "built app fails codesign --verify"

log "Quitting Nehir…"
osascript -e 'quit app "Nehir"' >/dev/null 2>&1 || true
sleep 1
pkill -x Nehir >/dev/null 2>&1 || true
sleep 2
if pgrep -x Nehir >/dev/null 2>&1; then
  die "Nehir is still running — quit it from the menu bar and retry."
fi

log "Installing $SRC -> $DEST"
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
ditto "$SRC" "$DEST"

# Keep the on-PATH CLIs in sync with the build (best-effort; skipped if absent).
REL="$ROOT_DIR/.build/apple/Products/Release"
if [ -d "$REL" ]; then
  mkdir -p "$HOME/.local/bin"
  for cli in nehirctl nehirshellctl; do
    if [ -f "$REL/$cli" ]; then
      install -m 755 "$REL/$cli" "$HOME/.local/bin/$cli"
    fi
  done
fi

log "Relaunching…"
open "$DEST"
log "Reinstalled $VERSION and relaunched."
