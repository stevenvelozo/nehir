#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Steven Velozo
# SPDX-License-Identifier: GPL-2.0-only
#
# Stage 2: build a signed, notarized .pkg installer that deploys:
#   /Applications/Nehir.app        (the signed, notarized app from stage 1)
#   <CLI_INSTALL_DIR>/nehirctl      (Developer-ID-signed CLI)
#   <CLI_INSTALL_DIR>/nehirshellctl (Developer-ID-signed CLI)
# A signed+notarized component .pkg is the MDM/Munki/Jamf-friendly artifact for
# pushing to many Macs.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

require_app_identity
require_installer_identity

APP="$DIST_DIR/Nehir.app"
[ -d "$APP" ] || die "dist/Nehir.app not found — run packaging/build-app.sh first."

REL="$ROOT_DIR/.build/apple/Products/Release"
STAGING="$DIST_DIR/pkg-staging"
PKG="$DIST_DIR/Nehir-$VERSION.pkg"

log "Signing CLI binaries (Developer ID, hardened runtime)..."
for cli in nehirctl nehirshellctl; do
  [ -f "$REL/$cli" ] || die "$REL/$cli not found — run packaging/build-app.sh (universal release) first."
  codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$REL/$cli"
done

log "Assembling install staging tree..."
rm -rf "$STAGING"
mkdir -p "$STAGING/Applications" "$STAGING$CLI_INSTALL_DIR"
cp -R "$APP" "$STAGING/Applications/Nehir.app"
install -m 755 "$REL/nehirctl" "$STAGING$CLI_INSTALL_DIR/nehirctl"
install -m 755 "$REL/nehirshellctl" "$STAGING$CLI_INSTALL_DIR/nehirshellctl"

log "Building signed component package $PKG..."
rm -f "$PKG"
pkgbuild \
  --root "$STAGING" \
  --install-location / \
  --identifier "$BUNDLE_ID.pkg" \
  --version "$VERSION" \
  --ownership recommended \
  --sign "$INSTALLER_IDENTITY" \
  --timestamp \
  "$PKG"

log "Notarizing $PKG (this waits for Apple)..."
xcrun notarytool submit "$PKG" --keychain-profile "$NOTARY_PROFILE" --wait --timeout 30m
xcrun stapler staple "$PKG"
xcrun stapler validate "$PKG"

rm -rf "$STAGING"
log "Installer ready: $PKG"
shasum -a 256 "$PKG"
