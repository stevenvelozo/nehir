// SPDX-FileCopyrightText: 2026 Steven Velozo
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import Foundation

/// A single newline-delimited JSON request on the shell control socket.
///
/// Deliberately its own wire protocol on its own socket — the base manager's
/// `IPCCommandName` is an exhaustive Swift enum, so extending it would mean
/// conflict-prone edits to upstream. This layer owns its vocabulary end to end,
/// and shares these types between the server and the `nehirshellctl` client.
public struct ShellRequest: Codable, Sendable {
    public var command: String
    public var key: String?
    public var expression: String?
    public var template: String?
    public var data: [String: String]?
    public var message: String?
    public var level: String?

    public init(
        command: String,
        key: String? = nil,
        expression: String? = nil,
        template: String? = nil,
        data: [String: String]? = nil,
        message: String? = nil,
        level: String? = nil
    ) {
        self.command = command
        self.key = key
        self.expression = expression
        self.template = template
        self.data = data
        self.message = message
        self.level = level
    }
}

/// A single newline-delimited JSON response.
public struct ShellResponse: Codable, Sendable {
    public var ok: Bool
    public var result: String?
    public var error: String?
    public var values: [String: String]?

    public init(ok: Bool, result: String? = nil, error: String? = nil, values: [String: String]? = nil) {
        self.ok = ok
        self.result = result
        self.error = error
        self.values = values
    }

    public static func success(_ result: String? = nil, values: [String: String]? = nil) -> ShellResponse {
        ShellResponse(ok: true, result: result, error: nil, values: values)
    }

    public static func failure(_ error: String) -> ShellResponse {
        ShellResponse(ok: false, result: nil, error: error, values: nil)
    }
}
