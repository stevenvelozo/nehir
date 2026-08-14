// SPDX-FileCopyrightText: 2026 Steven Velozo
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import AppKit
import Foundation
@testable import Nehir

/// The on-screen desktop status panel: a borderless, non-activating, floating
/// desklet whose text is produced by `ShellPanelModel` and refreshed on a timer.
///
/// It registers with the base manager's `OwnedWindowRegistry` so the window
/// manager treats it as an owned utility surface and never tiles it — the one
/// place this feature touches the WM, through its public-to-us registry rather
/// than any layout internals.
@MainActor
final class ShellPanelController {
    private let model: ShellPanelModel
    private let panel: NSPanel
    private let label: NSTextField
    private var timer: Timer?
    private var corner: PanelCorner
    private var refreshSeconds: Double

    init(model: ShellPanelModel, config: PanelConfig) {
        self.model = model
        corner = config.corner
        refreshSeconds = max(0.1, config.refreshSeconds)

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.state = .active
        background.blendingMode = .behindWindow
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true

        label = NSTextField(labelWithString: "")
        label.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -14),
            label.centerYAnchor.constraint(equalTo: background.centerYAnchor)
        ])
        panel.contentView = background
    }

    func show() {
        refresh()
        OwnedWindowRegistry.shared.register(panel)
        panel.orderFrontRegardless()
        startTimer()
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        OwnedWindowRegistry.shared.unregister(panel)
        panel.orderOut(nil)
    }

    /// Re-apply config (e.g. after a reload) without recreating the window.
    func update(model updatedModel: PanelConfig) {
        corner = updatedModel.corner
        refreshSeconds = max(0.1, updatedModel.refreshSeconds)
        startTimer()
        refresh()
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: refreshSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func refresh() {
        label.stringValue = model.render(now: Date())
        resizeAndReposition()
    }

    private func resizeAndReposition() {
        label.sizeToFit()
        let width = max(120, label.frame.width + 28)
        let height: CGFloat = 44
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let margin: CGFloat = 12
        let originX: CGFloat
        let originY: CGFloat
        switch corner {
        case .topRight:
            originX = visible.maxX - width - margin
            originY = visible.maxY - height - margin
        case .topLeft:
            originX = visible.minX + margin
            originY = visible.maxY - height - margin
        case .bottomRight:
            originX = visible.maxX - width - margin
            originY = visible.minY + margin
        case .bottomLeft:
            originX = visible.minX + margin
            originY = visible.minY + margin
        }
        panel.setFrame(NSRect(x: originX, y: originY, width: width, height: height), display: true)
    }
}
