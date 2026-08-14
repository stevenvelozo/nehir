# Auto-update (Sparkle)

Nehir updates itself with [Sparkle](https://sparkle-project.org). Binaries are
distributed as GitHub Release assets; the update feed (`appcast.xml`) is served from
GitHub Pages. Sparkle only ever applies a build that is **EdDSA-signed with our key**
and passes Gatekeeper, so a bad or unsigned artifact can never replace a running WM.

The feed URL and public key live in `Info.plist` (`SUFeedURL`, `SUPublicEDKey`). The
`Sparkle.framework` is embedded and signed by `.config/mise/tasks/package/release`.

## One-time setup

1. **Create the signing key.** Run Sparkle's `generate_keys` (it ships in the SwiftPM
   artifact after `swift build`):

   ```
   "$(find .build/artifacts -type f -name generate_keys | head -1)"
   ```

   The **private** key is stored in your login Keychain (never in the repo). Copy the
   printed **public** key into `Info.plist` under `SUPublicEDKey`, replacing the
   `REPLACE_WITH_SPARKLE_ED_PUBLIC_KEY` placeholder. Until this is done, the updater is
   inert by design (no key → no update is trusted).

2. **Publish the feed.** Enable GitHub Pages for the fork (e.g. Pages source = `main`
   branch, `/docs` folder). `SUFeedURL` in `Info.plist` must match the resulting URL
   (default: `https://stevenvelozo.github.io/nehir/appcast.xml`).

## Per release

1. Bump the version (the existing `release` task flow / `Info.plist`
   `CFBundleShortVersionString`).
2. Build + Developer-ID sign + notarize, producing `dist/Nehir-<version>.zip` (the
   `package/release` task — it now embeds and signs Sparkle automatically).
3. Create the GitHub Release for tag `v<version>` and upload the `.zip` as an asset.
4. Update the feed:

   ```
   packaging/generate-appcast.sh
   ```

   This signs the release with your Keychain key, points its download URL at the
   GitHub Release asset, preserves older entries, and writes `docs/appcast.xml`.
5. Commit `docs/appcast.xml`. GitHub Pages serves it; running copies pick up the update
   on their next scheduled check (or via the menu-bar **Check for Updates…**).

## Moving the feed later (e.g. to Exordium)

Point `SUFeedURL` at the new host and cut one release so installed copies learn the new
URL. Binaries can stay on GitHub Releases regardless of where the feed is served.
