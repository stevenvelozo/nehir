// SPDX-FileCopyrightText: 2026 Steven Velozo
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import AppKit
import FableCore
import Foundation
import NehirShellWire

/// Routes shell control-socket requests to the config store and the fable/pict
/// logic core. `@MainActor` (hence `Sendable`) so the socket's background reader
/// threads can hold a reference and hop here to run a command.
@MainActor
final class ShellCommandRouter {
    private let core: FableCore
    private let version: String
    private var config: ShellConfig
    /// Set after construction (the overlay controller is built later in startup) so
    /// `overlay.*` commands can drive it — used for iPad-remote / scripted summons.
    weak var overlays: OverlayController?

    init(core: FableCore, config: ShellConfig, version: String) {
        self.core = core
        self.version = version
        self.config = config
    }

    /// Handle one JSON request line, returning a JSON response line (no trailing
    /// newline — the socket frames responses).
    func handleLine(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return encode(.failure("empty request"))
        }
        guard let data = trimmed.data(using: .utf8),
              let request = try? JSONDecoder().decode(ShellRequest.self, from: data)
        else {
            return encode(.failure("invalid JSON request"))
        }
        return encode(handle(request))
    }

    // MARK: - Command dispatch

    private func handle(_ request: ShellRequest) -> ShellResponse {
        switch request.command {
        case "ping": return .success("pong")
        case "version": return .success(version)
        case "config.get": return configGet(request)
        case "config.reload": return configReload()
        case "config.dump": return configDump()
        case "solve": return solveExpression(request)
        case "render": return renderTemplate(request)
        case "log": return emitLog(request)
        case "overlay.show": return overlayShow(request)
        case "overlay.hide":
            overlays?.hide()
            return .success("hidden")
        case "overlay.list":
            return .success(overlays?.listRegistered().joined(separator: ", ") ?? "")
        case "quit": return quitApp()
        default: return .failure("unknown command \"\(request.command)\"")
        }
    }

    private func overlayShow(_ request: ShellRequest) -> ShellResponse {
        guard let id = request.key else { return .failure("overlay.show requires 'key' (the overlay id)") }
        guard let overlays else { return .failure("overlays are not available") }
        overlays.show(id)
        return .success("showing \(id)")
    }

    private func quitApp() -> ShellResponse {
        // Terminate on the next run-loop tick so this response flushes first. This
        // runs the app's normal shutdown path, which restores parked windows.
        DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
        return .success("quitting")
    }

    private func configGet(_ request: ShellRequest) -> ShellResponse {
        guard let key = request.key else { return .failure("config.get requires 'key'") }
        return .success(describe(core.setting("Shell.\(key)")))
    }

    private func configReload() -> ShellResponse {
        let reloaded = ShellConfigLoader.loadOrSeed()
        config = reloaded
        ShellConfigLoader.apply(reloaded, to: core)
        return .success("reloaded \(reloaded.custom.count) custom key(s)")
    }

    private func configDump() -> ShellResponse {
        var dump = config.custom
        dump["socketEnabled"] = String(config.socketEnabled)
        dump["greeting"] = config.greeting
        return .success(values: dump)
    }

    private func solveExpression(_ request: ShellRequest) -> ShellResponse {
        guard let expression = request.expression else { return .failure("solve requires 'expression'") }
        do {
            return .success(try core.solve(expression).string ?? "")
        } catch {
            return .failure(String(describing: error))
        }
    }

    private func renderTemplate(_ request: ShellRequest) -> ShellResponse {
        guard let template = request.template else { return .failure("render requires 'template'") }
        do {
            return .success(try core.render(template, data: request.data ?? [:]))
        } catch {
            return .failure(String(describing: error))
        }
    }

    private func emitLog(_ request: ShellRequest) -> ShellResponse {
        let level = FableLogLevel(rawValue: request.level ?? "info") ?? .info
        core.log(level, request.message ?? "")
        return .success("logged")
    }

    // MARK: - Helpers

    private func describe(_ value: FableValue) -> String {
        if let string = value.string { return string }
        if let int = value.int { return String(int) }
        if let bool = value.bool { return String(bool) }
        if let double = value.double { return String(double) }
        return value.isNull ? "" : String(describing: value.raw ?? "")
    }

    private func encode(_ response: ShellResponse) -> String {
        guard let data = try? JSONEncoder().encode(response),
              let json = String(data: data, encoding: .utf8)
        else {
            return #"{"ok":false,"error":"response encoding failed"}"#
        }
        return json
    }
}
