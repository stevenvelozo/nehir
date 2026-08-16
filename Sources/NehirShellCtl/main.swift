// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import Foundation
import NehirShellWire

func die(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

func parseKeyValues(_ pairs: [String]) -> [String: String] {
    var result: [String: String] = [:]
    for pair in pairs {
        guard let separator = pair.firstIndex(of: "=") else { continue }
        result[String(pair[..<separator])] = String(pair[pair.index(after: separator)...])
    }
    return result
}

let usage = """
nehirshellctl — control the Nehir shell layer over its Unix socket.

Usage:
  nehirshellctl ping
  nehirshellctl version
  nehirshellctl quit                       # gracefully quit Nehir (restores parked windows)
  nehirshellctl solve <expression>
  nehirshellctl render <template> [key=value ...]
  nehirshellctl config get <key>
  nehirshellctl config reload
  nehirshellctl config dump
  nehirshellctl overlay list                # list registered overlay ids
  nehirshellctl overlay show <id>           # summon an overlay (no hotkey needed)
  nehirshellctl overlay hide
  nehirshellctl log <trace|debug|info|warn|error> <message ...>

Examples:
  nehirshellctl solve "(2 + 3) * 4"
  nehirshellctl render "Hi {~Data:Record.name~}" name=Steven
  nehirshellctl config get greeting

Socket path: $NEHIR_SHELL_SOCKET, else \(ShellPaths.socketPath())
"""

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    print(usage)
    exit(0)
}

let request: ShellRequest
switch command {
case "-h",
     "--help",
     "help":
    print(usage)
    exit(0)

case "ping":
    request = ShellRequest(command: "ping")

case "version":
    request = ShellRequest(command: "version")

case "quit":
    request = ShellRequest(command: "quit")

case "solve":
    guard arguments.count >= 2 else { die("usage: nehirshellctl solve <expression>") }
    request = ShellRequest(command: "solve", expression: arguments[1])

case "render":
    guard arguments.count >= 2 else { die("usage: nehirshellctl render <template> [key=value ...]") }
    let data = parseKeyValues(Array(arguments.dropFirst(2)))
    request = ShellRequest(command: "render", template: arguments[1], data: data.isEmpty ? nil : data)

case "config":
    guard arguments.count >= 2 else { die("usage: nehirshellctl config <get|reload|dump> [key]") }
    switch arguments[1] {
    case "get":
        guard arguments.count >= 3 else { die("usage: nehirshellctl config get <key>") }
        request = ShellRequest(command: "config.get", key: arguments[2])
    case "reload":
        request = ShellRequest(command: "config.reload")
    case "dump":
        request = ShellRequest(command: "config.dump")
    default:
        die("unknown config subcommand \"\(arguments[1])\" (get|reload|dump)")
    }

case "overlay":
    guard arguments.count >= 2 else { die("usage: nehirshellctl overlay <show|hide|list> [id]") }
    switch arguments[1] {
    case "show":
        guard arguments.count >= 3 else { die("usage: nehirshellctl overlay show <id>") }
        request = ShellRequest(command: "overlay.show", key: arguments[2])
    case "hide":
        request = ShellRequest(command: "overlay.hide")
    case "list":
        request = ShellRequest(command: "overlay.list")
    default:
        die("unknown overlay subcommand \"\(arguments[1])\" (show|hide|list)")
    }

case "log":
    guard arguments.count >= 3 else { die("usage: nehirshellctl log <level> <message ...>") }
    request = ShellRequest(
        command: "log",
        message: arguments.dropFirst(2).joined(separator: " "),
        level: arguments[1]
    )

default:
    die("unknown command \"\(command)\" (try `nehirshellctl help`)")
}

let client = ShellControlClient(socketPath: ShellPaths.socketPath())
do {
    let response = try client.send(request)
    guard response.ok else {
        die(response.error ?? "command failed")
    }
    if let values = response.values {
        for key in values.keys.sorted() {
            print("\(key)=\(values[key] ?? "")")
        }
    } else if let result = response.result, !result.isEmpty {
        print(result)
    }
    exit(0)
} catch let error as ShellControlClient.ClientError {
    die(error.description, code: 2)
} catch {
    die(String(describing: error), code: 2)
}
