// SPDX-FileCopyrightText: 2026 Steven Velozo
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import FableCore
import Foundation
import NehirShellWire
import TOML

/// Resolved NehirShell configuration.
///
/// Split into a small typed core (the settings the shell itself acts on) plus a
/// free-form `custom` string map for user values that flow into fable — readable
/// from templates (`{~Data:…~}`) and over the control socket (`config.get`).
struct ShellConfig: Sendable, Equatable {
    var socketEnabled: Bool
    var greeting: String
    var panel: PanelConfig
    var deck: DeckConfig
    var terminal: TerminalConfig
    var overlays: [OverlayBinding]
    var custom: [String: String]

    static let fallback = ShellConfig(
        socketEnabled: true,
        greeting: "Nehir shell online",
        panel: .fallback,
        deck: .fallback,
        terminal: .fallback,
        overlays: [],
        custom: [:]
    )
}

/// Appearance for the Deck's inherent terminal pane.
struct TerminalConfig: Sendable, Equatable {
    /// Point size of the terminal font.
    var fontSize: Double
    /// Font family name; empty uses the system monospaced font.
    var fontFamily: String
    /// Background opacity, 0…1 (1 = fully opaque). Lets the desktop show through.
    var opacity: Double
    /// Corner radius of the pane, in points.
    var cornerRadius: Double
    /// Margin (points) around the terminal-active OSD assembly on the screen edges.
    var margin: Double
    /// Inner padding (points) between the terminal text and the pane edge.
    var padding: Double
    /// Terminal height in text rows (vertical lines) — the single source of truth for the
    /// pane height, used identically by backtick-focus and a commandlet run.
    var rows: Int

    static let fallback = TerminalConfig(fontSize: 13, fontFamily: "", opacity: 1.0, cornerRadius: 12, margin: 72, padding: 10, rows: 24)
}

/// Configuration for the Control Deck — the chord-driven window-management HUD.
struct DeckConfig: Sendable, Equatable {
    var enabled: Bool
    /// Global trigger chord, e.g. "cmd+d", "opt+cmd+space". Registered as a Carbon hotkey,
    /// so the OS always consumes it on *this* machine (never forwarded to a Screen Sharing
    /// session) — it opens the local OSD.
    var hotkey: String
    /// A second summon chord for reaching the OSD *through* a Screen Sharing session. Handled
    /// by an event tap: when a `remotePassthroughApps` window is focused it passes the chord
    /// through (so it lands on the machine you're shelled into, whose own Nehir opens its OSD);
    /// otherwise it opens the local OSD — so, like the primary, it shadows this chord in the
    /// focused local app whenever you're not in a session. Empty (or an unparseable / duplicate
    /// value) disables it.
    var remoteHotkey: String
    /// Bundle IDs whose focused window makes `remoteHotkey` pass through to the remote instead
    /// of opening the local OSD (default: macOS Screen Sharing). Add other remote-desktop
    /// clients (VNC, RDP, …) here.
    var remotePassthroughApps: [String]
    /// Resize-grid dimensions (columns × rows).
    var gridColumns: Int
    var gridRows: Int

    static let fallback = DeckConfig(
        enabled: true,
        hotkey: "cmd+d",
        remoteHotkey: "cmd+j",
        remotePassthroughApps: ["com.apple.ScreenSharing"],
        gridColumns: 8,
        gridRows: 5
    )
}

/// Configuration for the desktop status panel — a fable-template-driven desklet.
struct PanelConfig: Sendable, Equatable {
    var enabled: Bool
    var template: String
    var refreshSeconds: Double
    var corner: PanelCorner

    static let fallback = PanelConfig(
        enabled: false,
        template: "{~Data:Record.time~}   {~Data:Record.date~}",
        refreshSeconds: 1.0,
        corner: .topRight
    )
}

enum PanelCorner: String, Sendable, Equatable {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    init(label: String) {
        self = PanelCorner(rawValue: label) ?? .topRight
    }
}

/// On-disk schema for a single `shell.d/*.toml` file. Every field is optional so a
/// fragment can set just the keys it cares about; missing keys fall back to prior
/// files (then to `ShellConfig.fallback`).
private struct ShellConfigFile: Decodable {
    struct Socket: Decodable { var enabled: Bool? }
    struct Shell: Decodable { var greeting: String? }
    struct Panel: Decodable {
        var enabled: Bool?
        var template: String?
        var refreshSeconds: Double?
        var corner: String?
    }

    struct Deck: Decodable {
        var enabled: Bool?
        var hotkey: String?
        var remoteHotkey: String?
        var remotePassthroughApps: [String]?
        var grid: String?
    }

    struct Terminal: Decodable {
        var fontSize: Double?
        var fontFamily: String?
        var opacity: Double?
        var cornerRadius: Double?
        var margin: Double?
        var padding: Double?
        var rows: Int?
    }

