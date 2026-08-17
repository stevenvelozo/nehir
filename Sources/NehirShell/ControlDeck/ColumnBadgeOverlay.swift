// SPDX-FileCopyrightText: 2026 Steven Velozo
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import AppKit
@testable import Nehir
import SwiftUI

// MARK: - Shared responsive badge

/// How much of a badge to draw. Collapses gracefully as room shrinks so the same unit works
/// for the on-window decoration, the list row, and (later) the off-edge sliver: the
/// shaped/number is always drawn; richer fields are added in priority order
/// number → icon → name → size → min-policy.
enum BadgeDetail: Int, Comparable {
    case numberOnly
    case compact
    case full
    static func < (lhs: BadgeDetail, rhs: BadgeDetail) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// One window's badge data. Managed windows carry their column index (the `⌘D → n` target)
/// drawn in a circle; floating windows carry their `⌘D V → n` index drawn in a rounded square.
struct WindowBadge: Identifiable {
    let id = UUID()
    let number: String
    let isFloating: Bool
    let appName: String
    let appIcon: NSImage?
    let title: String?
    let minPercent: Int?
    let width: Int
    let height: Int
    /// 0-based column index for `focusColumn(index:)` when the badge is tapped (managed columns
    /// only; nil for floating). Lets the OSD edge badges be touch targets for iPad remote use.
    var columnIndex: Int?
}

/// The shaped, colored number — managed → circle, floating → rounded square, so the shape
/// encodes which key sequence (`⌘D <n>` vs `⌘D V <n>`) reaches the window. Shared by every
/// consumer so the visual language stays identical.
struct ShapedNumber: View {
    let number: String
    let isFloating: Bool
    var size: CGFloat = 38

    var body: some View {
        let fill = (isFloating ? Color.orange : Color.accentColor).opacity(0.92)
        let radius = size * 0.24
        Text(number)
            .font(.system(size: size * 0.53, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background {
                if isFloating {
                    RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill)
                } else {
                    Circle().fill(fill)
                }
            }
            .overlay {
                if isFloating {
                    RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(.white.opacity(0.85), lineWidth: 2)
                } else {
                    Circle().stroke(.white.opacity(0.85), lineWidth: 2)
                }
            }
            .shadow(color: .black.opacity(0.35), radius: 5, y: 2)
    }
}

/// The shared badge view used by the on-window decoration and the list: a shaped number plus a
/// responsive stacked info block. (The off-edge indicator composes `ShapedNumber` + icon
/// directly, since it pins the number to the screen edge.)
struct WindowBadgeChip: View {
    let badge: WindowBadge
    var detail: BadgeDetail = .full

    var body: some View {
        HStack(spacing: 7) {
            if badge.number.isEmpty {
                // A window stacked below its column's ordinal window: no number, indented so it
                // reads as nested under the numbered entry above it.
                Color.clear.frame(width: 14, height: 1)
            } else {
                ShapedNumber(number: badge.number, isFloating: badge.isFloating)
            }
            if detail >= .compact {
                if let icon = badge.appIcon {
                    // Floats between the shape and the text block, a touch smaller than the shape.
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 30, height: 30)
                        .cornerRadius(6)
                        .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
                }
                textBlock
            }
        }
    }

