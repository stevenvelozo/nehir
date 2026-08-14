// SPDX-FileCopyrightText: 2026 Steven Velozo
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import Foundation

/// A runtime that can execute named retold operations and return a JSON result.
///
/// The same surface is implemented by two backends: `FableCore` (in-process
/// JavaScriptCore — synchronous, zero external dependencies, no network/DB) and a
/// Node sidecar (out-of-process — real async, network, filesystem, and full npm
/// modules such as meadow). Callers hold `any FableRuntime` and stay agnostic to
/// where the work actually runs; the sidecar is chosen only when an operation
/// needs capabilities JavaScriptCore cannot provide.
public protocol FableRuntime: Sendable {
    /// Execute `method` with JSON `params`, returning a JSON result. Method names
    /// and their expected params are backend-defined; a backend throws for methods
    /// it does not implement.
    func invoke(_ method: String, _ params: JSONValue) async throws -> JSONValue

    /// Release any backing resources (e.g. terminate a sidecar process).
    func shutdown() async
}

// MARK: - FableCore conformance (in-process JavaScriptCore backend)

extension FableCore: FableRuntime {
    public nonisolated func invoke(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        try await MainActor.run {
            try self.invokeOnMain(method, params)
        }
    }

    // swiftlint:disable:next async_without_await
    public nonisolated func shutdown() async {}

    @MainActor
    private func invokeOnMain(_ method: String, _ params: JSONValue) throws -> JSONValue {
        switch method {
        case "uuid": return .string(uuid())
        case "solve": return try invokeSolve(params)
        case "render": return try invokeRender(params)
        case "config.get": return try invokeConfigGet(params)
        case "config.set": return invokeConfigSet(params)
        case "log": return invokeLog(params)
        default: throw FableCoreError("FableCore has no in-process method \"\(method)\"")
        }
    }

    @MainActor
    private func invokeSolve(_ params: JSONValue) throws -> JSONValue {
        guard let expression = params["expression"].string else {
            throw FableCoreError("solve requires string param 'expression'")
        }
        return try solve(expression, scope: params["scope"].stringMap).json
    }

    @MainActor
    private func invokeRender(_ params: JSONValue) throws -> JSONValue {
        guard let template = params["template"].string else {
            throw FableCoreError("render requires string param 'template'")
        }
        return .string(try render(template, data: params["data"].stringMap))
    }

    @MainActor
    private func invokeConfigGet(_ params: JSONValue) throws -> JSONValue {
        guard let key = params["key"].string else {
            throw FableCoreError("config.get requires string param 'key'")
        }
        return setting(key).json
    }

    @MainActor
    private func invokeConfigSet(_ params: JSONValue) -> JSONValue {
        guard let key = params["key"].string else { return .bool(false) }
        setSetting(key, params["value"].string ?? params["value"].double ?? params["value"].bool ?? "")
        return .bool(true)
    }

    @MainActor
    private func invokeLog(_ params: JSONValue) -> JSONValue {
        let level = FableLogLevel(rawValue: params["level"].string ?? "info") ?? .info
        log(level, params["message"].string ?? "")
        return .bool(true)
    }
}

// MARK: - FableValue → JSONValue

extension FableValue {
    /// Best-effort conversion of the bridged value into a `JSONValue`.
    public var json: JSONValue {
        guard let raw else { return .null }
        if let data = try? JSONSerialization.data(withJSONObject: raw, options: [.fragmentsAllowed]),
           let value = try? JSONDecoder().decode(JSONValue.self, from: data)
        {
            return value
        }
        if let string = raw as? String { return .string(string) }
        if let number = raw as? NSNumber { return .number(number.doubleValue) }
        return .null
    }
}
