#!/usr/bin/env bash
# Refresh the vendored pict/fable browser bundle used by FableCore's JavaScriptCore host.
# Re-run after publishing a newer pict build you want the Swift app to pick up.
set -euo pipefail
SRC="${RETOLD_PICT_DIST:-$HOME/Code/retold/modules/pict/pict/dist/pict.min.js}"
DEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pict.min.js"
if [ ! -f "$SRC" ]; then
  echo "pict bundle not found at $SRC (set RETOLD_PICT_DIST or run 'npx quack build' in pict)." >&2
  exit 1
fi
cp "$SRC" "$DEST"
echo "Vendored $(node -e "console.log(require('$(dirname "$SRC")/../package.json').version)" 2>/dev/null || echo '?') -> $DEST"
