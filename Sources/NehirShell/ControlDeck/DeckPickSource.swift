// SPDX-FileCopyrightText: 2026 Steven Velozo
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import AppKit
@testable import Nehir

/// Builds the live drill-in rows for the Deck's list modes. Columns use the same
/// `engine.columns(in:)` the badges and the base `focusColumn` command use, so a
/// row's number matches its on-screen badge and `⌘D → digit` target. Floating rows
/// cover windows outside the column flow, which the column jump can't reach.
enum DeckPickSource {
    @MainActor
    static func items(for mode: DeckModeID, using controller: WMController) -> [DeckPickItem] {
        switch mode {
        case .columns: columns(using: controller)
        case .floating: floating(using: controller)
        default: []
        }
    }

    @MainActor
    private static func columns(using controller: WMController) -> [DeckPickItem] {
        guard let engine = controller.niriEngine,
              let workspaceId = controller.interactionWorkspace()?.id
        else { return [] }
        return engine.columns(in: workspaceId).prefix(10).enumerated().map { index, column in
            let number = index + 1
            return DeckPickItem(
                label: label(for: number),
                title: title(ofColumn: column, number: number, controller: controller)
            ) { [weak controller] in
                _ = controller?.commandHandler.performCommand(.focusColumn(index))
            }
        }
    }

    @MainActor
    private static func floating(using controller: WMController) -> [DeckPickItem] {
        controller.workspaceManager.allFloatingEntries().prefix(10).enumerated().map { index, entry in
            let token = entry.token
            return DeckPickItem(
                label: label(for: index + 1),
                title: title(of: entry, fallback: "Window \(index + 1)")
            ) { [weak controller] in
                controller?.focusWindow(token)
            }
        }
    }

    /// Every window you can configure — the interaction workspace's tiled columns plus
    /// all floating windows — numbered for the Configure flow's "pick a window" step.
    @MainActor
    static func configureTargets(using controller: WMController) -> [ConfigureTargetItem] {
        var entries: [WindowModel.Entry] = []
        if let engine = controller.niriEngine, let workspaceId = controller.interactionWorkspace()?.id {
            for column in engine.columns(in: workspaceId) {
                if let token = column.windowNodes.first?.token,
                   let entry = controller.workspaceManager.entry(for: token)
                {
                    entries.append(entry)
                }
            }
        }
        entries.append(contentsOf: controller.workspaceManager.allFloatingEntries())

        return entries.prefix(10).enumerated().compactMap { index, entry in
            guard let bundleId = NSRunningApplication(processIdentifier: entry.token.pid)?.bundleIdentifier
            else { return nil }
            let title = title(of: entry, fallback: "Window \(index + 1)")
            return ConfigureTargetItem(
                label: label(for: index + 1),
                title: title,
                target: ConfigureTarget(token: entry.token, bundleId: bundleId, title: title)
            )
        }
    }

    private static func label(for number: Int) -> String {
        number == 10 ? "0" : String(number)
    }

    /// A column's display title: its focused window's title, else the app name (needs
    /// no Screen Recording grant), else a plain "Column N".
    @MainActor
    private static func title(ofColumn column: NiriContainer, number: Int, controller: WMController) -> String {
        guard let token = column.windowNodes.first?.token,
              let entry = controller.workspaceManager.entry(for: token)
        else { return "Column \(number)" }
        return title(of: entry, fallback: "Column \(number)")
    }

    @MainActor
    private static func title(of entry: WindowModel.Entry, fallback: String) -> String {
        if let title = AXWindowService.titlePreferFast(windowId: UInt32(entry.windowId)),
           !title.isEmpty
        {
            return title
        }
        if let appName = NSRunningApplication(processIdentifier: entry.token.pid)?.localizedName {
            return appName
        }
        return fallback
    }
}
