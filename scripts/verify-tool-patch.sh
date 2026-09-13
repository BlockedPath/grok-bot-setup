#!/usr/bin/env bash
# Verifies:
# 1. tool-id / tool-call fixes are present in LIVE xai-prompt-session.cjs
# 2. createSession hook is present in LIVE host-main.cjs
# Restores both if a host update wiped either, exiting 10 (RESTORED).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SAND_HOST="${SAND_HOST_DIR:-$HOME/sand-host}"
SRC="${XAI_SESSION_SRC:-$ROOT/xai-prompt-session.cjs}"
DST="$SAND_HOST/xai-prompt-session.cjs"
HOST_MAIN="$SAND_HOST/host-main.cjs"
ENSURE_SCRIPT="${XAI_ENSURE_SCRIPT:-$ROOT/scripts/ensure-xai-inference.sh}"
MARKERS=("pairToolCallsAndResults" "phantom pair" 'type: "tool-call" }' '        strict: false,' 'Preserve omitted end_turn: progress updates must not end the host turn.' 'toolCalls.length === 0 &&' 'message: asString(text).trim(), end_turn: true')

missing_session=0
for m in "${MARKERS[@]}"; do
  grep -qF "$m" "$DST" 2>/dev/null || missing_session=1
done

missing_hook=0
if [[ ! -f "$HOST_MAIN" ]] || ! grep -qF "createXaiPromptSession" "$HOST_MAIN" 2>/dev/null; then
  missing_hook=1
fi

if [[ "$missing_session" -eq 0 && "$missing_hook" -eq 0 ]]; then
  echo "OK: tool-call patches and host inference hook present"
  exit 0
fi

echo "MISSING: missing_session=$missing_session missing_hook=$missing_hook"

# Hook recovery also installs SRC, so validate it before either repair path.
if [[ ! -f "$SRC" ]]; then
  echo "ERROR: repo source missing at $SRC - cannot restore session"
  exit 2
fi
for m in "${MARKERS[@]}"; do
  if ! grep -qF "$m" "$SRC"; then
    echo "ERROR: source lacks required fixes; refusing to deploy"
    exit 3
  fi
done
if ! node --check "$SRC" >/dev/null 2>&1; then
  echo "ERROR: repo source fails syntax check - refusing to deploy"
  exit 3
fi

restored=0

if [[ "$missing_session" -ne 0 ]]; then
  cp "$DST" "/tmp/xai-host-prepatch-$(date +%s).cjs" 2>/dev/null || true
  cp "$SRC" "$DST" || { echo "ERROR: copy failed"; exit 4; }
  node --check "$DST" >/dev/null 2>&1 || { echo "ERROR: deployed file bad"; exit 5; }
  echo "RESTORED: session patches reapplied to $DST"
  restored=1
fi

if [[ "$missing_hook" -ne 0 ]]; then
  if [[ ! -x "$ENSURE_SCRIPT" ]]; then
    chmod +x "$ENSURE_SCRIPT" 2>/dev/null || true
  fi
  if [[ ! -f "$ENSURE_SCRIPT" ]]; then
    echo "ERROR: missing $ENSURE_SCRIPT"
    exit 6
  fi
  SAND_HOST_DIR="$SAND_HOST" XAI_SESSION_SRC="$SRC" bash "$ENSURE_SCRIPT" || {
    echo "ERROR: ensure-xai-inference failed"
    exit 7
  }
  echo "RESTORED: host hook reinjected into $HOST_MAIN"
  restored=1
fi

if [[ "$restored" -eq 1 ]]; then
  echo "RESTORED: host patches reapplied (host restart needed to load)"
  exit 10
fi

echo "ERROR: unexpected state"
exit 1
