// SPDX-FileCopyrightText: 2026 Steven Velozo
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import AppKit
import WebKit

/// A borderless panel that *can* become key, for the interactive webview overlay:
/// unlike the grid's non-activating panel, a web app needs keyboard focus to be
/// usable, so this one takes focus (the app is activated alongside it) and reports
/// Esc (`cancelOperation`) and losing focus (`resignKey`) back to the controller
/// for dismissal.
final class OverlayKeyPanel: NSPanel {
    var onEsc: (() -> Void)?
    var onResignKey: (() -> Void)?

    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        true
    }

    override func cancelOperation(_: Any?) {
        onEsc?()
    }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }

    /// ⌘W closes the panel even when a subview is swallowing ordinary keystrokes
    /// — e.g. an embedded terminal that (correctly) captures Esc for fzf/vim.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "w" {
            onEsc?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Builds and configures the panel + web view for a webview overlay. The web view
/// itself is warm-cached by the controller (created once, reused across summons)
/// so re-summoning is instant and keeps page state; only the lightweight panel is
/// rebuilt each time and re-adopts the cached view.
/// Bridges `window.webkit.messageHandlers.nehir.postMessage({...})` from a webview
/// overlay back to the shell. The page posts a JSON action (today: a run request);
/// the controller wired into `onAction` decides what to do with it. Holding the
/// callback (rather than the controller) keeps this free of a retain cycle.
@MainActor
final class OverlayWebBridge: NSObject, @preconcurrency WKScriptMessageHandler {
    var onAction: ([String: Any]) -> Void = { _ in }

    func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        onAction(body)
    }
}

enum OverlayWebPanel {
    static func makeWebView(bridge: OverlayWebBridge? = nil) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        if let bridge {
            configuration.userContentController.add(bridge, name: "nehir")
        }
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.autoresizingMask = [.width, .height]
        return webView
    }

    /// Resolve a webview overlay URL. A `nehir-resource://<file>` URL maps to a
    /// page bundled with the shell (e.g. the tool-runner); everything else is a
    /// plain http/https or file URL.
    private static func resolve(_ urlString: String) -> URL? {
        let scheme = "nehir-resource://"
        if urlString.hasPrefix(scheme) {
            let name = String(urlString.dropFirst(scheme.count))
            let base = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            return Bundle.module.url(forResource: base, withExtension: ext)
        }
        return URL(string: urlString)
    }

    /// Load `url` into `webView` only if it differs from what it last loaded, so a
    /// warm re-summon doesn't reload (and lose scroll/state). Returns the URL it
    /// settled on so the caller can track it.
    @discardableResult
    static func load(_ urlString: String?, into webView: WKWebView, lastLoaded: URL?) -> URL? {
        guard let urlString, let url = resolve(urlString) else { return lastLoaded }
        guard url != lastLoaded else { return lastLoaded }
        if url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.load(URLRequest(url: url))
        }
        return url
    }

    static func makePanel(frame: CGRect) -> OverlayKeyPanel {
        let panel = OverlayKeyPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .stationary]
        return panel
    }
}