    /// App name on top, the metadata string beneath — narrow and readable. The app icon is
    /// drawn separately (floating between the shape and this block), not inside it.
    private var textBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(badge.appName.isEmpty ? (badge.isFloating ? "Floating" : "Managed") : badge.appName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
            if detail >= .full {
                HStack(spacing: 4) {
                    Text("\(badge.width)×\(badge.height)").monospacedDigit()
                    if let pct = badge.minPercent {
                        pillDot
                        Text("min \(pct)%")
                    }
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .frame(maxWidth: 220, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(.black.opacity(0.62)))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(.white.opacity(0.22), lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 4, y: 1)
    }

    private var pillDot: some View {
        Circle().fill(.white.opacity(0.4)).frame(width: 2.5, height: 2.5)
    }
}

/// Build one window's badge data — shared by every consumer.
@MainActor
enum WindowBadgeBuilder {
    static func make(
        number: String,
        isFloating: Bool,
        token: WindowToken,
        entry: WindowModel.Entry,
        frame: CGRect?,
        columnIndex: Int? = nil
    ) -> WindowBadge {
        let app = NSRunningApplication(processIdentifier: token.pid)
        let title = AXWindowService.titlePreferFast(windowId: UInt32(token.windowId))
        let minPercent = app?.bundleIdentifier
            .flatMap { NehirShell.windowRules?.rule(bundleId: $0, title: title)?.minWidthPercent }
            .map { Int($0.rounded()) }
        return WindowBadge(
            number: number,
            isFloating: isFloating,
            appName: app?.localizedName ?? "",
            appIcon: app?.icon,
            title: title,
            minPercent: minPercent,
            width: Int((frame?.width ?? 0).rounded()),
            height: Int((frame?.height ?? 0).rounded()),
            columnIndex: columnIndex
        )
    }
}

// MARK: - Feature 1: on-window decorations

/// A badge anchored over a window. `x`/`y` are the shaped-number's center in panel-local
/// (top-left origin) points.
private struct PositionedBadge: Identifiable {
    let id = UUID()
    let badge: WindowBadge
    let x: CGFloat
    let y: CGFloat
}

private struct OverWindowBadgesView: View {
    let badges: [PositionedBadge]

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(badges) { positioned in
                WindowBadgeChip(badge: positioned.badge)
                    .offset(x: positioned.x - 19, y: positioned.y - 19)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

/// Click-through overlay drawing a numbered badge over each column while the Deck is open,
/// so the `⌘D → digit` column jump has a visible target. Badge N matches the `engine.columns`
/// index the base `focusColumn` uses.
@MainActor
final class ColumnBadgeOverlayController {
    private var panel: NSPanel?

    func present(using controller: WMController) {
        guard let engine = controller.niriEngine,
              let workspaceId = controller.interactionWorkspace()?.id
        else {
            hide()
            return
        }

        var targetScreen: NSScreen?
        var badges: [PositionedBadge] = []
        for (index, column) in engine.columns(in: workspaceId).prefix(10).enumerated() {
            guard let token = column.windowNodes.first?.token,
                  let entry = controller.workspaceManager.entry(for: token),
                  let frame = try? AXWindowService.frame(entry.axRef)
            else { continue }
            let center = CGPoint(x: frame.midX, y: frame.midY)
            guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) ?? NSScreen.main
            else { continue }
            if targetScreen == nil { targetScreen = screen }
            guard screen === targetScreen else { continue }
            let number = index + 1
            badges.append(PositionedBadge(
                badge: WindowBadgeBuilder.make(
                    number: number == 10 ? "0" : String(number),
                    isFloating: false,
                    token: token,
                    entry: entry,
                    frame: frame
                ),
                x: frame.midX - screen.frame.minX,
                y: (screen.frame.maxY - frame.maxY) + 26
            ))
        }

        if let screen = targetScreen, !badges.isEmpty {
            let panel = panel ?? makePanel()
            self.panel = panel
            panel.setFrame(screen.frame, display: true)
            panel.contentView = NSHostingView(rootView: OverWindowBadgesView(badges: badges))
            panel.orderFrontRegardless()
        } else {
            hide()
        }
    }

    func hide() {
        panel?.orderOut(nil)
        panel?.contentView = nil
    }

    private func makePanel() -> NSPanel { NehirBadgePanel.make() }
}

// MARK: - Feature 2: centered window list

private struct WindowListView: View {
    let managed: [WindowBadge]
    let floating: [WindowBadge]
    /// Panel-local (top-origin) y at which to start the list, so it sits just below the Deck.
    var topInset: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !managed.isEmpty {
                header("Windows  ·  ⌘D + number")
                ForEach(managed) { WindowBadgeChip(badge: $0) }
            }
            if !floating.isEmpty {
                header("Floating  ·  ⌘D V + number")
                ForEach(floating) { WindowBadgeChip(badge: $0) }
            }
            if managed.isEmpty, floating.isEmpty {
                Text("No windows on this workspace")
                    .font(.system(size: 14, weight: .medium)).foregroundStyle(.white.opacity(0.6))
            }
        }
        .padding(22)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.black.opacity(0.82))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(.white.opacity(0.14), lineWidth: 1))
                .shadow(color: .black.opacity(0.5), radius: 24, y: 8)
        )
        .padding(.top, topInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(false)
    }

