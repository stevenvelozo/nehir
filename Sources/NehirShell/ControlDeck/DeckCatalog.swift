// SPDX-FileCopyrightText: 2026 Steven Velozo
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import CoreGraphics
import Foundation
@testable import Nehir

/// Static definition of the Deck's modes and their bindings. Phase 1: everything
/// here maps onto an existing base-WM `HotkeyCommand`.
enum DeckCatalog {
    static func mode(_ id: DeckModeID) -> DeckMode {
        switch id {
        case .root: root
        case .columnWidth: columnWidth
        case .windowWidth: windowWidth
        case .resizeGrid: resizeGrid
        case .columns: columns
        case .floating: floating
        case .configurePick: configurePick
        case .configureEdit: configureEdit
        case .display: display
        case .layout: layout
        }
    }

    /// The Display pane: live toggles for a few macOS screen-layout settings.
    static let display = DeckMode(id: .display, title: "Display settings", actions: [])

    /// The layout-engine pane: pick the global layout family (River / Blades / Free).
    static let layout = DeckMode(id: .layout, title: "Layout engine", actions: [])

    /// The drill-in lists. Rows are supplied live by the model (`pickItems`), not static
    /// here; digit keys select, driven by those rows.
    static let columns = DeckMode(id: .columns, title: "Columns", actions: [])
    static let floating = DeckMode(id: .floating, title: "Floating windows", actions: [])

    /// The Configure flow (data-driven, like the drill-ins).
    static let configurePick = DeckMode(id: .configurePick, title: "Configure — pick a window", actions: [])
    static let configureEdit = DeckMode(id: .configureEdit, title: "Configure window", actions: [])

    /// Forced column min-width presets, as a percent of the monitor working width.
    static let widthPercents: [Double] = [20, 25, 33, 50, 66, 75, 100]

    static let root = DeckMode(
        id: .root,
        title: "Nehir",
        actions: [
            DeckAction(
                key: .arrowLeft,
                keyLabel: "←",
                title: "Move Left",
                symbol: "arrow.left",
                kind: .command(.move(.left), sticky: true)
            ),
            DeckAction(
                key: .arrowDown,
                keyLabel: "↓",
                title: "Move Down",
                symbol: "arrow.down",
                kind: .command(.move(.down), sticky: true)
            ),
            DeckAction(
                key: .arrowUp,
                keyLabel: "↑",
                title: "Move Up",
                symbol: "arrow.up",
                kind: .command(.move(.up), sticky: true)
            ),
            DeckAction(
                key: .arrowRight,
                keyLabel: "→",
                title: "Move Right",
                symbol: "arrow.right",
                kind: .command(.move(.right), sticky: true)
            ),
            DeckAction(
                key: .character("h"),
                keyLabel: "H",
                title: "Focus Left",
                symbol: "chevron.left",
                kind: .command(.focus(.left), sticky: true)
            ),
            DeckAction(
                key: .character("j"),
                keyLabel: "J",
                title: "Focus Down",
                symbol: "chevron.down",
                kind: .command(.focus(.down), sticky: true)
            ),
            DeckAction(
                key: .character("k"),
                keyLabel: "K",
                title: "Focus Up",
                symbol: "chevron.up",
                kind: .command(.focus(.up), sticky: true)
            ),
            DeckAction(
                key: .character("l"),
                keyLabel: "L",
                title: "Focus Right",
                symbol: "chevron.right",
                kind: .command(.focus(.right), sticky: true)
            ),
            DeckAction(
                key: .character("w"),
                keyLabel: "W",
                title: "Column Width",
                symbol: "rectangle.split.2x1",
                kind: .enterMode(.columnWidth)
            ),
            DeckAction(
                key: .character("s"),
                keyLabel: "S",
                title: "Window Width",
                symbol: "rectangle.leadinghalf.inset.filled",
                kind: .enterMode(.windowWidth)
            ),
            DeckAction(
                key: .character("r"),
                keyLabel: "R",
                title: "Resize",
                symbol: "square.grid.3x3",
                kind: .enterMode(.resizeGrid)
            ),
            DeckAction(
                key: .character("f"),
                keyLabel: "F",
                title: "Toggle Float",
                symbol: "macwindow.on.rectangle",
                kind: .floatToggle
            ),
            DeckAction(
                key: .character("t"),
                keyLabel: "T",
                title: "Tile All",
                symbol: "rectangle.3.group",
                kind: .retileAll
            ),
            // Display pane: macOS screen-layout toggles (menu bar / Dock). A layout op.
            DeckAction(
                key: .character("d"),
                keyLabel: "D",
                title: "Display",
                symbol: "menubar.dock.rectangle",
                kind: .enterMode(.display)
            ),
            // Layout-engine pane: switch the global layout family (River / Blades / Free).
            DeckAction(
                key: .character("e"),
                keyLabel: "E",
                title: "Engine",
                symbol: "square.stack.3d.down.right",
                kind: .enterMode(.layout)
            ),
            // Touch/click entry to the Columns drill-in (number + window title list).
            // The digit bindings below stay bound at root too, so `⌘D → 1` still jumps
            // directly by keyboard without opening the list.
            DeckAction(
                key: .character("c"),
                keyLabel: "C",
                title: "Columns",
                symbol: "list.number",
                kind: .enterMode(.columns)
            ),
            // Keyboard/touch selection for floating windows, which aren't in the column
            // flow and so can't be reached by the column jump.
            DeckAction(
                key: .character("v"),
                keyLabel: "V",
                title: "Floating",
                symbol: "macwindow.on.rectangle",
                kind: .enterMode(.floating)
            ),
            // Configure durable per-window rules: forced column width + always-float.
            DeckAction(
                key: .character("g"),
                keyLabel: "G",
                title: "Configure",
                symbol: "slider.horizontal.3",
                kind: .enterMode(.configurePick)
            )
        ] + columnJumpActions()
    )

