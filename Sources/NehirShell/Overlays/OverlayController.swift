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

/// A pict extension's Deck/OSD registration (from `shell.overlay.osd`).
private struct OSDRegistration {
    let id: String
    let group: String
    let key: Character
    let label: String
    let tile: Bool
    let status: FableFunction?
}

/// The decodable options object passed to `shell.overlay.osd(id, options, statusFn?)`.
private struct OSDOptions: Decodable {
    var group: String?
    var key: String?
    var label: String?
    var tile: Bool?
}

/// A resolved OSD entry (live status pulled) handed to the Deck controller.
struct OSDEntry {
    let id: String
    let group: String
    let key: Character
    let label: String
    let tile: Bool
    let status: String?
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
    /// One message bridge per webview-overlay id, retained alongside its web view.
    private var webBridges: [String: OverlayWebBridge] = [:]
    /// Floating SwiftTerm panel for the "Run here" target.
    private let terminalController = OverlayTerminalController()
    /// True once the inherent terminal has been summoned and not yet ⌘W-closed, so
    /// the Deck re-presents it above the controls each time the OSD opens.
    private var terminalActive = false
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
    /// `key`/`label` feed the help quick-reference when it auto-appends.
    private var keyActions: [String: [(chord: OverlayKeyChord, handler: FableFunction, key: String, label: String)]] =
        [:]

    /// OSD (Deck) registrations per overlay id, from `shell.overlay.osd`.
    private var osdRegistrations: [String: OSDRegistration] = [:]

