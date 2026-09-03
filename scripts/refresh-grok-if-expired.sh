#!/usr/bin/env bash
# M2 — attempt a non-interactive grok CLI refresh when oauth is soon or expired.
# Never device-auth. Never delete auth.json. Never print tokens.
# skip (exit 0) when ok. refresh-failed (exit 3) if still expired after grok models.
set -euo pipefail

_script_dir() {
  local src="${BASH_SOURCE[0]}"
  local dir
  while [[ -L "$src" ]]; do
    dir="$(cd -P "$(dirname "$src")" && pwd)"
    src="$(readlink "$src")"
    [[ "$src" != /* ]] && src="$dir/$src"
  done
  cd -P "$(dirname "$src")" && pwd
}

ROOT="$(cd "$(_script_dir)/.." && pwd)"
STATUS="$ROOT/bin/grok-auth-status"
export GROK_AUTH_FILE="${GROK_AUTH_FILE:-$HOME/.grok/auth.json}"

rc=0
"$STATUS" >/dev/null || rc=$?
if [[ "$rc" -eq 0 ]]; then
  printf 'skip\n'
  exit 0
fi
if [[ "$rc" -ne 1 && "$rc" -ne 2 ]]; then
  printf 'refresh-failed\n'
  exit 3
fi

if ! command -v grok >/dev/null 2>&1; then
  printf 'refresh-failed\n'
  exit 3
fi

# Unproven that `grok models` rotates expires_at. Capture only the exit code.
grok models >/dev/null 2>&1 || true

rc2=0
"$STATUS" >/dev/null || rc2=$?
if [[ "$rc2" -eq 2 ]]; then
  printf 'refresh-failed\n'
  exit 3
fi
printf 'refreshed\n'
exit 0
