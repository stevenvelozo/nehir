// SPDX-FileCopyrightText: 2026 Steven Velozo
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import CoreGraphics
import Foundation
@testable import Nehir

/// A rectangular screen region in top-left-origin unit space (0…1 on each axis).
/// The controller maps this onto the focused window's screen (`visibleFrame`).
struct DeckRegion: Equatable, Sendable {
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat
}

/// A key the Deck responds to. Physical keys (arrows/esc/space/enter) plus characters.
enum DeckKey: Equatable, Sendable {
    case character(Character)
    case arrowLeft
    case arrowRight
    case arrowUp
    case arrowDown
    case escape
    case space
    case enter
    /// ⌘+digit (1…9, 0) while the Deck is open — "send window to ordinal N".
    case commandDigit(Int)
    /// ⌥+digit (1…9) while the Deck is open — "load" a commandlet slot (write the
    /// line but leave the cursor), as opposed to a bare digit which runs it.
    case optionDigit(Int)
}

/// A cell in the resize grid (0-based column/row), shared by keyboard and mouse.
struct GridCell: Equatable {
    var column: Int
    var row: Int
}

/// What activating a Deck entry does.
enum DeckActionKind {
    /// Run a base-WM command. `sticky` keeps the Deck open (for chaining moves);
    /// otherwise it's a terminal "set" action that closes the Deck after running.
    case command(HotkeyCommand, sticky: Bool)
    /// Float the focused window and snap it to a screen region, then close.
    case region(DeckRegion)
    /// Toggle float on the focused window: float (fit to display) ⇄ re-tile. Closes.
    case floatToggle
    /// Re-tile every floating window back into the flow. Closes.
    case retileAll
    /// Drill into a submode (e.g. width presets).
    case enterMode(DeckModeID)
    /// Back to root, or close the Deck if already at root.
    case back
    /// Summon a registered overlay (a pict extension) by id, then close.
    case showOverlay(String)
}

/// One selectable entry, addressable by key or tap.
struct DeckAction: Identifiable {
    let id = UUID()
    let key: DeckKey
    let keyLabel: String
    let title: String
    let symbol: String
    let kind: DeckActionKind
    /// Optional live status line (extensions), shown under the title.
    var subtitle: String? = nil
    /// Group label for dynamically-registered extension entries (nil = built-in).
    var group: String? = nil
    /// A headless extension entry: dispatched by key but drawn no tile.
    var isHeadless: Bool = false
}

enum DeckModeID: Equatable {
    case root
    case columnWidth
    case windowWidth
    case resizeGrid
    case columns
    case floating
    case configurePick
    case configureEdit
    case display
    case layout
    case internals
    case commandlets
}

/// The window chosen in the Configure flow, carried into the edit screen.
struct ConfigureTarget: Equatable {
    let token: WindowToken
    let bundleId: String
    let title: String
}

/// One row in the Configure "pick a window" list.
struct ConfigureTargetItem: Identifiable {
    let id = UUID()
    let label: String
    let title: String
    let target: ConfigureTarget
}

struct DeckMode {
    let id: DeckModeID
    let title: String
    let actions: [DeckAction]
}

/// A snapshot of the Deck's current target window, shown in the root header pill:
/// tiled vs floating, any configured forced min-width %, and the live pixel size.
struct FocusInfo: Equatable {
    let isFloating: Bool
    let minPercent: Int?
    let width: Int
    let height: Int
}

/// One row in a drill-in list (Columns or Floating): a number key on the left, a
/// window title on the right, and the action its key/tap runs. Built live from the
/// workspace when the mode is entered.
struct DeckPickItem: Identifiable {
    let id = UUID()
    /// The digit that selects this row ("1"…"9", "0" for the 10th).
    let label: String
    let title: String
    /// Focus the column/window this row stands for (the model closes the Deck after).
    let activate: @MainActor () -> Void
}
