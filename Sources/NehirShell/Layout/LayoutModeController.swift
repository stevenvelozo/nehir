// SPDX-FileCopyrightText: 2026 Steven Velozo
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import AppKit
@testable import Nehir

/// Owns the global layout family (River / Blades / Free) and drives the transitions.
///
/// The mode is published to the base through `NehirShellHook.layoutMode`, which the
/// Blades positioning seam and the Free open-floating seam read. River↔Blades is just a
/// relayout (same columns, different X); Free floats every window on the way in and
/// re-tiles them on the way out. Global (not per-workspace) and persisted across launches.
@MainActor
final class LayoutModeController {
    private weak var controller: WMController?
    private(set) var mode: NehirLayoutMode
    private static let defaultsKey = "NehirLayoutMode"

    /// Additional per-workspace-layout-applied callback (beyond Blades z-order), chained off the
    /// single `NehirShellHook.didApplyWorkspaceLayout` closure. Used to update the off-edge
    /// indicators live as columns scroll on/off.
    var onDidApplyLayout: (@MainActor (WorkspaceDescriptor.ID) -> Void)?

    init(controller: WMController) {
        self.controller = controller
        mode = NehirLayoutMode(rawValue: UserDefaults.standard.string(forKey: Self.defaultsKey) ?? "") ?? .river
        NehirShellHook.layoutMode = mode
        NehirShellHook.didApplyWorkspaceLayout = { [weak self] workspaceId in
            self?.applyBladesZOrder(workspaceId: workspaceId)
            self?.onDidApplyLayout?(workspaceId)
        }
        // Launching straight into Free: float whatever is currently tiled.
        if mode == .free { enterFree() }
    }

    /// Blades ordinal z-order: stack a workspace's columns front-to-back by index — each
    /// window ordered above the previous, so the first column is at the back and the last
    /// on top (every window's left edge peeks out). The ordinal is the user's to arrange;
    /// we never reshuffle by width or focus. A no-op outside Blades.
    private func applyBladesZOrder(workspaceId: WorkspaceDescriptor.ID) {
        guard NehirShellHook.layoutMode == .blades,
              let engine = controller?.niriEngine
        else { return }
        var previous: UInt32?
        for column in engine.columns(in: workspaceId) {
            for window in column.windowNodes {
                let wid = UInt32(window.token.windowId)
                if let previous {
                    SkyLight.shared.orderWindow(wid, relativeTo: previous, order: .above)
                }
                previous = wid
            }
        }
    }

    func set(_ newMode: NehirLayoutMode) {
        guard newMode != mode, let controller else { return }
        let previous = mode
        mode = newMode
        NehirShellHook.layoutMode = newMode
        UserDefaults.standard.set(newMode.rawValue, forKey: Self.defaultsKey)

        // Gallery flips every column to/from forced full width — that both re-resolves cached
        // widths AND leaves the viewport scroll anchor stale, so a plain relayout would leave the
        // (now full-bleed) windows straddling the old scroll position. `reflowForWorkingWidthChange`
        // re-resolves the widths and re-centers the active column (the same path the zoom uses).
        let galleryTransition = newMode == .gallery || previous == .gallery

        if newMode == .free, previous != .free {
            enterFree()
        } else if previous == .free, newMode != .free {
            retileAllFloating()
            if galleryTransition {
                controller.niriLayoutHandler.reflowForWorkingWidthChange()
            } else {
                controller.layoutRefreshController.requestRefresh(reason: .workspaceLayoutToggled)
            }
        } else if galleryTransition {
            controller.niriLayoutHandler.reflowForWorkingWidthChange()
        } else {
            // River ↔ Blades: just reposition.
            controller.layoutRefreshController.requestRefresh(reason: .workspaceLayoutToggled)
        }
    }

    /// Enter Free: float every tiled window, then — once the relayout has actually applied
    /// the float frames (a post-layout hook, so we never race the transition) — rescue any
    /// window river had scrolled fully off-screen so it isn't left invisible.
    private func enterFree() {
        guard let controller else { return }
        for entry in controller.workspaceManager.allEntries() where entry.mode == .tiling {
            _ = controller.toggleWindowFloating(token: entry.token)
        }
        controller.layoutRefreshController.requestRefresh(
            reason: .workspaceLayoutToggled,
            postLayout: { [weak self] in self?.rescueOffscreenFloatingWindows() }
        )
    }

    private func retileAllFloating() {
        guard let controller else { return }
        for entry in controller.workspaceManager.allEntries() where entry.mode == .floating {
            _ = controller.toggleWindowFloating(token: entry.token)
        }
    }

    private func rescueOffscreenFloatingWindows() {
        guard let controller else { return }
        for entry in controller.workspaceManager.allEntries() where entry.mode == .floating {
            clampNearlyInvisibleOnScreen(entry)
        }
    }

    /// Move a floating window onto a display only if it's *nearly* invisible (≤15% on
    /// screen) — a window scrolled off-screen by river. Anything meaningfully visible is
    /// left exactly where it is, so this never disturbs windows the user placed.
    private func clampNearlyInvisibleOnScreen(_ entry: WindowModel.Entry) {
        guard let frame = try? AXWindowService.frame(entry.axRef) else { return }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) })
            ?? NSScreen.screens.first(where: { $0.frame.intersects(frame) })
            ?? NSScreen.main
        else { return }
        let visible = screen.visibleFrame
        let onScreen = frame.intersection(visible)
        let onScreenArea = onScreen.isNull ? 0 : onScreen.width * onScreen.height
        let windowArea = frame.width * frame.height
        guard windowArea > 0, onScreenArea / windowArea <= 0.15 else { return }
        let width = min(frame.width, visible.width)
        let height = min(frame.height, visible.height)
        let originX = min(max(frame.minX, visible.minX), visible.maxX - width)
        let originY = min(max(frame.minY, visible.minY), visible.maxY - height)
        _ = AXWindowService.setFrame(entry.axRef, frame: CGRect(x: originX, y: originY, width: width, height: height))
    }
}
