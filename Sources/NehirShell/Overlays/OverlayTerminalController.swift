// SPDX-FileCopyrightText: 2026 Steven Velozo
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import AppKit
import Darwin
import SwiftTerm

/// The Deck's persistent inherent terminal, presented as a pane in the OSD above
/// the controls. A warm login+interactive shell (`$SHELL -li`) stays alive across
/// OSD shows and hides, so scrollback and shell state persist. It shows non-key —
/// a surface to glance at — and takes keyboard focus only on demand. Its
/// visibility follows the OSD; it does not dismiss itself on focus loss. Only ⌘W
/// (or the shell exiting) ends the session. Interactive programs (fzf, less, vim)
/// work because the shell runs in a real pseudo-terminal.
@MainActor
final class OverlayTerminalController: NSObject, @preconcurrency LocalProcessTerminalViewDelegate {
    private var panel: OverlayKeyPanel?
    private var terminalView: LocalProcessTerminalView?
    private var processRunning = false
    /// True while we have activated the app to give the terminal focus, so hiding
    /// or closing hands focus back to the previous app (a non-key peek does not).
    private var didActivate = false
    /// Fired when the session ends (⌘W or the shell exiting) so the owner can stop
    /// presenting the pane with the OSD until it is summoned again.
    var onSessionEnded: () -> Void = {}
    /// Fired when the terminal yields keyboard focus (⌘W close, or click / Cmd-Tab away),
    /// so the OSD can re-arm its key control instead of being stranded uninteractive.
    var onYieldFocus: () -> Void = {}
    /// Appearance (font, opacity, corner radius, padding) applied to the session.
    var appearance: TerminalConfig = .fallback
    /// A plain wrapper view that carries the inner-padding inset (kept so the inset can
    /// be resized live without a rebuild). The terminal fills this; this is inset in the
    /// rounded container — SwiftTerm overrides frame insets applied to itself directly.
    private var paddedView: NSView?

    /// Whether the pane is currently on-screen.
    var isVisible: Bool { panel?.isVisible ?? false }
    /// Whether the terminal currently holds keyboard focus.
    var isKey: Bool { panel?.isKeyWindow ?? false }

    // MARK: - Presentation

    /// Show the terminal pane *without* taking focus (the OSD peek). Builds the warm
    /// session on first use; repositions an existing one to `frame`.
    func showPeek(frame: CGRect) {
        ensureSession(frame: frame)
        panel?.orderFront(nil)
    }

    /// Give the (already-shown) terminal keyboard focus so the user can type.
    func focus() {
        guard panel != nil else { return }
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
        // Make the terminal the first responder now, so the first keystroke after
        // the backtick focus lands in the shell instead of being eaten (and beeping).
        if let terminal = terminalView { panel?.makeFirstResponder(terminal) }
        didActivate = true
    }

    /// Order the pane out but keep the shell warm (the OSD hid). Hands focus back
    /// to the previous app if we had taken it.
    func hide() {
        panel?.orderOut(nil)
        relinquishFocus()
    }

    /// End the session: order out, tear down the shell, and notify the owner.
    func close() {
        guard panel != nil || terminalView != nil else { return }
        teardownSession()
        relinquishFocus()
        onSessionEnded()
        onYieldFocus()
    }

    // MARK: - Running commands

    /// Focus the terminal and run `command` in it (the Tools overlay's "Run here").
    func runCommand(_ command: String, frame: CGRect) {
        ensureSession(frame: frame)
        focus()
        sendLine(command)
    }

    /// Type `text` into the live shell and run it (appends a newline).
    func sendLine(_ text: String) {
        terminalView?.send(txt: text + "\n")
    }

    /// Type `text` into the live shell *without* running it (stage/"load").
    func send(_ text: String) {
        terminalView?.send(txt: text)
    }

    /// Ask the live shell to append its in-memory history to the history file, so the
    /// commandlet manager's Refresh picks up commands just run in this warm session (a
    /// warm shell doesn't write history until it exits). The leading space keeps the flush
    /// out of history on ignore-space shells; `fc -AI` (zsh) falls back to `history -a`
    /// (bash), output suppressed.
    func flushHistory() {
        guard isRunning else { return }
        send(" fc -AI 2>/dev/null || history -a 2>/dev/null\n")
    }

    /// True when a warm shell session is live (panel built and process running).
    var isRunning: Bool { terminalView != nil && processRunning }

