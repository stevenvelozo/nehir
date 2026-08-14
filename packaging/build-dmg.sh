#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Steven Velozo
# SPDX-License-Identifier: GPL-2.0-only
#
# Optional stage: a signed, notarized drag-to-Applications DMG. Handy for manual
# installs; the .pkg (build-installer.sh) is the better fit for scripted/MDM fleet
# deployment. Needs only the Developer ID Application cert (no Installer cert).
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

require_app_identity

APP="$DIST_DIR/Nehir.app"
[ -d "$APP" ] || die "dist/Nehir.app not found — run packaging/build-app.sh first."

DMG="$DIST_DIR/Nehir-$VERSION.dmg"
STAGING="$DIST_DIR/dmg-staging"

log "Assembling DMG contents..."
rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/Nehir.app"
ln -s /Applications "$STAGING/Applications"

log "Creating $DMG..."
hdiutil create -volname "Nehir" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null

log "Signing + notarizing DMG..."
codesign --force --timestamp --sign "$SIGNING_IDENTITY" "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait --timeout 30m
xcrun stapler staple "$DMG"

rm -rf "$STAGING"
log "DMG ready: $DMG"
shasum -a 256 "$DMG"