    /// The resize submode: an interactive drag-grid (in the view) plus these
    /// keyboard preset snaps. Each floats the focused window and closes the Deck.
    static let resizeGrid = DeckMode(
        id: .resizeGrid,
        title: "Resize",
        // Arrows drive the keyboard cursor (see DeckModel.handleResizeGrid), so the old
        // arrow half-presets are gone — a cursor+anchor selection covers halves and more.
        // The digit/letter quick-presets stay.
        actions: [
            DeckAction(
                key: .character("1"),
                keyLabel: "1",
                title: "Top Left",
                symbol: "square.fill",
                kind: .region(DeckRegion(x: 0, y: 0, width: 0.5, height: 0.5))
            ),
            DeckAction(
                key: .character("2"),
                keyLabel: "2",
                title: "Top Right",
                symbol: "square.fill",
                kind: .region(DeckRegion(x: 0.5, y: 0, width: 0.5, height: 0.5))
            ),
            DeckAction(
                key: .character("3"),
                keyLabel: "3",
                title: "Bottom Left",
                symbol: "square.fill",
                kind: .region(DeckRegion(x: 0, y: 0.5, width: 0.5, height: 0.5))
            ),
            DeckAction(
                key: .character("4"),
                keyLabel: "4",
                title: "Bottom Right",
                symbol: "square.fill",
                kind: .region(DeckRegion(x: 0.5, y: 0.5, width: 0.5, height: 0.5))
            ),
            DeckAction(
                key: .character("c"),
                keyLabel: "C",
                title: "Center",
                symbol: "square.dashed",
                kind: .region(DeckRegion(x: 0.17, y: 0.17, width: 0.66, height: 0.66))
            ),
            DeckAction(
                key: .character("m"),
                keyLabel: "M",
                title: "Maximize",
                symbol: "rectangle.fill",
                kind: .region(DeckRegion(x: 0, y: 0, width: 1, height: 1))
            )
        ]
    )

    static let columnWidth = DeckMode(
        id: .columnWidth,
        title: "Column Width",
        actions: widthActions { .setColumnWidth($0) }
    )

    static let windowWidth = DeckMode(
        id: .windowWidth,
        title: "Window Width",
        actions: widthActions { .setWindowWidth($0) }
    )

    /// The four width presets, closing the Deck once a preset is chosen.
    /// `NiriSizeChange.setProportion` takes a PERCENT (0–100) — the engine divides
    /// it by 100 — so pass 25/50/75/100, not 0.25/0.5/….
    private static func widthActions(_ command: @escaping (NiriSizeChange) -> HotkeyCommand) -> [DeckAction] {
        // Row 1: quarters (1–4); row 2: thirds (5=33%, 6=66%). The view wraps every 4.
        let presets: [(String, CGFloat)] = [("1", 25), ("2", 50), ("3", 75), ("4", 100), ("5", 33), ("6", 66)]
        return presets.map { label, percent in
            DeckAction(
                key: .character(Character(label)),
                keyLabel: label,
                title: "\(Int(percent))%",
                symbol: "rectangle",
                kind: .command(command(.setProportion(percent)), sticky: false)
            )
        }
    }

    /// Root-level "jump to column N" bindings: digits 1–9 then 0 map to columns 1–10.
    /// The base `focusColumn` command is 0-based, so column N is index N−1; digit 0 is
    /// the 10th column (index 9). Out-of-range (fewer columns present) is a safe no-op
    /// in the engine. Non-sticky — jump to the column and close (columns are ordinals,
    /// not apps, so this addresses e.g. multiple Chrome-profile windows cmd+tab can't).
    private static func columnJumpActions() -> [DeckAction] {
        let columns = Array(1 ... 10)
        return columns.map { column in
            let label = column == 10 ? "0" : String(column)
            return DeckAction(
                key: .character(Character(label)),
                keyLabel: label,
                title: "Column \(column)",
                symbol: "\(column).square",
                kind: .command(.focusColumn(column - 1), sticky: false)
            )
        }
    }
}
