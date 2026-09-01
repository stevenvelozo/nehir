// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import FableCore
import Foundation
@testable import Nehir
import NehirShellWire
import os

/// Entry point for the **NehirShell** extension layer — a "modern LiteStep":
/// run-my-computer / shell features built on top of the base Nehir window
/// manager.
///
/// Everything in this target is fork-original and lives under `Sources/NehirShell/`,
/// a directory upstream does not have, so `git merge upstream/main` never touches
/// it. The only contact with the base window manager is:
///   - the bootstrap hook (`NehirShellHook.activate`, wired below), and
///   - whatever base APIs feature modules read through `@testable import Nehir`.
///
/// `@testable import Nehir` is deliberate: it lets the shell layer reach the
/// base manager's `internal` types (`WMController`, `SettingsStore`, …) without
/// forcing visibility changes in upstream-derived sources. It relies on the
/// `Nehir` target being built with `-enable-testing`, which it already is (see
/// `Package.swift`), and mirrors how `NehirApp` imports the base module.
public enum NehirShell {
    private static let log = Logger(subsystem: "dev.guria.nehir.shell", category: "NehirShell")

    /// The fable/pict logic core, held for the app's lifetime once activated.
    @MainActor static var core: FableCore?

    /// The shell control socket, held so it keeps listening for the app's lifetime.
    @MainActor static var controlSocket: ShellControlSocket?

    /// The desktop status panel, held so it stays on screen for the app's lifetime.
    @MainActor static var panel: ShellPanelController?

    /// The chord-driven Control Deck, held for the app's lifetime.
    @MainActor static var deck: ControlDeckController?

    /// Fork-local durable window rules (forced column width / always-float), held for
    /// the app's lifetime so the rule-effects hook can read them on every reconcile.
    @MainActor static var windowRules: WindowConfigStore?

    /// UserDefaults key the Display pane's cross-display-overflow toggle persists to.
    static let crossMonitorOverflowDefaultsKey = "NehirCrossMonitorOverflow"

    /// UserDefaults key for the F1 "show full window list in the OSD" toggle. When on, opening
    /// the Deck badges every window (managed columns + floating windows), not just the columns.
    static let showFullWindowListDefaultsKey = "NehirShowFullWindowList"

    /// The persisted F1 OSD full-window-list preference (defaults to off/false).
    static var showFullWindowList: Bool {
        get { UserDefaults.standard.bool(forKey: showFullWindowListDefaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: showFullWindowListDefaultsKey) }
    }

    /// The Sparkle auto-updater, held for the app's lifetime so its scheduled checks run.
    @MainActor static var updater: NehirUpdaterController?

    /// The global layout-family controller (River / Blades / Free), held for the app's life.
    @MainActor static var layoutModes: LayoutModeController?

    /// The abstract-viewport zoom controller, held for the app's lifetime so the persisted zoom
    /// applies from the first layout and the Deck can cycle it live.
    @MainActor static var viewportInset: ViewportInsetController?

    /// Persistent off-screen-column edge indicators, updated live from the layout hook.
    @MainActor static var offEdgeIndicators: OffEdgeIndicatorController?

    /// The pict-driven overlay feature (hotkey-summoned native popups), held for the
    /// app's lifetime so its hotkeys and JS registry stay live.
    @MainActor static var overlays: OverlayController?

    /// Called once from the app entry point (`NehirApp.init`) to register the
    /// shell layer with the base window manager. Public and parameterless so the
    /// app target can call it with a plain `import NehirShell` — no base-manager
    /// types cross the module boundary in this signature, and it carries no actor
    /// isolation so it composes cleanly with a Swift-5-mode caller.
    public static func install() {
        NehirShellHook.activate = { controller, settings in
            activate(controller: controller, settings: settings)
        }
    }