    private func header(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(.white.opacity(0.45))
            .kerning(0.6)
    }
}

/// The separate centered list panel, toggled by F1/`i`. Lists every window (managed columns,
/// then floating) in one place — the "is Chrome 8 or 9?" inventory. Independent of the
/// on-window decorations.
@MainActor
final class WindowListOverlayController {
    private var panel: NSPanel?

    /// - Parameter belowDeckFrame: the Deck panel's frame (screen coords), so the list can be
    ///   anchored just beneath it with a small gap — it is a reference to glance at, not a
    ///   modal, so it must not sit on top of the Deck.
    func present(using controller: WMController, belowDeckFrame: CGRect? = nil) {
        guard let engine = controller.niriEngine,
              let workspaceId = controller.interactionWorkspace()?.id,
              let screen = NSScreen.main
        else {
            hide()
            return
        }

        var managed: [WindowBadge] = []
        for (index, column) in engine.columns(in: workspaceId).prefix(10).enumerated() {
            let columnNumber = index + 1
            // Every window in the column is listed. The first carries the column ordinal
            // (the ⌘D → n target); windows stacked below it show icon + size but no number.
            for (windowIndex, node) in column.windowNodes.enumerated() {
                guard let entry = controller.workspaceManager.entry(for: node.token) else { continue }
                let number = windowIndex == 0 ? (columnNumber == 10 ? "0" : String(columnNumber)) : ""
                managed.append(WindowBadgeBuilder.make(
                    number: number,
                    isFloating: false,
                    token: node.token,
                    entry: entry,
                    frame: try? AXWindowService.frame(entry.axRef),
                    columnIndex: index
                ))
            }
        }

        var floating: [WindowBadge] = []
        for (index, entry) in controller.workspaceManager.allFloatingEntries().prefix(10).enumerated() {
            let number = index + 1
            floating.append(WindowBadgeBuilder.make(
                number: number == 10 ? "0" : String(number),
                isFloating: true,
                token: entry.token,
                entry: entry,
                frame: try? AXWindowService.frame(entry.axRef)
            ))
        }

        // Anchor just below the Deck: convert the Deck's bottom edge (screen, bottom-origin)
        // to panel-local (top-origin) y and add a gap. Falls back to a bit below center.
        let gap: CGFloat = 16
        let topInset: CGFloat = if let belowDeckFrame {
            (screen.frame.maxY - belowDeckFrame.minY) + gap
        } else {
            screen.frame.height * 0.55
        }

        let panel = panel ?? NehirBadgePanel.make()
        self.panel = panel
        panel.setFrame(screen.frame, display: true)
        panel.contentView = NSHostingView(
            rootView: WindowListView(managed: managed, floating: floating, topInset: topInset)
        )
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
        panel?.contentView = nil
    }
}

// MARK: - Shared panel

/// A borderless, non-activating, click-through floating panel used by the badge overlays —
/// never key, never intercepts input, purely visual.
enum NehirBadgePanel {
    @MainActor
    static func make() -> NSPanel {
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
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .stationary]
        return panel
    }
}
