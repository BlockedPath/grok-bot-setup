#!/usr/bin/env bash
# Start CLIProxyAPI for Claude OAuth (Opus etc.) with tool support.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${CLIPROXY_BIN:-$HOME/go/bin/server}"
CONFIG="${CLIPROXY_CONFIG:-$ROOT/config.yaml}"
LOG="${CLIPROXY_LOG:-/tmp/cliproxy.log}"
PORT=8317

"$ROOT/scripts/sync-claude-auth.sh"

if [ ! -x "$BIN" ]; then
  echo "CLIProxyAPI binary not found at $BIN" >&2
  echo "Install: go install github.com/router-for-me/CLIProxyAPI/v6/cmd/server@latest" >&2
  exit 1
fi

# Stop previous instance on this port if ours
if command -v fuser >/dev/null 2>&1; then
  fuser -k "${PORT}/tcp" 2>/dev/null || true
  sleep 0.3
fi

nohup "$BIN" -config "$CONFIG" >>"$LOG" 2>&1 &
echo "CLIProxyAPI pid $! log $LOG"
for i in 1 2 3 4 5 6 7 8 9 10; do
  if curl -sf -m 1 -H 'Authorization: Bearer sand-cliproxy' "http://127.0.0.1:${PORT}/v1/models" >/dev/null; then
    echo "listening on http://127.0.0.1:${PORT}/v1"
    exit 0
  fi
  sleep 0.5
done
echo "failed to become ready; see $LOG" >&2
exit 1