    /// Invoked on the main actor after the base `WMController` is fully
    /// bootstrapped (controller, status bar, and IPC are all up). This is the
    /// attach point for shell feature modules — config loading from a `nehir`
    /// shell-config namespace, a dedicated control socket, launchers/panels, and
    /// so on.
    ///
    /// v1 feature: bring the FableCore logic core online, load the shell config
    /// namespace into it, and (when enabled) start the shell control socket. The
    /// window manager itself is untouched — this is purely additive shell surface.
    @MainActor
    static func activate(controller: WMController, settings _: SettingsStore) {
        do {
            let core = try FableCore(product: "NehirShell")
            core.onLog = { level, line in
                log.log(level: Self.osLogType(for: level), "\(line, privacy: .public)")
            }
            self.core = core

            // Load the shell config namespace (~/.config/nehir/shell.d/) and push it
            // into fable so templates and the control socket can address it.
            let config = ShellConfigLoader.loadOrSeed()
            ShellConfigLoader.apply(config, to: core)
            NehirShellHook.allowCrossMonitorOverflow = initialCrossMonitorOverflow(config: config)
            core.log(.info, config.greeting)

            // Overlays: pict decides what to show, Swift renders it. Built here (before
            // the router) so `overlay.*` socket commands can drive it. Independent of the
            // Deck, so it comes up even when the Deck is disabled.
            let overlays = OverlayController(core: core, controller: controller)
            overlays.start(bindings: config.overlays)
            overlays.configureTerminal(config.terminal)
            self.overlays = overlays

            // Stand up the control socket in front of config + the logic core.
            let router = ShellCommandRouter(core: core, config: config, version: appVersion())
            router.overlays = overlays
            if config.socketEnabled {
                let socketPath = ShellPaths.socketPath()
                let socket = ShellControlSocket(socketPath: socketPath, router: router)
                try socket.start()
                controlSocket = socket
                log.info("shell control socket listening at \(socketPath, privacy: .public)")
            } else {
                log.info("shell control socket disabled by config")
            }

            // Show the desktop status panel (a fable-template desklet) if enabled.
            if config.panel.enabled {
                let model = ShellPanelModel(core: core, config: config.panel, custom: config.custom)
                let panel = ShellPanelController(model: model, config: config.panel)
                panel.show()
                self.panel = panel
                log.info("shell status panel shown (corner=\(config.panel.corner.rawValue, privacy: .public))")
            }

            // Load fork window rules and install the rule-effects hook so forced
            // column widths apply on every reconcile (percent → points per monitor).
            let windowRules = WindowConfigStore()
            self.windowRules = windowRules
            NehirShellHook.overrideRuleEffects = { [weak controller] effects, token, workspaceId in
                guard let controller else { return effects }
                return WindowConfigApplier.apply(
                    effects,
                    token: token,
                    workspaceId: workspaceId,
                    store: windowRules,
                    controller: controller
                )
            }
            // The WM's startup window-rescan runs BEFORE this hook is installed, so any
            // window admitted at launch never had its fork rule applied. Re-evaluate the
            // already-admitted windows once, now that the hook is live, so persisted forced
            // widths take effect on launch (windows created later self-apply on admission).
            let admittedTokens = controller.workspaceManager.allEntries().map(\.token)
            if !admittedTokens.isEmpty {
                Task { @MainActor [weak controller] in
                    _ = await controller?.reevaluateWindowRules(for: Set(admittedTokens.map { .window($0) }))
                }
            }

            startDeckAndUpdater(controller: controller, config: config)
        } catch {
            log.error("NehirShell failed to start: \(String(describing: error), privacy: .public)")
        }
    }

    /// Bring the Sparkle auto-updater online (feed URL + key from Info.plist) and, when
    /// enabled, stand up the chord-driven Control Deck wired to a manual update check.
    /// Resolve the launch value for cross-display overflow: the persisted Display-pane
    /// toggle wins; `[custom] crossMonitorOverflow = "true"` is the fallback default.
    private static func initialCrossMonitorOverflow(config: ShellConfig) -> Bool {
        UserDefaults.standard.object(forKey: crossMonitorOverflowDefaultsKey) as? Bool
            ?? (config.custom["crossMonitorOverflow"] == "true")
    }

    @MainActor
    private static func startDeckAndUpdater(controller: WMController, config: ShellConfig) {
        // Only bring Sparkle online once a real signing key is shipped; otherwise it
        // fatals on the placeholder key and pops an update-server error every launch.
        let updater = NehirUpdaterController.isConfigured ? NehirUpdaterController() : nil
        self.updater = updater
        if updater == nil {
            log.info("auto-updater disabled (SUPublicEDKey not configured)")
        }

        let layoutModes = LayoutModeController(controller: controller)
        self.layoutModes = layoutModes
        let viewportInset = ViewportInsetController(controller: controller)
        self.viewportInset = viewportInset

        let offEdge = OffEdgeIndicatorController()
        offEdge.controller = controller
        layoutModes.onDidApplyLayout = { [weak offEdge] workspaceId in
            offEdge?.update(workspaceId: workspaceId)
        }
        self.offEdgeIndicators = offEdge

        guard config.deck.enabled else { return }
        let deck = ControlDeckController(
            wmController: controller,
            gridColumns: config.deck.gridColumns,
            gridRows: config.deck.gridRows
        )
        if let updater {
            deck.onCheckForUpdates = { [weak updater] in updater?.checkForUpdates() }
        }
        deck.layoutModeController = layoutModes
        deck.viewportInsetController = viewportInset
        deck.overlays = overlays
        deck.install(
            primaryHotkey: config.deck.hotkey,
            remoteHotkey: config.deck.remoteHotkey,
            passthroughApps: config.deck.remotePassthroughApps
        )
        // Let the Settings pane read the current summon chords and re-register them live.
        overlays?.readDeckHotkeys = { [weak deck] in deck?.currentHotkeys() ?? ("cmd+d", "") }
        overlays?.applyDeckHotkeys = { [weak deck] primary, remote in
            deck?.applyHotkeysFromSettings(primary: primary, remote: remote)
        }
        self.deck = deck
        log.info("""
        control deck armed (hotkey=\(config.deck.hotkey, privacy: .public), \
        remoteHotkey=\(config.deck.remoteHotkey, privacy: .public))
        """)
    }

    private static func appVersion() -> String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0"
    }

    private static func osLogType(for level: FableLogLevel) -> OSLogType {
        switch level {
        case .trace,
             .debug: .debug
        case .info: .info
        case .warn: .default
        case .error: .error
        }
    }
}
