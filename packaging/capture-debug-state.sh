#!/usr/bin/env bash
# capture-debug-state.sh — grab everything useful for debugging a wedged Nehir into one
# timestamped folder. Run this FIRST when Nehir misbehaves (input capture, stuck focus, windows
# not picked up) and BEFORE you recover/restart — the state is gone once you restart.
#
# It talks to Nehir over the IPC socket, which is independent of the event/input tap, so it works
# even when clicking is captured — including over SSH from another machine.
#
#   ./packaging/capture-debug-state.sh            # -> ~/nehir-debug-<timestamp>/
#   ./packaging/capture-debug-state.sh /tmp/foo   # -> /tmp/foo/
set -uo pipefail

NC="${NEHIRCTL:-$HOME/.local/bin/nehirctl}"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="${1:-$HOME/nehir-debug-$STAMP}"
mkdir -p "$OUT"

if ! command -v "$NC" >/dev/null 2>&1 && [ ! -x "$NC" ]; then
  echo "nehirctl not found at '$NC' (set NEHIRCTL=/path/to/nehirctl)" >&2
  exit 1
fi

# The meat: reconcile-debug carries the live snapshot + the trace ring buffer. Everything else is
# supporting context. Failures are tolerated (a wedged Nehir may not answer every query).
"$NC" query reconcile-debug --format json > "$OUT/reconcile-debug.json" 2>"$OUT/reconcile-debug.err" || true
for q in windows focused-window focused-window-decision displays workspaces rules apps active-workspace focused-monitor; do
  "$NC" query "$q" --format json > "$OUT/$q.json" 2>/dev/null || true
done

# Flush the background trace ring buffer to ~/.local/state/nehir/traces/, then snapshot the state dir.
"$NC" command debug capture-recent-trace >/dev/null 2>&1 || true
cp -a "$HOME/.local/state/nehir/runtime-state.json" "$OUT/" 2>/dev/null || true
cp -a "$HOME/.local/state/nehir/traces" "$OUT/traces" 2>/dev/null || true

{
  echo "captured: $(date)"
  echo "nehirctl: $NC"
  "$NC" version 2>/dev/null || true
} > "$OUT/_meta.txt" 2>&1

echo "Captured Nehir debug state to: $OUT"
ls -la "$OUT"
