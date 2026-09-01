// SPDX-FileCopyrightText: 2026 Steven Velozo
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import AppKit
@testable import Nehir
import NehirShellWire
import SwiftUI

/// A borderless key panel — mirrors the base command palette's panel recipe so it
/// captures keys without disturbing the WM's focus tracking.
private final class DeckPanel: NSPanel {
    override var canBecomeKey: Bool {
        true
    }
}

/// Hosts the Deck's SwiftUI content and accepts the first mouse click. The panel is
/// non-activating and never becomes key (so it never steals the WM's focus border),
/// which otherwise makes AppKit swallow the initial mouse-down as an activating click
/// instead of delivering it to SwiftUI — breaking the resize grid's drag. Returning
/// true routes the whole down/drag/up sequence to the grid without activating.
private final class DeckHostingView: NSHostingView<DeckView> {
    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }
}

/// Owns the Control Deck: its panel, the SwiftUI HUD, key capture, the global
/// trigger hotkey, and a menu-bar trigger. Routes chosen actions into the base WM.
@MainActor
final class ControlDeckController: NSObject {
    private let model = DeckModel()
    private let panel: DeckPanel
    private let hostingView: DeckHostingView
    private let hotkey = DeckHotkey()
    /// A second, pass-through summon chord for reaching the OSD across a Screen Sharing session.
    private let remoteHotkey = DeckRemoteHotkey()
    /// The raw chord strings currently registered, remembered so the Settings pane can read them
    /// back and re-save; `remotePassthroughApps` is applied but not surfaced in the pane.
    private(set) var currentPrimaryHotkey = "cmd+d"
    private(set) var currentRemoteHotkey = ""
    private var remotePassthroughApps: [String] = []
    private let columnBadges = ColumnBadgeOverlayController()
    private let windowList = WindowListOverlayController()
    private weak var wmController: WMController?
    var statusItem: NSStatusItem?
    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    /// Injected by the shell layer: trigger a Sparkle update check (menu-bar item).
    var onCheckForUpdates: (() -> Void)?
    /// Injected by the shell layer: the global layout-family controller.
    weak var layoutModeController: LayoutModeController?
    weak var viewportInsetController: ViewportInsetController?
    /// The overlay feature, so registered pict extensions appear as Deck entries.
    weak var overlays: OverlayController?

    init(wmController: WMController, gridColumns: Int, gridRows: Int) {
        self.wmController = wmController

        panel = DeckPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 260),
            // Non-activating: the Deck captures keys as a key panel, but the app it
            // sits over keeps focus — so the focused-window border stays and deferred
            // layout refreshes (column/window width) still apply.
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        hostingView = DeckHostingView(
            rootView: DeckView(model: model, gridColumns: gridColumns, gridRows: gridRows)
        )
        super.init()

        // The model needs the grid dimensions for the keyboard cursor and commit math.
        model.gridColumns = gridColumns
        model.gridRows = gridRows

        panel.level = .floating
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        // Must be false for a non-activating panel: the app never activates, so a
        // hide-on-deactivate panel would vanish immediately.
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.contentView = hostingView

