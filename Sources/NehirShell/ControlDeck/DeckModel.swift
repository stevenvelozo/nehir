// SPDX-FileCopyrightText: 2026 Steven Velozo
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import CoreGraphics
import Foundation
@testable import Nehir

/// The Deck's live state and dispatch. `@Observable` so the SwiftUI view reflects
/// mode changes; the controller injects `perform` (run a WM command) and `onClose`.
@MainActor
@Observable
final class DeckModel {
    private(set) var mode: DeckMode = DeckCatalog.root

    /// Runs a base-WM command (injected by the controller, which holds the WMController).
    var perform: (HotkeyCommand) -> Void = { _ in }
    /// Floats the focused window and snaps it to a screen region (injected by the controller).
    var applyRegion: (DeckRegion) -> Void = { _ in }
    /// Toggles float (float+fit ⇄ re-tile) on the focused window (injected by the controller).
    var toggleFloat: () -> Void = {}
    /// Re-tiles every floating window (injected by the controller).
    var retileAll: () -> Void = {}
    /// Requests the controller to hide the Deck.
    var onClose: () -> Void = {}
    /// Fired after the mode changes, so the controller can resize/recenter the panel.
    var onModeChanged: () -> Void = {}
    /// Summons a registered overlay by id (injected by the controller).
    var onShowOverlay: (String) -> Void = { _ in }
    /// Dynamically-registered extension entries, appended to the root mode when it's
    /// shown (refreshed by the controller each time the Deck opens).
    var extensionActions: [DeckAction] = []
    /// Supplies the live drill-in rows for a list mode (injected by the controller,
    /// which reads the workspace's columns / floating windows and their titles).
    var requestPickItems: (DeckModeID) -> [DeckPickItem] = { _ in [] }

    /// The drill-in rows for the current entry into a list mode (`.columns`/`.floating`).
    private(set) var pickItems: [DeckPickItem] = []

    /// Supplies the "pick a window" rows for the Configure flow (injected by controller).
    var requestConfigureTargets: () -> [ConfigureTargetItem] = { [] }
    /// Loads the existing rule for a target, or a fresh one (injected by controller).
    var loadConfigureRule: (ConfigureTarget) -> WindowConfigRule = {
        WindowConfigRule(bundleId: $0.bundleId, titleContains: $0.title)
    }

    /// Persists + applies a configured rule for its window (injected by controller).
    var commitConfigureRule: (WindowConfigRule, WindowToken) -> Void = { _, _ in }

    private(set) var configureTargets: [ConfigureTargetItem] = []
    private(set) var configureTarget: ConfigureTarget?
    /// The rule currently being edited on the Configure screen.
    private(set) var configureRule: WindowConfigRule?

    /// Resize-grid dimensions (set by the controller from config).
    var gridColumns = 8
    var gridRows = 5
    /// Keyboard cursor in the resize grid, and the anchored first corner (nil until set).
    /// Both keyboard and mouse drive these, so the highlight is one source of truth.
    private(set) var resizeCursor = GridCell(column: 0, row: 0)
    private(set) var resizeAnchor: GridCell?

    /// Live macOS screen-layout settings shown/toggled in the Display pane. Read fresh
    /// on entering the pane; each toggle writes through immediately.
    private(set) var displaySettings = DisplaySettings.unknown

    /// Nehir's own chrome toggles, also shown in the Display pane (read/applied through
    /// the base via injected closures, since they live in the WM's settings, not macOS).
    private(set) var workspaceBarEnabled = false
    private(set) var windowBordersEnabled = false
    var readNehirChrome: () -> (bar: Bool, borders: Bool) = { (false, false) }
    var applyWorkspaceBar: (Bool) -> Void = { _ in }
    var applyWindowBorders: (Bool) -> Void = { _ in }

    /// Cross-display overflow: let columns straddle onto a neighboring monitor instead of
    /// being hidden. Read/applied through the base (runtime flag + relayout + persist) via
    /// injected closures, so the Display pane can toggle it live.
    private(set) var crossMonitorOverflowEnabled = false
    var readCrossMonitorOverflow: () -> Bool = { false }
    var applyCrossMonitorOverflow: (Bool) -> Void = { _ in }

    /// The active global layout family, shown/selected in the Layout-engine pane.
    private(set) var layoutMode: NehirLayoutMode = .river
    var readLayoutMode: () -> NehirLayoutMode = { .river }
    var applyLayoutMode: (NehirLayoutMode) -> Void = { _ in }

