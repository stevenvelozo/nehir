// SPDX-FileCopyrightText: 2026 Steven Velozo
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import AppKit

/// The Deck's menu-bar status item. Left-click toggles the Deck (the touch /
/// remote-desktop path); right-click opens a small menu for the auto-updater and quit.
extension ControlDeckController {
    func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "square.grid.2x2",
            accessibilityDescription: "Nehir Control Deck"
        )
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
    }

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showStatusMenu()
        } else {
            toggle()
        }
    }

    private func showStatusMenu() {
        let menu = NSMenu()
        // Only offer "Check for Updates…" when the updater is actually configured
        // (a real signing key is shipped); otherwise it's a dead item that errors.
        if onCheckForUpdates != nil {
            let check = NSMenuItem(
                title: "Check for Updates…",
                action: #selector(checkForUpdatesClicked),
                keyEquivalent: ""
            )
            check.target = self
            menu.addItem(check)
            menu.addItem(.separator())
        }
        let quit = NSMenuItem(title: "Quit Nehir", action: #selector(quitClicked), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
        guard let button = statusItem?.button else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    @objc private func checkForUpdatesClicked() {
        onCheckForUpdates?()
    }

    @objc private func quitClicked() {
        NSApplication.shared.terminate(nil)
    }
}
