// SPDX-FileCopyrightText: 2026 Steven Velozo
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import Foundation

/// The pict→native contract: what a registered overlay provider returns when
/// pulled. A *content query plus presentation intent* — never pixels. Decoded
/// from the JavaScript object the provider returns, so every field is optional
/// with a sensible default; a provider can emit only the keys it cares about.
///
/// `source.kind` keeps the primitive general: `fileQuery` (this phase) is a
/// declarative directory query resolved natively; `items` (later) is an explicit
/// list the provider built itself; `webview` (later) is a URL surface.
struct OverlaySpec: Decodable {
    var source: OverlaySource
    var present: OverlayPresentation
    var item: OverlayItemBehavior
    var dismiss: OverlayDismiss
    var help: OverlayHelp?

    private enum CodingKeys: String, CodingKey {
        case source, present, item, dismiss, help
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        source = try container.decode(OverlaySource.self, forKey: .source)
        present = (try? container.decode(OverlayPresentation.self, forKey: .present)) ?? .init()
        item = (try? container.decode(OverlayItemBehavior.self, forKey: .item)) ?? .init()
        dismiss = (try? container.decode(OverlayDismiss.self, forKey: .dismiss)) ?? .init()
        help = try? container.decode(OverlayHelp.self, forKey: .help)
    }
}

/// Config-driven help for an overlay: a toggle key that shows/hides one or more
/// docked panes (a hotkey quick-reference and/or prose rendered by
/// pict-section-content).
struct OverlayHelp: Decodable {
    var toggle: String
    var panes: [OverlayHelpPane]

    private enum CodingKeys: String, CodingKey { case toggle, panes }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        toggle = (try? container.decode(String.self, forKey: .toggle)) ?? "f1"
        panes = (try? container.decode([OverlayHelpPane].self, forKey: .panes)) ?? []
    }
}

struct OverlayHelpKey: Decodable {
    var key: String
    var label: String

    init(key: String, label: String) {
        self.key = key
        self.label = label
    }

    private enum CodingKeys: String, CodingKey { case key, label }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = (try? container.decode(String.self, forKey: .key)) ?? ""
        label = (try? container.decode(String.self, forKey: .label)) ?? ""
    }
}

struct OverlayHelpPane: Decodable {
    enum Kind: String { case quickref, prose, unknown }
    enum Position: String { case left, right, above, below, custom }
    enum Links: String { case browser, inPane }

    var kind: Kind
    var position: Position
    /// Thickness of the pane (width for left/right, height for above/below).
    /// "%" of the overlay's matching dimension, or a pixel number.
    var size: String?
    var title: String?
    // quickref
    var keys: [OverlayHelpKey]
    var auto: Bool
    // prose
    var markdown: String?
    var html: String?
    var url: String?
    var links: Links
    // custom position
    var x: String?
    var y: String?
    var width: String?
    var height: String?

    private enum CodingKeys: String, CodingKey {
        case kind, position, size, title, keys, auto, markdown, html, url, links, x, y, width, height
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = Kind(rawValue: (try? container.decode(String.self, forKey: .kind)) ?? "") ?? .unknown
        position = Position(rawValue: (try? container.decode(String.self, forKey: .position)) ?? "") ?? .right
        size = try? container.decode(String.self, forKey: .size)
        title = try? container.decode(String.self, forKey: .title)
        keys = (try? container.decode([OverlayHelpKey].self, forKey: .keys)) ?? []
        auto = (try? container.decode(Bool.self, forKey: .auto)) ?? false
        markdown = try? container.decode(String.self, forKey: .markdown)
        html = try? container.decode(String.self, forKey: .html)
        url = try? container.decode(String.self, forKey: .url)
        let linksText = ((try? container.decode(String.self, forKey: .links)) ?? "").lowercased()
        links = (linksText == "in-pane" || linksText == "inpane") ? .inPane : .browser
        x = try? container.decode(String.self, forKey: .x)
        y = try? container.decode(String.self, forKey: .y)
        width = try? container.decode(String.self, forKey: .width)
        height = try? container.decode(String.self, forKey: .height)
    }
}

