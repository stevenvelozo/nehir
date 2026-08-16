// SPDX-FileCopyrightText: 2026 Steven Velozo
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import AppKit
import Carbon.HIToolbox
import FableCore
@testable import Nehir
import NehirShellWire
import SwiftUI
import WebKit

/// A TOML-declared hotkey binding for a registered overlay id.
struct OverlayBinding: Equatable, Sendable {
    let id: String
    let hotkey: String
    let enabled: Bool
}

/// Owns the overlay feature: a JavaScript-side registry (populated by user
/// scripts calling `shell.overlay.register`), the global hotkeys that summon
/// overlays, and the single native panel that renders one at a time.
///
/// pict decides *what* — a provider function returns an `OverlaySpec` when
/// pulled; Swift decides *how* — resolves the spec's file query natively and
/// renders a draggable grid. The pull runs under a wall-clock budget
/// (`evaluateGuarded`) so a runaway provider aborts the script, never the shell.
@MainActor
final class OverlayController {
    private let core: FableCore
    weak var controller: WMController?

    private let hotkeys = OverlayHotkeys()
    private var panel: NSPanel?
    private var visibleOverlayId: String?
    private var autoDismissTask: Task<Void, Never>?
    private var timerTasks: [Task<Void, Never>] = []

    /// Warm-cached web views, one per webview-overlay id: created once and reused
    /// across summons so re-opening is instant and page state survives. `lastLoaded`
    /// avoids reloading the same URL on a warm re-summon.
    private var webViews: [String: WKWebView] = [:]
    private var lastLoadedURL: [String: URL] = [:]
    /// True while an interactive overlay is up (it activated the app so clicks and
    /// keys land); drives returning focus to the previous app on dismiss.
    private var didActivateApp = false
    /// The item last clicked in a grid overlay (for keyboard actions like Quick Look).
    private var selectedItem: OverlayItem?
    private let quickLook = OverlayQuickLook()
    /// The spec and items of the overlay on screen, so selection changes can
    /// re-render the grid and keyboard actions know the item set.
    private var visibleSpec: OverlaySpec?
    private var visibleItems: [OverlayItem] = []
    /// Developer-registered key handlers per overlay id (via `shell.overlay.onKey`).
    private var keyActions: [String: [(chord: OverlayKeyChord, handler: FableFunction)]] = [:]
    /// Whether the overlay currently on screen persists its frame; the size at the
    /// start of an in-progress resize gesture.
    private var visibleRemember = false
    private var resizeAnchorSize: CGSize?

    private var localKeyMonitor: Any?
    private var globalKeyMonitor: Any?
    private var globalClickMonitor: Any?

    /// Hard budget for a single provider pull. Generous for legitimate spec
    /// construction, tiny next to a hang.
    private let pullTimeLimitSeconds: TimeInterval = 0.25

    init(core: FableCore, controller: WMController) {
        self.core = core
        self.controller = controller
    }

    // MARK: - Startup

    /// Install the JS registry and native capabilities, load user overlay
    /// scripts, and bind the TOML-declared hotkeys to the overlays that actually
    /// registered a provider.
    func start(bindings: [OverlayBinding]) {
        _ = try? core.evaluate(Self.bootstrapJS)
        installCapabilities()
        loadScripts()
        bindHotkeys(bindings)
    }

    /// Native functions user scripts can call. Push control (`show`/`hide`/
    /// `update`) and scheduling (`every`) are the script-host surface; the pull
    /// path (`register`) stays JS-only. Every user callback runs under the same
    /// wall-clock budget as a pull.
    private func installCapabilities() {
        core.installHostFunctions(namespace: "shell.overlay", [
            "show": { [weak self] args in
                if let id = args.string(at: 0) { self?.show(id) }
                return nil
            },
            "hide": { [weak self] _ in
                self?.hide()
                return nil
            },
            "update": { [weak self] args in
                if let id = args.string(at: 0) { self?.update(id: id, specValue: args.value(at: 1)) }
                return nil
            },
            "onKey": { [weak self] args in
                guard let id = args.string(at: 0), let chordText = args.string(at: 1),
                      let handler = args.function(at: 2), let chord = OverlayKeyChord.parse(chordText)
                else { return nil }
                self?.keyActions[id, default: []].append((chord, handler))
                return nil
            }
        ])
        core.installHostFunctions(namespace: "shell", [
            "every": { [weak self] args in
                self?.scheduleEvery(args)
                return nil
            },
            "log": { [weak self] args in
                if let message = args.string(at: 0) { self?.core.log(.info, message) }
                return nil
            }
        ])
    }

