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

# Stamp a very high dev version so Sparkle never offers to "update" this local
# build DOWN to a published release. This must happen BEFORE the build (the
# packager copies Info.plist into the app, then signs it — a post-sign edit
# would break the signature). The tracked Info.plist is restored on exit, even
# on failure, so the repo stays at its baseline version.
DEV_VERSION="9999.0.0"
_orig_short="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT_DIR/Info.plist")"
_orig_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$ROOT_DIR/Info.plist")"
restore_info_plist() {
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $_orig_short" "$ROOT_DIR/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $_orig_build" "$ROOT_DIR/Info.plist"
}
trap restore_info_plist EXIT
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $DEV_VERSION" "$ROOT_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $DEV_VERSION" "$ROOT_DIR/Info.plist"

log "Building + Developer-ID signing Nehir.app $DEV_VERSION (dev, skipping notarization)…"
# Capture the (noisy) release build/sign output to a log so a clean run stays
# quiet, but a FAILURE is surfaced instead of swallowed — otherwise a failed
# build looks exactly like "Nehir quit but never came back".
build_log="$(mktemp -t nehir-dev-install)"
if ! SIGN_AND_NOTARIZE=true \
  SIGNING_IDENTITY="$SIGNING_IDENTITY" \
  NOTARIZE_SKIP=true \
  ENTITLEMENTS="$ROOT_DIR/Nehir.entitlements" \
  bash "$ROOT_DIR/.config/mise/tasks/package/release" true >"$build_log" 2>&1; then
  cat "$build_log" >&2
  rm -f "$build_log"
  die "release build/sign failed (output above)."
fi
rm -f "$build_log"

log "Installing to ~/Applications + ~/.local/bin…"
rm -rf "$HOME/Applications/Nehir.app"
cp -R "$DIST_DIR/Nehir.app" "$HOME/Applications/Nehir.app"
mkdir -p "$HOME/.local/bin"
REL="$ROOT_DIR/.build/apple/Products/Release"
install -m 755 "$REL/nehirctl" "$HOME/.local/bin/nehirctl"
install -m 755 "$REL/nehirshellctl" "$HOME/.local/bin/nehirshellctl"

log "Installed. Relaunch:  open ~/Applications/Nehir.app"