    func reset() {
        setMode(DeckCatalog.root)
    }

    /// Run a drill-in row's action and close (from a digit key or a list tap).
    func activatePick(_ item: DeckPickItem) {
        item.activate()
        onClose()
    }

    /// Send the current window/column to ordinal `digit` (1…9, 0 = the 10th), shifting the
    /// others over, then reveal (scroll to) the new position. Keyboard-only — ⌘D then ⌘digit.
    func sendWindowToOrdinal(_ digit: Int) {
        // `digit` is the slot number the user pressed (1…9, 0 = the 10th). The move and
        // focus engine APIs disagree on base: moveColumnToIndex is 1-based (its parameter
        // is `oneBasedIndex`), focusColumn is 0-based. Feed each the base it expects so the
        // window lands on — and the view scrolls to — the same slot the user pressed.
        let ordinal = digit == 0 ? 10 : digit
        perform(.moveColumnToIndex(ordinal))
        perform(.focusColumn(ordinal - 1))
        onClose()
    }

    // MARK: - Configure flow

    /// Choose a window to configure, loading its current (or a fresh) rule, then open
    /// the edit screen. Stays open — the edit screen is where the work happens.
    func selectConfigureTarget(_ item: ConfigureTargetItem) {
        configureTarget = item.target
        configureRule = loadConfigureRule(item.target)
        setMode(DeckCatalog.configureEdit)
    }

    /// Set (or clear, with `nil`) the forced column min-width percent, then persist+apply.
    func setConfigureWidth(_ percent: Double?) {
        configureRule?.minWidthPercent = percent
        commitConfigure()
    }

    func toggleConfigureFloat() {
        configureRule?.alwaysFloat.toggle()
        commitConfigure()
    }

    /// Switch the rule between pinning this one window (by title) and the whole app.
    func setConfigureTitleScoped(_ titleScoped: Bool) {
        configureRule?.titleContains = titleScoped ? configureTarget?.title : nil
        commitConfigure()
    }

    /// Drop all effects (removes the rule on commit).
    func clearConfigure() {
        configureRule?.minWidthPercent = nil
        configureRule?.alwaysFloat = false
        commitConfigure()
    }

    private func commitConfigure() {
        guard let rule = configureRule, let token = configureTarget?.token else { return }
        commitConfigureRule(rule, token)
    }

    /// Activate an entry (from a keypress or a tap). Returns the shared path so key
    /// and touch behave identically.
    func activate(_ action: DeckAction) {
        switch action.kind {
        case let .command(command, sticky):
            perform(command)
            if !sticky { onClose() }
        case let .region(region):
            resize(to: region)
        case .floatToggle:
            toggleFloat()
            onClose()
        case .retileAll:
            retileAll()
            onClose()
        case let .enterMode(id):
            setMode(DeckCatalog.mode(id))
        case .back:
            goBack()
        case let .showOverlay(id):
            onShowOverlay(id)
            onClose()
        }
    }

    /// Float the focused window and snap it to `region`, then close. Called by both
    /// keyboard preset actions and the resize grid's drag selection.
    func resize(to region: DeckRegion) {
        applyRegion(region)
        onClose()
    }

    // MARK: - Resize grid (keyboard cursor + mouse drag)

    /// Move the keyboard cursor, clamped to the grid.
    func moveResizeCursor(dColumn: Int, dRow: Int) {
        resizeCursor.column = min(max(resizeCursor.column + dColumn, 0), gridColumns - 1)
        resizeCursor.row = min(max(resizeCursor.row + dRow, 0), gridRows - 1)
    }

    /// Space: first press anchors the start corner; second press commits the rectangle.
    func toggleResizeAnchor() {
        if resizeAnchor == nil {
            resizeAnchor = resizeCursor
        } else {
            commitResizeSelection()
        }
    }

    /// Begin a mouse drag: anchor and cursor both start at the pressed cell.
    func beginResizeDrag(at cell: GridCell) {
        resizeAnchor = cell
        resizeCursor = cell
    }

    /// Extend a mouse drag to `cell`.
    func dragResizeCursor(to cell: GridCell) {
        resizeCursor = cell
    }

