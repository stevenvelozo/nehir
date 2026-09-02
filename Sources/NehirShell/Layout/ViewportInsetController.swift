// SPDX-FileCopyrightText: 2026 Steven Velozo
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import AppKit
@testable import Nehir

/// Owns the abstract-viewport zoom and pushes it to the base.
///
/// The live knob (Deck `Z`, in the Display pane) cycles a **symmetric horizontal** zoom — the
/// fraction of the screen reserved as a gutter on EACH side — through a few preset levels. The
/// resolved per-edge fractions are published to
/// `NehirShellHook.viewportInset{Leading,Trailing}Fraction`, which the single region-shrink funnel
/// (`WMController.insetWorkingFrame(from:)`) and the park-gate un-clip (`NiriLayout`) read. Global
/// (not per-workspace) and persisted across launches, mirroring `LayoutModeController`.
///
/// The stored value is the whole `AbstractViewport`, so asymmetric insets and (later) slide-to-peek
/// are data changes rather than rewrites; only the symmetric-shrink path is exposed to the Deck
/// today. Asymmetric insets can already be exercised by writing the base fractions directly (e.g.
/// `defaults`-driven experiments) since the base seam is per-edge.
@MainActor
final class ViewportInsetController {
    private weak var controller: WMController?
    private(set) var viewport: AbstractViewport
    private static let zoomDefaultsKey = "NehirViewportZoom"

    /// Preset per-side zoom levels the Deck key cycles through (fraction of screen width per side).
    /// 0 = off (identity). Kept small so a "100%" column stays clearly dominant while its neighbors
    /// peek. Tunable set, not magic constants tied to one screen size — each is a fraction.
    static let zoomLevels: [CGFloat] = [0, 0.02, 0.05, 0.10, 0.15, 0.20]

    init(controller: WMController) {
        self.controller = controller
        let stored = UserDefaults.standard.object(forKey: Self.zoomDefaultsKey) as? Double
        let fraction = Self.clampZoom(CGFloat(stored ?? 0))
        viewport = AbstractViewport(insets: .horizontal(fraction), reveal: .shrink)
        publish()
    }

    /// The current symmetric per-side zoom as a fraction (0 when off).
    var zoomFraction: CGFloat {
        viewport.insets.leading.fraction
    }

    /// Deck label: "Off" or e.g. "5%".
    var zoomLabel: String {
        let fraction = zoomFraction
        return fraction <= 0 ? "Off" : "\(Int((fraction * 100).rounded()))%"
    }

    /// Cycle to the next preset per-side zoom, wrapping back to Off.
    func cycleZoom() {
        let current = zoomFraction
        let next = Self.zoomLevels.first(where: { $0 > current + 0.0001 }) ?? Self.zoomLevels.first ?? 0
        setZoom(next)
    }

    /// Set a symmetric per-side zoom fraction, persist, and relayout so the change is felt live.
    func setZoom(_ fraction: CGFloat) {
        let clamped = Self.clampZoom(fraction)
        viewport.insets = .horizontal(clamped)
        viewport.reveal = .shrink
        UserDefaults.standard.set(Double(clamped), forKey: Self.zoomDefaultsKey)
        publish()
        reflowAndRecenterActiveColumn()
    }

    /// Apply a zoom nudge: resize the columns against the new region and re-center the focused one.
    /// A plain relayout preserves the stale scroll anchor by design, so the base reflow both resizes
    /// and re-centers — driving the scroll animation so the change lands smoothly, not with a flicker.
    private func reflowAndRecenterActiveColumn() {
        controller?.niriLayoutHandler.reflowForWorkingWidthChange()
    }

    /// Push the resolved per-edge fractions to the base hook (the `.shrink` seam).
    private func publish() {
        NehirShellHook.viewportInsetLeadingFraction = Self.clampZoom(viewport.insets.leading.fraction)
        NehirShellHook.viewportInsetTrailingFraction = Self.clampZoom(viewport.insets.trailing.fraction)
    }

    /// A single side never eats more than 45% of the screen, so the region can't collapse even if
    /// both sides are maxed. Matches the clamp the base applies, so the shrink and the un-clip agree.
    private static func clampZoom(_ fraction: CGFloat) -> CGFloat {
        max(0, min(0.45, fraction))
    }
}
