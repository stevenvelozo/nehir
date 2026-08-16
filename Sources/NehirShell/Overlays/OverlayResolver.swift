// SPDX-FileCopyrightText: 2026 Steven Velozo
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import Darwin
import Foundation
import UniformTypeIdentifiers

/// One resolved entry an overlay shows. `id` is the file path so SwiftUI can
/// diff a grid across refreshes; `url` drives thumbnailing and the drag-out.
struct OverlayItem: Identifiable, Hashable {
    let id: String
    let url: URL
    let displayName: String
}

/// Turns a declarative `fileQuery` source into concrete items, entirely in
/// native code — pict decides *what*, this decides *which files*. Directory
/// enumeration, type/name filtering, sorting, and the limit all live here so no
/// filesystem work crosses into the JavaScript host.
enum OverlayResolver {
    static func resolve(_ source: OverlaySource) -> [OverlayItem] {
        switch source.kind {
        case .fileQuery: return resolveFileQuery(source)
        case .items: return resolveItems(source)
        case .webview,
             .unknown: return []
        }
    }

    /// A provider-supplied explicit list: map each entry to an item, keeping the
    /// provider's order (it already decided "what"), applying only the limit.
    private static func resolveItems(_ source: OverlaySource) -> [OverlayItem] {
        let mapped = source.items.compactMap { entry -> OverlayItem? in
            guard !entry.path.isEmpty else { return nil }
            let url = URL(fileURLWithPath: (entry.path as NSString).expandingTildeInPath)
            return OverlayItem(id: url.path, url: url, displayName: entry.name ?? url.lastPathComponent)
        }
        return source.limit > 0 ? Array(mapped.prefix(source.limit)) : mapped
    }

    private static func resolveFileQuery(_ source: OverlaySource) -> [OverlayItem] {
        let keys: Set<URLResourceKey> = [
            .contentModificationDateKey, .isRegularFileKey, .localizedNameKey, .contentTypeKey
        ]
        var collected: [(url: URL, modified: Date, name: String)] = []

        for root in source.resolvedRoots {
            let entries = (try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            )) ?? []

            for url in entries {
                let values = try? url.resourceValues(forKeys: keys)
                if values?.isRegularFile == false { continue }
                if !passesTypeFilter(values?.contentType, source.filter.uti) { continue }
                if let glob = source.filter.nameGlob, !matchesGlob(glob, url.lastPathComponent) { continue }

                collected.append((
                    url: url,
                    modified: values?.contentModificationDate ?? .distantPast,
                    name: values?.localizedName ?? url.lastPathComponent
                ))
            }
        }

        sort(&collected, by: source.sort)
        let limited = source.limit > 0 ? Array(collected.prefix(source.limit)) : collected
        return limited.map { OverlayItem(id: $0.url.path, url: $0.url, displayName: $0.name) }
    }

    /// True when there is no type restriction, or the file's content type conforms
    /// to any of the requested UTIs (e.g. `public.image`).
    private static func passesTypeFilter(_ type: UTType?, _ wanted: [String]) -> Bool {
        guard !wanted.isEmpty else { return true }
        guard let type else { return false }
        return wanted.contains { identifier in
            guard let target = UTType(identifier) else { return false }
            return type.conforms(to: target)
        }
    }

    /// Case-insensitive shell-glob match on the filename via `fnmatch`.
    private static func matchesGlob(_ pattern: String, _ name: String) -> Bool {
        pattern.withCString { patternPointer in
            name.withCString { namePointer in
                fnmatch(patternPointer, namePointer, FNM_CASEFOLD) == 0
            }
        }
    }

    private static func sort(_ items: inout [(url: URL, modified: Date, name: String)], by order: OverlaySort) {
        switch order {
        case .modifiedDesc: items.sort { $0.modified > $1.modified }
        case .modifiedAsc: items.sort { $0.modified < $1.modified }
        case .nameAsc: items.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .nameDesc: items.sort { $0.name.localizedStandardCompare($1.name) == .orderedDescending }
        }
    }
}
