// SPDX-FileCopyrightText: 2026 Steven Velozo
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import Foundation
import JavaScriptCore

/// A Foundation-bridged value returned from the JavaScript logic core, with typed
/// accessors and a JSON-based `decode` for `Decodable` models. This keeps
/// `JSValue` out of FableCore's public surface — callers work in Swift types.
public struct FableValue {
    /// The bridged value (`String`, `NSNumber`, `[String: Any]`, `[Any]`, or nil).
    public let raw: Any?

    init(_ jsValue: JSValue?) {
        guard let jsValue, !jsValue.isUndefined, !jsValue.isNull else {
            raw = nil
            return
        }
        raw = jsValue.toObject()
    }

    init(raw: Any?) {
        self.raw = raw
    }

    public var isNull: Bool {
        raw == nil
    }

    public var string: String? {
        raw as? String
    }

    public var bool: Bool? {
        (raw as? Bool) ?? (raw as? NSNumber)?.boolValue
    }

    public var int: Int? {
        (raw as? Int) ?? (raw as? NSNumber)?.intValue
    }

    public var double: Double? {
        (raw as? Double) ?? (raw as? NSNumber)?.doubleValue
    }

    public var dictionary: [String: Any]? {
        raw as? [String: Any]
    }

    public var array: [Any]? {
        raw as? [Any]
    }

    /// Decode the bridged value into a `Decodable` model by round-tripping through
    /// JSON. Useful for pulling a structured config or service result into a Swift
    /// struct.
    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        guard let raw else {
            throw FableCoreError("cannot decode a null FableValue into \(T.self)")
        }
        let data = try JSONSerialization.data(withJSONObject: raw)
        return try JSONDecoder().decode(T.self, from: data)
    }
}