/// The content query. Only `fileQuery` is resolved this phase; other kinds decode
/// but are reported as unsupported until their phase lands.
struct OverlaySource: Decodable {
    enum Kind: String { case fileQuery, items, webview, unknown }

    var kind: Kind
    var roots: [String]
    var filter: OverlayFilter
    var sort: OverlaySort
    var limit: Int
    /// For `kind == items`: an explicit, provider-built list. Lets a provider
    /// decide the entire "what" in JavaScript (e.g. from state it already holds,
    /// or a list a background task stashed for it) rather than a file query.
    var items: [OverlaySourceItem]
    /// For `kind == webview`: the http(s) or file:// URL to load.
    var url: String?

    private enum CodingKeys: String, CodingKey {
        case kind, roots, filter, sort, limit, items, url
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = Kind(rawValue: (try? container.decode(String.self, forKey: .kind)) ?? "") ?? .unknown
        roots = (try? container.decode([String].self, forKey: .roots)) ?? []
        filter = (try? container.decode(OverlayFilter.self, forKey: .filter)) ?? .init()
        sort = OverlaySort(rawValue: (try? container.decode(String.self, forKey: .sort)) ?? "") ?? .modifiedDesc
        limit = max(0, (try? container.decode(Int.self, forKey: .limit)) ?? 24)
        items = (try? container.decode([OverlaySourceItem].self, forKey: .items)) ?? []
        url = try? container.decode(String.self, forKey: .url)
    }

    /// Whether this phase can render the source into a grid natively.
    var isRenderable: Bool {
        kind == .fileQuery || kind == .items
    }

    /// Roots with a leading `~` expanded to the current user's home directory.
    var resolvedRoots: [URL] {
        roots.map { raw in
            URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
        }
    }
}

/// One explicit entry for an `items` source: a file path (tilde allowed) and an
/// optional display name (defaults to the filename).
struct OverlaySourceItem: Decodable {
    var path: String
    var name: String?

    private enum CodingKeys: String, CodingKey { case path, name }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = (try? container.decode(String.self, forKey: .path)) ?? ""
        name = try? container.decode(String.self, forKey: .name)
    }
}

struct OverlayFilter: Decodable {
    /// Uniform Type Identifiers a file's content type must conform to (any-of).
    /// Empty means "no UTI restriction".
    var uti: [String]
    /// A shell-style glob the filename must match (case-insensitive). Nil means
    /// "no name restriction".
    var nameGlob: String?

    init() {
        uti = []
        nameGlob = nil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        uti = (try? container.decode([String].self, forKey: .uti)) ?? []
        nameGlob = try? container.decode(String.self, forKey: .nameGlob)
    }

    private enum CodingKeys: String, CodingKey { case uti, nameGlob }
}

enum OverlaySort: String {
    case modifiedDesc, modifiedAsc, nameAsc, nameDesc
}

struct OverlayPresentation: Decodable {
    enum Anchor: String { case activeMonitorCenter, cursorMonitorCenter }
    enum SizeClass: String { case small, medium, large }
    enum Layout: String { case grid, list }
    enum ThumbSize: String { case small, medium, large }

    var anchor: Anchor
    var sizeClass: SizeClass
    var layout: Layout
    var thumb: ThumbSize
    /// Whether the user can drag-resize the panel (a corner grip is shown).
    var resizable: Bool
    /// Whether to persist the last size/position per overlay id and restore it on
    /// the next summon (the spec's default geometry only seeds the first-ever open).
    var remember: Bool
    /// Whether summoning takes keyboard focus (activates the app). Required for
    /// keyboard features (Quick Look, arrows, custom keys). `false` = an ambient
    /// overlay that never steals focus. Default: on.
    var activates: Bool
    var chrome: OverlayChrome

