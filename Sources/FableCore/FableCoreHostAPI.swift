// SPDX-FileCopyrightText: 2026 Steven Velozo
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import Foundation
import JavaScriptCore

/// An opaque handle to a JavaScript function captured from the host (e.g. a
/// callback passed to `shell.every(ms, fn)`), so Swift can call it later without
/// `JSValue` leaking into FableCore's public surface. Call it with
/// `FableCore.call(_:arguments:timeLimitSeconds:)`.
public final class FableFunction {
    let value: JSValue
    init(_ value: JSValue) {
        self.value = value
    }
}

/// Typed, bounds-checked access to the arguments a JS caller passed to a host
/// function. Keeps `JSValue` internal — host closures work in Swift types.
public struct HostArgs {
    private let values: [JSValue]

    init(_ values: [JSValue]) {
        self.values = values
    }

    public var count: Int {
        values.count
    }

    public func string(at index: Int) -> String? {
        guard index < values.count, values[index].isString else { return nil }
        return values[index].toString()
    }

    public func number(at index: Int) -> Double? {
        guard index < values.count, values[index].isNumber else { return nil }
        return values[index].toDouble()
    }

    public func bool(at index: Int) -> Bool? {
        guard index < values.count, values[index].isBoolean else { return nil }
        return values[index].toBool()
    }

    /// A callable handle for an argument that is a JS function (functions are
    /// objects, so this returns non-nil for any object; calling a non-function
    /// later throws, which the caller handles).
    public func function(at index: Int) -> FableFunction? {
        guard index < values.count, values[index].isObject else { return nil }
        return FableFunction(values[index])
    }

    /// The raw bridged value at `index` (for objects/arrays a provider returned).
    public func value(at index: Int) -> FableValue {
        FableValue(index < values.count ? values[index] : nil)
    }
}

/// A native function exposed to the JavaScript host. Runs on the main actor (JS
/// is single-threaded and main-actor isolated here); may return a value to JS.
public typealias HostFunction = @MainActor (HostArgs) -> Any?

extension FableCore {
    /// Install native functions callable from JS as `<namespace>.<name>(...)`
    /// (e.g. namespace `"shell.overlay"`, name `"show"`). Intermediate namespace
    /// objects are created or reused, so this composes with a JS-defined object of
    /// the same name.
    public func installHostFunctions(namespace: String, _ functions: [String: HostFunction]) {
        runtime.installHostFunctions(namespace: namespace, functions)
    }

    /// Call a captured JS function, optionally under a wall-clock budget (used for
    /// user callbacks — a timer body or provider). On overrun the script is
    /// aborted and this throws; the budget is cleared before returning.
    @discardableResult
    public func call(
        _ function: FableFunction,
        arguments: [Any] = [],
        timeLimitSeconds: TimeInterval? = nil
    ) throws -> FableValue {
        if let timeLimitSeconds { runtime.setExecutionTimeLimit(timeLimitSeconds) }
        defer { if timeLimitSeconds != nil { runtime.clearExecutionTimeLimit() } }
        return FableValue(try runtime.callValue(function.value, arguments: arguments))
    }
}

extension JSRuntime {
    func installHostFunctions(namespace: String, _ functions: [String: HostFunction]) {
        let target = ensureNamespaceObject(namespace)
        for (name, function) in functions {
            let block: @convention(block) () -> Any? = {
                let raw = (JSContext.currentArguments() as? [JSValue]) ?? []
                var result: Any?
                MainActor.assumeIsolated { result = function(HostArgs(raw)) }
                return result
            }
            target.setObject(block, forKeyedSubscript: name as NSString)
        }
    }

    func callValue(_ function: JSValue, arguments: [Any]) throws -> JSValue {
        pendingException = nil
        let result = function.call(withArguments: arguments)
        try throwIfNeeded(source: "host-call")
        return result ?? JSValue(undefinedIn: context)
    }

    /// Walk (creating as needed) a dotted namespace path from the global object,
    /// returning the leaf object host functions attach to.
    private func ensureNamespaceObject(_ path: String) -> JSValue {
        var current = context.globalObject ?? JSValue(newObjectIn: context)!
        for segment in path.split(separator: ".").map(String.init) {
            let existing = current.objectForKeyedSubscript(segment)
            if let existing, existing.isObject, !existing.isUndefined, !existing.isNull {
                current = existing
            } else {
                let created = JSValue(newObjectIn: context) ?? JSValue(undefinedIn: context)!
                current.setObject(created, forKeyedSubscript: segment as NSString)
                current = created
            }
        }
        return current
    }
}
