#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Steven Velozo
# SPDX-License-Identifier: GPL-2.0-only
#
# One-shot fleet release: signed + notarized Nehir.app, a signed + notarized .pkg
# installer, and (with WITH_DMG=true) a notarized DMG. Run from a machine that has
# the two Developer ID certs in its Keychain and the notarytool profile stored.
#
#   ./packaging/release.sh                 # app + pkg
#   WITH_DMG=true ./packaging/release.sh   # app + pkg + dmg
#   VERSION=0.1.0 ./packaging/release.sh   # override the version
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

log "Nehir release $VERSION → $DIST_DIR"

"$PKG_DIR/build-app.sh"
"$PKG_DIR/build-installer.sh"
if [ "${WITH_DMG:-false}" = "true" ]; then
  "$PKG_DIR/build-dmg.sh"
fi

log "Release complete. Artifacts:"
ls -1 "$DIST_DIR"/Nehir-"$VERSION".pkg "$DIST_DIR"/Nehir-"$VERSION".dmg "$DIST_DIR"/Nehir-"$VERSION".zip 2>/dev/null || true
