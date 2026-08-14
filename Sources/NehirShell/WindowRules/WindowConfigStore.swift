// SPDX-FileCopyrightText: 2026 Steven Velozo
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import Foundation
import NehirShellWire

/// Loads, persists, and matches the fork-local `WindowConfigRule`s. Backed by a single
/// JSON file at `~/.config/nehir/window-rules.json` — programmatically managed (written
/// by the Deck's Configure flow), so it lives beside the user-authored `shell.d/` TOML
/// rather than inside it.
@MainActor
final class WindowConfigStore {
    private(set) var rules: [WindowConfigRule]
    private let fileURL: URL
    private let fileManager: FileManager

    init(fileURL: URL = WindowConfigStore.defaultFileURL(), fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        rules = WindowConfigStore.load(from: fileURL)
    }

    static func defaultFileURL() -> URL {
        // configDirectory() is `.../nehir/shell.d`; the rules file sits one level up.
        ShellPaths.configDirectory()
            .deletingLastPathComponent()
            .appendingPathComponent("window-rules.json", isDirectory: false)
    }

    /// The most specific rule matching a window: a title-scoped rule wins over an
    /// app-only rule so pinning one window never gets shadowed by a broad app rule.
    func rule(bundleId: String, title: String?) -> WindowConfigRule? {
        let matches = rules.filter { $0.matches(bundleId: bundleId, title: title) }
        return matches.first(where: \.isTitleScoped) ?? matches.first
    }

    /// Insert or replace a rule (by id), then persist. An effect-less rule is removed.
    func upsert(_ rule: WindowConfigRule) {
        rules.removeAll { $0.id == rule.id }
        if !rule.hasNoEffect {
            rules.append(rule)
        }
        save()
    }

    func remove(id: UUID) {
        rules.removeAll { $0.id == id }
        save()
    }

    private static func load(from fileURL: URL) -> [WindowConfigRule] {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([WindowConfigRule].self, from: data)
        else { return [] }
        return decoded
    }

    private func save() {
        try? fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard let data = try? JSONEncoder().encode(rules) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
