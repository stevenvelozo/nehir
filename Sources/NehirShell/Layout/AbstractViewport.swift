// SPDX-FileCopyrightText: 2026 Steven Velozo
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import CoreGraphics

/// The **abstract viewport**: the explicit layer between a monitor and the scrolling column
/// stream. Instead of laying columns into the monitor's whole working area, Nehir can lay them
/// into a smaller, possibly off-center region and let the neighbor columns' edges peek into the
/// reserved gutters. This file is the value model; `ViewportInsetController` owns the live state
/// and pushes the resolved fractions to the base through `NehirShellHook.viewportInset*`.
///
/// Today only the horizontal `.shrink` path is wired. `insets.top`/`.bottom` (vertical gutters,
/// for thin widget strips) and the `.slide` reveal mode are shaped here so they land as additive
/// changes, not rewrites — per the design intent that the layer be explicit from the start.

/// A length along one axis, expressed as either a fraction of that axis or absolute points.
/// Fractions drive the zoom (the reveal scales with the monitor); points are for fixed
/// reservations — a future Very-Thin-Widget strip wants a constant width, not a percentage.
enum ViewportExtent: Equatable {
    case fraction(CGFloat)
    case points(CGFloat)

    static let zero = ViewportExtent.fraction(0)

    /// Resolve to points against the given axis length.
    func points(along axis: CGFloat) -> CGFloat {
        switch self {
        case let .fraction(value): return axis * value
        case let .points(value): return value
        }
    }

    /// The fraction this extent represents (0 for a points-based extent, which the base's
    /// fraction seam does not consume yet).
    var fraction: CGFloat {
        switch self {
        case let .fraction(value): return value
        case .points: return 0
        }
    }

    var isZero: Bool {
        switch self {
        case let .fraction(value): return value == 0
        case let .points(value): return value == 0
        }
    }
}

/// Per-edge insets that shrink the layout region within the monitor. Asymmetry is first-class: a
/// larger `leading` inset shifts the region right (off-center) and reveals more of the LEFT
/// neighbor; setting one side to zero snaps the focused column flush to that edge with the gutter
/// only on the other side. `top`/`bottom` are reserved for a future vertical zoom / widget strips
/// and are not yet consumed by the base.
struct ViewportInsets: Equatable {
    var leading: ViewportExtent = .zero
    var trailing: ViewportExtent = .zero
    var top: ViewportExtent = .zero
    var bottom: ViewportExtent = .zero

    static let none = ViewportInsets()

    /// Symmetric horizontal zoom: the same fraction reserved on each side.
    static func horizontal(_ fraction: CGFloat) -> ViewportInsets {
        ViewportInsets(leading: .fraction(fraction), trailing: .fraction(fraction))
    }
}

/// How the reveal is achieved.
///
/// - `.shrink` (implemented): the focused window gets smaller so both gutters open and both
///   neighbors can peek. This is what a "100% wide" window becoming ~90% of the screen means.
/// - `.slide` (reserved): keep the window full-size and bias the viewport so ONE neighbor peeks
///   and the window's far edge slides off — a different feel, added later without reworking the
///   inset model (it will resolve to a scroll bias rather than to struts).
enum ViewportRevealMode: Equatable {
    case shrink
    case slide
}

/// The resolved abstract viewport: per-edge insets plus the reveal mode. `.identity` reproduces
/// upstream behavior exactly (the region fills the monitor), so the feature is inert until a
/// non-zero inset is set.
struct AbstractViewport: Equatable {
    var insets: ViewportInsets = .none
    var reveal: ViewportRevealMode = .shrink

    static let identity = AbstractViewport()
}