        model.perform = { [weak self] command in
            self?.retileFocusedIfNeeded(for: command)
            self?.alignInteractionMonitor()
            self?.syncLayoutSelectionToCommandTarget(for: command)
            _ = self?.wmController?.commandHandler.performCommand(command)
        }
        model.applyRegion = { [weak self] region in self?.resizeFocusedWindow(to: region) }
        model.toggleFloat = { [weak self] in self?.toggleFloatWithFit() }
        model.retileAll = { [weak self] in self?.retileAllFloating() }
        model.onClose = { [weak self] in self?.hide() }
        model.onShowOverlay = { [weak self] id in self?.overlays?.show(id) }
        model.onModeChanged = { [weak self] in
            self?.resizeAndCenter()
            self?.repositionWindowList()
        }
        model.requestPickItems = { [weak self] mode in
            guard let controller = self?.wmController else { return [] }
            return DeckPickSource.items(for: mode, using: controller)
        }
        windowList.onReorder = { [weak self] fromIndex, toOrdinal in
            self?.reorderColumn(fromIndex: fromIndex, toOrdinal: toOrdinal)
        }
        installConfigureBindings()
    }

    // MARK: - Re-tiling

    /// Width presets act on the tiled flow, so re-tile the focused window first if
    /// it's currently floating (e.g. left floating by the resize grid).
    private func retileFocusedIfNeeded(for command: HotkeyCommand) {
        switch command {
        case .setColumnWidth,
             .setWindowWidth: break
        default: return
        }
        guard let controller = wmController,
              let token = controller.managedCommandTargetToken(),
              let entry = controller.workspaceManager.entry(for: token),
              entry.mode == .floating
        else { return }
        _ = controller.toggleWindowFloating(token: token)
    }

    /// Make the Niri layout selection coherent with the window the Deck is acting on.
    ///
    /// There are two independent "current window" pointers: AX focus (the bordered
    /// window, which `managedCommandTargetToken` resolves via the frontmost app) and
    /// the layout engine's `selectedNodeId`. Base keeps them in sync through focus
    /// events — but the Deck is a non-activating panel that fires none, so a prior
    /// drift survives. `setColumnWidth`/`setWindowWidth` read `selectedNodeId`
    /// (NiriLayoutHandler.setColumnWidth), so a stale selection resizes the wrong
    /// window (e.g. the border on one window, the resize landing on another). Re-point
    /// the selection at the command target before those commands run. Scoped to width
    /// commands so move/focus keep the base's own target resolution.
    private func syncLayoutSelectionToCommandTarget(for command: HotkeyCommand) {
        switch command {
        case .setColumnWidth,
             .setWindowWidth,
             .moveColumnToIndex: break
        default: return
        }
        guard let controller = wmController,
              let token = controller.managedCommandTargetToken(),
              let entry = controller.workspaceManager.entry(for: token),
              let engine = controller.niriEngine,
              let node = engine.findNode(for: token)
        else { return }
        var state = controller.workspaceManager.niriViewportState(for: entry.workspaceId)
        guard state.selectedNodeId != node.id else { return } // already coherent
        engine.activateWindow(node.id)
        state.selectedNodeId = node.id
        _ = controller.workspaceManager.applySessionPatch(
            WorkspaceSessionPatch(
                workspaceId: entry.workspaceId,
                viewportState: state,
                rememberedFocusToken: token
            )
        )
    }

    /// Snap every floating window back into the tiled flow (the "Tile All" action),
    /// then scroll the focused window back into view.
    private func retileAllFloating() {
        guard let controller = wmController else { return }
        for entry in controller.workspaceManager.allEntries() where entry.mode == .floating {
            _ = controller.toggleWindowFloating(token: entry.token)
        }
        revealCommandTargetAfterReflow()
    }

    /// After a reflow, scroll the focused window into view — the "reveal the focused
    /// one" reflow policy (keep base's scroll offset otherwise, don't force a
    /// left-pack). Deferred a tick so the un-float reconcile has re-inserted the
    /// window into its column before base's `navigateToWindow` tries to reveal it.
    private func revealCommandTargetAfterReflow() {
        DispatchQueue.main.async { [weak self] in
            guard let controller = self?.wmController,
                  let token = controller.managedCommandTargetToken(),
                  let handle = controller.workspaceManager.handle(for: token)
            else { return }
            _ = controller.windowActionHandler.navigateToWindow(handle: handle)
        }
    }

    // MARK: - Interaction-monitor alignment

    /// Realign the base's interaction monitor to the focused window's monitor before a
    /// command runs. The Deck activates on the screen it opens on, which can shift the
    /// interaction monitor off the target window on a second display — and
    /// monitor-gated operations (notably column/window width) then compute but never
    /// apply to the window's actual screen. Move isn't gated, which is why it worked
    /// while width didn't.
    private func alignInteractionMonitor() {
        guard let controller = wmController,
              let workspaceId = controller.interactionWorkspace()?.id,
              let monitor = controller.workspaceManager.monitor(for: workspaceId)
        else { return }
        _ = controller.workspaceManager.setInteractionMonitor(monitor.id)
    }

    // MARK: - Drag-to-reorder (OSD window list)

    /// Move the column the user dragged (identified by its current 0-based index) to a new
    /// 1-based slot, then re-render the OSD. The ⌘-digit move always targets the *bordered*
    /// window; a drag targets the *grabbed* column instead — so we point the layout selection at
    /// that column ourselves and perform the move directly, bypassing the border-window re-sync
    /// that `model.perform` applies to `.moveColumnToIndex`.
    private func reorderColumn(fromIndex: Int, toOrdinal: Int) {
        // A drag targets the GRABBED column, not the bordered window, so point the layout
        // selection at that column and perform the move directly (bypassing the border-window
        // re-sync that model.perform applies to .moveColumnToIndex), then relabel the on-window
        // number badges to match.
        guard let controller = wmController,
              let workspaceId = controller.interactionWorkspace()?.id,
              let engine = controller.niriEngine
        else { return }
        let columns = engine.columns(in: workspaceId)
        guard columns.indices.contains(fromIndex),
              let node = columns[fromIndex].windowNodes.first
        else { return }
        var state = controller.workspaceManager.niriViewportState(for: workspaceId)
        engine.activateWindow(node.id)
        state.selectedNodeId = node.id
        _ = controller.workspaceManager.applySessionPatch(
            WorkspaceSessionPatch(workspaceId: workspaceId, viewportState: state, rememberedFocusToken: node.token)
        )
        alignInteractionMonitor()
        _ = controller.commandHandler.performCommand(.moveColumnToIndex(toOrdinal))
        DispatchQueue.main.async { [weak self] in
            guard let self, let controller = self.wmController else { return }
            self.columnBadges.present(using: controller)
        }
    }

    // MARK: - Float toggle (float + fit to display, or re-tile)

    private func toggleFloatWithFit() {
        guard let controller = wmController,
              let token = controller.managedCommandTargetToken(),
              let entry = controller.workspaceManager.entry(for: token)
        else { return }
        let wasTiling = entry.mode == .tiling
        alignInteractionMonitor()
        _ = controller.toggleFocusedWindowFloating()
        if wasTiling {
            // Just floated → shrink to fit its display when it overflows.
            DispatchQueue.main.async { [weak self] in self?.fitFloatingWindowToDisplay(token: token) }
        }
    }

    private func fitFloatingWindowToDisplay(token: WindowToken) {
        guard let entry = wmController?.workspaceManager.entry(for: token),
              let frame = try? AXWindowService.frame(entry.axRef)
        else { return }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) ?? NSScreen.main
        else { return }
        let visible = screen.visibleFrame
        guard frame.width > visible.width || frame.height > visible.height else { return }
        let width = min(frame.width, visible.width)
        let height = min(frame.height, visible.height)
        let originX = min(max(frame.minX, visible.minX), visible.maxX - width)
        let originY = min(max(frame.minY, visible.minY), visible.maxY - height)
        applyFrame(CGRect(x: originX, y: originY, width: width, height: height), token: token)
    }

    // MARK: - Resize (float the focused window + snap it to a region)

    private func resizeFocusedWindow(to region: DeckRegion) {
        guard let controller = wmController,
              let token = controller.managedCommandTargetToken(),
              let entry = controller.workspaceManager.entry(for: token)
        else { return }

        // Keep it floating so the tiler leaves our frame alone (the user's intent).
        let didFloat = entry.mode == .tiling
        if didFloat {
            _ = controller.toggleFocusedWindowFloating()
        }

        let windowFrame = (try? AXWindowService.frame(entry.axRef)) ?? .zero
        let center = CGPoint(x: windowFrame.midX, y: windowFrame.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) })
            ?? NSScreen.main
        else { return }

        let visible = screen.visibleFrame
        let target = CGRect(
            x: visible.minX + region.x * visible.width,
            y: visible.maxY - (region.y + region.height) * visible.height,
            width: region.width * visible.width,
            height: region.height * visible.height
        )
        applyFrame(target, token: token)
        if didFloat {
            // The float transition schedules its own layout refresh; re-assert on the
            // next tick so our frame wins.
            DispatchQueue.main.async { [weak self] in self?.applyFrame(target, token: token) }
        }
    }

    private func applyFrame(_ frame: CGRect, token: WindowToken) {
        guard let controller = wmController,
              let entry = controller.workspaceManager.entry(for: token)
        else { return }
        _ = AXWindowService.setFrame(entry.axRef, frame: frame)
        // The focus border doesn't follow a floating window's frame on its own, so push
        // the new frame to it (a no-op if this window isn't the current border target).
        controller.updateManagedKeyboardFocusBorder(token: token, preferredFrame: frame)
    }

    /// Register the trigger hotkeys and menu-bar item. Call once after bootstrap.
    func install(primaryHotkey: String, remoteHotkey remote: String, passthroughApps: [String]) {
        applyHotkeys(primary: primaryHotkey, remote: remote, passthroughApps: passthroughApps)
        installStatusItem()
    }

    /// Register (or re-register) both summon chords live, remembering the raw strings so the
    /// Settings pane can read them back. The primary is a Carbon global hotkey (always consumed
    /// on this machine); the remote is an event tap that passes through to a focused Screen
    /// Sharing session (see `DeckRemoteHotkey`). An empty `remote` disables the pass-through tap.
    func applyHotkeys(primary: String, remote: String, passthroughApps: [String]) {
        currentPrimaryHotkey = primary
        currentRemoteHotkey = remote
        remotePassthroughApps = passthroughApps
        let primaryChord = DeckHotkeyChord.parse(primary)
        hotkey.register(chord: primaryChord) { [weak self] in self?.toggle() }
        // The pass-through tap must NOT silently fall back to ⌘D: it is a head-insert event tap,
        // so registering ⌘D there would consume ⌘D before Carbon and break "⌘D is always local".
        // Register it only for a chord that resolves on its own (strict parse) and differs from
        // the primary; an empty, unparseable, or duplicate remote chord leaves the tap off.
        if let remoteChord = DeckHotkeyChord.parseStrict(remote), remoteChord != primaryChord {
            remoteHotkey.register(
                chord: remoteChord,
                passthroughBundleIDs: passthroughApps
            ) { [weak self] in self?.toggle() }
        } else {
            remoteHotkey.unregister()
        }
    }

    /// The chords currently registered — answers the Settings pane's `hotkeysGet`.
    func currentHotkeys() -> (primary: String, remote: String) {
        (currentPrimaryHotkey, currentRemoteHotkey)
    }

    /// Apply new summon chords from the Settings pane: re-register live and persist a config
    /// fragment (mirroring the terminal-settings fragment) so the change survives a restart.
    func applyHotkeysFromSettings(primary: String, remote: String) {
        applyHotkeys(primary: primary, remote: remote, passthroughApps: remotePassthroughApps)
        writeHotkeysFragment(primary: primary, remote: remote)
    }

    /// Persist the summon chords to `10-deck.toml`. Only the two chord keys are written; the
    /// rest of `[deck]` (enabled, grid, remotePassthroughApps) stays sourced from earlier
    /// fragments, since the config merge overrides only the keys present in each file.
    private func writeHotkeysFragment(primary: String, remote: String) {
        let directory = ShellPaths.configDirectory()
        let file = directory.appendingPathComponent("10-deck.toml", isDirectory: false)
        func escape(_ value: String) -> String {
            value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
        }
        let toml = """
        # Managed by Nehir Settings (menu bar -> Settings...). Hand-edits here are
        # overwritten when you save from the Settings panel.
        [deck]
        hotkey = "\(escape(primary))"
        remoteHotkey = "\(escape(remote))"
        """
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Data(toml.utf8).write(to: file)
    }

    func shutdown() {
        hotkey.unregister()
        remoteHotkey.unregister()
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
        hide()
    }

    // MARK: - Show / hide

    func toggle() {
        if panel.isVisible {
            hide()
        } else {
            show()
        }
    }

    /// Pull the current pict-extension OSD registrations into Deck root entries (with
    /// live status), so the Deck reflects them each time it opens.
    private func refreshExtensionEntries() {
        let entries = overlays?.osdEntries() ?? []
        model.extensionActions = entries.map { entry in
            DeckAction(
                key: .character(entry.key),
                keyLabel: String(entry.key).uppercased(),
                title: entry.label,
                symbol: "square.on.square",
                kind: .showOverlay(entry.id),
                subtitle: entry.status,
                group: entry.group,
                isHeadless: !entry.tile
            )
        }
    }

    func show() {
        refreshExtensionEntries()
        model.reset()
        OwnedWindowRegistry.shared.register(panel)
        resizeAndCenter()
        NehirShell.offEdgeIndicators?.setDeckOpen(true)
        // Surface without activating the app, so the underlying window keeps focus.
        panel.orderFrontRegardless()
        // Present the overlays AFTER fronting the Deck, so the interactive window-list card
        // ends up front-most. Presenting it before (with the Deck fronted last) leaves the list
        // behind the Deck in z-order, and the background, non-activating list panel then doesn't
        // receive drag events — it shows but can't be dragged until an `i`-toggle re-fronts it.
        presentColumnBadges()
        installKeyTap()
        overlays?.presentInherentTerminalPane(frame: inherentTerminalPaneFrame())
    }

    func hide() {
        removeKeyTap()
        columnBadges.hide()
        windowList.hide()
        overlays?.dismissInherentTerminalPane()
        NehirShellHook.suppressRevealRaise = false
        NehirShell.offEdgeIndicators?.setDeckOpen(false)
        OwnedWindowRegistry.shared.unregister(panel)
        panel.orderOut(nil)
        model.reset()
        // Defensive: guarantee no key tap survives a hide, so keyboard input is never
        // stranded even if teardown re-entered and armed one.
        removeKeyTap()
    }

    /// Backtick focuses the inherent terminal pane for typing, suspending the Deck's
    /// key capture so keystrokes reach the shell (⌘D hides the OSD; reopening
    /// restores chord capture). The OSD stays up — the terminal is part of it.
    private func enterInherentTerminal() {
        // Switch the OSD into its terminal-active layout (Deck drops to the lower
        // band, list re-anchors to the Deck's right), then place the focused
        // terminal in the top band and hand keystrokes to it.
        overlays?.markInherentTerminalActive()
        // ⌘W in the terminal cleanly dismisses the whole OSD. We deliberately do NOT
        // re-arm the key tap when the terminal yields focus: a tap left armed after the
        // terminal is gone stranded all keyboard input. ⌘D also hides the OSD, and
        // reopening restores chord capture from a clean state.
        overlays?.onInherentTerminalYieldedFocus = { [weak self] in self?.hide() }
        resizeAndCenter()
        presentColumnBadges()
        overlays?.focusInherentTerminal(frame: inherentTerminalPaneFrame())
        removeKeyTap()
    }

    /// The frame for the inherent terminal pane: the top band of the screen, above
    /// the lowered Deck bar, inset by a margin on the top and sides. The Deck bar
    /// carries the bottom margin, so the terminal + Deck assembly is inset all round.
    private func inherentTerminalPaneFrame() -> CGRect {
        let visible = screenForPresentation().visibleFrame
        let edge = osdEdge(visible)
        let gap: CGFloat = 16
        let x = visible.minX + edge
        let width = visible.width - 2 * edge
        // Anchor above the Deck's *target* bottom position (screen + Deck height), NOT its
        // current frame — so the height is identical whether the pane is placed before or
        // after `resizeAndCenter` drops the Deck (the old bug: backtick moved the Deck first
        // and got a tall pane; a commandlet run measured the Deck before the move and got a
        // short one).
        let bottom = visible.minY + edge + panel.frame.height + gap
        // Row count is the source of truth for the height; clamp so it never overruns the
        // top margin on a short screen.
        let ceiling = (visible.maxY - edge) - bottom
        let desired = overlays?.terminalPaneHeight ?? 320
        let height = max(160, min(desired, ceiling))
        return CGRect(x: x, y: bottom, width: width, height: height)
    }

    /// Screen-derived breathing room for the terminal-active OSD assembly (top,
    /// bottom, and side margins), clamped so it stays sane on small and large displays.
    private func osdEdge(_ visible: CGRect) -> CGFloat {
        let configured = overlays?.terminalEdgeMargin ?? 72
        return min(max(configured, 16), visible.height * 0.3)
    }

    // MARK: - Column number badges

    /// Show the column-number badges for the current workspace (the geometry lives in
    /// the overlay controller, which reads the same `engine.columns(in:)` the base
    /// `focusColumn` jump indexes, so a badge and its `⌘D → digit` target can't drift).
    private func presentColumnBadges() {
        guard let wmController else {
            columnBadges.hide()
            windowList.hide()
            NehirShellHook.suppressRevealRaise = false
            return
        }
        // Feature 1: on-window decorations always show with the Deck.
        columnBadges.present(using: wmController)
        // Feature 2: the separate centered list only shows when the F1/`i` toggle is on.
        if NehirShell.showFullWindowList {
            if overlays?.isInherentTerminalActive == true {
                windowList.present(using: wmController, rightOfDeckFrame: panel.frame)
            } else {
                windowList.present(using: wmController, belowDeckFrame: panel.frame)
            }
        } else {
            windowList.hide()
        }
        // While the interactive list is up, tell the layout refresh not to raise a window it moves
        // to absolute front — that raise would land over the non-activating drag panel and steal
        // its mouse input (leaving reorder dead until the panel is re-presented).
        NehirShellHook.suppressRevealRaise = NehirShell.showFullWindowList
    }

    /// F1/`i` toggles the persisted "show full window list" preference and re-evaluates the
    /// overlays live, so the separate centered list panel appears/disappears. The on-window
    /// decorations are unaffected.
    private func toggleFullWindowList() {
        NehirShell.showFullWindowList.toggle()
        presentColumnBadges()
    }

    // MARK: - Layout

    /// Re-anchor the drag-to-reorder list beneath the Deck's CURRENT frame. Called on pane changes
    /// so the list follows the Deck as it grows/shrinks instead of being left overlapping it.
    ///
    /// Guarded on `panel.isVisible`: `onModeChanged` also fires from `model.reset()` inside `hide()`
    /// (after the Deck is ordered out) and `show()` (before it's fronted). Without this guard the
    /// hide-time reset would re-present the list right after `hide()` dismissed it, leaving the
    /// list stuck on screen; show-time presentation is handled explicitly by `presentColumnBadges`.
    private func repositionWindowList() {
        guard panel.isVisible, let wmController, NehirShell.showFullWindowList else { return }
        windowList.present(using: wmController, belowDeckFrame: panel.frame)
    }

    // MARK: - Advanced Internals pane

    /// Snapshot the engine's per-window runtime state for the Advanced Internals pane, flagging the
    /// suspicious learned/cached values worth clearing: an ephemeral resize floor, a fixed-size
    /// verdict, or a manual single-window width override.
    private func buildInternalsRows() -> [DeckInternalsRow] {
        guard let controller = wmController,
              let wsId = controller.interactionWorkspace()?.id,
              let engine = controller.niriEngine
        else { return [] }

        var columnByToken: [WindowToken: NiriContainer] = [:]
        for column in engine.columns(in: wsId) {
            for window in column.windowNodes { columnByToken[window.token] = column }
        }

        var rows: [DeckInternalsRow] = []
        for (index, entry) in controller.workspaceManager.tiledEntries(in: wsId).prefix(10).enumerated() {
            let token = entry.token
            var anomalies: [String] = []   // engine-inferred (potentially wrong) — orange
            var notes: [String] = []       // user-intended (a hand-set width) — neutral
            if let floor = controller.workspaceManager.observedResizeFloor(for: token) {
                anomalies.append("floor \(Int(floor.width.rounded()))×\(Int(floor.height.rounded()))")
            }
            if let constraints = controller.workspaceManager.cachedConstraints(for: token, maxAge: .greatestFiniteMagnitude),
               constraints.isFixed
            {
                anomalies.append("fixed")
            }
            if let column = columnByToken[token], column.hasManualSingleWindowWidthOverride {
                if let width = column.loneWindowLayoutWidthOverride {
                    notes.append("manual \(Int(width.rounded()))")
                } else {
                    notes.append("manual")
                }
            }
            let appName = NSRunningApplication(processIdentifier: pid_t(token.pid))?.localizedName ?? "pid \(token.pid)"
            // The window's real on-screen width — unaffected by a cached-span invalidation, so the
            // detail never blanks after a reset (unlike the engine's `cachedWidth`).
            let width = (try? AXWindowService.frame(entry.axRef))?.width ?? (columnByToken[token]?.cachedWidth ?? 0)
            let detail = width > 0 ? "\(Int(width.rounded()))w" : ""
            rows.append(DeckInternalsRow(
                id: token.windowId,
                number: index + 1,
                appName: appName,
                detail: detail,
                anomalies: anomalies,
                notes: notes
            ))
        }
        return rows
    }

    /// Reset one row's window runtime state — the same per-window clear the `nehirctl` escape hatch
    /// performs — then relayout so a freed window re-tests its size immediately.
    private func resetInternalsRow(_ number: Int) {
        guard let controller = wmController,
              let wsId = controller.interactionWorkspace()?.id
        else { return }
        let entries = Array(controller.workspaceManager.tiledEntries(in: wsId).prefix(10))
        let index = number - 1
        guard entries.indices.contains(index) else { return }
        let token = entries[index].token
        controller.workspaceManager.resetWindowRuntimeState(for: token)
        if let engine = controller.niriEngine {
            engine.updateWindowConstraints(for: token, constraints: .unconstrained)
            // Re-resolve ONLY this column's width (not every column) so a cleared resize floor lets
            // the window shrink, while other rows keep their widths. A hand-set width (the neutral
            // `manual` note) is user intent, not engine magic, so it is deliberately left untouched.
            for column in engine.columns(in: wsId)
                where column.windowNodes.contains(where: { $0.token == token })
            {
                column.cachedWidth = 0
            }
        }
        controller.layoutRefreshController.requestRefresh(reason: .layoutCommand)
    }

    private func resizeAndCenter() {
        hostingView.layoutSubtreeIfNeeded()
        var size = hostingView.fittingSize
        // Floor against a not-yet-laid-out (0-size) hosting view. The width matches
        // DeckView's declared frame; the height floor keeps a single-row submode visible.
        size.width = max(size.width, 380)
        size.height = max(size.height, 120)
        let screen = screenForPresentation()
        let visible = screen.visibleFrame

        // Terminal-active OSD: drop the Deck bar to a lower band (still horizontally
        // centered, with a bottom margin) so the inherent terminal fills the top band
        // above it and the window list sits to the Deck's right. Computed straight from
        // the screen, so the assembly does not drift across dismiss/re-open.
        if overlays?.isInherentTerminalActive == true {
            let edge = osdEdge(visible)
            let origin = NSPoint(x: visible.midX - size.width / 2, y: visible.minY + edge)
            panel.setFrame(NSRect(origin: origin, size: size), display: true)
            return
        }

        // When the drag-to-reorder list is shown beneath the Deck, center the Deck + gap + list as a
        // single stack (clamped to the screen) so a tall pane never grows down into the list and the
        // whole thing stays visible. The list's height is stable across pane changes (it tracks the
        // window set, not the pane), so its last presented size is an accurate reservation. Must use
        // the same gap the list anchors with (ColumnBadgeOverlay's `present`).
        let listGap: CGFloat = 16
        let listHeight = NehirShell.showFullWindowList ? (windowList.lastCardSize?.height ?? 0) : 0
        let stackHeight = listHeight > 0 ? size.height + listGap + listHeight : size.height
        var deckTop = visible.midY + stackHeight / 2
        deckTop = min(deckTop, visible.maxY)                        // keep the Deck's top on screen
        if deckTop - stackHeight < visible.minY {                  // and lift the stack off the bottom
            deckTop = min(visible.maxY, visible.minY + stackHeight)
        }
        let origin = NSPoint(x: visible.midX - size.width / 2, y: deckTop - size.height)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private func screenForPresentation() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    // MARK: - Key capture (CGEvent tap)

    // A session event tap captures keys while the Deck is open WITHOUT activating the
    // app — so the underlying window keeps focus (border stays, deferred layout
    // refreshes apply). Recognized Deck keys are consumed; everything else passes
    // through. Requires Accessibility trust, which the WM already has.
    private func installKeyTap() {
        // Idempotent: tear down any existing tap first so we never orphan one in the
        // run loop. An orphaned tap keeps eating keys after removeKeyTap() clears only
        // the latest reference — which stranded all global keyboard input.
        removeKeyTap()
        let eventMask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let controller = Unmanaged<ControlDeckController>.fromOpaque(userInfo).takeUnretainedValue()

            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                MainActor.assumeIsolated { controller.reenableTap() }
                return Unmanaged.passUnretained(event)
            }
            guard type == .keyDown, let nsEvent = NSEvent(cgEvent: event) else {
                return Unmanaged.passUnretained(event)
            }
            let flags = nsEvent.modifierFlags
            // ⌘+digit (no other modifiers) is a Deck command — "send window to ordinal N".
            // Intercept it before the general ⌘/⌃ passthrough below.
            if flags.contains(.command),
               flags.isDisjoint(with: [.control, .option, .shift]),
               let digit = ControlDeckController.digit(from: nsEvent)
            {
                let handled = MainActor.assumeIsolated { controller.model.handle(key: .commandDigit(digit)) }
                return handled ? nil : Unmanaged.passUnretained(event)
            }
            // ⌥+digit (no other modifiers) → "load" a commandlet slot (a bare digit runs
            // it). Resolved here like the ⌘+digit chord above, because the general resolver
            // strips modifiers and would deliver an indistinguishable `.character` digit.
            if flags.contains(.option),
               flags.isDisjoint(with: [.command, .control, .shift]),
               let digit = ControlDeckController.digit(from: nsEvent)
            {
                let handled = MainActor.assumeIsolated { controller.model.handle(key: .optionDigit(digit)) }
                return handled ? nil : Unmanaged.passUnretained(event)
            }
            // Toggle the full window list in the OSD. Bound to F1 (keyCode 0x7A) and to `i`
            // (keyCode 0x22): F1 only reaches this tap as a keyDown when "standard function
            // keys" is enabled — otherwise macOS routes it as a media/system event we never
            // see — whereas `i` is always delivered as a keyDown. Handled before the
            // command/control passthrough and the typographic/function fall-through below.
            if flags.isDisjoint(with: [.command, .control, .option]),
               nsEvent.keyCode == 0x7A || nsEvent.keyCode == 0x22
            {
                MainActor.assumeIsolated { controller.toggleFullWindowList() }
                return nil
            }
            // Backtick (keyCode 0x32) summons + focuses the persistent inherent
            // terminal, dismissing the Deck — intercepted here before the
            // typographic swallow below (backtick is otherwise a no-op punct key).
            if flags.isDisjoint(with: [.command, .control, .option]),
               nsEvent.keyCode == 0x32
            {
                MainActor.assumeIsolated { controller.enterInherentTerminal() }
                return nil
            }
            // Other command/control chords are never Deck keys — let them through so system
            // shortcuts (⌘Tab, ⌘Q, …) still work while the Deck is open.
            if !flags.isDisjoint(with: [.command, .control]) {
                return Unmanaged.passUnretained(event)
            }
            // Resolve the (Sendable) DeckKey here so the non-Sendable CGEvent never
            // crosses into the main-actor closure; hop over only the key.
            if let key = ControlDeckController.deckKey(from: nsEvent),
               MainActor.assumeIsolated({ controller.model.handle(key: key) })
            {
                return nil
            }
            // Swallow any remaining typographic key (letters/digits/punctuation/space) so
            // a mistype can't leak into the window below while the Deck is open. Function
            // and media keys fall through untouched.
            if ControlDeckController.isTypographicKey(nsEvent) {
                return nil
            }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        eventTapSource = source
    }

    private func removeKeyTap() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        if let eventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), eventTapSource, .commonModes)
        }
        eventTap = nil
        eventTapSource = nil
    }

    private func reenableTap() {
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
    }
}

