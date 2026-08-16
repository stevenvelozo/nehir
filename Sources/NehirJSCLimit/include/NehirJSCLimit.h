// SPDX-FileCopyrightText: 2026 Steven Velozo
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

#ifndef NEHIR_JSC_LIMIT_H
#define NEHIR_JSC_LIMIT_H

#include <JavaScriptCore/JavaScriptCore.h>

/// Arm a wall-clock execution budget (seconds) on the group backing `ctx`. Any
/// script that overruns it is aborted by JavaScriptCore, surfacing as a thrown JS
/// exception — the safeguard that keeps a runaway user script from wedging the
/// single-threaded, main-actor JS host.
void nehir_jsc_set_execution_time_limit(JSContextRef ctx, double seconds);

/// Remove the budget so ordinary in-process work runs unbounded again.
void nehir_jsc_clear_execution_time_limit(JSContextRef ctx);

#endif /* NEHIR_JSC_LIMIT_H */
