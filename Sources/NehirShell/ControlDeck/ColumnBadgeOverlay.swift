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
    /// Stable across refreshes (derived from the window token), so a reordered list keeps each
    /// row's SwiftUI identity — and thus its live drag gesture — instead of churning on new UUIDs.
    var stableKey: String = ""
    var number: String
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
            stableKey: "\(token.pid):\(token.windowId)",
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

/// The centered list, now interactive: each column is a row you can drag vertically to reorder
/// the tiling. Dropping a row at slot K moves that column to the 1-based ordinal K — the same
/// target the ⌘-digit move uses. Floating windows are listed for reference but aren't
/// reorderable. The panel behind this view is click-through outside the card, so dragging never
/// steals focus from the bordered window.
private struct ReorderableWindowListView: View {
    let floating: [WindowBadge]
    /// Uniform row height so the drag translation maps cleanly to a whole-slot delta, and so a
    /// single gesture can resolve which row was grabbed from where the drag started.
    var rowHeight: CGFloat = 48
    /// (fromIndex 0-based, toOrdinal 1-based) — fired on drop, only when the slot changes.
    let onReorder: (Int, Int) -> Void

    /// The list owns its order for the life of the Deck session: a drop moves the row within THIS
    /// array (relabelling + animating in place) and tells the engine to move the real window. It
    /// is never rebuilt from outside mid-session — no teardown, no flash — so dragging keeps
    /// working. Seeded once from the engine order (the Deck builds a fresh view each time shown).
    @State private var order: [WindowBadge]
    @State private var draggingIndex: Int?
    @State private var translation: CGFloat = 0

    init(columns: [WindowBadge], floating: [WindowBadge], rowHeight: CGFloat = 48,
         onReorder: @escaping (Int, Int) -> Void) {
        self.floating = floating
        self.rowHeight = rowHeight
        self.onReorder = onReorder
        _order = State(initialValue: columns)
    }

    /// The 0-based slot the dragged row currently hovers over, from how many row heights it has
    /// travelled. Clamped to the column range. `target + 1` is the 1-based ordinal to move to.
    private var target: Int? {
        guard let from = draggingIndex else { return nil }
        let delta = Int((translation / rowHeight).rounded())
        return min(max(from + delta, 0), order.count - 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !order.isEmpty {
                header("Windows  ·  drag to reorder")
                columnStack
            }
            if !floating.isEmpty {
                header("Floating  ·  ⌘D V + number")
                ForEach(floating) { WindowBadgeChip(badge: $0) }
            }
            if order.isEmpty, floating.isEmpty {
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
    }

    private var columnStack: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(order.enumerated()), id: \.element.stableKey) { index, badge in
                // The number reflects the row's CURRENT position, so a reorder relabels live.
                WindowBadgeChip(badge: renumbered(badge, at: index))
                    .frame(height: rowHeight, alignment: .leading)
                    .offset(y: rowOffset(for: index))
                    .zIndex(draggingIndex == index ? 1 : 0)
                    .opacity(draggingIndex == index ? 0.95 : 1)
                    .animation(.interactiveSpring(response: 0.28, dampingFraction: 0.82), value: target)
            }
        }
        // The drag is handled by an AppKit mouse layer, NOT a SwiftUI gesture: a SwiftUI
        // DragGesture in this non-key panel recognizes only ONCE per presentation — input goes
        // dead until the list is re-presented. Discrete AppKit mouseDown/Dragged/Up (with
        // acceptsFirstMouse) keeps delivering across repeated drags with no rebuild. The layer
        // overlays the rows, so a mouse-down's y ÷ rowHeight is the grabbed row.
        .overlay(
            RowDragCatcher(
                rowHeight: rowHeight,
                rowCount: { order.count },
                onBegin: { draggingIndex = $0 },
                onChange: { translation = $0 },
                onEnd: { drop() }
            )
        )
    }

    /// The badge relabelled to its current 0-based position (10th slot shows "0").
    private func renumbered(_ badge: WindowBadge, at index: Int) -> WindowBadge {
        var copy = badge
        copy.number = index == 9 ? "0" : String(index + 1)
        return copy
    }

    /// Commit the drag: move the row within our order (relabels + animates) and tell the engine
    /// to move the real window to the same 1-based slot.
    private func drop() {
        defer { draggingIndex = nil; translation = 0 }
        guard let from = draggingIndex, let to = target, to != from else { return }
        var next = order
        next.insert(next.remove(at: from), at: to)
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { order = next }
        onReorder(from, to + 1)
    }

    /// Slide the non-dragged rows aside so a gap opens at the hover slot: rows between the
    /// origin and the target shift one row height; the dragged row itself follows the cursor.
    private func rowOffset(for index: Int) -> CGFloat {
        guard let from = draggingIndex else { return 0 }
        if index == from { return translation }
        guard let to = target else { return 0 }
        if from < to, index > from, index <= to { return -rowHeight }
        if to < from, index >= to, index < from { return rowHeight }
        return 0
    }

    private func header(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(.white.opacity(0.45))
            .kerning(0.6)
    }
}

/// A transparent AppKit view laid over the column rows that turns mouse drags into reorder
/// callbacks. Used instead of a SwiftUI `DragGesture` because that gesture goes deaf after one
/// drag in this non-key panel; discrete AppKit mouse events keep working. `acceptsFirstMouse`
/// lets a drag start even though the panel never becomes key.
private struct RowDragCatcher: NSViewRepresentable {
    let rowHeight: CGFloat
    let rowCount: () -> Int
    let onBegin: (Int) -> Void
    let onChange: (CGFloat) -> Void
    let onEnd: () -> Void

    func makeNSView(context _: Context) -> CatcherView { CatcherView() }

