#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Steven Velozo
# SPDX-License-Identifier: GPL-2.0-only
#
# Swap this machine's installed Nehir back to the latest PUBLISHED release from
# GitHub — the clean way to undo a `dev-install` (whose 9999.0.0 version keeps
# Sparkle from offering the release). Downloads the newest signed+notarized
# Nehir-*.zip, installs it to ~/Applications, and relaunches, so Sparkle sees a
# real release version again and auto-update resumes normally.
#
# Requires the `gh` CLI (brew install gh), authenticated to GitHub.
set -euo pipefail

REPO="stevenvelozo/nehir"
DEST="$HOME/Applications/Nehir.app"

command -v gh >/dev/null 2>&1 || { echo "This needs the gh CLI (brew install gh)." >&2; exit 1; }

echo "▸ Quitting Nehir…"
"$HOME/.local/bin/nehirshellctl" quit >/dev/null 2>&1 || osascript -e 'quit app "Nehir"' >/dev/null 2>&1 || true
sleep 2

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "▸ Downloading the latest release of $REPO…"
gh release download --repo "$REPO" --pattern 'Nehir-*.zip' --dir "$tmp"
zip="$(ls "$tmp"/Nehir-*.zip 2>/dev/null | head -1)"
[ -n "$zip" ] || { echo "No Nehir-*.zip asset found on the latest release." >&2; exit 1; }

echo "▸ Installing $(basename "$zip") → $DEST"
ditto -x -k "$zip" "$tmp/unpacked"
app="$(find "$tmp/unpacked" -maxdepth 2 -name 'Nehir.app' -type d | head -1)"
[ -n "$app" ] || { echo "No Nehir.app inside the release zip." >&2; exit 1; }

rm -rf "$DEST"
cp -R "$app" "$DEST"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DEST/Contents/Info.plist" 2>/dev/null || echo '?')"
echo "▸ Launching Nehir $version…"
open "$DEST"
echo "✓ Switched to the released build (Nehir $version). Your ~/.local/bin ctl tools are unchanged; re-run dev-install to go back to the local build."
