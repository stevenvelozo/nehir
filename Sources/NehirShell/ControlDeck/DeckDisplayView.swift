// SPDX-FileCopyrightText: 2026 Steven Velozo
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import SwiftUI

/// The Display pane: live toggles for a few macOS screen-layout settings — auto-hide
/// menu bar (M), auto-hide Dock (D), Dock magnification (G), and Dock position (B/L/R).
/// Each change writes through immediately (Dock changes restart the Dock); the row
/// highlights its current state. Esc backs to the root deck.
struct DeckDisplayView: View {
    let model: DeckModel

    private var settings: DisplaySettings {
        model.displaySettings
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            toggleRow("M", "Auto-hide menu bar", on: settings.menuBarAutoHide) {
                model.toggleMenuBarAutoHide()
            }
            toggleRow("D", "Auto-hide Dock", on: settings.dockAutoHide) {
                model.toggleDockAutoHide()
            }
            toggleRow("G", "Dock magnification", on: settings.dockMagnification) {
                model.toggleDockMagnification()
            }
            cycleRow("S", "Scroll bars", value: settings.scrollBars.title) {
                model.cycleScrollBars()
            }
            positionSection
            toggleRow("W", "Workspace bar", on: model.workspaceBarEnabled) {
                model.toggleWorkspaceBar()
            }
            toggleRow("E", "Window borders", on: model.windowBordersEnabled) {
                model.toggleWindowBorders()
            }
            toggleRow("O", "Cross-display overflow", on: model.crossMonitorOverflowEnabled) {
                model.toggleCrossMonitorOverflow()
            }
            cycleRow("Z", "Viewport zoom", value: model.viewportZoomLabel) {
                model.cycleViewportZoomAction()
            }
        }
        .frame(width: 320, alignment: .leading)
    }

    private func toggleRow(
        _ key: String,
        _ label: String,
        on: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                keyCap(key)
                Text(label)
                    .font(.callout.weight(.medium))
                Spacer(minLength: 0)
                Text(on ? "On" : "Off")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(on ? .primary : .secondary)
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .frame(maxWidth: .infinity)
            .background(fill(active: on))
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// A row whose control cycles through named values (rather than on/off) — the trailing
    /// text shows the current value; tapping / pressing the key advances it.
    private func cycleRow(
        _ key: String,
        _ label: String,
        value: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                keyCap(key)
                Text(label)
                    .font(.callout.weight(.medium))
                Spacer(minLength: 0)
                Text(value)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .frame(maxWidth: .infinity)
            .background(fill(active: false))
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var positionSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("DOCK POSITION")
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(.tertiary)
            HStack(spacing: 6) {
                positionChip("B", .bottom)
                positionChip("L", .left)
                positionChip("R", .right)
            }
        }
    }

    private func positionChip(_ key: String, _ position: DockPosition) -> some View {
        let active = settings.dockPosition == position
        return Button {
            model.setDockPosition(position)
        } label: {
            VStack(spacing: 2) {
                Text(key)
                    .font(.system(.caption2, design: .monospaced).weight(.semibold))
                    .foregroundStyle(active ? .white : .secondary)
                Text(position.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(active ? .white : .primary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(fill(active: active))
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func keyCap(_ text: String) -> some View {
        Text(text)
            .font(.system(.caption2, design: .monospaced).weight(.semibold))
            .frame(minWidth: 18)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.quaternary))
    }

    private func fill(active: Bool) -> some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(active ? Color.accentColor.opacity(0.85) : Color.primary.opacity(0.07))
    }
}
