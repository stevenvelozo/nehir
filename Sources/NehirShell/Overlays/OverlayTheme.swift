// SPDX-FileCopyrightText: 2026 Steven Velozo
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import Foundation
import NehirShellWire

/// Persists which pict theme is active across overlays and restarts. The themes themselves —
/// the 44-theme catalog, the `Tokens.Color.*` design tokens, and the `--theme-color-*` CSS
/// they emit — all live in `pict-section-theme`; nehir only stores and broadcasts the chosen
/// theme **hash** so every overlay converges on one theme. `~/.config/nehir/theme.json`
/// holds `{ "active": "<hash>" }`.
enum ThemeStore {
    private static var baseDirectory: URL {
        ShellPaths.configDirectory().deletingLastPathComponent()
    }

    private static var activeFileURL: URL {
        baseDirectory.appendingPathComponent("theme.json", isDirectory: false)
    }

    /// The persisted active theme hash, or nil if the user hasn't chosen one yet (the pict
    /// provider then boots its own catalog default).
    static func activeThemeID() -> String? {
        guard let data = try? Data(contentsOf: activeFileURL),
              let object = try? JSONDecoder().decode([String: String].self, from: data)
        else { return nil }
        return object["active"]
    }

    static func setActiveThemeID(_ id: String) {
        try? FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(["active": id]) {
            try? data.write(to: activeFileURL)
        }
    }
}
