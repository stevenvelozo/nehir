// SPDX-FileCopyrightText: 2026 Steven Velozo
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import Foundation

/// A fork-local, durable window rule the user sets from the Deck's Configure flow.
///
/// Width is stored as a **percent** of the monitor's working width (not points), so a
/// rule stays meaningful across displays — the shell converts it to points against the
/// window's current monitor each time the layout re-evaluates. Matching is by app bundle
/// id plus an optional title substring: with no substring the rule covers every window
/// of the app; with one it pins a single window whose title carries a stable token (e.g.
/// a Chrome app/PWA window titled "Plansheet"). Plain multi-profile Chrome windows whose
/// titles don't distinguish fall back to app-only — an inherent AX limit, surfaced in UI.
struct WindowConfigRule: Codable, Identifiable, Equatable {
    var id = UUID()
    var bundleId: String
    /// Optional title substring; `nil`/empty matches every window of the app.
    var titleContains: String?
    /// Forced column minimum width as a percent (0…100) of the monitor working width.
    var minWidthPercent: Double?
    /// The width (percent 0…100 of working width) a NEW window of this app/title opens at,
    /// overriding the layout default. Unlike `minWidthPercent` this is a one-shot INITIAL
    /// width applied only at admission — the window stays freely resizable afterward. `nil`
    /// leaves the layout default. Captured from an explicit user width command (⌘D→W).
    var createWidthPercent: Double?
    /// Pin the matched window to floating.
    var alwaysFloat: Bool = false

    init(
        id: UUID = UUID(),
        bundleId: String,
        titleContains: String? = nil,
        minWidthPercent: Double? = nil,
        createWidthPercent: Double? = nil,
        alwaysFloat: Bool = false
    ) {
        self.id = id
        self.bundleId = bundleId
        self.titleContains = titleContains
        self.minWidthPercent = minWidthPercent
        self.createWidthPercent = createWidthPercent
        self.alwaysFloat = alwaysFloat
    }

    /// Tolerant decoding so a hand-edited or forward-versioned rules file still loads:
    /// only `bundleId` is required; everything else falls back to its default.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        bundleId = try container.decode(String.self, forKey: .bundleId)
        titleContains = try container.decodeIfPresent(String.self, forKey: .titleContains)
        minWidthPercent = try container.decodeIfPresent(Double.self, forKey: .minWidthPercent)
        createWidthPercent = try container.decodeIfPresent(Double.self, forKey: .createWidthPercent)
        alwaysFloat = try container.decodeIfPresent(Bool.self, forKey: .alwaysFloat) ?? false
    }

    func matches(bundleId: String, title: String?) -> Bool {
        guard self.bundleId == bundleId else { return false }
        guard let needle = titleContains, !needle.isEmpty else { return true }
        return (title ?? "").localizedCaseInsensitiveContains(needle)
    }

    /// True when the rule pins a specific window by title rather than the whole app.
    var isTitleScoped: Bool {
        (titleContains?.isEmpty == false)
    }

    /// True when the rule would change nothing (safe to drop instead of persist).
    var hasNoEffect: Bool {
        minWidthPercent == nil && createWidthPercent == nil && !alwaysFloat
    }
}
