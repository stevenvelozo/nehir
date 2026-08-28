// SPDX-FileCopyrightText: 2026 Steven Velozo
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import Foundation
import NehirShellWire

/// One saved command, optionally bound to a Deck runner slot. Persisted as JSON in
/// `~/.config/nehir/commandlets.json`, hand- and UI-editable.
///
/// A commandlet runs in the inherent terminal: *run* writes the line and presses
/// Enter, *load* writes the line and leaves the cursor for the author to edit first.
struct Commandlet: Codable, Identifiable, Equatable {
    /// Stable id (also the temp-file base name once program interpreters land).
    var id: String
    /// Human label shown in the palette and manager.
    var name: String
    /// `argv` (run as-is — the default for a line picked from history), or
    /// `bash | zsh | sh`. Program interpreters (node/python/…) are a later phase.
    var interpreter: String
    /// The command text.
    var body: String
    /// The folder to run in when `pinnedCwd` is true; ignored when false.
    var cwd: String?
    /// When true the runner prefixes `cd <cwd> &&`; when false the body runs in
    /// whatever directory the terminal is currently in (floating).
    var pinnedCwd: Bool
    /// Environment variable *names* to surface (never values — no secrets in the
    /// store). Optional; unused by the history-picker MVP.
    var env: [String]?
    /// 1...9 when bound to a palette slot; nil when only in the manager list.
    var slot: Int?

    init(id: String, name: String, interpreter: String = "argv", body: String,
         cwd: String? = nil, pinnedCwd: Bool = false, env: [String]? = nil, slot: Int? = nil) {
        self.id = id
        self.name = name
        self.interpreter = interpreter
        self.body = body
        self.cwd = cwd
        self.pinnedCwd = pinnedCwd
        self.env = env
        self.slot = slot
    }

    /// The exact line handed to the shell. For shell/argv bodies this is the body,
    /// optionally prefixed with a `cd` into the pinned folder. (Program-interpreter
    /// bodies materialize a temp file — deferred to a later phase.)
    var runLine: String {
        guard pinnedCwd, let directory = cwd, !directory.isEmpty else { return body }
        // Expand a leading `~` before quoting — the shell won't expand it inside quotes,
        // and quoting is what keeps paths with spaces intact.
        let expanded = (directory as NSString).expandingTildeInPath
        return "cd \(Commandlet.shellQuote(expanded)) && \(body)"
    }

    /// Single-quote a path for the shell, escaping embedded single quotes so paths
    /// with spaces or metacharacters survive the `cd`.
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Loads and saves the commandlet list. Best-effort and non-throwing, matching the
/// rest of the shell-config layer: a missing or malformed file reads as an empty
/// list rather than an error.
enum CommandletStore {
    /// The nehir base config dir (`~/.config/nehir/`) — the parent of `shell.d/`.
    /// `commandlets.json` is a standalone JSON store, not a merged `shell.d` TOML fragment,
    /// so it lives at the base, a peer of `shell.d/`.
    private static var baseDirectory: URL {
        ShellPaths.configDirectory().deletingLastPathComponent()
    }

    /// `~/.config/nehir/commandlets.json`.
    static var fileURL: URL {
        baseDirectory.appendingPathComponent("commandlets.json", isDirectory: false)
    }

    static func load() -> [Commandlet] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([Commandlet].self, from: data)) ?? []
    }

    static func save(_ commandlets: [Commandlet]) {
        try? FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(commandlets) else { return }
        try? data.write(to: fileURL)
    }

    /// The commandlet bound to a given 1...9 slot, if any.
    static func commandlet(inSlot slot: Int, from commandlets: [Commandlet]) -> Commandlet? {
        commandlets.first { $0.slot == slot }
    }
}
