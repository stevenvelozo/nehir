// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import Foundation

extension NiriLayoutEngine {
    func persistedPlacements(in workspaceId: WorkspaceDescriptor.ID) -> [WindowToken: PersistedNiriPlacement] {
        let columns = columns(in: workspaceId)
        guard !columns.isEmpty else { return [:] }

        var placements: [WindowToken: PersistedNiriPlacement] = [:]
        placements.reserveCapacity(columns.reduce(0) { $0 + $1.windowNodes.count })

        for (columnIndex, column) in columns.enumerated() {
            let columnState = PersistedNiriColumnState(
                displayMode: column.displayMode,
                activeTileIndex: column.activeTileIdx,
                width: column.width,
                presetWidthIndex: column.presetWidthIdx,
                isFullWidth: column.isFullWidth,
                savedWidth: column.savedWidth,
                hasManualSingleWindowWidthOverride: column.hasManualSingleWindowWidthOverride
            )

            for (tileIndex, window) in column.windowNodes.enumerated() {
                placements[window.token] = PersistedNiriPlacement(
                    columnIndex: columnIndex,
                    tileIndex: tileIndex,
                    column: columnState,
                    window: PersistedNiriWindowState(
                        sizingMode: window.sizingMode,
                        height: window.height,
                        savedHeight: window.savedHeight,
                        windowWidth: window.windowWidth
                    ),
                    columnGroupId: column.id.uuid
                )
            }
        }

        return placements
    }

    @discardableResult
    func restoreInitialPlacements(
        _ placements: [WindowToken: PersistedNiriPlacement],
        matching tokens: [WindowToken],
        soloColumnTokens: Set<WindowToken> = [],
        in workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        guard !placements.isEmpty, !tokens.isEmpty else { return false }

        let root = ensureRoot(for: workspaceId)
        let currentTokens = root.windowIdSet
        let placedTokens = Set(tokens.compactMap { token -> WindowToken? in
            guard let placement = placements[token],
                  placement.columnIndex >= 0,
                  placement.tileIndex >= 0
            else {
                return nil
            }
            return token
        })
        let missingPlacedTokens = placedTokens.subtracting(currentTokens)
        guard !placedTokens.isEmpty, !missingPlacedTokens.isEmpty else { return false }
        guard currentTokens.isEmpty || currentTokens.isSubset(of: placedTokens) else { return false }

        removeEmptyColumnsIfWorkspaceEmpty(in: root)

        var tokenOrder: [WindowToken: Int] = [:]
        tokenOrder.reserveCapacity(tokens.count)
        for (index, token) in tokens.enumerated() where tokenOrder[token] == nil {
            tokenOrder[token] = index
        }

        // Group by COLUMN IDENTITY (the persisted container id) rather than the bare positional
        // columnIndex. Two windows that were independent columns carry different group ids and are
        // NEVER merged — even when their columnIndex collides across save snapshots (the
        // multi-window stacking bug: two Screen Sharing windows crushed into one half-height
        // column). Windows the user deliberately stacked into one column share a group id and stay
        // together. Placements saved before group ids existed have a nil id and fall back to
        // columnIndex grouping, so an already-stacked pair stays put until manually un-stacked.
        var groups: [String: [(token: WindowToken, placement: PersistedNiriPlacement)]] = [:]
        var groupColumnIndex: [String: Int] = [:]
        for token in tokens {
            guard placedTokens.contains(token), let placement = placements[token] else { continue }
            let key = placement.columnGroupId?.uuidString ?? "idx:\(placement.columnIndex)"
            groups[key, default: []].append((token, placement))
            groupColumnIndex[key] = min(groupColumnIndex[key] ?? Int.max, placement.columnIndex)
        }

        guard !groups.isEmpty else { return false }

        var reusableNodes: [WindowToken: NiriWindow] = [:]
        reusableNodes.reserveCapacity(currentTokens.count)
        for window in root.allWindows {
            reusableNodes[window.token] = window
        }

        for window in reusableNodes.values {
            window.detach()
        }
        removeEmptyColumnsIfWorkspaceEmpty(in: root)

        // Left-to-right order: by each group's original columnIndex, then a stable tiebreak (its
        // earliest window) so two independent columns that collided on one index stay adjacent.
        let orderedGroupKeys = groups.keys.sorted { lhs, rhs in
            let li = groupColumnIndex[lhs] ?? Int.max
            let ri = groupColumnIndex[rhs] ?? Int.max
            if li != ri { return li < ri }
            let lt = groups[lhs]?.compactMap { tokenOrder[$0.token] }.min() ?? Int.max
            let rt = groups[rhs]?.compactMap { tokenOrder[$0.token] }.min() ?? Int.max
            return lt < rt
        }

        // Within each group, honor the per-app soloColumn escape hatch: a solo-column window is
        // never stacked with siblings even if they somehow share a group id.
        for groupKey in orderedGroupKeys {
            let groupedPlacements = groups[groupKey, default: []].sorted { lhs, rhs in
                if lhs.placement.tileIndex != rhs.placement.tileIndex {
                    return lhs.placement.tileIndex < rhs.placement.tileIndex
                }
                return (tokenOrder[lhs.token] ?? Int.max) < (tokenOrder[rhs.token] ?? Int.max)
            }
            guard !groupedPlacements.isEmpty else { continue }

            var pending: [(token: WindowToken, placement: PersistedNiriPlacement)] = []
            func flushPending() {
                guard let seed = pending.first else { return }
                let column = NiriContainer()
                applyPersistedColumnState(seed.placement.column, to: column)
                root.appendChild(column)
                for groupedPlacement in pending {
                    let window = reusableNodes[groupedPlacement.token] ?? NiriWindow(token: groupedPlacement.token)
                    applyPersistedWindowState(groupedPlacement.placement.window, to: window)
                    column.appendChild(window)
                    tokenToNode[groupedPlacement.token] = window
                }
                column.setActiveTileIdx(min(seed.placement.column.activeTileIndex, pending.count - 1))
                updateTabbedColumnVisibility(column: column)
                pending.removeAll(keepingCapacity: true)
            }

            for groupedPlacement in groupedPlacements {
                if soloColumnTokens.contains(groupedPlacement.token) {
                    flushPending() // close any accumulated non-solo column first
                    pending = [groupedPlacement]
                    flushPending() // the solo window is its own column
                } else {
                    pending.append(groupedPlacement)
                }
            }
            flushPending()
        }

        return true
    }

    private func applyPersistedColumnState(_ state: PersistedNiriColumnState, to column: NiriContainer) {
        column.displayMode = state.displayMode
        column.width = state.width
        column.presetWidthIdx = state.presetWidthIndex
        column.isFullWidth = state.isFullWidth
        column.savedWidth = state.savedWidth
        column.hasManualSingleWindowWidthOverride = state.hasManualSingleWindowWidthOverride
        column.cachedWidth = 0
        column.widthAnimation = nil
        column.targetWidth = nil
    }

    private func applyPersistedWindowState(_ state: PersistedNiriWindowState, to window: NiriWindow) {
        window.sizingMode = state.sizingMode
        window.height = state.height
        window.savedHeight = state.savedHeight
        window.windowWidth = state.windowWidth
        window.resolvedHeight = nil
        window.resolvedWidth = nil
        window.heightFixedByConstraint = false
        window.widthFixedByConstraint = false
        window.isHiddenInTabbedMode = false
    }
}
