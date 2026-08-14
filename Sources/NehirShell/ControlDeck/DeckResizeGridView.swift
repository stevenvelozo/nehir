// SPDX-FileCopyrightText: 2026 Steven Velozo
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import SwiftUI

/// The resize submode's grid. Pick any rectangle by **keyboard** (arrows move the
/// cursor, space anchors the first corner, space/enter commits) or **mouse/touch**
/// (drag). Both drive the model's cursor/anchor, so the highlight is one source of
/// truth. Digit/letter quick-presets (1–4, C, M) still apply instantly.
struct DeckResizeGrid: View {
    let model: DeckModel
    let columns: Int
    let rows: Int

    private let gridWidth: CGFloat = 320

    @State private var dragging = false

    var body: some View {
        VStack(spacing: 10) {
            GeometryReader { geometry in
                let cellWidth = geometry.size.width / CGFloat(columns)
                let cellHeight = geometry.size.height / CGFloat(rows)
                ZStack(alignment: .topLeading) {
                    ForEach(0 ..< rows, id: \.self) { row in
                        ForEach(0 ..< columns, id: \.self) { column in
                            cellView(column: column, row: row)
                                .frame(width: cellWidth - 3, height: cellHeight - 3)
                                .offset(x: CGFloat(column) * cellWidth + 1.5, y: CGFloat(row) * cellHeight + 1.5)
                        }
                    }
                }
                // The cells are placed with `.offset`, which positions them visually but
                // leaves the ZStack sized to a single cell — pin it to the full grid so
                // the whole area is draggable, not just the top-left cell.
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let cell = cell(at: value.location, cellWidth: cellWidth, cellHeight: cellHeight)
                            if dragging {
                                model.dragResizeCursor(to: cell)
                            } else {
                                dragging = true
                                model.beginResizeDrag(at: cell)
                            }
                        }
                        .onEnded { _ in
                            dragging = false
                            model.commitResizeSelection()
                        }
                )
            }
            .frame(width: gridWidth, height: gridWidth * CGFloat(rows) / CGFloat(columns))

            Text("arrows move · space set corner · enter apply · or drag · 1–4 quarters · C center · M max")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private func cellView(column: Int, row: Int) -> some View {
        let selected = isSelected(column, row)
        let isCursor = column == model.resizeCursor.column && row == model.resizeCursor.row
        return RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(selected ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.08))
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: isCursor ? 2 : 0)
            )
    }

    private func isSelected(_ column: Int, _ row: Int) -> Bool {
        let cursor = model.resizeCursor
        guard let anchor = model.resizeAnchor else {
            return column == cursor.column && row == cursor.row
        }
        return column >= min(anchor.column, cursor.column)
            && column <= max(anchor.column, cursor.column)
            && row >= min(anchor.row, cursor.row)
            && row <= max(anchor.row, cursor.row)
    }

    private func cell(at point: CGPoint, cellWidth: CGFloat, cellHeight: CGFloat) -> GridCell {
        GridCell(
            column: min(max(Int(point.x / cellWidth), 0), columns - 1),
            row: min(max(Int(point.y / cellHeight), 0), rows - 1)
        )
    }
}
