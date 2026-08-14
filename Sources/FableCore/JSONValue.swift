// SPDX-FileCopyrightText: 2026 Steven Velozo
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import Foundation

/// A `Sendable`, `Codable` JSON value — the marshaling currency for the unified
/// runtime protocol, so requests and results can cross an `async`/process boundary
/// without dragging non-`Sendable` `Any` along.
public enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }

    // MARK: - Convenience

    public var string: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    public var double: Double? {
        if case let .number(value) = self { return value }
        return nil
    }

    public var int: Int? {
        double.map(Int.init)
    }

    public var bool: Bool? {
        if case let .bool(value) = self { return value }
        return nil
    }

    public var object: [String: JSONValue]? {
        if case let .object(value) = self { return value }
        return nil
    }

    public var array: [JSONValue]? {
        if case let .array(value) = self { return value }
        return nil
    }

    /// Keyed lookup into an object value; `.null` for anything else.
    public subscript(key: String) -> JSONValue {
        object?[key] ?? .null
    }

    /// A `[String: String]` view of an object of string values (skips non-strings).
    public var stringMap: [String: String] {
        guard case let .object(value) = self else { return [:] }
        return value.compactMapValues(\.string)
    }
}