    /// Commit the current selection (anchor→cursor, or the lone cursor cell) as a region.
    func commitResizeSelection() {
        let anchor = resizeAnchor ?? resizeCursor
        let minColumn = min(anchor.column, resizeCursor.column)
        let maxColumn = max(anchor.column, resizeCursor.column)
        let minRow = min(anchor.row, resizeCursor.row)
        let maxRow = max(anchor.row, resizeCursor.row)
        resize(to: DeckRegion(
            x: CGFloat(minColumn) / CGFloat(gridColumns),
            y: CGFloat(minRow) / CGFloat(gridRows),
            width: CGFloat(maxColumn - minColumn + 1) / CGFloat(gridColumns),
            height: CGFloat(maxRow - minRow + 1) / CGFloat(gridRows)
        ))
    }

    /// Switch the global layout family (stays open so the highlight updates).
    func setLayoutEngine(_ mode: NehirLayoutMode) {
        applyLayoutMode(mode)
        layoutMode = mode
    }

    /// Display-pane keys: M/D/G toggle menu-bar/Dock hide + magnification; S cycles the
    /// scroll-bar mode; B/L/R set the Dock position; W/E toggle Nehir's own chrome. Stays
    /// open (settings surface); Esc dismisses.
    private func handleDisplay(key: DeckKey) -> Bool {
        guard case let .character(character) = key else { return false }
        if let position = [Character("b"): DockPosition.bottom, "l": .left, "r": .right][character] {
            setDockPosition(position)
            return true
        }
        switch character {
        case "m": toggleMenuBarAutoHide()
        case "d": toggleDockAutoHide()
        case "g": toggleDockMagnification()
        case "s": cycleScrollBars()
        case "o": toggleCrossMonitorOverflow()
        case "w": toggleWorkspaceBar()
        case "e": toggleWindowBorders()
        default: return false
        }
        return true
    }

    /// Keyboard handling for the resize grid: arrows move the cursor, space anchors then
    /// commits, enter commits. Other keys (1–4/C/M presets) fall through to the catalog.
    private func handleResizeGrid(key: DeckKey) -> Bool {
        switch key {
        case .arrowLeft: moveResizeCursor(dColumn: -1, dRow: 0)
        case .arrowRight: moveResizeCursor(dColumn: 1, dRow: 0)
        case .arrowUp: moveResizeCursor(dColumn: 0, dRow: -1)
        case .arrowDown: moveResizeCursor(dColumn: 0, dRow: 1)
        case .space: toggleResizeAnchor()
        case .enter: commitResizeSelection()
        default: return false
        }
        return true
    }

    /// Map a physical key to the current mode's action and run it. Escape backs out
    /// (submode → root, root → close). Returns whether the key was consumed.
    @discardableResult
    func handle(key: DeckKey) -> Bool {
        // Keys that act the same in every mode (Esc backs out; ⌘+digit sends to ordinal).
        if let result = handleGlobalKey(key) { return result }
        // Data-driven / pane modes handle their own keys; the resize grid falls through
        // to the static 1–4/C/M presets when its cursor keys don't apply.
        switch mode.id {
        case .resizeGrid:
            if handleResizeGrid(key: key) { return true }
        case .display:
            return handleDisplay(key: key)
        case .layout:
            return handleLayout(key: key)
        case .columns,
             .floating:
            return handleListPick(key: key)
        case .configurePick:
            return handleConfigurePick(key: key)
        case .configureEdit:
            return handleConfigureEdit(key: key)
        default:
            break
        }
        guard let action = mode.actions.first(where: { $0.key == key }) else {
            return false
        }
        activate(action)
        return true
    }

    /// Keys handled identically in every mode. Returns nil to fall through to mode keys.
    private func handleGlobalKey(_ key: DeckKey) -> Bool? {
        switch key {
        case .escape:
            // Esc always dismisses the Deck outright (from any submode) — reopening with
            // the chord is one keystroke, and a single Esc reads cleaner than back-then-close.
            // The tappable Back chip still steps back one level via `goBack()`.
            onClose()
            return true
        case let .commandDigit(digit):
            sendWindowToOrdinal(digit)
            return true
        default:
            return nil
        }
    }

    private func handleLayout(key: DeckKey) -> Bool {
        switch key {
        case .character("r"): setLayoutEngine(.river)
        case .character("b"): setLayoutEngine(.blades)
        case .character("f"): setLayoutEngine(.free)
        default: return false
        }
        return true
    }

