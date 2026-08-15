// SPDX-FileCopyrightText: 2026 Steven Velozo
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import AppKit
@testable import Nehir
import SwiftUI

/// Look-and-feel knobs for the off-edge indicators. Grouped as one style struct so a theme can
/// eventually supply the whole set at once; for now each field is UserDefaults-backed (key
/// `NehirOffEdge<Field>`) so it can be tuned with `defaults write` + relaunch, no rebuild.
///
/// The indicator appears at `activeOpacity`/`activeSaturation` on any change, holds `fadeAfter`
/// seconds, then animates over `fadeDuration` to `restingOpacity`/`restingSaturation` (drop
/// saturation toward 0 for a muted/monochrome rest). `maxBadges` caps how many badges draw per
/// edge before the rest collapse into a "+N".
struct OffEdgeIndicatorStyle {
    var activeOpacity: Double
    var restingOpacity: Double
    var activeSaturation: Double
    var restingSaturation: Double
    var fadeAfter: TimeInterval
    var fadeDuration: TimeInterval
    var maxBadges: Int

    private static let prefix = "NehirOffEdge"

    static func load() -> OffEdgeIndicatorStyle {
        let defaults = UserDefaults.standard
        func double(_ key: String, _ fallback: Double) -> Double {
            defaults.object(forKey: prefix + key) as? Double ?? fallback
        }
        func integer(_ key: String, _ fallback: Int) -> Int {
            defaults.object(forKey: prefix + key) as? Int ?? fallback
        }
        return OffEdgeIndicatorStyle(
            activeOpacity: double("ActiveOpacity", 1.0),
            restingOpacity: double("RestingOpacity", 0.35),
            activeSaturation: double("ActiveSaturation", 1.0),
            restingSaturation: double("RestingSaturation", 1.0),
            fadeAfter: double("FadeAfter", 3.0),
            fadeDuration: double("FadeDuration", 0.4),
            maxBadges: max(0, integer("MaxBadges", 5))
        )
    }
}

/// Vertically-centered stacks of collapsed badges pinned to the left and right screen edges,
/// one badge per off-screen column on that side (plus a "+N" when more are hidden than
/// `maxBadges`). Purely visual.
private struct OffEdgeIndicatorView: View {
    let leftBadges: [WindowBadge]
    let leftOverflow: Int
    let rightBadges: [WindowBadge]
    let rightOverflow: Int
    var opacity: Double = 1.0
    var saturation: Double = 1.0
    /// When true (Deck open), the badges are tap targets — for touching them via iPad remote.
    var clickable = false
    var onTap: (Int) -> Void = { _ in }

