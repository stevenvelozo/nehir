// SPDX-FileCopyrightText: 2026 Steven Velozo
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import Foundation

/// One deduplicated shell-history command: the text, how many times it appears, and the
/// most recent time it ran (epoch seconds) when the history file records timestamps.
struct ShellHistoryEntry: Codable, Equatable {
    var command: String
    var count: Int
    var lastUsed: Double?
}

/// Reads the user's shell history (zsh / bash) and returns unique commands. This is the
/// commandlet manager's host-data bridge — the manager asks Swift for the history so the
/// picker reflects what the user actually runs, the same JS-on-Swift pattern as the font
/// list. The manager sorts (recent vs frequent) client-side from `count` + `lastUsed`.
enum ShellHistory {
    static func entries(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        limit: Int = 600
    ) -> [ShellHistoryEntry] {
        let shell = ((environment["SHELL"] ?? "zsh") as NSString).lastPathComponent
        let isZsh = shell.contains("zsh")
        let home = environment["HOME"] ?? NSHomeDirectory()

        let path: String
        if let histFile = environment["HISTFILE"], !histFile.isEmpty {
            path = (histFile as NSString).expandingTildeInPath
        } else if isZsh {
            path = home + "/.zsh_history"
        } else if shell.contains("bash") {
            path = home + "/.bash_history"
        } else {
            path = home + "/.\(shell)_history"
        }

        // zsh extended history can contain non-UTF8 bytes, so decode lossily.
        guard let data = FileManager.default.contents(atPath: path) else { return [] }
        let raw = String(decoding: data, as: UTF8.self)
        return parse(raw, isZsh: isZsh, limit: limit)
    }

    private static func parse(_ raw: String, isZsh: Bool, limit: Int) -> [ShellHistoryEntry] {
        var byCommand: [String: ShellHistoryEntry] = [:]
        var lastIndex: [String: Int] = [:]
        var index = 0
        var pendingBashTimestamp: Double?

        for lineSub in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(lineSub)
            var timestamp: Double?

            if isZsh, line.hasPrefix(": ") {
                // Extended zsh history: ": <startEpoch>:<elapsed>;<command>"
                if let semicolon = line.firstIndex(of: ";") {
                    let meta = line[line.index(line.startIndex, offsetBy: 2) ..< semicolon]
                    if let colon = meta.firstIndex(of: ":") {
                        timestamp = Double(meta[meta.startIndex ..< colon])
                    }
                    line = String(line[line.index(after: semicolon)...])
                }
            } else if !isZsh, line.hasPrefix("#"), let epoch = Double(line.dropFirst()) {
                // bash with HISTTIMEFORMAT writes a "#<epoch>" line before each command.
                pendingBashTimestamp = epoch
                continue
            }

            let command = line.trimmingCharacters(in: .whitespaces)
            guard !command.isEmpty else { continue }
            let resolved = timestamp ?? pendingBashTimestamp
            pendingBashTimestamp = nil

            index += 1
            lastIndex[command] = index
            if var existing = byCommand[command] {
                existing.count += 1
                if let resolved, (existing.lastUsed ?? 0) < resolved { existing.lastUsed = resolved }
                byCommand[command] = existing
            } else {
                byCommand[command] = ShellHistoryEntry(command: command, count: 1, lastUsed: resolved)
            }
        }

        // Most-recent first (by last appearance in the file), capped.
        let sorted = byCommand.values.sorted { (lastIndex[$0.command] ?? 0) > (lastIndex[$1.command] ?? 0) }
        return Array(sorted.prefix(limit))
    }
}
