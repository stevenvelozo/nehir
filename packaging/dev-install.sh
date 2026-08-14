#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Steven Velozo
# SPDX-License-Identifier: GPL-2.0-only
#
# Fast local iteration for window-manager features: a Developer-ID-SIGNED (but not
# notarized) build, installed to ~/Applications + ~/.local/bin. Signing keeps the
# STABLE identity, so the Accessibility grant persists — unlike `mise run dev`
# (ad-hoc identity, loses the grant). No Apple round-trip, so it's quick.
#
# Quit Nehir before running this (a running WM + reinstall is asking for trouble),
# then relaunch ~/Applications/Nehir.app afterwards.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

require_app_identity

if pgrep -x Nehir >/dev/null 2>&1; then
  die "Nehir is running — quit it from the menu bar first, then re-run this."
fi

log "Building + Developer-ID signing Nehir.app $VERSION (skipping notarization)…"
SIGN_AND_NOTARIZE=true \
  SIGNING_IDENTITY="$SIGNING_IDENTITY" \
  NOTARIZE_SKIP=true \
  ENTITLEMENTS="$ROOT_DIR/Nehir.entitlements" \
  bash "$ROOT_DIR/.config/mise/tasks/package/release" true >/dev/null

log "Installing to ~/Applications + ~/.local/bin…"
rm -rf "$HOME/Applications/Nehir.app"
cp -R "$DIST_DIR/Nehir.app" "$HOME/Applications/Nehir.app"
mkdir -p "$HOME/.local/bin"
REL="$ROOT_DIR/.build/apple/Products/Release"
install -m 755 "$REL/nehirctl" "$HOME/.local/bin/nehirctl"
install -m 755 "$REL/nehirshellctl" "$HOME/.local/bin/nehirshellctl"

log "Installed. Relaunch:  open ~/Applications/Nehir.app"
