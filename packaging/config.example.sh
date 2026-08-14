# Nehir fleet-packaging configuration.
#
# Copy this file to `config.sh` (git-ignored) and adjust as needed, or export any
# of these as environment variables. The Team ID and identity names are not
# secret — they are embedded in every signed artifact — so the defaults below are
# safe to keep in a private fork. The notarization credential (an app-specific
# password) is NEVER stored here; it lives in the Keychain via `notarytool
# store-credentials` and is referenced only by profile name.

# --- Signing identities (from `security find-identity -v -p codesigning`) --------

# Developer ID Application — signs the .app and the CLI binaries. (You have this.)
: "${SIGNING_IDENTITY:=Developer ID Application: Steven Velozo (BYWQB9JL46)}"

# Developer ID Installer — signs the .pkg. Create it the same way you made the
# Application cert: Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates ▸ + ▸
# "Developer ID Installer" (or the portal ▸ Certificates ▸ + ▸ Developer ID Installer).
: "${INSTALLER_IDENTITY:=Developer ID Installer: Steven Velozo (BYWQB9JL46)}"

# --- Notarization -----------------------------------------------------------------

# notarytool Keychain profile name. Create it once with:
#   xcrun notarytool store-credentials "nehir-notary" \
#       --apple-id "you@example.com" --team-id "BYWQB9JL46" \
#       --password "<app-specific-password from appleid.apple.com>"
: "${NOTARY_PROFILE:=nehir-notary}"

# --- Identifiers ------------------------------------------------------------------

: "${TEAM_ID:=BYWQB9JL46}"
: "${BUNDLE_ID:=dev.guria.nehir}"

# Version for artifact filenames + the pkg. Empty = read CFBundleShortVersionString
# from Info.plist. Override for real releases, e.g. VERSION=0.1.0.
: "${VERSION:=}"

# Where the CLIs install on target machines (must be on the default PATH).
: "${CLI_INSTALL_DIR:=/usr/local/bin}"
