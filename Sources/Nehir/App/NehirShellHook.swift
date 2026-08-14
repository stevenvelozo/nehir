// SPDX-FileCopyrightText: 2026 Steven Velozo
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import CoreGraphics
import Foundation

/// The active global layout family. `river` is the base niri scrolling layout; the shell
/// layer sets this and the layout/admission seams below consult it. Kept here (not in
/// NehirShell) so the base can read it without importing the shell layer.
enum NehirLayoutMode: String, Sendable, CaseIterable {
    /// Base niri scrolling columns (the default).
    case river
    /// Same columns, positioned overlapping and distributed edge-to-edge.
    case blades
    /// Everything floats.
    case free
}

/// Fork-local extension seam for the NehirShell layer.
///
/// The base window manager calls out through this hook once the `WMController`
/// is fully bootstrapped. The NehirShell target — a separate SwiftPM target that
/// upstream does not ship — installs a handler at app launch. Routing through a
/// closure here keeps the upstream-derived sources free of any reference to the
/// shell layer (which would be a circular dependency, since NehirShell depends
/// on this module), so the only edits to upstream-tracked files are:
///   1. the single fenced call site in `AppDelegate.continueBootstrap`, and
///   2. the single `NehirShell.install()` call in `NehirApp.init`.
///
/// In an upstream-style build with no shell layer linked in, `activate` stays
/// nil and the call site is a no-op.
enum NehirShellHook {
    /// Installed by the app entry point when the NehirShell layer is linked in.
    /// Invoked once, on the main actor, after the controller, status bar, and IPC
    /// are wired up.
    ///
    /// Stored `nonisolated(unsafe)` to mirror the app-lifecycle singleton idiom
    /// already used in this module (`AppDelegate.sharedBootstrap`): it is written
    /// exactly once during `NehirApp.init` and read once during bootstrap, both on
    /// the main thread, so there is no concurrent access to guard.
    nonisolated(unsafe) static var activate: (@MainActor (WMController, SettingsStore) -> Void)?

    /// Lets the shell layer override a managed window's rule effects as the base
    /// finalizes them during reconciliation — used to inject a fork-configured forced
    /// column min-width (stored as a monitor-independent percent, converted to points
    /// against the window's workspace here). Given the window token and its resolved
    /// workspace so the handler can compute the monitor working width without a
    /// stored entry (the window may be mid-admission). Returns the effects unchanged
    /// when no shell layer is linked in or no rule matches.
    nonisolated(unsafe) static var overrideRuleEffects: (
        @MainActor (ManagedWindowRuleEffects, WindowToken, WorkspaceDescriptor.ID) -> ManagedWindowRuleEffects
    )?

    /// The active layout family, set by the shell layer. Read on the main thread by the
    /// layout/admission seams (same single-writer/main-reader idiom as `activate`).
    nonisolated(unsafe) static var layoutMode: NehirLayoutMode = .river

    /// When true, the niri visibility seam stops hiding a column whose overflow would spill
    /// onto a neighboring monitor — it stays visible, straddling the bezel onto the next
    /// display, instead of being parked. Set by the shell from the `crossMonitorOverflow`
    /// fork config. Off by default = upstream hide-on-neighbor behavior.
    nonisolated(unsafe) static var allowCrossMonitorOverflow = false

    /// Called after a workspace's layout frames are applied, so the shell layer can
    /// re-assert Blades' ordinal z-order (columns stacked front-to-back by index). A
    /// no-op in the other layout families.
    nonisolated(unsafe) static var didApplyWorkspaceLayout: (@MainActor (WorkspaceDescriptor.ID) -> Void)?

    /// Blades positioning: the on-screen left-edge offset for the column at `index`,
    /// given every column's width and the working width. Each column slides along its
    /// OWN range — from flush-left (0) to flush-right (`workingWidth − its width`) — by
    /// its index fraction, so the first is flush-left, the last flush-right, and the rest
    /// distributed in between without ever collapsing when a column is very wide (e.g. a
    /// full-width column simply pins to 0). A single column is centered. Pure math, so
    /// the layout seam can call it off any actor.
    static func bladesColumnX(index: Int, widths: [CGFloat], workingWidth: CGFloat) -> CGFloat {
        let count = widths.count
        guard count > 1, index >= 0, index < count else {
            let width = widths.indices.contains(index) ? widths[index] : (widths.first ?? 0)
            return max(0, (workingWidth - width) / 2)
        }
        let travel = max(0, workingWidth - widths[index])
        return CGFloat(index) / CGFloat(count - 1) * travel
    }
}
