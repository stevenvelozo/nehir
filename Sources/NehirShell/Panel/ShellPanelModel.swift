// SPDX-FileCopyrightText: 2026 Steven Velozo
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import FableCore
import Foundation

/// The content brain of the desktop status panel: turns the configured fable
/// template plus live data (clock, date, host) and the shell's `custom` config
/// values into the string the panel displays. Kept free of AppKit so it can be
/// exercised without a window on screen.
@MainActor
final class ShellPanelModel {
    private let core: FableCore
    private var template: String
    private var customData: [String: String]

    private let timeFormatter: DateFormatter
    private let dateFormatter: DateFormatter
    private let weekdayFormatter: DateFormatter

    init(core: FableCore, config: PanelConfig, custom: [String: String]) {
        self.core = core
        template = config.template
        customData = custom

        timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm:ss"
        dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        weekdayFormatter = DateFormatter()
        weekdayFormatter.dateFormat = "EEEE"
    }

    /// Render the panel text for a given instant. Falls back to the raw template
    /// if fable rendering throws, so the panel never goes blank on a bad template.
    func render(now: Date) -> String {
        var data = customData
        data["time"] = timeFormatter.string(from: now)
        data["date"] = dateFormatter.string(from: now)
        data["weekday"] = weekdayFormatter.string(from: now)
        data["host"] = Host.current().localizedName ?? ProcessInfo.processInfo.hostName

        do {
            return try core.render(template, data: data)
        } catch {
            return template
        }
    }

    /// Update the template/data live (e.g. after a config reload) without
    /// recreating the panel.
    func update(config: PanelConfig, custom: [String: String]) {
        template = config.template
        customData = custom
    }
}
