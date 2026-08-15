// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import Foundation

enum DefaultFloatingApps {
    static let bundleIds: Set<String> = [
        "com.apple.systempreferences",
        "com.apple.SystemPreferences",
        "com.apple.iphonesimulator",
        "com.apple.PhotoBooth",
        "com.apple.calculator",
        "com.itoolab.unlockgo",
        // NEHIR: com.apple.ScreenSharing and com.apple.remotedesktop were removed from this
        // list — VNC / remote-desktop windows are large, resizable, real app windows worth
        // tiling by default (unlike the small utility surfaces above). Add an app-rule with
        // layout = "float" for either bundle id to restore the old floating behavior.
    ]

    static func shouldFloat(_ bundleId: String?) -> Bool {
        guard let bundleId else { return false }
        return bundleIds.contains(bundleId)
    }
}
