// SPDX-FileCopyrightText: 2026 Steven Velozo
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import SwiftUI

/// The Configure flow's edit screen for one window: choose a forced column min-width
/// (percent presets 1–7, N clears), toggle always-float (F), switch window/app scope
/// (S), or remove the rule (X). Every change applies live — the model persists and
/// re-lays-out — so this is a settings surface, not a form; Esc backs to the window list.
struct DeckConfigureEditView: View {
    let model: DeckModel

    private var rule: WindowConfigRule? {
        model.configureRule
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title = model.configureTarget?.title {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            scopeRow
            widthSection
            HStack(spacing: 8) {
                floatChip
                removeChip
            }
        }
        .frame(width: 340, alignment: .leading)
    }

    private var scopeRow: some View {
        let titleScoped = rule?.isTitleScoped ?? true
        return Button {
            model.setConfigureTitleScoped(!titleScoped)
        } label: {
            HStack(spacing: 8) {
                keyCap("S")
                sectionLabel("Scope")
                Spacer(minLength: 0)
                Text(titleScoped ? "This window" : "This app")
                    .font(.callout.weight(.medium))
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .frame(maxWidth: .infinity)
            .background(fill(active: false))
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var widthSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            sectionLabel("Min column width")
            HStack(spacing: 6) {
                ForEach(Array(DeckCatalog.widthPercents.enumerated()), id: \.offset) { index, percent in
                    presetChip(
                        key: String(index + 1),
                        text: "\(Int(percent))%",
                        active: rule?.minWidthPercent == percent
                    ) { model.setConfigureWidth(percent) }
                }
                presetChip(key: "N", text: "None", active: rule?.minWidthPercent == nil) {
                    model.setConfigureWidth(nil)
                }
            }
        }
    }

    private var floatChip: some View {
        let on = rule?.alwaysFloat == true
        return Button {
            model.toggleConfigureFloat()
        } label: {
            HStack(spacing: 8) {
                keyCap("F")
                Text("Float")
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

    private var removeChip: some View {
        Button {
            model.clearConfigure()
        } label: {
            HStack(spacing: 8) {
                keyCap("X")
                Text("Remove")
                    .font(.callout.weight(.medium))
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(fill(active: false))
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func presetChip(
        key: String,
        text: String,
        active: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text(key)
                    .font(.system(.caption2, design: .monospaced).weight(.semibold))
                    .foregroundStyle(active ? .white : .secondary)
                Text(text)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(active ? .white : .primary)
            }
            .frame(width: 38, height: 40)
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

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(.tertiary)
    }

    private func fill(active: Bool) -> some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(active ? Color.accentColor.opacity(0.85) : Color.primary.opacity(0.07))
    }
}