    struct Overlay: Decodable {
        var id: String?
        var hotkey: String?
        var enabled: Bool?
    }

    var socket: Socket?
    var shell: Shell?
    var panel: Panel?
    var deck: Deck?
    var terminal: Terminal?
    var overlay: [Overlay]?
    var custom: [String: String]?
}

/// Loads and merges the shell config directory, seeding a documented sample on
/// first run.
enum ShellConfigLoader {
    /// Load `~/.config/nehir/shell.d/`, creating the directory and a starter
    /// `00-shell.toml` if it does not exist yet.
    static func loadOrSeed(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> ShellConfig {
        let directory = ShellPaths.configDirectory(environment: environment)
        if !fileManager.fileExists(atPath: directory.path) {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            seedSample(in: directory)
        }
        return load(from: directory, fileManager: fileManager)
    }

    /// Merge every `*.toml` in `directory` in filename order (later files win).
    /// Unparseable files are skipped rather than failing the whole load.
    static func load(from directory: URL, fileManager: FileManager = .default) -> ShellConfig {
        var result = ShellConfig.fallback
        let files = ((try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? [])
            .filter { $0.pathExtension == "toml" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        for file in files {
            guard let data = try? Data(contentsOf: file),
                  let parsed = try? TOMLDecoder().decode(ShellConfigFile.self, from: data)
            else { continue }

            if let enabled = parsed.socket?.enabled { result.socketEnabled = enabled }
            if let greeting = parsed.shell?.greeting { result.greeting = greeting }
            mergePanel(parsed.panel, into: &result.panel)
            mergeDeck(parsed.deck, into: &result.deck)
            mergeTerminal(parsed.terminal, into: &result.terminal)
            mergeOverlays(parsed.overlay, into: &result.overlays)
            if let custom = parsed.custom {
                result.custom.merge(custom) { _, latest in latest }
            }
        }
        return result
    }

    private static func mergePanel(_ panel: ShellConfigFile.Panel?, into result: inout PanelConfig) {
        guard let panel else { return }
        if let enabled = panel.enabled { result.enabled = enabled }
        if let template = panel.template { result.template = template }
        if let refresh = panel.refreshSeconds { result.refreshSeconds = refresh }
        if let corner = panel.corner { result.corner = PanelCorner(label: corner) }
    }

    private static func mergeDeck(_ deck: ShellConfigFile.Deck?, into result: inout DeckConfig) {
        guard let deck else { return }
        if let enabled = deck.enabled { result.enabled = enabled }
        if let hotkey = deck.hotkey { result.hotkey = hotkey }
        if let remoteHotkey = deck.remoteHotkey { result.remoteHotkey = remoteHotkey }
        if let apps = deck.remotePassthroughApps { result.remotePassthroughApps = apps }
        if let grid = deck.grid, let dimensions = parseGridDimensions(grid) {
            result.gridColumns = dimensions.columns
            result.gridRows = dimensions.rows
        }
    }

    private static func mergeTerminal(_ terminal: ShellConfigFile.Terminal?, into result: inout TerminalConfig) {
        guard let terminal else { return }
        if let fontSize = terminal.fontSize { result.fontSize = fontSize }
        if let fontFamily = terminal.fontFamily { result.fontFamily = fontFamily }
        if let opacity = terminal.opacity { result.opacity = opacity }
        if let cornerRadius = terminal.cornerRadius { result.cornerRadius = cornerRadius }
        if let margin = terminal.margin { result.margin = margin }
        if let padding = terminal.padding { result.padding = padding }
        if let rows = terminal.rows { result.rows = rows }
    }

    /// Accumulate `[[overlay]]` tables across files. A later file binding the same
    /// id replaces the earlier one (so a fragment can override the hotkey or
    /// disable a seeded overlay); a valid table needs both an id and a hotkey.
    private static func mergeOverlays(_ overlays: [ShellConfigFile.Overlay]?, into result: inout [OverlayBinding]) {
        guard let overlays else { return }
        for overlay in overlays {
            guard let id = overlay.id, !id.isEmpty, let hotkey = overlay.hotkey, !hotkey.isEmpty else { continue }
            let binding = OverlayBinding(id: id, hotkey: hotkey, enabled: overlay.enabled ?? true)
            if let index = result.firstIndex(where: { $0.id == id }) {
                result[index] = binding
            } else {
                result.append(binding)
            }
        }
    }

    /// Parse a "COLUMNSxROWS" grid string (e.g. "8x5") into positive dimensions.
    private static func parseGridDimensions(_ string: String) -> (columns: Int, rows: Int)? {
        let parts = string.lowercased().split(separator: "x")
        guard parts.count == 2,
              let columns = Int(parts[0]), columns > 0,
              let rows = Int(parts[1]), rows > 0
        else { return nil }
        return (columns, rows)
    }

    /// Push resolved config into the fable settings object under a `Shell`
    /// namespace, so templates and the control socket can address it.
    @MainActor
    static func apply(_ config: ShellConfig, to core: FableCoreConfigTarget) {
        core.setSetting("Shell.socketEnabled", config.socketEnabled)
        core.setSetting("Shell.greeting", config.greeting)
        for (key, value) in config.custom {
            core.setSetting("Shell.\(key)", value)
        }
    }

    private static func seedSample(in directory: URL) {
        let sample = """
        # NehirShell configuration — the fork's "modern LiteStep" layer.
        # This is NOT base Nehir config; the window manager's own settings stay in
        # ~/.config/nehir/settings.toml etc. Files in this directory are merged in
        # filename order (later files win), so drop per-feature fragments alongside
        # this one.

        [socket]
        # Enable the shell control socket (nehir shell IPC). Disable to run the
        # shell layer without an external control surface.
        enabled = true

        [shell]
        # Logged when the shell layer comes online.
        greeting = "Nehir shell online"

        [panel]
        # A desktop status desklet whose text is a fable template, rendered live by
        # FableCore. Off by default; set enabled = true to show it.
        enabled = false
        # Template data record provides: time, date, weekday, host — plus every
        # [custom] key below. Inline solver hashes ({~Solve:...~}) work too.
        template = "{~Data:Record.time~}   {~Data:Record.date~}"
        refreshSeconds = 1
        # topRight | topLeft | bottomRight | bottomLeft
        corner = "topRight"

        [deck]
        # The Control Deck: a chord-driven window-management HUD.
        enabled = true
        # Global trigger chord. NOTE: cmd+d shadows app shortcuts (browser bookmark,
        # "Don't Save" in save dialogs) system-wide — change it here if that bites.
        # e.g. "opt+cmd+d", "opt+cmd+space", "ctrl+shift+j".
        hotkey = "cmd+d"
        # A SECOND summon chord for reaching the OSD across a Screen Sharing session. When a
        # window listed in remotePassthroughApps is focused, this chord passes THROUGH to that
        # session (so the Mac you're shelled into opens its own OSD); otherwise it opens the
        # LOCAL OSD — so it shadows this chord in the focused app whenever you're NOT in a
        # session (cmd+j is used by some apps). Pick a chord that isn't already eaten locally
        # (cmd+d is). An unparseable or duplicate value disables it; empty = disabled.
        remoteHotkey = "cmd+j"
        # Focused windows of these apps make remoteHotkey pass through instead of opening the
        # local OSD. Add other remote-desktop clients (VNC, RDP, …) as needed.
        remotePassthroughApps = ["com.apple.ScreenSharing"]
        # Resize-grid dimensions (columns x rows) you drag on in the Resize submode.
        grid = "8x5"

        [terminal]
        # The Deck's inherent terminal pane (⌘D then backtick). Changes apply to the
        # next session — ⌘W to close it, then summon again (or restart Nehir).
        fontSize = 13
        # Font family; empty uses the system monospaced font. e.g. "Menlo", "SF Mono".
        fontFamily = ""
        # Background opacity 0..1 (1 = opaque). Lower it to see the desktop through it.
        opacity = 1.0
        # Corner radius of the pane, in points.
        cornerRadius = 12
        # Margin (points) around the terminal-active OSD on the screen edges.
        margin = 72
        # Inner padding (points) between the terminal text and the pane edge.
        padding = 10
        # Terminal height in text rows (vertical lines) — the source of truth for the pane
        # height, used by both backtick-focus and a commandlet run.
        rows = 24

        # Overlays: pict-driven native popups summoned by a hotkey. The overlay's
        # provider (WHAT to show) lives in a small script under
        # ~/.config/nehir/overlays/*.js; this block binds it to a chord. Add one
        # [[overlay]] block per overlay. The seeded "desktop-shots" overlay pops a
        # draggable grid of recent ~/Desktop images. NOTE: avoid opt+cmd+d — macOS
        # reserves it for the Dock auto-hide toggle, so it never reaches Nehir.
        [[overlay]]
        id = "desktop-shots"
        hotkey = "ctrl+opt+cmd+o"
        enabled = true

        # Arbitrary string values. Readable from fable templates as
        # {~Data:Record.<key>~} after a render `data` merge, and over the control
        # socket via `config.get <key>`.
        [custom]
        # example = "value"
        """
        try? Data(sample.utf8).write(to: directory.appendingPathComponent("00-shell.toml", isDirectory: false))
    }
}

/// The slice of `FableCore` the config loader needs — declared as a protocol so
/// `ShellConfigLoader` stays unit-testable without a live JavaScriptCore host.
@MainActor
protocol FableCoreConfigTarget: AnyObject {
    func setSetting(_ keyPath: String, _ value: Any)
}

extension FableCore: FableCoreConfigTarget {}
