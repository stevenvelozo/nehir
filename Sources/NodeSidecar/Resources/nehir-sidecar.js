// SPDX-FileCopyrightText: 2026 Steven Velozo
// SPDX-License-Identifier: GPL-2.0-only
//
// Nehir Node sidecar harness. Reads newline-delimited JSON requests on stdin
// ({ id, method, params }) and writes newline-delimited JSON responses on stdout
// ({ id, ok, result } or { id, ok:false, error }). stdout is reserved strictly for
// the protocol; all logging (including fable-log) is redirected to stderr so it
// never corrupts a response frame.
"use strict";

// Keep stdout clean: fable-log and any console use must go to stderr.
const logToStderr = (...args) => process.stderr.write(args.map(String).join(" ") + "\n");
console.log = console.info = console.warn = console.error = console.debug = console.trace = logToStderr;

const readline = require("readline");
const fs = require("fs");

// Lazily instantiate fable/pict from the vendored bundle the Swift host points us
// at, so a sidecar that only does Node-native work never pays to load it.
let fableApp = null;
function fable() {
	if (fableApp) return fableApp;
	const bundlePath = process.env.NEHIR_SIDECAR_BUNDLE;
	if (!bundlePath) throw new Error("fable bundle not configured (NEHIR_SIDECAR_BUNDLE unset)");
	const Pict = require(bundlePath);
	fableApp = new Pict({ Product: "NehirSidecar" });
	return fableApp;
}

async function dispatch(method, params) {
	params = params || {};
	switch (method) {
		case "ping":
			return { pong: true };
		case "version":
			return { node: process.version, pid: process.pid, platform: process.platform, arch: process.arch };
		case "env":
			return { value: process.env[params.name] === undefined ? null : process.env[params.name] };
		case "readFile":
			return { content: fs.readFileSync(params.path, "utf8") };
		case "httpGet": {
			if (typeof fetch !== "function") throw new Error("global fetch unavailable in this Node runtime");
			const response = await fetch(params.url);
			const body = await response.text();
			const limit = typeof params.limit === "number" ? params.limit : 200;
			return { status: response.status, length: body.length, body: body.slice(0, limit) };
		}
		// Shared fable surface: return the bare value so the result shape matches
		// the in-process FableCore backend (both `invoke("solve", …)` -> "43").
		case "solve":
			return fable().ExpressionParser.solve(params.expression, params.scope || {});
		case "render":
			return fable().parseTemplate(params.template, params.data || {});
		default:
			throw new Error('unknown sidecar method "' + method + '"');
	}
}

const rl = readline.createInterface({ input: process.stdin });
rl.on("line", async (rawLine) => {
	const line = rawLine.trim();
	if (!line) return;
	let message;
	try {
		message = JSON.parse(line);
	} catch (parseError) {
		process.stdout.write(JSON.stringify({ id: null, ok: false, error: "invalid JSON: " + parseError.message }) + "\n");
		return;
	}
	try {
		const result = await dispatch(message.method, message.params);
		process.stdout.write(JSON.stringify({ id: message.id, ok: true, result: result }) + "\n");
	} catch (error) {
		process.stdout.write(JSON.stringify({ id: message.id, ok: false, error: String((error && error.message) || error) }) + "\n");
	}
});
rl.on("close", () => process.exit(0));

process.stderr.write("nehir-sidecar ready\n");
