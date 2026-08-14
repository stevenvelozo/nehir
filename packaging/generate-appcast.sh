#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Steven Velozo
# SPDX-License-Identifier: GPL-2.0-only
#
# Generate/update the Sparkle appcast for a release.
#
# Runs Sparkle's `generate_appcast` (from the SwiftPM artifact cache) over the release
# ZIP, signing it with the EdDSA private key in your Keychain (created once by
# `generate_keys`). The new item's download URL points at the GitHub Release asset for
# this version's tag; existing items in the appcast are preserved. Writes the result to
# the GitHub Pages source (docs/appcast.xml by default).
#
# Usage:   packaging/generate-appcast.sh [<release-zip>]
# Env:     GH_OWNER (default stevenvelozo)  GH_REPO (default nehir)
#          TAG (default v<version>)         APPCAST_DIR (default <root>/docs)
set -euo pipefail

ROOT_DIR="$(git rev-parse --show-toplevel)"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT_DIR/Info.plist")"
ZIP="${1:-$ROOT_DIR/dist/Nehir-$VERSION.zip}"
GH_OWNER="${GH_OWNER:-stevenvelozo}"
GH_REPO="${GH_REPO:-nehir}"
TAG="${TAG:-v$VERSION}"
APPCAST_DIR="${APPCAST_DIR:-$ROOT_DIR/docs}"

GEN="$(find "$ROOT_DIR/.build/artifacts" -type f -name generate_appcast 2>/dev/null | head -1)"
[ -n "$GEN" ] || { echo "generate_appcast not found — run 'swift build' first." >&2; exit 1; }
[ -f "$ZIP" ]  || { echo "Release ZIP not found: $ZIP" >&2; exit 1; }

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
cp "$ZIP" "$STAGING/"
mkdir -p "$APPCAST_DIR"
# Seed the existing appcast so prior versions' items (and URLs) are preserved.
[ -f "$APPCAST_DIR/appcast.xml" ] && cp "$APPCAST_DIR/appcast.xml" "$STAGING/appcast.xml"

"$GEN" \
  --download-url-prefix "https://github.com/$GH_OWNER/$GH_REPO/releases/download/$TAG/" \
  "$STAGING"

cp "$STAGING/appcast.xml" "$APPCAST_DIR/appcast.xml"
echo "Updated $APPCAST_DIR/appcast.xml for $VERSION."
echo "Next:"
echo "  1. Upload $ZIP to the '$TAG' GitHub Release (asset name must match the appcast enclosure)."
echo "  2. Commit $APPCAST_DIR/appcast.xml — GitHub Pages serves it as the feed."
