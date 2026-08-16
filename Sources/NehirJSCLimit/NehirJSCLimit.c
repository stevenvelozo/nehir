// SPDX-FileCopyrightText: 2026 Steven Velozo
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

#include "NehirJSCLimit.h"
#include <stdbool.h>
#include <stddef.h>

// These three symbols are JavaScriptCore SPI (declared in the framework's private
// <JavaScriptCore/JSContextRefPrivate.h>). We redeclare the prototypes here rather
// than depend on the private header being installed; the symbols themselves are
// exported by the JavaScriptCore framework we link against. This is used solely to
// bound the run time of user-authored overlay scripts. It is acceptable for
// Developer-ID + notarized distribution (notarization does not reject SPI); it
// would not pass App Store review.
typedef bool (*NehirJSShouldTerminateCallback)(JSContextRef ctx, void *context);
extern void JSContextGroupSetExecutionTimeLimit(JSContextGroupRef group, double limit, NehirJSShouldTerminateCallback callback, void *context);
extern void JSContextGroupClearExecutionTimeLimit(JSContextGroupRef group);

// Always terminate once the limit is reached.
static bool nehir_jsc_should_terminate(JSContextRef ctx, void *context)
{
    (void)ctx;
    (void)context;
    return true;
}

void nehir_jsc_set_execution_time_limit(JSContextRef ctx, double seconds)
{
    JSContextGroupRef group = JSContextGetGroup(ctx);
    JSContextGroupSetExecutionTimeLimit(group, seconds, nehir_jsc_should_terminate, NULL);
}

void nehir_jsc_clear_execution_time_limit(JSContextRef ctx)
{
    JSContextGroupRef group = JSContextGetGroup(ctx);
    JSContextGroupClearExecutionTimeLimit(group);
}
