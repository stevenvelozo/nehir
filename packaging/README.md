# Nehir fleet packaging

Signed + notarized build pipeline for deploying Nehir to many Macs.

Artifacts land in `../dist/`:

- **`Nehir.app`** — universal, Developer-ID-signed, notarized, stapled.
- **`Nehir-<version>.pkg`** — signed + notarized installer (the fleet artifact):
  installs `Nehir.app` → `/Applications` and `nehirctl` + `nehirshellctl` →
  `/usr/local/bin`. MDM / Munki / Jamf can push it silently.
- **`Nehir-<version>.dmg`** — optional drag-to-Applications disk image.

## One-time setup (per build machine)

1. **Developer ID Application** certificate — signs the app + CLIs. *(Already
   installed.)*

2. **Developer ID Installer** certificate — signs the `.pkg`. Create it the same
   way: Xcode ▸ Settings ▸ Accounts ▸ *Manage Certificates…* ▸ **+** ▸
   **Developer ID Installer** (or the Developer portal ▸ Certificates ▸ **+**).

3. **Notarization credentials** — store an app-specific password in the Keychain
   once (no password ever lives in this repo):

   ```bash
   # Create an app-specific password at https://appleid.apple.com (Sign-In & Security).
   xcrun notarytool store-credentials "nehir-notary" \
     --apple-id "you@example.com" \
     --team-id "BYWQB9JL46" \
     --password "abcd-efgh-ijkl-mnop"
   ```

4. **Config** — copy the template and adjust if your identities differ:

   ```bash
   cp packaging/config.example.sh packaging/config.sh   # config.sh is git-ignored
   ```

Verify identities are present:

```bash
security find-identity -v -p codesigning   # should list BOTH Developer ID certs
```

## Build a release

```bash
./packaging/release.sh                  # app + pkg
WITH_DMG=true ./packaging/release.sh     # app + pkg + dmg
VERSION=0.1.0 ./packaging/release.sh     # stamp a real version (default reads Info.plist)
```

Run individual stages if you want:

```bash
./packaging/build-app.sh        # app: build + sign + notarize + staple
./packaging/build-installer.sh  # pkg: sign CLIs + component pkg + notarize + staple
./packaging/build-dmg.sh        # dmg (optional)
```

## Installing on a target Mac

Double-click `Nehir-<version>.pkg` (or push via MDM). After install, each user
grants Accessibility **once** — because every build is signed with the same
Developer ID identity, the grant then persists across updates.

> Version bumps: the pipeline reads `CFBundleShortVersionString` from
> `../Info.plist` (currently the `0.0.0` dev placeholder). Set a real version in
> `Info.plist` or pass `VERSION=…` for distributed builds.
