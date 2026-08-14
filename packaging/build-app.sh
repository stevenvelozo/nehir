#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Steven Velozo
# SPDX-License-Identifier: GPL-2.0-only
#
# Stage 1: build a universal Nehir.app, Developer-ID sign it with a hardened
# runtime, notarize it, and staple the ticket. Produces dist/Nehir.app.
#
# Reuses the in-repo package task (which assembles the app + all resource bundles
# and handles the codesign/notary sequence) so this fork pipeline stays a thin,
# fork-owned distribution layer on top of it.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

require_app_identity

log "Building + signing + notarizing Nehir.app $VERSION (Developer ID)..."
SIGN_AND_NOTARIZE=true \
  SIGNING_IDENTITY="$SIGNING_IDENTITY" \
  NOTARIZE_PROFILE="$NOTARY_PROFILE" \
  ENTITLEMENTS="$ROOT_DIR/Nehir.entitlements" \
  NOTARIZE_WAIT_TIMEOUT="30m" \
  bash "$ROOT_DIR/.config/mise/tasks/package/release" true

log "dist/Nehir.app is signed, notarized, and stapled."