    var body: some View {
        HStack {
            edgeStack(leftBadges, overflow: leftOverflow, edge: .leading)
            Spacer(minLength: 0)
            edgeStack(rightBadges, overflow: rightOverflow, edge: .trailing)
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .opacity(opacity)
        .saturation(saturation)
        // Only hit-test while clickable; the transparent areas never capture, so clicks pass
        // through to windows/Deck below except directly on a badge.
        .allowsHitTesting(clickable)
    }

    @ViewBuilder
    private func edgeStack(_ badges: [WindowBadge], overflow: Int, edge: HorizontalEdge) -> some View {
        if badges.isEmpty {
            Color.clear.frame(width: 0)
        } else {
            VStack(spacing: 6) {
                ForEach(badges) { edgeBadge($0, edge: edge) }
                if overflow > 0 { plusN(overflow) }
            }
        }
    }

    /// The number is pinned to the screen edge; the app icon sits on the inside (toward center)
    /// so you can tell at a glance which app it is. Tappable while the Deck is open.
    @ViewBuilder
    private func edgeBadge(_ badge: WindowBadge, edge: HorizontalEdge) -> some View {
        let row = HStack(spacing: 5) {
            if edge == .leading {
                ShapedNumber(number: badge.number, isFloating: badge.isFloating, size: 34)
                icon(badge)
            } else {
                icon(badge)
                ShapedNumber(number: badge.number, isFloating: badge.isFloating, size: 34)
            }
        }
        if clickable, let columnIndex = badge.columnIndex {
            Button { onTap(columnIndex) } label: { row }
                .buttonStyle(.plain)
        } else {
            row
        }
    }

    @ViewBuilder
    private func icon(_ badge: WindowBadge) -> some View {
        if let appIcon = badge.appIcon {
            Image(nsImage: appIcon)
                .resizable()
                .frame(width: 24, height: 24)
                .cornerRadius(5)
                .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
        }
    }

    private func plusN(_ count: Int) -> some View {
        Text("+\(count)")
            .font(.system(size: 15, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: 38, height: 30)
            .background(Capsule().fill(.black.opacity(0.7)))
            .overlay(Capsule().stroke(.white.opacity(0.5), lineWidth: 1.5))
    }
}

/// Persistent per-display overlays marking the columns scrolled off each edge, using the same
/// `WindowBadgeChip` (collapsed to number-only). Updated live from the layout-applied hook.
/// Pass 1: rendering only (full strength). Pass 2 adds the timed fade to the resting
/// opacity/saturation from `OffEdgeIndicatorStyle`.
@MainActor
final class OffEdgeIndicatorController {
    weak var controller: WMController?
    private var panels: [Monitor.ID: NSPanel] = [:]
    private var deckOpen = false

    /// Width reserved at an edge for the badge stack. If the strip's visible content leaves at
    /// least this much empty space at an edge, the badges sit in the gap (persistent);
    /// otherwise they would overlay windows, so they only show while the Deck/OSD is open.
    private let edgeBadgeReserve: CGFloat = 54

    /// The Deck opening/closing gates the overlay-on-windows case. Re-evaluates immediately.
    func setDeckOpen(_ open: Bool) {
        deckOpen = open
        if let workspaceId = controller?.interactionWorkspace()?.id {
            update(workspaceId: workspaceId)
        }
    }

    func update(workspaceId: WorkspaceDescriptor.ID) {
        guard let controller,
              let engine = controller.niriEngine,
              let monitor = controller.workspaceManager.monitor(for: workspaceId),
              controller.workspaceManager.activeWorkspace(on: monitor.id)?.id == workspaceId
        else {
            return
        }

        let columns = engine.columns(in: workspaceId)
        let state = controller.workspaceManager.niriViewportState(for: workspaceId)
        let visibleFrame = monitor.visibleFrame

        // Two-pass: use the real rendered frame only to decide what's actually ON-SCREEN (a
        // window's on-screen overlap; a parked column has almost none, wherever it's parked).
        // Off-screen columns are then assigned a side by their column INDEX relative to the
        // visible run — NOT by where they're physically parked (multi-monitor parks off-screen
        // columns on the safe left edge, so their frames are misleading).
        struct Col { let index: Int; let badge: WindowBadge; let frame: CGRect; let onScreen: Bool }
        let onScreenThreshold: CGFloat = 40
        var cols: [Col] = []
        for (index, column) in columns.enumerated() {
            guard let token = column.windowNodes.first?.token,
                  let entry = controller.workspaceManager.entry(for: token),
                  let frame = try? AXWindowService.frame(entry.axRef)
            else { continue }
            let number = index + 1
            let badge = WindowBadgeBuilder.make(
                number: number == 10 ? "0" : String(number),
                isFloating: false, token: token, entry: entry, frame: frame, columnIndex: index
            )
            let overlap = min(frame.maxX, visibleFrame.maxX) - max(frame.minX, visibleFrame.minX)
            cols.append(Col(index: index, badge: badge, frame: frame, onScreen: overlap > onScreenThreshold))
        }

        let onScreen = cols.filter(\.onScreen)
        let splitStart = onScreen.first?.index ?? state.activeColumnIndex
        let splitEnd = onScreen.last?.index ?? state.activeColumnIndex

        var offLeft: [WindowBadge] = []
        var offRight: [WindowBadge] = []
        var contentRight: CGFloat = visibleFrame.minX
        var contentLeft: CGFloat = visibleFrame.maxX
        for col in cols {
            if col.onScreen {
                contentRight = max(contentRight, col.frame.maxX)
                contentLeft = min(contentLeft, col.frame.minX)
            } else if col.index < splitStart {
                offLeft.append(col.badge)
            } else if col.index > splitEnd {
                offRight.append(col.badge)
            }
        }

        // A side gets a persistent badge only if the edge-most strip is empty (a gap); when
        // content fills the edge, the badges would sit on top of a window, so require the Deck.
        let gapLeft = (contentLeft - visibleFrame.minX) >= edgeBadgeReserve
        let gapRight = (visibleFrame.maxX - contentRight) >= edgeBadgeReserve
        let showLeft = !offLeft.isEmpty && (gapLeft || deckOpen)
        let showRight = !offRight.isEmpty && (gapRight || deckOpen)

        guard showLeft || showRight else {
            hide(monitor: monitor.id)
            return
        }

        let style = OffEdgeIndicatorStyle.load()
        let (leftShown, leftOverflow) = showLeft ? cap(offLeft, to: style.maxBadges) : ([], 0)
        let (rightShown, rightOverflow) = showRight ? cap(offRight, to: style.maxBadges) : ([], 0)

        let panel = panels[monitor.id] ?? NehirBadgePanel.make()
        panels[monitor.id] = panel
        // Accept clicks only while the Deck is open (for iPad-remote taps); otherwise stay
        // click-through so the persistent indicators never intercept normal interaction.
        panel.ignoresMouseEvents = !deckOpen
        panel.setFrame(monitor.frame, display: true)
        panel.contentView = NSHostingView(rootView: OffEdgeIndicatorView(
            leftBadges: leftShown,
            leftOverflow: leftOverflow,
            rightBadges: rightShown,
            rightOverflow: rightOverflow,
            opacity: style.activeOpacity,
            saturation: style.activeSaturation,
            clickable: deckOpen,
            onTap: { [weak self] index in
                self?.controller?.layoutCoordinator.focusColumn(index: index)
            }
        ))
        panel.orderFrontRegardless()
    }

    private func cap(_ badges: [WindowBadge], to maximum: Int) -> ([WindowBadge], Int) {
        guard maximum > 0, badges.count > maximum else { return (badges, 0) }
        return (Array(badges.prefix(maximum)), badges.count - maximum)
    }

    private func hide(monitor id: Monitor.ID) {
        panels[id]?.orderOut(nil)
        panels[id]?.contentView = nil
    }

    func hideAll() {
        for panel in panels.values {
            panel.orderOut(nil)
            panel.contentView = nil
        }
    }
}