extension ControlDeckController {
    /// Inject the Configure-flow closures the model calls (kept out of `init` so the
    /// class body stays within the lint budget).
    func installConfigureBindings() {
        model.requestConfigureTargets = { [weak self] in
            guard let controller = self?.wmController else { return [] }
            return DeckPickSource.configureTargets(using: controller)
        }
        model.loadConfigureRule = { target in
            NehirShell.windowRules?.rule(bundleId: target.bundleId, title: target.title)
                ?? WindowConfigRule(bundleId: target.bundleId, titleContains: target.title)
        }
        model.commitConfigureRule = { [weak self] rule, token in
            self?.commitWindowRule(rule, token: token)
        }
        model.readNehirChrome = { [weak self] in
            guard let settings = self?.wmController?.settings else { return (false, false) }
            return (settings.workspaceBarEnabled, settings.bordersEnabled)
        }
        model.applyWorkspaceBar = { [weak self] enabled in
            self?.wmController?.setWorkspaceBarEnabled(enabled)
        }
        model.applyWindowBorders = { [weak self] enabled in
            guard let controller = self?.wmController else { return }
            controller.settings.bordersEnabled = enabled
            controller.setBordersEnabled(enabled)
        }
        model.readLayoutMode = { [weak self] in self?.layoutModeController?.mode ?? .river }
        model.applyLayoutMode = { [weak self] mode in self?.layoutModeController?.set(mode) }
        model.readCrossMonitorOverflow = { NehirShellHook.allowCrossMonitorOverflow }
        model.applyCrossMonitorOverflow = { [weak self] enabled in
            NehirShellHook.allowCrossMonitorOverflow = enabled
            UserDefaults.standard.set(enabled, forKey: NehirShell.crossMonitorOverflowDefaultsKey)
            // Re-run the layout so the visibility culling picks up the change immediately.
            self?.wmController?.layoutRefreshController.requestRefresh(reason: .workspaceLayoutToggled)
        }
        model.readViewportZoomLabel = { [weak self] in self?.viewportInsetController?.zoomLabel ?? "Off" }
        model.cycleViewportZoom = { [weak self] in self?.viewportInsetController?.cycleZoom() }
        model.readInternalsRows = { [weak self] in self?.buildInternalsRows() ?? [] }
        model.resetInternalsWindow = { [weak self] number in self?.resetInternalsRow(number) }
        model.readCommandletSlots = { [weak self] in self?.buildCommandletSlots() ?? [] }
        model.runCommandletSlot = { [weak self] slot in self?.runCommandletSlot(slot) }
        model.loadCommandletSlot = { [weak self] slot in self?.loadCommandletSlot(slot) }
        model.runBuiltinCommandlet = { [weak self] commandlet in self?.runBuiltinCommandlet(commandlet) }
    }

