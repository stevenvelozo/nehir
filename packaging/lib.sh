# SPDX-FileCopyrightText: 2026 Steven Velozo
# SPDX-License-Identifier: GPL-2.0-only
#
# Shared setup + helpers for the Nehir fleet-packaging scripts. Sourced by the
# stage scripts; not meant to be run directly.
set -euo pipefail

PKG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$PKG_DIR/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"

# Local overrides (git-ignored) win; the committed example fills in defaults.
# shellcheck disable=SC1091
[ -f "$PKG_DIR/config.sh" ] && source "$PKG_DIR/config.sh"
# shellcheck disable=SC1091
source "$PKG_DIR/config.example.sh"

if [ -z "${VERSION:-}" ]; then
  VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT_DIR/Info.plist")"
fi

log() { printf '\033[1;34m▸ %s\033[0m\n' "$*"; }
die() { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

require_app_identity() {
  security find-identity -v -p codesigning 2>/dev/null | grep -qF "$SIGNING_IDENTITY" \
    || die "Developer ID Application identity not found: '$SIGNING_IDENTITY'. See packaging/README.md."
}

require_installer_identity() {
  security find-identity -v 2>/dev/null | grep -qF "$INSTALLER_IDENTITY" \
    || die "Developer ID Installer identity not found: '$INSTALLER_IDENTITY'. Create it (packaging/README.md), then retry."
}
