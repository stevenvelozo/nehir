// SPDX-FileCopyrightText: 2026 Steven Velozo
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

@testable import Nehir
import SwiftUI

/// The layout-engine pane: pick the global layout family. River is the scrolling column
/// layout; Blades overlaps those same columns distributed edge-to-edge; Free floats every
/// window. The active family is checked; selecting one applies it live (Esc backs out).
struct DeckLayoutView: View {
    let model: DeckModel

    private struct Option {
        let key: String
        let mode: NehirLayoutMode
        let title: String
        let subtitle: String
        let symbol: String
    }

    private let options: [Option] = [
        Option(key: "R", mode: .river, title: "River", subtitle: "Scrolling columns", symbol: "water.waves"),
        Option(
            key: "B",
            mode: .blades,
            title: "Blades",
            subtitle: "Overlapping, edge to edge",
            symbol: "rectangle.stack"
        ),
        Option(key: "F", mode: .free, title: "Free", subtitle: "Everything floats", symbol: "macwindow.on.rectangle")
    ]

    var body: some View {
        VStack(spacing: 6) {
            ForEach(options, id: \.key) { optionRow($0) }
        }
        .frame(width: 320)
    }

    private func optionRow(_ option: Option) -> some View {
        let active = model.layoutMode == option.mode
        return Button {
            model.setLayoutEngine(option.mode)
        } label: {
            HStack(spacing: 10) {
                keyCap(option.key)
                Image(systemName: option.symbol)
                    .font(.body)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.title)
                        .font(.callout.weight(.semibold))
                    Text(option.subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if active {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 42)
            .frame(maxWidth: .infinity)
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
