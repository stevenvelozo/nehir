// SPDX-FileCopyrightText: 2026 Steven Velozo
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

// This file is Swift-6-only and consumed in-process by the (also Swift-6) shell
// layer, so the "annotate public MainActor API with @preconcurrency for Swift 5
// compatibility" heuristic is a false positive here. Disable it file-wide.
// swiftlint:disable incompatible_concurrency_annotation

import Foundation
import JavaScriptCore

/// An in-process bridge to the retold **fable/pict** ecosystem, hosted in
/// JavaScriptCore. One `FableCore` owns one Pict application instance (Pict
/// extends Fable, so this single surface covers both): service dependency
/// injection, configuration, logging, templating, and expression solving — all
/// reusing the shipped `pict.min.js` bundle rather than reimplementing anything in
/// Swift.
///
/// Main-actor isolated: JavaScriptCore is single-threaded and every call funnels
/// through the app's main actor. Work that needs real Node (network, database
/// connectors, long-running servers) is out of scope here by design and belongs to
/// a Node sidecar reached over the shell's control socket.
@MainActor
public final class FableCore {
    private let runtime: JSRuntime
    private let app: JSValue
    private let helpers: JSValue

    /// Receives fable-log output (and any other `console.*` writes) emitted by the
    /// JavaScript side, so the host can route it into the app's own logging.
    public var onLog: ((FableLogLevel, String) -> Void)?

    /// Spin up a logic core. `product` names the fable/pict application (used in log
    /// lines and config); `settings` seeds the fable settings object.
    public init(product: String, settings: [String: Any] = [:]) throws {
        let runtime = try JSRuntime()
        let constructor = try runtime.bootstrap()

        var seedSettings = settings
        if seedSettings["Product"] == nil {
            seedSettings["Product"] = product
        }

        let instance = try runtime.construct(constructor, arguments: [seedSettings])
        guard let helpers = runtime.context.objectForKeyedSubscript("__fableCoreHelpers"),
              !helpers.isUndefined
        else {
            throw FableCoreError("FableCore helper surface failed to load")
        }

        self.runtime = runtime
        app = instance
        self.helpers = helpers

        // Wire console/log forwarding now that all stored properties exist.
        runtime.onConsole = { [weak self] level, line in
            self?.onLog?(level, line)
        }
    }

    // MARK: - Identity

    /// A fresh v4 UUID from fable's UUID service.
    public func uuid() -> String {
        (try? runtime.invoke(app, method: "getUUID", arguments: []).toString()) ?? ""
    }

    // MARK: - Logging (Swift → fable-log)

    /// Emit a structured log line through fable-log. `datum` is passed as the
    /// bunyan-style second argument.
    public func log(_ level: FableLogLevel, _ message: String, _ datum: [String: Any]? = nil) {
        guard let logObject = app.objectForKeyedSubscript("log"), !logObject.isUndefined else { return }
        var arguments: [Any] = [message]
        if let datum {
            arguments.append(datum)
        }
        _ = try? runtime.invoke(logObject, method: level.rawValue, arguments: arguments)
    }

    // MARK: - Configuration

    /// Read a dotted keypath from the fable settings object (e.g. `"Bar.Height"`).
    public func setting(_ keyPath: String) -> FableValue {
        FableValue(try? runtime.invoke(helpers, method: "getSetting", arguments: [app, keyPath]))
    }

    /// Write a dotted keypath into the fable settings object, creating intermediate
    /// objects as needed.
    public func setSetting(_ keyPath: String, _ value: Any) {
        _ = try? runtime.invoke(helpers, method: "setSetting", arguments: [app, keyPath, value])
    }

    // MARK: - Templating

    /// Render a pict template string against a data record. Supports data hashes
    /// (`{~Data:Record.x~}`) and inline solver hashes (`{~Solve:(1 + 2)~}`).
    public func render(_ template: String, data: Any = [String: Any]()) throws -> String {
        try runtime.invoke(helpers, method: "render", arguments: [app, template, data]).toString() ?? ""
    }

    // MARK: - Solving

    /// Evaluate a fable expression (math/logic/string) through the ExpressionParser
    /// service, optionally against a scope of named values.
    @discardableResult
    public func solve(_ expression: String, scope: [String: Any]? = nil) throws -> FableValue {
        FableValue(try runtime.invoke(helpers, method: "solve", arguments: [app, expression, scope ?? [String: Any]()]))
    }

    // MARK: - Services (generic dependency-injected surface)

    /// Call `method` on a named fable/pict service (e.g. `"Math"`, `"DataFormat"`,
    /// `"Dates"`), resolving or instantiating the service on demand.
    @discardableResult
    public func callService(_ serviceName: String, method: String, arguments: [Any] = []) throws -> FableValue {
        let service = try runtime.invoke(helpers, method: "service", arguments: [app, serviceName])
        guard !service.isUndefined, !service.isNull else {
            throw FableCoreError("service \"\(serviceName)\" could not be resolved")
        }
        return FableValue(try runtime.invoke(service, method: method, arguments: arguments))
    }

    // MARK: - Escape hatch

    /// Evaluate arbitrary JavaScript in the runtime. The Pict/Fable app instance is
    /// available to that script as the global `app`.
    @discardableResult
    public func evaluate(_ javaScript: String) throws -> FableValue {
        runtime.context.setObject(app, forKeyedSubscript: "app" as NSString)
        return FableValue(try runtime.evaluate(javaScript, source: "user-script"))
    }
}

// swiftlint:enable incompatible_concurrency_annotation