    // MARK: - Commandlets

    /// The palette's slot rows, built from the store (only the bound 1…9 slots). Each row's
    /// tap runs the slot, matching the digit key.
    private func buildCommandletSlots() -> [DeckPickItem] {
        let commandlets = CommandletStore.load()
        return (1 ... 9).compactMap { slot -> DeckPickItem? in
            guard let commandlet = CommandletStore.commandlet(inSlot: slot, from: commandlets) else { return nil }
            return DeckPickItem(label: String(slot), title: commandlet.name, activate: { [weak self] in
                self?.runCommandletSlot(slot)
            })
        }
    }

    /// Run a slot: reveal the inherent terminal as an OSD pane (a non-key peek), lay the OSD
    /// out in its terminal-active arrangement, and run the command — keeping the palette up
    /// so the output stays visible and more slots can run.
    private func runCommandletSlot(_ slot: Int) {
        guard let commandlet = CommandletStore.commandlet(inSlot: slot, from: CommandletStore.load()) else { return }
        overlays?.markInherentTerminalActive()
        overlays?.presentInherentTerminalPane(frame: inherentTerminalPaneFrame())
        resizeAndCenter()
        presentColumnBadges()
        overlays?.runCommandlet(commandlet, load: false)
    }

    /// Run a built-in nehir commandlet (from the catalog's `.nehirCommandlets` mode). Same
    /// terminal-pane reveal + run as a numbered slot — the palette stays up so the output is
    /// visible — but the command is baked into the catalog rather than read from the store.
    private func runBuiltinCommandlet(_ commandlet: Commandlet) {
        overlays?.markInherentTerminalActive()
        overlays?.presentInherentTerminalPane(frame: inherentTerminalPaneFrame())
        resizeAndCenter()
        presentColumnBadges()
        overlays?.runCommandlet(commandlet, load: false)
    }