    /// The current working directory of the live shell, read straight from the child
    /// process — used by the commandlet manager to default a slot's pinned folder to
    /// wherever the terminal is sitting. Nil when no session is running.
    var currentWorkingDirectory: String? {
        guard let terminal = terminalView, let process = terminal.process, process.running else { return nil }
        let pid = process.shellPid
        guard pid > 0 else { return nil }
        var info = proc_vnodepathinfo()
        let expected = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        let written = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, $0, expected)
        }
        guard written == expected else { return nil }
        return withUnsafeBytes(of: &info.pvi_cdir.vip_path) { rawBuffer in
            rawBuffer.baseAddress.map { String(cString: $0.assumingMemoryBound(to: CChar.self)) }
        }
    }

    // MARK: - Session lifecycle

    private func ensureSession(frame: CGRect) {
        if terminalView != nil, processRunning {
            panel?.setFrame(frame, display: true)
            return
        }
        teardownSession()
        buildSession(frame: frame)
    }

    private func buildSession(frame: CGRect) {
        let terminal = LocalProcessTerminalView(frame: CGRect(origin: .zero, size: frame.size))
        terminal.processDelegate = self

        let container = NSView(frame: CGRect(origin: .zero, size: frame.size))
        container.wantsLayer = true
        container.layer?.cornerRadius = CGFloat(appearance.cornerRadius)
        container.layer?.masksToBounds = true
        // Fill the padding gap with the terminal's own background so the inset reads as
        // seamless padding. Resolve in the effective appearance so it matches what
        // SwiftTerm actually renders (a raw .cgColor can resolve to the wrong mode).
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance {
            container.layer?.backgroundColor = terminal.nativeBackgroundColor.cgColor
        }

        // A plain padded view holds the inset. SwiftTerm's view manages its own layout
        // (it overrides setFrameSize/resizeSubviews), so it fills this wrapper edge to
        // edge while the wrapper — a well-behaved NSView — carries the padding.
        let pad = CGFloat(max(0, appearance.padding))
        let padded = NSView(frame: container.bounds.insetBy(dx: pad, dy: pad))
        padded.autoresizingMask = [.width, .height]
        container.addSubview(padded)
        terminal.frame = padded.bounds
        terminal.autoresizingMask = [.width, .height]
        padded.addSubview(terminal)
        paddedView = padded
        applyAppearance(to: terminal)

        let panel = OverlayWebPanel.makePanel(frame: frame)
        panel.contentView = container
        // The pane's visibility follows the OSD (the Deck shows/hides it); it does
        // not dismiss itself on focus loss. ⌘W ends the session; Esc is left to the
        // terminal (fzf/vim) since the panel only claims ⌘W as a key equivalent.
        panel.onCommandW = { [weak self] in self?.close() }
        panel.setFrame(frame, display: true)

        self.panel = panel
        terminalView = terminal
        applyPanelOpacity()

        // A login + interactive shell so the user's PATH, aliases, and functions
        // are loaded; no `-c`, so the shell stays alive as a persistent session.
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        let shell = environment["SHELL"] ?? "/bin/zsh"
        let home = environment["HOME"] ?? NSHomeDirectory()
        processRunning = true
        terminal.startProcess(
            executable: shell,
            args: ["-li"],
            environment: environment.map { "\($0.key)=\($0.value)" },
            currentDirectory: home
        )
    }

    /// Apply the configured font and background opacity to a terminal view.
    private func applyAppearance(to terminal: LocalProcessTerminalView) {
        let size = CGFloat(max(6, appearance.fontSize))
        if !appearance.fontFamily.isEmpty, let custom = NSFont(name: appearance.fontFamily, size: size) {
            terminal.font = custom
        } else {
            terminal.font = .monospacedSystemFont(ofSize: size, weight: .regular)
        }
        terminal.needsDisplay = true
    }

    /// Translucency is applied to the whole panel (a reliable, visible effect) rather
    /// than the terminal's per-cell background, which SwiftTerm paints opaque.
    private func applyPanelOpacity() {
        panel?.alphaValue = CGFloat(max(0.2, min(1.0, appearance.opacity)))
    }

    /// Re-apply the current appearance to a live session so a settings change shows on
    /// the next summon (or immediately, if the pane is visible) without a rebuild.
    func applyAppearanceLive() {
        guard let terminal = terminalView else { return }
        applyAppearance(to: terminal)
        if let container = panel?.contentView {
            container.layer?.cornerRadius = CGFloat(appearance.cornerRadius)
            let pad = CGFloat(max(0, appearance.padding))
            paddedView?.frame = container.bounds.insetBy(dx: pad, dy: pad)
        }
        applyPanelOpacity()
    }

    private func teardownSession() {
        panel?.orderOut(nil)
        panel = nil
        terminalView = nil
        processRunning = false
        paddedView = nil
    }

    /// Deactivate the app so focus returns to the previous app, but only if we took
    /// focus (a non-key peek never activated, so it must not deactivate).
    private func relinquishFocus() {
        guard didActivate else { return }
        didActivate = false
        NSApp.deactivate()
    }

    // MARK: - LocalProcessTerminalViewDelegate

    func sizeChanged(source _: LocalProcessTerminalView, newCols _: Int, newRows _: Int) {}
    func setTerminalTitle(source _: LocalProcessTerminalView, title _: String) {}
    func hostCurrentDirectoryUpdate(source _: TerminalView, directory _: String?) {}
    func processTerminated(source _: TerminalView, exitCode _: Int32?) {
        // The persistent shell ended (⌘W or `exit`). Leave the notice on screen for
        // this OSD session; the owner stops re-presenting it until summoned again.
        processRunning = false
        terminalView?.feed(text: "\r\n\u{1b}[2m— shell exited · summon again for a new session —\u{1b}[0m\r\n")
        onSessionEnded()
    }
}
