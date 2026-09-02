// SPDX-FileCopyrightText: 2026 Steven Velozo
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import AppKit
@testable import Nehir

/// Bridges fork window rules into the base layout: given a window's rule effects (as
/// the base finalizes them), the window token, and its workspace, it applies any
/// matching rule's forced column min-width. The width is stored as a percent and
/// converted to points against the window's *current* monitor here, so the same rule
/// stays correct as the window moves between displays.
@MainActor
enum WindowConfigApplier {
    static func apply(
        _ effects: ManagedWindowRuleEffects,
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        store: WindowConfigStore,
        controller: WMController
    ) -> ManagedWindowRuleEffects {
        guard let bundleId = NSRunningApplication(processIdentifier: token.pid)?.bundleIdentifier else {
            return effects
        }
        let title = AXWindowService.titlePreferFast(windowId: UInt32(token.windowId))
        guard let rule = store.rule(bundleId: bundleId, title: title),
              let percent = rule.minWidthPercent,
              let monitor = controller.workspaceManager.monitor(for: workspaceId)
        else { return effects }

        let workingWidth = controller.insetWorkingFrame(for: monitor).width
        let points = Double(workingWidth) * percent / 100.0
        var updated = effects
        // Never shrink a min the base already set — take the larger.
        updated.minWidth = max(updated.minWidth ?? 0, points)
        return updated
    }

    /// The remembered open-width for a window, as a fraction (0…1) of working width, or nil
    /// when no rule sets one. Resolves the window's app/title the same way `apply` does, then
    /// reads the most-specific matching rule's `createWidthPercent`. Monitor-independent (a
    /// fraction, not points), so it needs no workspace/monitor.
    static func createWidthProportion(token: WindowToken, store: WindowConfigStore) -> Double? {
        guard let bundleId = NSRunningApplication(processIdentifier: token.pid)?.bundleIdentifier else {
            return nil
        }
        let title = AXWindowService.titlePreferFast(windowId: UInt32(token.windowId))
        guard let percent = store.rule(bundleId: bundleId, title: title)?.createWidthPercent else {
            return nil
        }
        return percent / 100.0
    }
}
