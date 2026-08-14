// SPDX-FileCopyrightText: 2026 Steven Velozo
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import Foundation
import JavaScriptCore

/// Owns a single JavaScriptCore context: installs the browser/CommonJS shim, loads
/// the vendored pict/fable UMD bundle, forwards `console.*` to the host, and turns
/// JS exceptions into thrown Swift errors.
///
/// All access is main-actor isolated. A `JSContext` is single-threaded, and this
/// host is only ever driven from the app's main actor; the `@convention(block)`
/// callbacks below re-enter that isolation with `assumeIsolated` because JS runs
/// exclusively on the main thread.
@MainActor
final class JSRuntime {
    let context: JSContext
    private var pendingException: JSValue?

    /// Forwarded `console.*` output, tagged with a best-effort level parsed from
    /// fable-log's line format (`… [info] (Product): message`).
    var onConsole: ((FableLogLevel, String) -> Void)?

    init() throws {
        guard let context = JSContext() else {
            throw FableCoreError("failed to create a JSContext")
        }
        self.context = context
        context.exceptionHandler = { [weak self] _, exception in
            MainActor.assumeIsolated {
                self?.pendingException = exception
            }
        }
        installConsole()
    }

    /// Load the shim, the bundle, and the helper surface, then hand back the
    /// exported Pict/Fable constructor captured from `module.exports`.
    func bootstrap() throws -> JSValue {
        try evaluateResource("FableCore-Prelude")
        try evaluateResource("pict.min")
        let export = try evaluate("module.exports", source: "capture-export")
        let exportType = try evaluate("typeof module.exports", source: "capture-export-type").toString()
        guard exportType == "function" else {
            throw FableCoreError("pict/fable bundle did not export a constructor (typeof = \(exportType ?? "?"))")
        }
        try evaluateResource("FableCore-Runtime")
        return export
    }

    // MARK: - Evaluation

    @discardableResult
    func evaluate(_ script: String, source: String) throws -> JSValue {
        pendingException = nil
        let result = context.evaluateScript(script)
        try throwIfNeeded(source: source)
        return result ?? JSValue(undefinedIn: context)
    }

    @discardableResult
    func invoke(_ target: JSValue, method: String, arguments: [Any]) throws -> JSValue {
        pendingException = nil
        let result = target.invokeMethod(method, withArguments: arguments)
        try throwIfNeeded(source: method)
        return result ?? JSValue(undefinedIn: context)
    }

    func construct(_ constructor: JSValue, arguments: [Any]) throws -> JSValue {
        pendingException = nil
        let instance = constructor.construct(withArguments: arguments)
        try throwIfNeeded(source: "constructor")
        guard let instance, !instance.isUndefined, !instance.isNull else {
            throw FableCoreError("constructor returned no instance")
        }
        return instance
    }

    // MARK: - Internals

    private func throwIfNeeded(source: String) throws {
        guard let exception = pendingException else { return }
        pendingException = nil
        let message = exception.toString() ?? "unknown JS exception"
        let stack = exception.objectForKeyedSubscript("stack")?.toString()
        throw FableCoreError("JS error in \(source): \(message)", jsStack: stack)
    }

    private func evaluateResource(_ name: String) throws {
        guard let url = Bundle.module.url(forResource: name, withExtension: "js") else {
            throw FableCoreError("missing bundled resource \(name).js")
        }
        let source = try String(contentsOf: url, encoding: .utf8)
        _ = try evaluate(source, source: "\(name).js")
    }

    private func installConsole() {
        let sink: @convention(block) (String, JSValue) -> Void = { [weak self] level, value in
            MainActor.assumeIsolated {
                self?.forwardConsole(level: level, line: value.toString() ?? "")
            }
        }
        let console = JSValue(newObjectIn: context) ?? JSValue(undefinedIn: context)!
        // Each console method binds its own level so fable-log's own formatting is
        // preserved but still tagged for the host logger.
        let methodLevels: [String: FableLogLevel] = [
            "log": .info, "info": .info, "warn": .warn,
            "error": .error, "debug": .debug, "trace": .trace
        ]
        for (method, level) in methodLevels {
            let bound: @convention(block) (JSValue) -> Void = { value in sink(level.rawValue, value) }
            console.setObject(bound, forKeyedSubscript: method as NSString)
        }
        context.setObject(console, forKeyedSubscript: "console" as NSString)
    }

    private func forwardConsole(level: String, line: String) {
        onConsole?(FableLogLevel(rawValue: level) ?? .info, line)
    }
}
