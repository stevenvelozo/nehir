// SPDX-FileCopyrightText: 2026 Steven Velozo
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import AppKit
@testable import Nehir
import SwiftUI

/// One column's number badge, positioned in panel-local (top-left origin) points.
/// `x`/`y` are the badge circle's center; the info pill trails to its right.
struct ColumnBadge: Identifiable {
    let id = UUID()
    let label: String
    let x: CGFloat
    let y: CGFloat
    let info: FocusInfo
}

/// The badges drawn over each column while the Deck is open: a number circle plus an
/// info pill (managed/floating · forced min-width % · live size) overlaid on the window.
private struct ColumnBadgeView: View {
    let badges: [ColumnBadge]

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(badges) { badge in
                HStack(spacing: 6) {
                    numberCircle(badge.label)
                    infoPill(badge.info)
                }
                // Anchor the circle's center at (x, y); the pill trails to the right.
                .offset(x: badge.x - 19, y: badge.y - 19)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    private func numberCircle(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 20, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: 38, height: 38)
            .background(Circle().fill(Color.accentColor.opacity(0.92)))
            .overlay(Circle().stroke(.white.opacity(0.85), lineWidth: 2))
            .shadow(color: .black.opacity(0.35), radius: 5, y: 2)
    }

    private func infoPill(_ info: FocusInfo) -> some View {
        HStack(spacing: 5) {
            Text(info.isFloating ? "Floating" : "Managed")
                .foregroundStyle(info.isFloating ? Color.orange : Color.white.opacity(0.9))
            if let pct = info.minPercent {
                pillDot
                Text("min \(pct)%").foregroundStyle(.white.opacity(0.9))
            }
            pillDot
            Text("\(info.width)×\(info.height)")
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.9))
        }
        .font(.system(size: 11, weight: .semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(.black.opacity(0.62)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 4, y: 1)
    }

    private var pillDot: some View {
        Circle().fill(.white.opacity(0.4)).frame(width: 2.5, height: 2.5)
    }
}

/// A click-through overlay that shows a number over each column while the Deck is
/// open, so the `⌘D → digit` column jump has a visible target. Non-activating and
/// `ignoresMouseEvents`, so it never disturbs focus, the key tap, or clicks — it is
/// purely a visual hint layer that mirrors the Deck's open/close lifecycle.
@MainActor
final class ColumnBadgeOverlayController {
    private var panel: NSPanel?

    /// Compute badges for the interaction workspace and show them. Columns come from
    /// the same `engine.columns(in:)` the base `focusColumn` command indexes, so badge
    /// N matches the `⌘D → N` jump. Positions come from each column's first window
    /// frame (AppKit coords → map straight onto `NSScreen`). v1: badges the columns on
    /// the first resolved screen only; recomputed per open (a sticky move can reflow).
    func present(using controller: WMController) {
        guard let engine = controller.niriEngine,
              let workspaceId = controller.interactionWorkspace()?.id
        else {
            hide()
            return
        }

        var targetScreen: NSScreen?
        var badges: [ColumnBadge] = []
        for (index, column) in engine.columns(in: workspaceId).prefix(10).enumerated() {
            guard let token = column.windowNodes.first?.token,
                  let entry = controller.workspaceManager.entry(for: token),
                  let frame = try? AXWindowService.frame(entry.axRef)
            else { continue }
            let center = CGPoint(x: frame.midX, y: frame.midY)
            guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) ?? NSScreen.main
            else { continue }
            if targetScreen == nil { targetScreen = screen }
            // v1: badge only the columns on the first resolved screen.
            guard screen === targetScreen else { continue }
            let number = index + 1
            badges.append(ColumnBadge(
                label: number == 10 ? "0" : String(number),
                x: frame.midX - screen.frame.minX,
                y: (screen.frame.maxY - frame.maxY) + 26,
                info: Self.focusInfo(token: token, entry: entry, frame: frame)
            ))
        }

        if let screen = targetScreen {
            show(badges: badges, on: screen)
        } else {
            hide()
        }
    }

    /// Build the info shown in a badge's pill: managed/floating, the configured forced
    /// min-width % (if any, matched by bundle id + title), and the live pixel size.
    private static func focusInfo(token: WindowToken, entry: WindowModel.Entry, frame: CGRect) -> FocusInfo {
        let title = AXWindowService.titlePreferFast(windowId: UInt32(token.windowId))
        let minPercent = NSRunningApplication(processIdentifier: token.pid)?.bundleIdentifier
            .flatMap { NehirShell.windowRules?.rule(bundleId: $0, title: title)?.minWidthPercent }
            .map { Int($0.rounded()) }
        return FocusInfo(
            isFloating: entry.mode == .floating,
            minPercent: minPercent,
            width: Int(frame.width.rounded()),
            height: Int(frame.height.rounded())
        )
    }

    func show(badges: [ColumnBadge], on screen: NSScreen) {
        guard !badges.isEmpty else {
            hide()
            return
        }
        let panel = panel ?? makePanel()
        self.panel = panel
        panel.setFrame(screen.frame, display: true)
        panel.contentView = NSHostingView(rootView: ColumnBadgeView(badges: badges))
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
        panel?.contentView = nil
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Purely visual: never intercept clicks or become key.
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .stationary]
        return panel
    }
}
