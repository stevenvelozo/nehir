// SPDX-FileCopyrightText: 2026 Steven Velozo
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import AppKit
import Quartz

/// Drives the system Quick Look panel to preview the selected grid item in place
/// (Space / Cmd-Y), so browsing files in an overlay feels like the Finder without
/// switching to it.
@MainActor
final class OverlayQuickLook: NSObject, @preconcurrency QLPreviewPanelDataSource,
    @preconcurrency QLPreviewPanelDelegate
{
    private var urls: [URL] = []

    var isVisible: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && (QLPreviewPanel.shared()?.isVisible ?? false)
    }

    func preview(_ url: URL) {
        urls = [url]
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.delegate = self
        if isVisible {
            panel.reloadData()
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    func numberOfPreviewItems(in _: QLPreviewPanel!) -> Int {
        urls.count
    }

    func previewPanel(_: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        urls.indices.contains(index) ? (urls[index] as NSURL) : nil
    }
}
