// SPDX-FileCopyrightText: 2026 Steven Velozo
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import Sparkle

/// Owns Sparkle's standard updater for the fork's auto-update feature.
///
/// The appcast feed URL (`SUFeedURL`) and the EdDSA public key (`SUPublicEDKey`) are
/// read from the app's `Info.plist`; automatic background checks are governed by
/// `SUEnableAutomaticChecks` / `SUScheduledCheckInterval` there too. This wrapper just
/// holds the controller for the app's lifetime and exposes a manual "check now" for the
/// menu-bar item. Updates are only ever applied if EdDSA-signed with the matching key
/// AND pass Gatekeeper — so a bad or unsigned build can never replace a running WM.
@MainActor
final class NehirUpdaterController {
    private let controller: SPUStandardUpdaterController

    /// Whether the fork ships a real EdDSA public key yet. Until `SUPublicEDKey` is a
    /// genuine key (not the build placeholder / empty), Sparkle fatals on startup and
    /// surfaces an "update server" error dialog, so the caller skips the updater entirely
    /// — no auto-update, no error popup — until the key + appcast are wired up.
    static var isConfigured: Bool {
        guard let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String else {
            return false
        }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && !trimmed.hasPrefix("REPLACE_WITH")
    }

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    var canCheckForUpdates: Bool {
        controller.updater.canCheckForUpdates
    }

    /// Present the standard "checking for updates" flow (from the menu-bar item / CLI).
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
