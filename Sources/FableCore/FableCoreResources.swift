// SPDX-FileCopyrightText: 2026 Steven Velozo
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import Foundation

/// Access to the resources FableCore vendors, so sibling targets (e.g. the Node
/// sidecar) can reuse the same pict/fable bundle instead of shipping a second copy.
public enum FableCoreResources {
    /// URL of the vendored pict/fable UMD bundle. It loads in Node's CommonJS
    /// loader as well as JavaScriptCore, so the sidecar can run fable in-process.
    public static var pictBundleURL: URL? {
        Bundle.module.url(forResource: "pict.min", withExtension: "js")
    }
}
