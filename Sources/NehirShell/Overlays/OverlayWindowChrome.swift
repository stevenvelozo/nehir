// SPDX-FileCopyrightText: 2026 Steven Velozo
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import AppKit
import SwiftUI

/// A transparent region that moves its host panel when dragged. Used as the title
/// bar's background so *only* the title bar moves the window — the content below
/// keeps its own click/drag behavior (dragging a grid cell still drags the file).
struct WindowMoveHandle: NSViewRepresentable {
    func makeNSView(context _: Context) -> NSView {
        MoveView()
    }

    func updateNSView(_: NSView, context _: Context) {}

    private final class MoveView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}

/// A slim title bar: drag-to-move background, a title, and an optional close
/// button. Sits above the overlay's content when `chrome.titleBar` is on.
struct OverlayTitleBar: View {
    let chrome: OverlayChrome
    let onClose: () -> Void

    var body: some View {
        ZStack {
            WindowMoveHandle()
            HStack(spacing: 8) {
                if chrome.close {
                    Button(action: onClose) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Close")
                }
                Text(chrome.title ?? "")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
        }
        .frame(height: 28)
        .background(.black.opacity(0.12))
    }
}

/// A bottom-right resize grip. Reports the cumulative drag translation (and a
/// final flag on release) so the controller can live-resize the panel.
struct ResizeGrip: View {
    let onResize: (CGSize, Bool) -> Void

    var body: some View {
        Image(systemName: "arrow.down.right")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.secondary)
            .frame(width: 18, height: 18)
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { value in onResize(value.translation, false) }
                    .onEnded { value in onResize(value.translation, true) }
            )
    }
}
