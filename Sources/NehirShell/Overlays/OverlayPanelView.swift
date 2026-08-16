// SPDX-FileCopyrightText: 2026 Steven Velozo
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import AppKit
import QuickLookThumbnailing
import SwiftUI

/// Loads a QuickLook thumbnail for one file, falling back to its Finder icon.
/// Native and async so the grid stays responsive; the JavaScript host never sees
/// a byte of file content.
@MainActor
final class OverlayThumbnail: ObservableObject {
    @Published var image: NSImage?

    private let url: URL
    private let pixels: CGFloat
    private var started = false

    init(url: URL, pixels: CGFloat) {
        self.url = url
        self.pixels = pixels
    }

    func load() {
        guard !started else { return }
        started = true
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: pixels, height: pixels),
            scale: scale,
            representationTypes: .thumbnail
        )
        let path = url.path
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
            let produced = representation?.nsImage ?? NSWorkspace.shared.icon(forFile: path)
            Task { @MainActor [weak self] in self?.image = produced }
        }
    }
}

/// One draggable cell: thumbnail plus a truncated name. The whole cell is a
/// native drag source carrying the file URL, so it drops into any window as the
/// real file.
private struct OverlayCell: View {
    let item: OverlayItem
    let pixels: CGFloat
    let behavior: OverlayItemBehavior
    let isSelected: Bool
    let onSelect: () -> Void
    let onActivate: (OverlayItem) -> Void

    @StateObject private var thumbnail: OverlayThumbnail

    init(
        item: OverlayItem,
        pixels: CGFloat,
        behavior: OverlayItemBehavior,
        isSelected: Bool,
        onSelect: @escaping () -> Void,
        onActivate: @escaping (OverlayItem) -> Void
    ) {
        self.item = item
        self.pixels = pixels
        self.behavior = behavior
        self.isSelected = isSelected
        self.onSelect = onSelect
        self.onActivate = onActivate
        _thumbnail = StateObject(wrappedValue: OverlayThumbnail(url: item.url, pixels: pixels))
    }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.accentColor.opacity(0.35) : .black.opacity(0.18))
                if let image = thumbnail.image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: pixels, maxHeight: pixels)
                        .cornerRadius(6)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: pixels + 16, height: pixels + 16)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.accentColor, lineWidth: isSelected ? 2.5 : 0)
            )
            .shadow(color: .black.opacity(0.25), radius: 4, y: 2)

            Text(item.displayName)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: pixels + 16)
        }
        .onAppear { thumbnail.load() }
        .onTapGesture(count: 2) { onActivate(item) }
        .onTapGesture(count: 1) { onSelect() }
        .onDrag { dragItem() }
    }

    private func dragItem() -> NSItemProvider {
        guard behavior.drag == .fileURL else { return NSItemProvider() }
        return NSItemProvider(contentsOf: item.url) ?? NSItemProvider(object: item.url as NSURL)
    }
}

/// The overlay's content: a titleless material panel with a scrolling grid of
/// resolved items (or an empty-state line). Presentation intent (thumbnail size,
/// layout) comes from the spec; exact geometry is the panel's.
struct OverlayPanelView: View {
    let title: String
    let presentation: OverlayPresentation
    let items: [OverlayItem]
    let behavior: OverlayItemBehavior
    let onActivate: (OverlayItem) -> Void
    var onSelect: (OverlayItem) -> Void = { _ in }
    var onClose: () -> Void = {}
    var onResize: (CGSize, Bool) -> Void = { _, _ in }
    /// Controller-owned selection so clicks and arrow keys stay in sync.
    var selectedID: String?

    private var pixels: CGFloat {
        switch presentation.thumb {
        case .small: 64
        case .medium: 96
        case .large: 128
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if presentation.chrome.titleBar {
                OverlayTitleBar(chrome: presentation.chrome, onClose: onClose)
            }
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.12), lineWidth: 1))
        .overlay(alignment: .bottomTrailing) {
            if presentation.resizable {
                ResizeGrip(onResize: onResize).padding(4)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            // In-content title only when there's no title bar showing it already.
            if !presentation.chrome.titleBar, !title.isEmpty {
                Text(title)
                    .font(.headline)
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 8)
            }
            if items.isEmpty {
                Spacer()
                Text("Nothing to show")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: pixels + 28), spacing: 18)],
                        spacing: 18
                    ) {
                        ForEach(items) { item in
                            OverlayCell(
                                item: item,
                                pixels: pixels,
                                behavior: behavior,
                                isSelected: item.id == selectedID,
                                onSelect: { onSelect(item) },
                                onActivate: onActivate
                            )
                        }
                    }
                    .padding(20)
                }
            }
        }
    }
}