    /// Drill-in lists (Columns/Floating) are data-driven: a digit selects the matching row.
    private func handleListPick(key: DeckKey) -> Bool {
        guard case let .character(character) = key,
              let item = pickItems.first(where: { $0.label == String(character) })
        else { return false }
        activatePick(item)
        return true
    }

    private func handleConfigurePick(key: DeckKey) -> Bool {
        guard case let .character(character) = key,
              let item = configureTargets.first(where: { $0.label == String(character) })
        else { return false }
        selectConfigureTarget(item)
        return true
    }

    /// Edit-screen keys: 1…7 pick a width preset, N clears the width, F toggles float,
    /// S toggles the window/app scope, X removes the rule. Edits apply live; Esc backs out.
    private func handleConfigureEdit(key: DeckKey) -> Bool {
        guard case let .character(character) = key else { return false }
        if let digit = character.wholeNumberValue,
           digit >= 1, digit <= DeckCatalog.widthPercents.count
        {
            setConfigureWidth(DeckCatalog.widthPercents[digit - 1])
            return true
        }
        switch character {
        case "n": setConfigureWidth(nil)
        case "f": toggleConfigureFloat()
        case "s": setConfigureTitleScoped(!(configureRule?.isTitleScoped ?? true))
        case "x": clearConfigure()
        default: return false
        }
        return true
    }

    private func goBack() {
        switch mode.id {
        case .root:
            onClose()
        case .configureEdit:
            // Back to the window list rather than all the way out.
            setMode(DeckCatalog.configurePick)
        default:
            setMode(DeckCatalog.root)
        }
    }

    private func setMode(_ newMode: DeckMode) {
        pickItems = isListMode(newMode.id) ? requestPickItems(newMode.id) : []
        switch newMode.id {
        case .configurePick:
            configureTargets = requestConfigureTargets()
        case .resizeGrid:
            // Start the cursor centered, no corner anchored yet.
            resizeCursor = GridCell(column: gridColumns / 2, row: gridRows / 2)
            resizeAnchor = nil
        case .display:
            displaySettings = MacDisplaySettings.current()
            let chrome = readNehirChrome()
            workspaceBarEnabled = chrome.bar
            windowBordersEnabled = chrome.borders
            crossMonitorOverflowEnabled = readCrossMonitorOverflow()
        case .layout:
            layoutMode = readLayoutMode()
        case .root:
            configureTargets = []
            configureTarget = nil
            configureRule = nil
        default:
            break
        }
        // Append dynamically-registered extension entries to the root mode.
        if newMode.id == .root, !extensionActions.isEmpty {
            mode = DeckMode(id: .root, title: newMode.title, actions: newMode.actions + extensionActions)
        } else {
            mode = newMode
        }
        onModeChanged()
    }

    private func isListMode(_ id: DeckModeID) -> Bool {
        id == .columns || id == .floating
    }
}

// MARK: - Display pane (macOS layout settings + Nehir chrome)

extension DeckModel {
    func toggleMenuBarAutoHide() {
        let value = !displaySettings.menuBarAutoHide
        MacDisplaySettings.setMenuBarAutoHide(value)
        displaySettings.menuBarAutoHide = value
    }

    func toggleDockAutoHide() {
        let value = !displaySettings.dockAutoHide
        MacDisplaySettings.setDockAutoHide(value)
        displaySettings.dockAutoHide = value
    }

    func toggleDockMagnification() {
        let value = !displaySettings.dockMagnification
        MacDisplaySettings.setDockMagnification(value)
        displaySettings.dockMagnification = value
    }

    func setDockPosition(_ position: DockPosition) {
        MacDisplaySettings.setDockPosition(position)
        displaySettings.dockPosition = position
    }

    /// Cycle the macOS "Show scroll bars" setting: Auto → When scrolling → Always → Auto.
    func cycleScrollBars() {
        let next = displaySettings.scrollBars.next
        MacDisplaySettings.setScrollBars(next)
        displaySettings.scrollBars = next
    }

    func toggleWorkspaceBar() {
        workspaceBarEnabled.toggle()
        applyWorkspaceBar(workspaceBarEnabled)
    }

    func toggleWindowBorders() {
        windowBordersEnabled.toggle()
        applyWindowBorders(windowBordersEnabled)
    }

    func toggleCrossMonitorOverflow() {
        crossMonitorOverflowEnabled.toggle()
        applyCrossMonitorOverflow(crossMonitorOverflowEnabled)
    }
}
