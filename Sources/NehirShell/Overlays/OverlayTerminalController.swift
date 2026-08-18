// SPDX-FileCopyrightText: 2026 Steven Velozo
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import AppKit
import SwiftTerm

/// A floating terminal panel that runs one command in the user's login shell,
/// for the Tools overlay's "Run here" target. Interactive programs (fzf, less,
/// mplayer) work because the command runs in a real pseudo-terminal. One
/// terminal shows at a time; Esc closes it (terminating the shell).
@MainActor
final class OverlayTerminalController: NSObject, @preconcurrency LocalProcessTerminalViewDelegate {
    private var panel: OverlayKeyPanel?
    private var terminalView: LocalProcessTerminalView?
    private var onClose: () -> Void = {}
    /// True while the child process is alive. Guards click-away dismissal so the
    /// panel doesn't vanish just because you Cmd-Tabbed away mid-run.
    private var processRunning = false

    var isShowing: Bool { panel != nil }

    /// Present a floating terminal running `command`, sized/positioned by `frame`.
    /// `onClose` fires when the panel is dismissed (Esc), so the caller can
    /// relinquish focus back to whatever the user was in.
    func run(command: String, frame: CGRect, onClose: @escaping () -> Void) {
        close()
        self.onClose = onClose

        let terminal = LocalProcessTerminalView(frame: CGRect(origin: .zero, size: frame.size))
        terminal.processDelegate = self
        terminal.autoresizingMask = [.width, .height]

        let container = NSView(frame: CGRect(origin: .zero, size: frame.size))
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.layer?.masksToBounds = true
        terminal.frame = container.bounds
        container.addSubview(terminal)

        let panel = OverlayWebPanel.makePanel(frame: frame)
        panel.contentView = container
        // Esc belongs to the terminal (fzf/vim); ⌘W closes the panel instead.
        // Clicking away closes it too, but only once the process has exited.
        panel.onEsc = { [weak self] in self?.close() }
        panel.onResignKey = { [weak self] in
            guard let self, !self.processRunning else { return }
            self.close()
        }
        panel.setFrame(frame, display: true)

        self.panel = panel
        terminalView = terminal

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)

        // A login + interactive shell so the user's PATH, aliases, and functions
        // (the kind a hand-written pipeline relies on) are all loaded before the
        // command runs.
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        let shell = environment["SHELL"] ?? "/bin/zsh"
        processRunning = true
        terminal.startProcess(
            executable: shell,
            args: ["-lic", command],
            environment: environment.map { "\($0.key)=\($0.value)" }
        )
    }

    func close() {
        guard panel != nil else { return }
        panel?.orderOut(nil)
        panel = nil
        terminalView = nil
        let callback = onClose
        onClose = {}
        callback()
    }

    // MARK: - LocalProcessTerminalViewDelegate

    func sizeChanged(source _: LocalProcessTerminalView, newCols _: Int, newRows _: Int) {}
    func setTerminalTitle(source _: LocalProcessTerminalView, title _: String) {}
    func hostCurrentDirectoryUpdate(source _: TerminalView, directory _: String?) {}
    func processTerminated(source _: TerminalView, exitCode _: Int32?) {
        // Leave the panel up so the final output stays readable; ⌘W (or clicking
        // away, now that the process is gone) closes it.
        processRunning = false
        terminalView?.feed(text: "\r\n\u{1b}[2m— process exited · ⌘W or click away to close —\u{1b}[0m\r\n")
    }
}