    func updateNSView(_ view: CatcherView, context _: Context) {
        view.rowHeight = rowHeight
        view.rowCount = rowCount
        view.onBegin = onBegin
        view.onChange = onChange
        view.onEnd = onEnd
    }

    final class CatcherView: NSView {
        var rowHeight: CGFloat = 48
        var rowCount: () -> Int = { 0 }
        var onBegin: (Int) -> Void = { _ in }
        var onChange: (CGFloat) -> Void = { _ in }
        var onEnd: () -> Void = {}

        private var startY: CGFloat = 0
        private var candidateRow: Int?
        private var began = false

        /// Top-left origin, y growing downward, to match the SwiftUI row layout.
        override var isFlipped: Bool { true }
        /// Start a drag even though the panel isn't key — otherwise the first click in a
        /// background panel is swallowed as an activation attempt.
        override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            startY = point.y
            began = false
            let count = rowCount()
            candidateRow = count > 0 ? min(max(Int(point.y / rowHeight), 0), count - 1) : nil
        }

        override func mouseDragged(with event: NSEvent) {
            guard let row = candidateRow else { return }
            let dy = convert(event.locationInWindow, from: nil).y - startY
            if !began {
                guard abs(dy) >= 4 else { return } // matches a SwiftUI minimumDistance of 4
                began = true
                onBegin(row)
            }
            onChange(dy)
        }

        override func mouseUp(with _: NSEvent) {
            if began { onEnd() }
            candidateRow = nil
            began = false
        }
    }
}

/// The separate centered list panel, toggled by F1/`i`. Lists every window (managed columns,
/// then floating) in one place — the "is Chrome 8 or 9?" inventory. Independent of the
/// on-window decorations.
@MainActor
final class WindowListOverlayController {
    private var panel: NSPanel?
    /// The card is built once and kept alive across refreshes; a drag reorder updates its
    /// `rootView` in place. Swapping the panel's content view instead would tear down the
    /// gesture machinery mid-session, so the list could be dragged exactly once.
    private var card: NSHostingView<ReorderableWindowListView>?
    /// Wired by the Deck controller: (fromIndex 0-based, toOrdinal 1-based) when a row is dropped.
    var onReorder: ((Int, Int) -> Void)?

    /// - Parameter belowDeckFrame: the Deck panel's frame (screen coords), so the list card can
    ///   be anchored just beneath it with a small gap — a surface to glance at *and* drag on, so
    ///   it must not sit on top of the Deck.
    func present(using controller: WMController, belowDeckFrame: CGRect? = nil) {
        guard let engine = controller.niriEngine,
              let workspaceId = controller.interactionWorkspace()?.id,
              let screen = NSScreen.main
        else {
            hide()
            return
        }

        // One draggable row per column — the numbered ⌘D → n targets, in tiling order. (Windows
        // stacked within a column share the column's slot, so the column is the unit you reorder.)
        var columns: [WindowBadge] = []
        for (index, column) in engine.columns(in: workspaceId).prefix(10).enumerated() {
            guard let node = column.windowNodes.first,
                  let entry = controller.workspaceManager.entry(for: node.token)
            else { continue }
            let columnNumber = index + 1
            columns.append(WindowBadgeBuilder.make(
                number: columnNumber == 10 ? "0" : String(columnNumber),
                isFloating: false,
                token: node.token,
                entry: entry,
                frame: try? AXWindowService.frame(entry.axRef),
                columnIndex: index
            ))
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

        let rootView = ReorderableWindowListView(
            columns: columns,
            floating: floating,
            onReorder: { [weak self] from, to in self?.onReorder?(from, to) }
        )

        // Reuse the existing hosting view — updating its data in place — so a refresh after a
        // drag never tears down the gesture machinery. Only its `rootView` and frame change.
        let card = card ?? NSHostingView(rootView: rootView)
        card.rootView = rootView
        card.layoutSubtreeIfNeeded()
        var size = card.fittingSize
        size.width = max(size.width, 260)
        size.height = max(size.height, 80)

        // Anchor the card just below the Deck (screen coords, bottom-origin), horizontally
        // centered; fall back to a touch below screen center when the Deck frame is unknown.
        let gap: CGFloat = 16
        let originX = screen.frame.midX - size.width / 2
        let originY: CGFloat = if let belowDeckFrame {
            belowDeckFrame.minY - gap - size.height
        } else {
            screen.frame.midY - size.height / 2
        }
        card.frame = NSRect(
            x: originX - screen.frame.minX,
            y: originY - screen.frame.minY,
            width: size.width,
            height: size.height
        )

        if self.card == nil {
            // First presentation: build the click-through container + panel once. The container
            // fills the screen but only the card is hit-testable, so clicks elsewhere still reach
            // the windows underneath.
            self.card = card
            let container = ReorderPassthroughView(frame: NSRect(origin: .zero, size: screen.frame.size))
            container.autoresizingMask = [.width, .height]
            container.addSubview(card)
            let panel = NehirReorderPanel.make()
            self.panel = panel
            panel.setFrame(screen.frame, display: true)
            panel.contentView = container
        }
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        card = nil
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

/// A screen-filling content view that is transparent to the mouse everywhere except its
/// subviews — so the reorder card can accept drags while every click outside it passes through
/// to the windows below. (`super.hitTest` returns the container itself for a point that misses
/// every subview; we translate that to `nil` = "not me, keep looking underneath".)
private final class ReorderPassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

/// Like `NehirBadgePanel`, but mouse-interactive: the reorder list needs drag events. Still
/// borderless and non-activating, and — being a borderless panel — it never becomes key, so the
/// bordered window keeps its focus (and its border) while you drag rows around.
enum NehirReorderPanel {
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
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .stationary]
        return panel
    }
}
