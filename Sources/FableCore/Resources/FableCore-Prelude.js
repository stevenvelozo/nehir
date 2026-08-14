// SPDX-FileCopyrightText: 2026 Steven Velozo
// SPDX-License-Identifier: GPL-2.0-only
//
// Minimal browser + CommonJS environment so a browserify UMD bundle (pict, which
// bundles fable) loads inside a bare JavaScriptCore context. Evaluated BEFORE the
// bundle. `console` is injected from Swift (forwarded to the host logger); timers
// and network (setTimeout/fetch/XHR) are intentionally absent in this in-process
// logic core — asynchronous/networked work belongs to the Node sidecar.
var global = this;
var self = this;
var window = this;
var globalThis = this;
var navigator = { userAgent: "JavaScriptCore/FableCore" };
var module = { exports: {} };
var exports = module.exports;
