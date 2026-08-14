// SPDX-FileCopyrightText: 2026 Steven Velozo
// SPDX-License-Identifier: GPL-2.0-only
//
// Helper surface for FableCore's Swift host, evaluated AFTER the pict/fable
// bundle loads. Each helper is pure and takes the app instance explicitly, so the
// Swift side never has to encode keypath walking or service-resolution rules.
var __fableCoreHelpers = {
	// Read a dotted keypath out of the app's settings object.
	getSetting: function (pApp, pKeyPath) {
		var tmpParts = String(pKeyPath).split(".");
		var tmpNode = pApp.settings;
		for (var i = 0; i < tmpParts.length; i++) {
			if (tmpNode == null) return undefined;
			tmpNode = tmpNode[tmpParts[i]];
		}
		return tmpNode;
	},

	// Write a dotted keypath into the app's settings object, creating intermediates.
	setSetting: function (pApp, pKeyPath, pValue) {
		var tmpParts = String(pKeyPath).split(".");
		var tmpNode = pApp.settings;
		for (var i = 0; i < tmpParts.length - 1; i++) {
			if (tmpNode[tmpParts[i]] == null || typeof tmpNode[tmpParts[i]] !== "object") {
				tmpNode[tmpParts[i]] = {};
			}
			tmpNode = tmpNode[tmpParts[i]];
		}
		tmpNode[tmpParts[tmpParts.length - 1]] = pValue;
		return true;
	},

	// Evaluate a fable expression (math/logic/string) through the ExpressionParser
	// service. Returns the solved value.
	solve: function (pApp, pExpression, pScope) {
		var tmpExpressionParser = pApp.ExpressionParser || pApp.instantiateServiceProviderIfNotExists("ExpressionParser");
		return tmpExpressionParser.solve(pExpression, pScope == null ? {} : pScope);
	},

	// Render a pict template string against a data record. Inline solver hashes
	// ({~Solve:...~}) and data hashes ({~Data:Record.x~}) both work here.
	render: function (pApp, pTemplate, pData) {
		return pApp.parseTemplate(pTemplate, pData == null ? {} : pData);
	},

	// Resolve a named service instance, instantiating it on demand when the app
	// did not eagerly create a default.
	service: function (pApp, pServiceName) {
		return pApp[pServiceName] || pApp.instantiateServiceProviderIfNotExists(pServiceName);
	},
};
