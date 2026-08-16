// SPDX-FileCopyrightText: 2026 Steven Velozo
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import AppKit
import SwiftUI
import WebKit

/// A single key-cap in the Deck's rounded visual language.
private struct KeyCap: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6).fill(.black.opacity(0.28)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(0.28), lineWidth: 1))
            .fixedSize()
    }
}

/// A compact hotkey quick-reference pane: key-cap + label rows.
struct QuickRefView: View {
    let title: String?
    let keys: [OverlayHelpKey]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title, !title.isEmpty {
                Text(title)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.top, 14)
                    .padding(.bottom, 8)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(keys.indices, id: \.self) { index in
                        HStack(spacing: 10) {
                            KeyCap(text: keys[index].key)
                            Text(keys[index].label)
                                .font(.system(size: 12))
                                .foregroundStyle(.primary)
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, title == nil ? 14 : 0)
                .padding(.bottom, 14)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.12), lineWidth: 1))
    }
}

/// Owns a web view that renders a prose help pane via the vendored
/// pict-section-content bundle (its `parseMarkdown` + CSS). Loads the bundled
/// host page, then pushes the markdown/HTML in once it's ready; routes link
/// clicks either to the system browser or lets the pane navigate in place.
@MainActor
final class ProseHelpWebView: NSObject, @preconcurrency WKNavigationDelegate, @preconcurrency WKScriptMessageHandler {
    let webView: WKWebView
    private let pane: OverlayHelpPane

    init(pane: OverlayHelpPane) {
        self.pane = pane
        let configuration = WKWebViewConfiguration()
        let userContent = WKUserContentController()
        configuration.userContentController = userContent
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        userContent.add(self, name: "nehirLink")
        webView.navigationDelegate = self
        load()
    }

    private func load() {
        // A url pane loads directly; markdown/html panes use the bundled host page.
        if let urlText = pane.url, let url = URL(string: urlText) {
            if url.isFileURL {
                webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            } else {
                webView.load(URLRequest(url: url))
            }
            return
        }
        guard let host = Bundle.module.url(forResource: "content-host", withExtension: "html") else { return }
        webView.loadFileURL(host, allowingReadAccessTo: host.deletingLastPathComponent())
    }

    func webView(_: WKWebView, didFinish _: WKNavigation!) {
        guard pane.url == nil else { return } // url panes render themselves
        webView.evaluateJavaScript("nehirSetLinks(\(Self.jsString(pane.links == .inPane ? "in-pane" : "browser")))")
        if let html = pane.html {
            webView.evaluateJavaScript("nehirRenderHTML(\(Self.jsString(html)))")
        } else {
            webView.evaluateJavaScript("nehirRender(\(Self.jsString(pane.markdown ?? "")))")
        }
    }

    func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "nehirLink",
              let href = message.body as? String,
              let url = URL(string: href), url.scheme != nil
        else { return }
        NSWorkspace.shared.open(url)
    }

    /// JSON-encode a Swift string into a safe JS string literal.
    static func jsString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let array = String(data: data, encoding: .utf8)
        else { return "\"\"" }
        return String(array.dropFirst().dropLast()) // strip the surrounding [ ]
    }
}