    /// Cancel scheduled scripts and drop hotkeys. Unused while the controller
    /// lives for the app's lifetime, but keeps teardown correct and testable.
    func stop() {
        for task in timerTasks { task.cancel() }
        timerTasks.removeAll()
        hotkeys.unregisterAll()
        hide()
    }

    private func loadScripts() {
        let directory = Self.overlaysDirectory()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            seedSampleScript(in: directory)
        }
        let files = ((try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? [])
            .filter { $0.pathExtension == "js" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        for file in files {
            guard let source = try? String(contentsOf: file, encoding: .utf8) else { continue }
            do {
                _ = try core.evaluate(source)
            } catch {
                core.log(
                    .error,
                    "overlay script failed to load",
                    ["file": file.lastPathComponent, "error": String(describing: error)]
                )
            }
        }
    }

    private func bindHotkeys(_ bindings: [OverlayBinding]) {
        let registered = registeredIds()
        for binding in bindings where binding.enabled {
            guard registered.contains(binding.id) else {
                core.log(.warn, "overlay hotkey bound to an unregistered provider", ["id": binding.id])
                continue
            }
            let chord = DeckHotkeyChord.parse(binding.hotkey)
            let id = binding.id
            hotkeys.register(chord: chord) { [weak self] in self?.toggle(id) }
        }
    }

    /// Ids currently registered on the JS side.
    private func registeredIds() -> Set<String> {
        Set(listRegistered())
    }

    /// Sorted list of registered overlay ids (for `nehirshellctl overlay list`).
    func listRegistered() -> [String] {
        guard let raw = try? core.evaluate("shell.overlay._ids()").array else { return [] }
        return raw.compactMap { $0 as? String }.sorted()
    }

    // MARK: - Show / hide (also the socket-command entry points)

    func toggle(_ id: String) {
        if visibleOverlayId == id {
            hide()
        } else {
            show(id)
        }
    }

    /// Summon overlay `id`: pull its spec, resolve it, present the panel. One
    /// overlay shows at a time this phase, so any current one is dismissed first.
    func show(_ id: String) {
        guard isValidId(id) else {
            core.log(.warn, "ignoring overlay id with unexpected characters", ["id": id])
            return
        }
        hide()

        guard let spec = pullSpec(id) else { return }
        switch spec.source.kind {
        case .fileQuery,
             .items:
            present(id: id, spec: spec, items: OverlayResolver.resolve(spec.source))
        case .webview:
            presentWebview(id: id, spec: spec)
        case .unknown:
            core.log(.warn, "overlay source kind not supported", ["id": id, "kind": spec.source.kind.rawValue])
        }
    }

    func hide() {
        autoDismissTask?.cancel()
        autoDismissTask = nil
        removeDismissMonitors()
        // Persist the final frame (captures both move and resize) before teardown.
        if visibleRemember, let id = visibleOverlayId, let panel {
            persistFrame(id: id, panel.frame)
        }
        panel?.orderOut(nil)
        panel = nil
        visibleOverlayId = nil
        visibleRemember = false
        resizeAnchorSize = nil
        // An interactive overlay activated the app; relinquish so focus returns to
        // whatever the user was in. Warm web views stay cached.
        selectedItem = nil
        visibleSpec = nil
        visibleItems = []
        if didActivateApp {
            didActivateApp = false
            NSApp.deactivate()
        }
    }

    var isShowing: Bool {
        visibleOverlayId != nil
    }

    // MARK: - Pull + present

    private func pullSpec(_ id: String) -> OverlaySpec? {
        do {
            let value = try core.evaluateGuarded("shell.overlay._pull('\(id)')", timeLimitSeconds: pullTimeLimitSeconds)
            return try value.decode(OverlaySpec.self)
        } catch {
            core.log(
                .error,
                "overlay provider failed to produce a spec",
                ["id": id, "error": String(describing: error)]
            )
            return nil
        }
    }

    private func present(id: String, spec: OverlaySpec, items: [OverlayItem]) {
        let frame = frameFor(id: id, present: spec.present)
        let panel = makePanel(frame: frame, resizable: spec.present.resizable)

        visibleOverlayId = id
        visibleSpec = spec
        visibleItems = items
        selectedItem = items.first

        panel.contentView = NSHostingView(rootView: gridView(id: id, spec: spec, items: items))
        panel.setFrame(frame, display: true)

        if spec.present.activates {
            // Take focus so clicks select and the keyboard (Quick Look, arrows,
            // custom keys) reaches the grid instead of passing through.
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            didActivateApp = true
        } else {
            panel.orderFrontRegardless()
        }

        self.panel = panel
        visibleRemember = spec.present.remember
        installDismissMonitors(spec)

        if let after = spec.dismiss.autoAfter, after > 0 {
            autoDismissTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(after))
                guard !Task.isCancelled else { return }
                self?.hide()
            }
        }
    }

    /// Build the grid view bound to the current selection. Rebuilt (cheaply) on any
    /// selection change so clicks and arrow keys share one source of truth.
    private func gridView(id: String, spec: OverlaySpec, items: [OverlayItem]) -> OverlayPanelView {
        OverlayPanelView(
            title: id,
            presentation: spec.present,
            items: items,
            behavior: spec.item,
            onActivate: { [weak self] item in self?.handleClick(item, action: spec.item.doubleClick) },
            onSelect: { [weak self] item in self?.handleClick(item, action: spec.item.click) },
            onClose: { [weak self] in self?.hide() },
            onResize: { [weak self] translation, ended in self?.handleResize(translation, ended: ended) },
            selectedID: selectedItem?.id
        )
    }

    private func handleClick(_ item: OverlayItem, action: OverlayItemBehavior.Action) {
        selectItem(item)
        performAction(item, action)
    }

    private func selectItem(_ item: OverlayItem) {
        selectedItem = item
        rerenderGrid()
    }

    private func rerenderGrid() {
        guard let id = visibleOverlayId, let spec = visibleSpec,
              let hosting = panel?.contentView as? NSHostingView<OverlayPanelView>
        else { return }
        hosting.rootView = gridView(id: id, spec: spec, items: visibleItems)
    }

    private func performAction(_ item: OverlayItem, _ action: OverlayItemBehavior.Action) {
        switch action {
        case .select: break
        case .reveal: NSWorkspace.shared.activateFileViewerSelecting([item.url])
        case .open: NSWorkspace.shared.open(item.url)
        case .quickLook: quickLook.preview(item.url)
        case .none: break
        }
    }

    /// Push path: a script re-renders the currently-shown overlay in place with a
    /// fresh spec. Ignored unless `id` is the overlay on screen.
    private func update(id: String, specValue: FableValue) {
        guard visibleOverlayId == id,
              panel?.contentView is NSHostingView<OverlayPanelView>,
              let spec = try? specValue.decode(OverlaySpec.self),
              spec.source.isRenderable
        else { return }
        visibleSpec = spec
        visibleItems = OverlayResolver.resolve(spec.source)
        selectedItem = visibleItems.first
        rerenderGrid()
    }

    /// `shell.every(ms, fn)`: run `fn` on a repeating schedule under the pull
    /// budget, so a scheduled script that loops forever aborts that tick, not the
    /// shell. A structured Task (not a `Timer`) keeps it main-actor isolated.
    private func scheduleEvery(_ args: HostArgs) {
        guard let milliseconds = args.number(at: 0), let function = args.function(at: 1) else { return }
        let interval = max(0.05, milliseconds / 1000.0)
        let task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard let self, !Task.isCancelled else { break }
                do {
                    _ = try self.core.call(function, timeLimitSeconds: self.pullTimeLimitSeconds)
                } catch {
                    self.core.log(.error, "scheduled script aborted", ["error": String(describing: error)])
                }
            }
        }
        timerTasks.append(task)
    }

    /// Present a warm-cached, interactive web view. The view persists across
    /// summons (only the panel is rebuilt); the app is activated so the web content
    /// can take keyboard focus, and dismiss restores focus to the previous app.
    private func presentWebview(id: String, spec: OverlaySpec) {
        let frame = panelFrame(for: spec.present)
        let webView = webViews[id] ?? OverlayWebPanel.makeWebView()
        webViews[id] = webView
        lastLoadedURL[id] = OverlayWebPanel.load(spec.source.url, into: webView, lastLoaded: lastLoadedURL[id])

        let container = NSView(frame: CGRect(origin: .zero, size: frame.size))
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.layer?.masksToBounds = true
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)

        let panel = OverlayWebPanel.makePanel(frame: frame)
        panel.contentView = container
        panel.onEsc = { [weak self] in if spec.dismiss.on.contains("esc") { self?.hide() } }
        panel.onResignKey = { [weak self] in if spec.dismiss.on.contains("clickAway") { self?.hide() } }
        panel.setFrame(frame, display: true)

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)

        self.panel = panel
        visibleOverlayId = id
        didActivateApp = true

        if let after = spec.dismiss.autoAfter, after > 0 {
            autoDismissTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(after))
                guard !Task.isCancelled else { return }
                self?.hide()
            }
        }
    }

    private func quickLookSelected() {
        guard let url = selectedItem?.url else { return }
        quickLook.preview(url)
    }

    /// Run a developer-registered key handler (from `shell.overlay.onKey`) if one
    /// matches this event; returns whether it handled it. The handler is called
    /// with the selected item as `{ path, name }`, under the pull time budget.
    private func runKeyHandler(id: String, event: NSEvent) -> Bool {
        guard let bindings = keyActions[id],
              let match = bindings.first(where: { $0.chord.matches(event) })
        else { return false }
        let argument: [String: Any] = [
            "path": selectedItem?.url.path ?? "",
            "name": selectedItem?.displayName ?? ""
        ]
        do {
            _ = try core.call(match.handler, arguments: [argument], timeLimitSeconds: pullTimeLimitSeconds)
        } catch {
            core.log(.error, "overlay key handler aborted", ["id": id, "error": String(describing: error)])
        }
        return true
    }

    /// Move the grid selection with the arrow keys. Up/Down step by an estimated
    /// column count derived from the panel width and thumbnail size.
    private func moveSelection(keyCode: UInt16) {
        guard !visibleItems.isEmpty else { return }
        let columns = currentGridColumns()
        let current = selectedItem.flatMap { selected in
            visibleItems.firstIndex(where: { $0.id == selected.id })
        } ?? 0
        var next = current
        switch Int(keyCode) {
        case kVK_LeftArrow: next = current - 1
        case kVK_RightArrow: next = current + 1
        case kVK_UpArrow: next = current - columns
        case kVK_DownArrow: next = current + columns
        default: break
        }
        next = max(0, min(visibleItems.count - 1, next))
        selectItem(visibleItems[next])
        if quickLook.isVisible { quickLookSelected() } // browse within Quick Look, Finder-style
    }

    private func currentGridColumns() -> Int {
        guard let width = panel?.frame.width else { return 1 }
        let thumb = visibleSpec?.present.thumb ?? .large
        let pixels: CGFloat = thumb == .small ? 64 : (thumb == .medium ? 96 : 128)
        let cell = pixels + 28 + 18 // adaptive min width + inter-item spacing
        return max(1, Int((width - 40 + 18) / cell))
    }

    // MARK: - Geometry

    private func panelFrame(for present: OverlayPresentation) -> CGRect {
        let size: CGSize
        switch present.sizeClass {
        case .small: size = CGSize(width: 460, height: 340)
        case .medium: size = CGSize(width: 680, height: 480)
        case .large: size = CGSize(width: 940, height: 660)
        }
        let area = activeMonitorVisibleFrame()
        let origin = CGPoint(x: area.midX - size.width / 2, y: area.midY - size.height / 2)
        return CGRect(origin: origin, size: size).integral
    }

    /// The frame to open at: a remembered frame if this overlay persists and has a
    /// usable saved one, else the spec's default geometry.
    private func frameFor(id: String, present: OverlayPresentation) -> CGRect {
        if present.remember, let saved = savedFrame(id: id) { return saved }
        return panelFrame(for: present)
    }

    private func savedFrame(id: String) -> CGRect? {
        guard let values = UserDefaults.standard.array(forKey: Self.frameDefaultsKey(id)) as? [Double],
              values.count == 4
        else { return nil }
        let rect = CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
        // Ignore a saved frame that no longer lands on any screen (monitors changed).
        guard NSScreen.screens.contains(where: { $0.frame.intersects(rect) }) else { return nil }
        return rect
    }

    private func persistFrame(id: String, _ frame: CGRect) {
        UserDefaults.standard.set(
            [Double(frame.minX), Double(frame.minY), Double(frame.width), Double(frame.height)],
            forKey: Self.frameDefaultsKey(id)
        )
    }

    private static func frameDefaultsKey(_ id: String) -> String {
        "NehirOverlayFrame_\(id)"
    }

    /// Live-resize the panel from the bottom-right grip, keeping the top-left
    /// corner fixed (AppKit's origin is bottom-left, so the top edge is maxY).
    private func handleResize(_ translation: CGSize, ended: Bool) {
        guard let panel else { return }
        let anchor = resizeAnchorSize ?? panel.frame.size
        if resizeAnchorSize == nil { resizeAnchorSize = anchor }
        let width = max(320, anchor.width + translation.width)
        let height = max(220, anchor.height + translation.height)
        let topEdge = panel.frame.maxY
        panel.setFrame(
            CGRect(x: panel.frame.minX, y: topEdge - height, width: width, height: height),
            display: true
        )
        if ended {
            resizeAnchorSize = nil
            if visibleRemember, let id = visibleOverlayId { persistFrame(id: id, panel.frame) }
        }
    }

    private func activeMonitorVisibleFrame() -> CGRect {
        if let workspaceId = controller?.interactionWorkspace()?.id,
           let monitor = controller?.workspaceManager.monitor(for: workspaceId)
        {
            return monitor.visibleFrame
        }
        return NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
    }

    private func makePanel(frame: CGRect, resizable: Bool) -> NSPanel {
        var style: NSWindow.StyleMask = [.borderless, .nonactivatingPanel]
        if resizable { style.insert(.resizable) }
        // Key-capable so the grid can hold focus for clicks and keyboard actions.
        let panel = OverlayKeyPanel(
            contentRect: frame,
            styleMask: style,
            backing: .buffered,
            defer: false
        )
        if resizable { panel.minSize = NSSize(width: 320, height: 220) }
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = false
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .stationary]
        return panel
    }

    // MARK: - Dismiss monitors

    /// Esc and click-away are observed with lightweight event monitors so the
    /// panel can stay non-activating (never stealing focus, never blocking a
    /// drag-out). Global monitors observe other apps; the local monitor also
    /// swallows Esc when our own panel is frontmost.
    private func installDismissMonitors(_ spec: OverlaySpec) {
        let dismiss = spec.dismiss
        let behavior = spec.item

        // The grid overlay is key+active, so the local monitor sees its keys.
        // Priority: developer key handlers, then arrows, Quick Look, then Esc.
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if let id = self.visibleOverlayId, self.runKeyHandler(id: id, event: event) {
                return nil
            }
            let arrows = [kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow]
            if behavior.arrows, arrows.contains(Int(event.keyCode)) {
                self.moveSelection(keyCode: event.keyCode)
                return nil
            }
            if behavior.quickLook,
               event.keyCode == UInt16(kVK_Space)
               || (event.keyCode == UInt16(kVK_ANSI_Y) && event.modifierFlags.contains(.command))
            {
                self.quickLookSelected()
                return nil
            }
            if dismiss.on.contains("esc"), event.keyCode == UInt16(kVK_Escape) {
                // While Quick Look is up, let it handle Esc (close preview, keep grid).
                if self.quickLook.isVisible { return event }
                self.hide()
                return nil
            }
            return event
        }
        if dismiss.on.contains("esc") {
            globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                if event.keyCode == UInt16(kVK_Escape) { self?.hide() }
            }
        }
        if dismiss.on.contains("clickAway") {
            globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [
                .leftMouseDown,
                .rightMouseDown
            ]) { [weak self] _ in
                self?.hide()
            }
        }
    }

    private func removeDismissMonitors() {
        for monitor in [localKeyMonitor, globalKeyMonitor, globalClickMonitor] {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
        localKeyMonitor = nil
        globalKeyMonitor = nil
        globalClickMonitor = nil
    }

    // MARK: - Helpers

    private func isValidId(_ id: String) -> Bool {
        !id.isEmpty && id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
    }

    /// `~/.config/nehir/overlays/` — a sibling of the `shell.d/` config dir.
    static func overlaysDirectory() -> URL {
        ShellPaths.configDirectory()
            .deletingLastPathComponent()
            .appendingPathComponent("overlays", isDirectory: true)
    }

    // MARK: - Injected JS

    /// Defines `shell.overlay.register(id, providerFn)` plus the internal `_pull`
    /// / `_ids` accessors the Swift side reads. Providers are held in a plain JS
    /// object; nothing here touches the filesystem or blocks.
    private static let bootstrapJS = """
    (function () {
      var g = (typeof globalThis !== 'undefined') ? globalThis : this;
      g.shell = g.shell || {};
      var registry = g.shell.__overlays = g.shell.__overlays || {};
      g.shell.overlay = g.shell.overlay || {};
      g.shell.overlay.register = function (id, provider) {
        if (typeof id === 'string' && typeof provider === 'function') { registry[id] = provider; }
      };
      g.shell.overlay._pull = function (id) {
        var provider = registry[id];
        return (typeof provider === 'function') ? provider() : null;
      };
      g.shell.overlay._ids = function () { return Object.keys(registry); };
    })();
    """

    private func seedSampleScript(in directory: URL) {
        let sample = """
        // NehirShell overlay — recent images on your Desktop, as a draggable grid.
        //
        // This runs in the pict/fable JavaScript host. `shell.overlay.register` binds
        // an id to a provider function; the provider returns an OverlaySpec describing
        // WHAT to show. Swift resolves the file query and renders it natively, so you
        // can drag a screenshot straight out into any window.
        //
        // Bind a hotkey to it in ~/.config/nehir/shell.d/00-shell.toml under [[overlay]].
        shell.overlay.register("desktop-shots", function () {
          return {
            source: {
              kind: "fileQuery",
              roots: ["~/Desktop"],
              filter: { uti: ["public.image"] }, // tighten with e.g. nameGlob: "Screen*.png"
              sort: "modifiedDesc",
              limit: 24
            },
            present: {
              anchor: "activeMonitorCenter", sizeClass: "medium", thumb: "large",
              resizable: true,   // drag the corner grip to resize
              remember: true,    // restores your last size/position next time
              chrome: { titleBar: true, title: "Desktop", close: true }
            },
            // Defaults: single-click selects, double-click reveals in Finder,
            // Space/Cmd-Y Quick Looks, arrow keys navigate. Register custom keys with
            // shell.overlay.onKey("desktop-shots", "c", function (item) { ... }).
            item: { drag: "fileURL" }
          };
        });
        """
        try? Data(sample.utf8).write(to: directory.appendingPathComponent("desktop-shots.js", isDirectory: false))

        let webviewSample = """
        // NehirShell overlay — an interactive web view in a floating panel.
        //
        // kind: "webview" loads a URL (http/https or file://) into a warm-cached,
        // keyboard-interactive WKWebView. Summon it with a hotkey (bind in a
        // shell.d/*.toml [[overlay]] block) or `nehirshellctl overlay show web`.
        shell.overlay.register("web", function () {
          return {
            source: { kind: "webview", url: "https://example.com" }, // change me
            present: { anchor: "activeMonitorCenter", sizeClass: "large" },
            dismiss: { on: ["esc", "clickAway", "retrigger"] }
          };
        });
        """
        try? Data(webviewSample.utf8).write(to: directory.appendingPathComponent(
            "webview-example.js",
            isDirectory: false
        ))
    }
}
