// SPDX-FileCopyrightText: 2026 Steven Velozo
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import Foundation
import JavaScriptCore
import NehirJSCLimit

extension JSRuntime {
    /// Arm a wall-clock budget on the context group. Any JS that overruns it is
    /// aborted (surfacing as a thrown `FableCoreError`), so a runaway host script
    /// can never wedge the single-threaded, main-actor JS host. Backed by
    /// JavaScriptCore SPI wrapped in the `NehirJSCLimit` C shim.
    func setExecutionTimeLimit(_ seconds: TimeInterval) {
        nehir_jsc_set_execution_time_limit(context.jsGlobalContextRef, seconds)
    }

    /// Remove the wall-clock budget so ordinary (trusted, in-process) work runs
    /// unbounded again.
    func clearExecutionTimeLimit() {
        nehir_jsc_clear_execution_time_limit(context.jsGlobalContextRef)
    }
}

extension FableCore {
    /// Evaluate `javaScript` with a hard wall-clock budget. Used for pulling
    /// user-authored values (e.g. an overlay spec) where an accidental infinite
    /// loop must abort the *script*, not hang the shell. The pict/fable `app`
    /// instance is available to the script as the global `app`, as with
    /// `evaluate(_:)`.
    ///
    /// On overrun the script is terminated and this throws; the caller decides how
    /// to degrade (typically: log and skip). The budget is cleared before
    /// returning so the limit never leaks onto later trusted work.
    @discardableResult
    public func evaluateGuarded(_ javaScript: String, timeLimitSeconds: TimeInterval) throws -> FableValue {
        runtime.setExecutionTimeLimit(timeLimitSeconds)
        defer { runtime.clearExecutionTimeLimit() }
        return try evaluate(javaScript)
    }
}