    /// Load a slot: focus the terminal for typing (like backtick), then stage the line so
    /// the author can edit it before pressing Enter.
    private func loadCommandletSlot(_ slot: Int) {
        guard let commandlet = CommandletStore.commandlet(inSlot: slot, from: CommandletStore.load()) else { return }
        enterInherentTerminal()
        overlays?.runCommandlet(commandlet, load: true)
    }

    /// Persist a configured window rule and apply it now: the forced width lands via the
    /// rule-effects hook on the reevaluation refresh; always-float floats the window
    /// immediately when it's currently tiled (durable re-float across relaunch rides on
    /// the base's own float persistence — a deliberate v1 limit for new windows).
    func commitWindowRule(_ rule: WindowConfigRule, token: WindowToken) {
        NehirShell.windowRules?.upsert(rule)
        guard let controller = wmController else { return }
        if rule.alwaysFloat,
           let entry = controller.workspaceManager.entry(for: token),
           entry.mode == .tiling
        {
            _ = controller.toggleWindowFloating(token: token)
        }
        // Re-admit the window through the base rule-reevaluation path so the fork
        // rule-effects hook recomputes the forced width and the relayout applies it LIVE.
        // A bare `requestRefresh(.windowRuleReevaluation)` only relayouts using the entry's
        // stale effects — it never re-runs the hook, so a live-configured width never lands.
        Task { @MainActor in
            _ = await controller.reevaluateWindowRules(for: [.window(token)])
        }
    }
}
