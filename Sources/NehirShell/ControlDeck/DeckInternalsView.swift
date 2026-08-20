// SPDX-FileCopyrightText: 2026 Steven Velozo
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import SwiftUI

/// One tiled window's engine runtime state, for the Advanced Internals pane. `anomalies` are the
/// suspicious learned/cached values worth clearing (a resize floor, a fixed-size verdict, a manual
/// width override); an empty list reads as healthy.
struct DeckInternalsRow: Identifiable {
    let id: Int          // window id — stable within a session
    let number: Int      // 1-based row number; press it to reset this window's tracked state
    let appName: String
    let detail: String   // always-shown dim summary (e.g. current column width), so the row reads live
    let anomalies: [String]   // engine-INFERRED, potentially-wrong state (orange): floor, fixed
    let notes: [String]       // user-INTENDED state (neutral): a manual width override

    var hasAnomaly: Bool { !anomalies.isEmpty }
}

/// The Advanced Internals pane: one row per tiled window showing the engine's per-window runtime
/// state, with anomalies highlighted and a numbered key to reset a stuck window's state (the same
/// per-window reset the `nehirctl … reset-focused-window-runtime` escape hatch performs).
struct DeckInternalsView: View {
    let model: DeckModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.internalsRows.isEmpty {
                Text("No tiled windows on this workspace")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                    .padding(.horizontal, 10)
            } else {
                ForEach(model.internalsRows) { row in
                    rowView(row)
                }
                Text("Press a number — or click a row — to reset its tracked state")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.top, 1)
            }
        }
        .frame(width: 380, alignment: .leading)
    }

    @ViewBuilder
    private func rowView(_ row: DeckInternalsRow) -> some View {
        Button {
            model.resetInternalsRowAction(row.number)
        } label: {
            HStack(spacing: 8) {
                keyCap(row.number == 10 ? "0" : String(row.number))
                Text(row.appName)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 6)
                ForEach(Array(row.anomalies.enumerated()), id: \.offset) { _, anomaly in
                    Text(anomaly)
                        .font(.system(.caption2, design: .monospaced).weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.orange.opacity(0.22)))
                        .foregroundStyle(.orange)
                }
                ForEach(Array(row.notes.enumerated()), id: \.offset) { _, note in
                    Text(note)
                        .font(.system(.caption2, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.secondary.opacity(0.16)))
                        .foregroundStyle(.secondary)
                }
                if !row.detail.isEmpty {
                    Text(row.detail)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(row.hasAnomaly ? Color.orange.opacity(0.12) : Color.primary.opacity(0.05))
            )
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
}
