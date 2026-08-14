// SPDX-FileCopyrightText: 2026 Steven Velozo
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import Foundation

/// Log severities that map 1:1 onto fable-log's methods (`log.info`, `log.warn`, …).
public enum FableLogLevel: String, Sendable, CaseIterable {
    case trace
    case debug
    case info
    case warn
    case error
}

/// An error raised while hosting or calling into the JavaScript logic core. Wraps
/// the JS-side message and, when available, the JS stack trace.
public struct FableCoreError: Error, CustomStringConvertible {
    public let message: String
    public let jsStack: String?

    public init(_ message: String, jsStack: String? = nil) {
        self.message = message
        self.jsStack = jsStack
    }

    public var description: String {
        guard let jsStack, !jsStack.isEmpty else { return message }
        return "\(message)\n\(jsStack)"
    }
}
