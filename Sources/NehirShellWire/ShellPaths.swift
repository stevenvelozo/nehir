// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import Foundation

/// File locations for the NehirShell layer, shared by the in-app server and the
/// `nehirshellctl` client so the two can never disagree on where the socket lives.
///
/// Intentionally self-contained (it re-derives XDG paths rather than reaching into
/// the base manager's internal `NehirStoragePaths`) so the shell layer never
/// couples to an upstream `internal` type — keeping upstream syncs conflict-free.
public enum ShellPaths {
    public static let socketEnvironmentKey = "NEHIR_SHELL_SOCKET"

    /// `~/.config/nehir/shell.d/` (honoring `$XDG_CONFIG_HOME`).
    public static func configDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        xdgBase(key: "XDG_CONFIG_HOME", fallback: ".config", environment: environment)
            .appendingPathComponent("nehir/shell.d", isDirectory: true)
    }

    /// Control-socket path. Overridable with `NEHIR_SHELL_SOCKET`; otherwise a
    /// per-user caches path alongside the base manager's own socket.
    public static func socketPath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> String {
        if let override = environment[socketEnvironmentKey], !override.isEmpty {
            return override
        }
        let cachesBase = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Caches", isDirectory: true)
        return cachesBase
            .appendingPathComponent("dev.guria.nehir", isDirectory: true)
            .appendingPathComponent("shell.sock", isDirectory: false)
            .path
    }

    private static func xdgBase(key: String, fallback: String, environment: [String: String]) -> URL {
        if let path = environment[key], path.hasPrefix("/") {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(fallback, isDirectory: true)
    }
}