    /// Help panes (docked windows) currently on screen for the visible overlay.
    private var helpShown = false
    private var helpPanels: [NSPanel] = []
    private var helpProse: [ProseHelpWebView] = []
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
        _ = try? core.evaluate(Self.builtinToolsJS)
        _ = try? core.evaluate(Self.builtinSettingsJS)
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
                let label = args.string(at: 3) ?? ""
                self?.keyActions[id, default: []].append((chord, handler, chordText, label))
                return nil
            },
            "refresh": { [weak self] _ in
                self?.refresh()
                return nil
            },
            "osd": { [weak self] args in
                guard let id = args.string(at: 0) else { return nil }
                self?.registerOSD(id: id, options: args.value(at: 1), status: args.function(at: 2))
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
        // Native shell.* actions (clipboard, file ops, run, notify, quickLook).
        ShellCapabilities.install(on: core, quickLook: quickLook)
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
        hideHelp()
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

    /// Re-pull the visible grid overlay and re-resolve its items (e.g. after a key
    /// handler moved a file to the Trash). Keeps the selection on the same item if
    /// it survives, otherwise on the item that took its slot. No-op for webview
    /// overlays or when nothing is shown.
    func refresh() {
        guard let id = visibleOverlayId,
              panel?.contentView is NSHostingView<OverlayPanelView>,
              let spec = pullSpec(id), spec.source.isRenderable
        else { return }
        let items = OverlayResolver.resolve(spec.source)
        let previousIndex = selectedItem.flatMap { selected in
            visibleItems.firstIndex(where: { $0.id == selected.id })
        } ?? 0
        visibleSpec = spec
        visibleItems = items
        if let selectedId = selectedItem?.id, let kept = items.first(where: { $0.id == selectedId }) {
            selectedItem = kept
        } else if !items.isEmpty {
            selectedItem = items[min(previousIndex, items.count - 1)]
        } else {
            selectedItem = nil
        }
        rerenderGrid()
    }

    private func performAction(_ item: OverlayItem, _ action: OverlayItemBehavior.Action) {
        switch action {
        case .select: break
        case .quickLook: quickLook.preview(item.url)
        case .none: break
        // Reveal/open switch to another app, so the overlay's job is done — dismiss it.
        case .reveal:
            NSWorkspace.shared.activateFileViewerSelecting([item.url])
            hide()
        case .open:
            NSWorkspace.shared.open(item.url)
            hide()
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
        let webView: WKWebView
        if let cached = webViews[id] {
            webView = cached
        } else {
            let bridge = OverlayWebBridge()
            bridge.onAction = { [weak self] body in self?.handleWebAction(body) }
            webBridges[id] = bridge
            webView = OverlayWebPanel.makeWebView(bridge: bridge)
            webViews[id] = webView
        }
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

    // MARK: - Webview action bridge (run a compiled command)

    /// The built-in "tools" overlay: the retold-tool-manager command builder,
    /// rendered from the page bundled with the shell and registered on the Deck
    /// under Extensions (⌘D → x). A user can still bind a standalone hotkey via a
    /// shell.d [[overlay]] block for id "tools".
    private static let builtinToolsJS = """
    shell.overlay.register("tools", function () {
      return {
        source: { kind: "webview", url: "nehir-resource://tool-runner.html" },
        present: { anchor: "activeMonitorCenter", sizeClass: "large" },
        dismiss: { on: ["esc", "clickAway", "retrigger"] }
      };
    });
    """
    // The Tools builder stays registered (reachable as the Commandlets palette's Builder
    // row via showOverlay("tools")); its old root `x` chord is gone — `x` now opens the
    // native Commandlets mode.

    /// The built-in "settings" overlay: the pict-section-form settings editor,
    /// opened from the menu-bar status item's right-click menu. Not bound to a Deck
    /// chord (no osd entry) — it is a menu-bar surface, summoned via show("settings").
    private static let builtinSettingsJS = """
    shell.overlay.register("settings", function () {
      return {
        source: { kind: "webview", url: "nehir-resource://settings.html" },
        present: { anchor: "activeMonitorCenter", sizeClass: "large" },
        dismiss: { on: ["esc", "clickAway"] }
      };
    });
    shell.overlay.register("commandlets", function () {
      return {
        source: { kind: "webview", url: "nehir-resource://commandlets.html" },
        present: { anchor: "activeMonitorCenter", sizeClass: "large" },
        dismiss: { on: ["esc", "clickAway"] }
      };
    });
    """

    /// Handle an action a webview overlay posted via `window.webkit.messageHandlers.nehir`.
    private func handleWebAction(_ body: [String: Any]) {
        guard let action = body["action"] as? String else { return }
        switch action {
        case "run":
            let command = (body["command"] as? String) ?? ""
            guard !command.isEmpty else { return }
            runWebCommand(command, target: (body["target"] as? String) ?? "clipboard")
        case "settingsGet":
            sendCurrentTerminalSettings()
        case "fontsGet":
            sendAvailableFonts()
        case "themeGet":
            sendActiveThemeHash()
        case "themeSet":
            if let id = body["id"] as? String { applyThemeSelection(id) }
        case "settingsSet":
            applyTerminalSettings(from: body["values"])
        case "overlayClose":
            hide()
        case "commandletsGet":
            sendCommandlets()
        case "historyGet":
            sendShellHistory()
        case "historyRefresh":
            // Flush the warm session's in-memory history to disk, then re-read after a beat
            // so commands just run in the OSD terminal show up in the picker.
            terminalController.flushHistory()
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 300_000_000)
                self?.sendShellHistory()
            }
        case "commandletsSet":
            applyCommandlets(from: body["commandlets"])
        case "terminalCwdGet":
            sendTerminalCwd()
        default:
            core.log(.warn, "unknown webview action", ["action": action])
        }
    }

    /// Dispatch a compiled command to a run target: `clipboard` copies it,
    /// `embedded` runs it in a floating SwiftTerm terminal ("Run here"), anything
    /// else launches it in a fresh external Terminal window.
    private func runWebCommand(_ command: String, target: String) {
        switch target {
        case "clipboard":
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
        case "embedded":
            presentTerminal(command)
        default:
            openInTerminal(command)
        }
    }

    /// Open a fresh Terminal window running `command`, via AppleScript `do script`
    /// (needs only the Automation permission Nehir already requests).
    private func openInTerminal(_ command: String) {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        tell application "Terminal"
            activate
            do script "\(escaped)"
        end tell
        """
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            core.log(.warn, "failed to open command in Terminal", ["error": String(describing: error)])
        }
    }

    /// Run `command` in a floating SwiftTerm terminal. The tool overlay steps
    /// aside (its panel dismisses) so the terminal takes keyboard focus; closing
    /// the terminal relinquishes focus back to the previous app.
    private func presentTerminal(_ command: String) {
        hide()
        activateInherentTerminal()
        terminalController.runCommand(command, frame: terminalFrame())
    }

    /// Apply the configured terminal appearance (font, opacity, corner radius) to
    /// new inherent-terminal sessions.
    func configureTerminal(_ config: TerminalConfig) {
        terminalController.appearance = config
    }

    /// The terminal-active OSD edge margin (points), read by the Deck layout.
    var terminalEdgeMargin: CGFloat { CGFloat(terminalController.appearance.margin) }

    /// The terminal pane's desired height in points, derived from the configured row count
    /// and font metrics — the single source of truth both the backtick-focus and the
    /// commandlet-run paths use, so the terminal is the same height however it's summoned.
    var terminalPaneHeight: CGFloat {
        let appearance = terminalController.appearance
        let size = CGFloat(max(6, appearance.fontSize))
        let font: NSFont = (!appearance.fontFamily.isEmpty ? NSFont(name: appearance.fontFamily, size: size) : nil)
            ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        let lineHeight = max(ceil(font.ascender - font.descender + font.leading), ceil(size * 1.1))
        let rows = CGFloat(max(4, appearance.rows))
        let padding = CGFloat(max(0, appearance.padding))
        return rows * lineHeight + 2 * padding
    }

    /// Answer a `settingsGet` from the settings form by pushing the live terminal
    /// config into it (the page calls `window.applyHostSettings` with these values).
    private func sendCurrentTerminalSettings() {
        guard let webView = webViews["settings"] else { return }
        let appearance = terminalController.appearance
        let family = appearance.fontFamily
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let json = "{\"fontSize\":\(appearance.fontSize),\"fontFamily\":\"\(family)\",\"opacity\":\(appearance.opacity),\"cornerRadius\":\(appearance.cornerRadius),\"margin\":\(appearance.margin),\"padding\":\(appearance.padding),\"rows\":\(appearance.rows)}"
        webView.evaluateJavaScript("window.applyHostSettings && window.applyHostSettings(\(json));", completionHandler: nil)
    }

    /// Answer a `fontsGet` from the settings form with the installed monospaced font
    /// families, so the font dropdown reflects what's actually available on this
    /// machine (the JS-on-Swift host-data bridge — the page asks Swift for system info).
    private func sendAvailableFonts() {
        guard let webView = webViews["settings"] else { return }
        var families = Set<String>()
        for name in NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask) ?? [] {
            if let family = NSFont(name: name, size: 12)?.familyName { families.insert(family) }
        }
        let items = families.sorted().map { family -> String in
            let safe = family.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(safe)\""
        }
        let jsonArray = "[" + items.joined(separator: ",") + "]"
        webView.evaluateJavaScript("window.applyHostFonts && window.applyHostFonts(\(jsonArray));", completionHandler: nil)
    }

    /// Quote a string as a JS string literal (escaping the characters that matter for the
    /// small payloads we inject: backslash, quote, newline, carriage return).
    private func jsString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "")
        return "\"\(escaped)\""
    }

    /// Push the persisted active theme hash into every open overlay, so a switch (or a
    /// fresh open) converges them all on one pict theme. No-op until one is chosen — the
    /// pict provider then keeps its own catalog default.
    private func sendActiveThemeHash() {
        guard let hash = ThemeStore.activeThemeID() else { return }
        for webView in webViews.values {
            webView.evaluateJavaScript("window.applyHostThemeHash && window.applyHostThemeHash(\(jsString(hash)));", completionHandler: nil)
        }
    }

    /// Persist a theme pick (a pict-section-theme hash, posted by the picker) and broadcast
    /// it so every open overlay converges on it.
    private func applyThemeSelection(_ id: String) {
        ThemeStore.setActiveThemeID(id)
        sendActiveThemeHash()
    }

    // MARK: - Commandlet manager bridge

    /// Push the commandlet store to the manager overlay (it calls `window.applyHostCommandlets`).
    private func sendCommandlets() {
        guard let webView = webViews["commandlets"] else { return }
        guard let data = try? JSONEncoder().encode(CommandletStore.load()),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.applyHostCommandlets && window.applyHostCommandlets(\(json));", completionHandler: nil)
    }

    /// The shell-history host-data bridge: read + dedupe the user's history and hand it to
    /// the manager's picker (`window.applyHostHistory`). `historyRefresh` just re-reads.
    private func sendShellHistory() {
        guard let webView = webViews["commandlets"] else { return }
        guard let data = try? JSONEncoder().encode(ShellHistory.entries()),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.applyHostHistory && window.applyHostHistory(\(json));", completionHandler: nil)
    }

    /// Default a slot's pinned folder to the terminal's live cwd (`window.applyHostTerminalCwd`).
    private func sendTerminalCwd() {
        guard let webView = webViews["commandlets"] else { return }
        let cwd = terminalController.currentWorkingDirectory ?? ""
        webView.evaluateJavaScript("window.applyHostTerminalCwd && window.applyHostTerminalCwd(\(jsString(cwd)));", completionHandler: nil)
    }

    /// Persist the commandlet list the manager posted (replaces the store on disk).
    private func applyCommandlets(from any: Any?) {
        guard let array = any as? [[String: Any]],
              let data = try? JSONSerialization.data(withJSONObject: array),
              let commandlets = try? JSONDecoder().decode([Commandlet].self, from: data) else { return }
        CommandletStore.save(commandlets)
    }

    /// Apply settings posted by the settings form: update the live appearance (so the
    /// next terminal summon and the OSD layout pick them up) and persist them to a
    /// managed shell.d fragment.
    private func applyTerminalSettings(from valuesAny: Any?) {
        let values = (valuesAny as? [String: Any]) ?? [:]
        var config = terminalController.appearance
        if let fontSize = doubleValue(values["fontSize"]) { config.fontSize = fontSize }
        if let fontFamily = values["fontFamily"] as? String { config.fontFamily = fontFamily }
        if let opacity = doubleValue(values["opacity"]) { config.opacity = opacity }
        if let cornerRadius = doubleValue(values["cornerRadius"]) { config.cornerRadius = cornerRadius }
        if let margin = doubleValue(values["margin"]) { config.margin = margin }
        if let padding = doubleValue(values["padding"]) { config.padding = padding }
        if let rows = doubleValue(values["rows"]) { config.rows = max(4, Int(rows)) }
        terminalController.appearance = config
        terminalController.applyAppearanceLive()
        writeTerminalSettingsFragment(config)
        // `keys` reveals whether the values dictionary actually arrived + parsed.
        core.log(.info, "terminal settings saved", [
            "keys": Array(values.keys).sorted().joined(separator: ","),
            "fontSize": config.fontSize,
            "opacity": config.opacity,
            "margin": config.margin
        ])
    }

    /// Coerce a JSON-bridged value (NSNumber / Double / Int / String) to a Double.
    private func doubleValue(_ value: Any?) -> Double? {
        switch value {
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s)
        default: return nil
        }
    }

    /// Write the terminal appearance to a managed `20-terminal.toml` fragment that the
    /// Settings form owns. Hand-edits there are overwritten on the next save.
    private func writeTerminalSettingsFragment(_ config: TerminalConfig) {
        let directory = ShellPaths.configDirectory()
        let file = directory.appendingPathComponent("20-terminal.toml", isDirectory: false)
        let family = config.fontFamily
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let toml = """
        # Managed by Nehir Settings (menu bar -> Settings...). Hand-edits here are
        # overwritten when you save from the Settings panel.
        [terminal]
        fontSize = \(config.fontSize)
        fontFamily = "\(family)"
        opacity = \(config.opacity)
        cornerRadius = \(config.cornerRadius)
        margin = \(config.margin)
        padding = \(config.padding)
        rows = \(config.rows)
        """
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Data(toml.utf8).write(to: file)
    }

    /// Whether the inherent terminal is active (re-presented with the OSD until it
    /// is ⌘W-closed). The Deck reads this to switch into its terminal-active layout.
    var isInherentTerminalActive: Bool { terminalActive }

    /// Mark the inherent terminal active without showing it yet, so the OSD can
    /// switch to its terminal-active layout before the pane is placed.
    func markInherentTerminalActive() {
        activateInherentTerminal()
    }

    /// Show the inherent terminal as a non-key pane at `frame` (the Deck positions
    /// it above its controls), but only if it's active — summoned and not yet
    /// ⌘W-closed. The shell stays warm across OSD shows/hides.
    func presentInherentTerminalPane(frame: CGRect) {
        guard terminalActive else { return }
        terminalController.showPeek(frame: frame)
    }

    /// Hide the inherent terminal pane (keeping the shell warm) when the OSD hides.
    func dismissInherentTerminalPane() {
        terminalController.hide()
    }

    /// Focus the inherent terminal for typing (the Deck backtick), summoning it at
    /// `frame` if needed and marking it active so it reappears with the OSD.
    func focusInherentTerminal(frame: CGRect) {
        activateInherentTerminal()
        terminalController.showPeek(frame: frame)
        terminalController.focus()
    }

    /// Run (or load) a commandlet in the inherent terminal. The Deck palette reveals
    /// its pane before calling; if no warm session is up (e.g. a standalone invocation),
    /// summon one centered so the run is visible. `load` writes the line and leaves the
    /// cursor for editing; otherwise the line runs (Enter).
    func runCommandlet(_ commandlet: Commandlet, load: Bool) {
        activateInherentTerminal()
        if !terminalController.isRunning {
            terminalController.showPeek(frame: terminalFrame())
        }
        // No focus() here: run keeps the terminal a non-key peek so the palette stays
        // interactive; load is focused by its caller (enterInherentTerminal) so edits land.
        if load {
            terminalController.send(commandlet.runLine)
        } else {
            terminalController.sendLine(commandlet.runLine)
        }
    }

    /// The inherent terminal's current working directory, for defaulting a slot's
    /// pinned folder to wherever the terminal is sitting. Nil when no session is up.
    func currentTerminalDirectory() -> String? {
        terminalController.currentWorkingDirectory
    }

    /// Mark the terminal active (re-presented with the OSD) and wire session-end to
    /// clear that, so a ⌘W-closed terminal stops reappearing until summoned again.
    /// Fired when the inherent terminal yields keyboard focus, so the Deck can re-arm
    /// its key control (set by the Deck).
    var onInherentTerminalYieldedFocus: () -> Void = {}

    private func activateInherentTerminal() {
        terminalActive = true
        terminalController.onSessionEnded = { [weak self] in self?.terminalActive = false }
        terminalController.onYieldFocus = { [weak self] in self?.onInherentTerminalYieldedFocus() }
    }

    /// A centered terminal frame on the active screen.
    private func terminalFrame() -> CGRect {
        let visible = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let size = CGSize(width: min(980, visible.width * 0.7), height: min(620, visible.height * 0.72))
        return CGRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2, width: size.width, height: size.height)
    }

    private func quickLookSelected() {
        guard let url = selectedItem?.url else { return }
        quickLook.preview(url)
    }

    // MARK: - OSD (Deck) registration

    private func registerOSD(id: String, options: FableValue, status: FableFunction?) {
        let opts = (try? options.decode(OSDOptions.self)) ?? OSDOptions()
        osdRegistrations[id] = OSDRegistration(
            id: id,
            group: opts.group ?? "Extensions",
            key: opts.key?.lowercased().first ?? "?",
            label: opts.label ?? id,
            tile: opts.tile ?? true,
            status: status
        )
    }

    /// Snapshot of the registered OSD entries for the Deck, pulling each live status
    /// callback (under the same budget as a spec pull). Called when the Deck opens.
    func osdEntries() -> [OSDEntry] {
        osdRegistrations.values.map { registration in
            let status = registration.status.flatMap { function in
                try? core.call(function, timeLimitSeconds: pullTimeLimitSeconds).string
            }
            return OSDEntry(
                id: registration.id,
                group: registration.group,
                key: registration.key,
                label: registration.label,
                tile: registration.tile,
                status: status
            )
        }
        .sorted { $0.label < $1.label }
    }

    // MARK: - Help (F1)

    func toggleHelp() {
        if helpShown {
            hideHelp()
            return
        }
        guard let id = visibleOverlayId, let spec = visibleSpec, let help = spec.help,
              let mainFrame = panel?.frame
        else { return }
        for pane in help.panes {
            guard pane.kind != .unknown, let raw = helpFrame(pane: pane, main: mainFrame) else { continue }
            let frame = clampOnScreen(raw)
            let helpPanel = makeHelpPanel(frame: frame)
            switch pane.kind {
            case .quickref:
                let keys = quickRefKeys(pane: pane, spec: spec, id: id)
                helpPanel.contentView = NSHostingView(rootView: QuickRefView(title: pane.title, keys: keys))
            case .prose:
                let prose = ProseHelpWebView(pane: pane)
                let container = NSView(frame: CGRect(origin: .zero, size: frame.size))
                container.wantsLayer = true
                container.layer?.cornerRadius = 14
                container.layer?.masksToBounds = true
                prose.webView.frame = container.bounds
                prose.webView.autoresizingMask = [.width, .height]
                container.addSubview(prose.webView)
                helpPanel.contentView = container
                helpProse.append(prose)
            case .unknown:
                continue
            }
            helpPanel.setFrame(frame, display: true)
            helpPanel.orderFrontRegardless()
            helpPanels.append(helpPanel)
        }
        helpShown = !helpPanels.isEmpty
    }

    private func hideHelp() {
        for helpPanel in helpPanels {
            helpPanel.orderOut(nil)
            helpPanel.contentView = nil
        }
        helpPanels.removeAll()
        helpProse.removeAll()
        helpShown = false
    }

    /// Quick-reference rows: the explicit `keys`, then (when `auto`) the built-in
    /// bindings implied by the item config plus any labeled `onKey` chords.
    private func quickRefKeys(pane: OverlayHelpPane, spec: OverlaySpec, id: String) -> [OverlayHelpKey] {
        var keys = pane.keys
        guard pane.auto else { return keys }
        if spec.item.quickLook { keys.append(OverlayHelpKey(key: "space", label: "Quick Look")) }
        if spec.item.arrows { keys.append(OverlayHelpKey(key: "↑ ↓ ← →", label: "Navigate")) }
        for binding in keyActions[id] ?? [] where !binding.label.isEmpty {
            keys.append(OverlayHelpKey(key: binding.key, label: binding.label))
        }
        return keys
    }

    /// A docked frame adjacent to the overlay. Sizes are a percent of the matching
    /// overlay dimension, or pixels; custom is positioned in the active monitor.
    private func helpFrame(pane: OverlayHelpPane, main: CGRect) -> CGRect? {
        let gap: CGFloat = 8
        switch pane.position {
        case .right:
            let width = length(pane.size, of: main.width, fallback: 260)
            return CGRect(x: main.maxX + gap, y: main.minY, width: width, height: main.height)
        case .left:
            let width = length(pane.size, of: main.width, fallback: 260)
            return CGRect(x: main.minX - gap - width, y: main.minY, width: width, height: main.height)
        case .above:
            let height = length(pane.size, of: main.height, fallback: 170)
            return CGRect(x: main.minX, y: main.maxY + gap, width: main.width, height: height)
        case .below:
            let height = length(pane.size, of: main.height, fallback: 170)
            return CGRect(x: main.minX, y: main.minY - gap - height, width: main.width, height: height)
        case .custom:
            let area = activeMonitorVisibleFrame()
            let width = length(pane.width, of: area.width, fallback: 320)
            let height = length(pane.height, of: area.height, fallback: 220)
            let originX = area.minX + length(pane.x, of: area.width, fallback: 0)
            // y is measured from the top of the visible area (author-friendly).
            let topOffset = length(pane.y, of: area.height, fallback: 0)
            return CGRect(x: originX, y: area.maxY - topOffset - height, width: width, height: height)
        }
    }

    /// Nudge a help-pane frame fully onto the screen it mostly overlaps, so a
    /// docked pane never lands off-screen (e.g. a left pane when the overlay's
    /// remembered position hugs the left edge).
    private func clampOnScreen(_ frame: CGRect) -> CGRect {
        let screen = NSScreen.screens.max(by: { first, second in
            let a = first.visibleFrame.intersection(frame)
            let b = second.visibleFrame.intersection(frame)
            let areaA = a.isNull ? 0 : a.width * a.height
            let areaB = b.isNull ? 0 : b.width * b.height
            return areaA < areaB
        })?.visibleFrame ?? (NSScreen.main?.visibleFrame ?? frame)
        var result = frame
        if result.maxX > screen.maxX { result.origin.x = screen.maxX - result.width }
        if result.minX < screen.minX { result.origin.x = screen.minX }
        if result.maxY > screen.maxY { result.origin.y = screen.maxY - result.height }
        if result.minY < screen.minY { result.origin.y = screen.minY }
        return result
    }

    /// Resolve a "NN%" (of `reference`) or pixel string to points.
    private func length(_ text: String?, of reference: CGFloat, fallback: CGFloat) -> CGFloat {
        guard let trimmed = text?.trimmingCharacters(in: .whitespaces), !trimmed.isEmpty else { return fallback }
        if trimmed.hasSuffix("%") {
            return (Double(trimmed.dropLast()).map { CGFloat($0) } ?? 0) / 100 * reference
        }
        return Double(trimmed).map { CGFloat($0) } ?? fallback
    }

    /// A non-activating panel for a help pane, so the main overlay keeps focus
    /// (F1 keeps toggling; grid keys keep working) while help is interactive.
    private func makeHelpPanel(frame: CGRect) -> NSPanel {
        let helpPanel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        helpPanel.level = .floating
        helpPanel.isFloatingPanel = true
        helpPanel.hidesOnDeactivate = false
        helpPanel.isOpaque = false
        helpPanel.backgroundColor = .clear
        helpPanel.hasShadow = true
        helpPanel.ignoresMouseEvents = false
        helpPanel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .stationary]
        return helpPanel
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
        // A handler may have mutated the filesystem (trash/run); reflect it live.
        refresh()
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
            if let help = self.visibleSpec?.help,
               let chord = OverlayKeyChord.parse(help.toggle), chord.matches(event)
            {
                self.toggleHelp()
                return nil
            }
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
            // Space/Cmd-Y Quick Looks, arrow keys navigate.
            item: { drag: "fileURL" },
            // F1 toggles help: a quick-reference (right) and pict-rendered prose (left).
            help: {
              toggle: "f1",
              panes: [
                { kind: "quickref", position: "right", size: 250, title: "Shortcuts", auto: true },
                { kind: "prose", position: "left", size: "32%", links: "browser",
                  markdown: "## Desktop\\n\\nRecent Desktop images. **Drag** one into any window; **Space** to Quick Look." }
              ]
            }
          };
        });

        // Developer key actions. The 4th arg labels the key for the F1 quick-reference.
        shell.overlay.onKey("desktop-shots", "c", function (item) { shell.clipboard(item.path); }, "Copy path");
        shell.overlay.onKey("desktop-shots", "r", function (item) { shell.reveal(item.path); shell.overlay.hide(); }, "Reveal in Finder");
        // Destructive actions are available too — bind them deliberately:
        // shell.overlay.onKey("desktop-shots", "t", function (item) { shell.trash(item.path); }, "Move to Trash");

        // Register in the Deck/OSD (Cmd-D): group, key, label + optional status callback.
        shell.overlay.osd("desktop-shots", { group: "Extensions", key: "o", label: "Desktop" }, function () {
          return "Recent Desktop images";
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
