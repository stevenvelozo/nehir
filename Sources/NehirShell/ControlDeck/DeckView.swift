// SPDX-FileCopyrightText: 2026 Steven Velozo
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import SwiftUI

/// The Control Deck HUD. Root reads by function: a wide Columns button (drill-in),
/// then a labeled row of square chips per group — Focus and Move each on their own
/// row. The Columns drill-in lists each column's number and window title. Every chip
/// is a real button, so touch/click drives the same `activate` path as the keyboard.
struct DeckView: View {
    let model: DeckModel
    let gridColumns: Int
    let gridRows: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.mode.id != .root { header }
            content
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
    }

    @ViewBuilder private var content: some View {
        switch model.mode.id {
        case .resizeGrid:
            DeckResizeGrid(model: model, columns: gridColumns, rows: gridRows)
        case .columns,
             .floating:
            pickList
        case .configurePick:
            configurePickList
        case .configureEdit:
            DeckConfigureEditView(model: model)
        case .display:
            DeckDisplayView(model: model)
        case .layout:
            DeckLayoutView(model: model)
        case .root:
            rootLayout
        default:
            submodeRow
        }
    }

    // MARK: - Root

    private var rootLayout: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let columnsAction { wideButton(columnsAction, big: "1–10", small: "Columns") }
                if let floatingAction { wideButton(floatingAction, big: "V", small: "Floating") }
            }
            if !focusActions.isEmpty { labeledRow("Focus", focusActions) }
            if !moveActions.isEmpty { labeledRow("Move", moveActions) }
            if !layoutActions.isEmpty { labeledRow("Layout", layoutActions) }
            if !windowActions.isEmpty { labeledRow("Window", windowActions) }
            ForEach(extensionGroups, id: \.name) { group in
                extensionRow(group.name, group.actions)
            }
        }
        .frame(width: 320, alignment: .leading)
    }

    /// Registered pict-extension entries, grouped by their `group` label. Headless
    /// entries dispatch by key but draw no tile, so they're excluded here.
    private var extensionGroups: [(name: String, actions: [DeckAction])] {
        let entries = model.mode.actions.filter { action in
            if case .showOverlay = action.kind { return !action.isHeadless }
            return false
        }
        return Dictionary(grouping: entries, by: { $0.group ?? "Extensions" })
            .sorted { $0.key < $1.key }
            .map { (name: $0.key, actions: $0.value) }
    }

    private func extensionRow(_ label: String, _ actions: [DeckAction]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            HStack(spacing: 8) {
                ForEach(actions) { extensionChip($0) }
                Spacer(minLength: 0)
            }
        }
        .padding(.top, 2)
    }

    /// A wide chip for an extension: key on the left, name + optional live status.
    private func extensionChip(_ action: DeckAction) -> some View {
        Button {
            model.activate(action)
        } label: {
            HStack(spacing: 8) {
                Text(action.keyLabel)
                    .font(.system(.caption2, design: .monospaced).weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(action.title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    if let subtitle = action.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 38)
            .frame(maxWidth: 150)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.quaternary))
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func labeledRow(_ label: String, _ actions: [DeckAction]) -> some View {
        // Center the chip cluster on the popup's axis so every row's buttons line up
        // (matching the split between the two top buttons). The left label is a pinned
        // overlay, deliberately outside the centering.
        ZStack {
            HStack(spacing: 8) {
                ForEach(actions) { squareChip($0) }
            }
            .frame(maxWidth: .infinity)
            HStack {
                rowLabel(label)
                Spacer(minLength: 0)
            }
        }
    }

    private func rowLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(.tertiary)
            .frame(width: 46, alignment: .leading)
    }

    // MARK: - Drill-in list (Columns / Floating)

    private var pickList: some View {
        VStack(spacing: 5) {
            if model.pickItems.isEmpty {
                Text(model.mode.id == .floating ? "No floating windows" : "No columns on this workspace")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(model.pickItems) { pickRow($0) }
            }
        }
        .frame(width: 320)
    }

    private func pickRow(_ item: DeckPickItem) -> some View {
        numberedRow(item.label, item.title) { model.activatePick(item) }
    }

    private var configurePickList: some View {
        VStack(spacing: 5) {
            if model.configureTargets.isEmpty {
                Text("No windows on this workspace")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(model.configureTargets) { item in
                    numberedRow(item.label, item.title) { model.selectConfigureTarget(item) }
                }
            }
        }
        .frame(width: 320)
    }

    /// A numbered list row: number chip on the left, title on the right, whole-row tap.
    private func numberedRow(_ label: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(label)
                    .font(.system(.body, design: .rounded).weight(.bold))
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.quaternary))
                Text(title)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Submodes (width presets keep their % label)

    private var submodeRow: some View {
        // Wrap presets into rows of 4 so extra widths (e.g. 5/6) form a second row.
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(stride(from: 0, to: model.mode.actions.count, by: 4)), id: \.self) { start in
                HStack(spacing: 8) {
                    ForEach(Array(model.mode.actions[start ..< min(start + 4, model.mode.actions.count)])) {
                        labelChip($0)
                    }
                }
            }
        }
    }

    // MARK: - Chips

    /// Square key+glyph chip for root's directional and window rows.
    private func squareChip(_ action: DeckAction) -> some View {
        Button {
            model.activate(action)
        } label: {
            VStack(spacing: 3) {
                Text(action.keyLabel)
                    .font(.system(.caption2, design: .monospaced).weight(.semibold))
                    .foregroundStyle(.secondary)
                Image(systemName: action.symbol)
                    .font(.body)
            }
            .frame(width: 42, height: 42)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.quaternary))
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// Key over a short label — for submodes where the label carries meaning (25% …).
    private func labelChip(_ action: DeckAction) -> some View {
        Button {
            model.activate(action)
        } label: {
            VStack(spacing: 3) {
                Text(action.keyLabel)
                    .font(.system(.caption2, design: .monospaced).weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(action.title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(width: 52, height: 42)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.quaternary))
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// A wide reminder/entry button that opens a numbered drill-in (Columns / Floating).
    private func wideButton(_ action: DeckAction, big: String, small: String) -> some View {
        Button {
            model.activate(action)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: action.symbol)
                    .font(.footnote)
                Text(big)
                    .font(.callout.weight(.semibold))
                Text(small)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .frame(height: 38)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var header: some View {
        HStack {
            Text(model.mode.title)
                .font(.subheadline.weight(.semibold))
            Spacer()
            Text("esc to go back")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Root groupings (classified by key / kind)

    private var columnsAction: DeckAction? {
        model.mode.actions.first { isEnter($0, .columns) }
    }

    private var floatingAction: DeckAction? {
        model.mode.actions.first { isEnter($0, .floating) }
    }

    private var focusActions: [DeckAction] {
        model.mode.actions.filter { isFocusKey($0.key) }
    }

    private var moveActions: [DeckAction] {
        model.mode.actions.filter { isArrow($0.key) }
    }

    /// Layout ops — column arrangement (`w` width, `t` tile), the `d` Display pane, and
    /// the `e` layout-engine pane.
    private var layoutActions: [DeckAction] {
        model.mode.actions.filter { isCharacterKey($0.key, in: ["w", "t", "d", "e"]) }
    }

    /// Window ops — those that act on the focused window (window width `s`, resize `r`,
    /// float `f`, configure `g`).
    private var windowActions: [DeckAction] {
        model.mode.actions.filter { isCharacterKey($0.key, in: ["s", "r", "f", "g"]) }
    }

    private func isEnter(_ action: DeckAction, _ mode: DeckModeID) -> Bool {
        if case let .enterMode(id) = action.kind { return id == mode }
        return false
    }

    private func isArrow(_ key: DeckKey) -> Bool {
        switch key {
        case .arrowLeft,
             .arrowRight,
             .arrowUp,
             .arrowDown: true
        default: false
        }
    }

    private func isCharacterKey(_ key: DeckKey, in set: Set<Character>) -> Bool {
        if case let .character(character) = key { return set.contains(character) }
        return false
    }

    private func isFocusKey(_ key: DeckKey) -> Bool {
        isCharacterKey(key, in: ["h", "j", "k", "l"])
    }
}