    init() {
        anchor = .activeMonitorCenter
        sizeClass = .medium
        layout = .grid
        thumb = .large
        resizable = false
        remember = false
        activates = true
        chrome = .init()
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        anchor = Anchor(rawValue: (try? container.decode(String.self, forKey: .anchor)) ?? "") ?? .activeMonitorCenter
        sizeClass = SizeClass(rawValue: (try? container.decode(String.self, forKey: .sizeClass)) ?? "") ?? .medium
        layout = Layout(rawValue: (try? container.decode(String.self, forKey: .layout)) ?? "") ?? .grid
        thumb = ThumbSize(rawValue: (try? container.decode(String.self, forKey: .thumb)) ?? "") ?? .large
        resizable = (try? container.decode(Bool.self, forKey: .resizable)) ?? false
        remember = (try? container.decode(Bool.self, forKey: .remember)) ?? false
        activates = (try? container.decode(Bool.self, forKey: .activates)) ?? true
        chrome = (try? container.decode(OverlayChrome.self, forKey: .chrome)) ?? .init()
    }

    private enum CodingKeys: String, CodingKey {
        case anchor, sizeClass, layout, thumb, resizable, remember, activates, chrome
    }
}

/// Optional window chrome: a slim title bar with a title, drag-to-move, and a
/// close button. Developer opt-in per overlay.
struct OverlayChrome: Decodable {
    var titleBar: Bool
    var title: String?
    var close: Bool

    init() {
        titleBar = false
        title = nil
        close = true
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        titleBar = (try? container.decode(Bool.self, forKey: .titleBar)) ?? false
        title = try? container.decode(String.self, forKey: .title)
        close = (try? container.decode(Bool.self, forKey: .close)) ?? true
    }

    private enum CodingKeys: String, CodingKey { case titleBar, title, close }
}

struct OverlayItemBehavior: Decodable {
    enum DragKind: String { case fileURL, none }
    /// What clicking/activating an item does. `select` just highlights it.
    enum Action: String { case select, reveal, open, quickLook, none }

    var drag: DragKind
    /// Single-click action (default: select).
    var click: Action
    /// Double-click action (default: reveal in Finder).
    var doubleClick: Action
    /// Whether Space / Cmd-Y Quick Looks the selection (default: on).
    var quickLook: Bool
    /// Whether arrow keys move the selection (default: on).
    var arrows: Bool

    init() {
        drag = .fileURL
        click = .select
        doubleClick = .reveal
        quickLook = true
        arrows = true
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        drag = DragKind(rawValue: (try? container.decode(String.self, forKey: .drag)) ?? "") ?? .fileURL
        click = Action(rawValue: (try? container.decode(String.self, forKey: .click)) ?? "") ?? .select
        doubleClick = Action(rawValue: (try? container.decode(String.self, forKey: .doubleClick)) ?? "") ?? .reveal
        quickLook = (try? container.decode(Bool.self, forKey: .quickLook)) ?? true
        arrows = (try? container.decode(Bool.self, forKey: .arrows)) ?? true
    }

    private enum CodingKeys: String, CodingKey { case drag, click, doubleClick, quickLook, arrows }
}

struct OverlayDismiss: Decodable {
    /// Gestures that dismiss the overlay: `esc`, `clickAway`, `retrigger`.
    var on: Set<String>
    /// Seconds after presentation to auto-dismiss; nil means "stay until dismissed".
    var autoAfter: TimeInterval?

    init() {
        on = ["esc", "clickAway", "retrigger"]
        autoAfter = nil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        on = Set((try? container.decode([String].self, forKey: .on)) ?? ["esc", "clickAway", "retrigger"])
        autoAfter = try? container.decode(TimeInterval.self, forKey: .autoAfter)
    }

    private enum CodingKeys: String, CodingKey { case on, autoAfter }
}
