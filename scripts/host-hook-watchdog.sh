#!/usr/bin/env bash
# Keep Grok Bot on grok-session (Heavy) after Cursor host-bundle wipes.
# Lives outside ~/sand-host so a host reset does not delete this loop.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SAND_HOST="${SAND_HOST_DIR:-$HOME/sand-host}"
HOST_MAIN="$SAND_HOST/host-main.cjs"
SESSION="$SAND_HOST/xai-prompt-session.cjs"
SETUP="${GROK_BOT_SETUP:-$HOME/grok-bot-setup}"
ENSURE="$SETUP/scripts/ensure-xai-inference.sh"
NPM_ADAPTERS="$HOME/.local/lib/node_modules/grok-bot-setup/adapters.sh"
CHECK_INTERVAL="${HOST_HOOK_CHECK_INTERVAL:-30}"
LOG="${HOST_HOOK_LOG:-/tmp/sand-xai-watchdog.log}"
PIDFILE="$ROOT/watchdog.pid"
export PATH="$HOME/.local/bin:$HOME/.grok/bin:$PATH"

wlog() { printf 'watchdog: %s %s\n' "$(date -u +%FT%TZ)" "$*" >>"$LOG"; }

echo $$ >"$PIDFILE"
trap 'rm -f "$PIDFILE"' EXIT

refresh_grok_if_expired() {
  local helper=""
  if [[ -x "$ROOT/refresh-grok-if-expired.sh" ]]; then helper="$ROOT/refresh-grok-if-expired.sh"; fi
  if [[ -z "$helper" && -x "$SETUP/scripts/refresh-grok-if-expired.sh" ]]; then helper="$SETUP/scripts/refresh-grok-if-expired.sh"; fi
  if [[ -z "$helper" && -x "$HOME/.local/lib/node_modules/grok-bot-setup/scripts/refresh-grok-if-expired.sh" ]]; then helper="$HOME/.local/lib/node_modules/grok-bot-setup/scripts/refresh-grok-if-expired.sh"; fi
  [[ -n "$helper" ]] || return 0
  "$helper" >/dev/null 2>&1 || true
}

adapters_bin() {
  local repo="$SETUP/adapters.sh"
  if [[ -f "$repo" ]] && [[ "$(wc -c < "$repo" 2>/dev/null || echo 0)" -gt 1000 ]]; then
    printf '%s' "$repo"
    return
  fi
  if [[ -x "$NPM_ADAPTERS" ]]; then
    printf '%s' "$NPM_ADAPTERS"
    return
  fi
  printf '%s' "$repo"
}

hook_ok() {
  [[ -f "$SESSION" ]] && [[ -f "$HOST_MAIN" ]] && grep -q createXaiPromptSession "$HOST_MAIN"
}

recover_once() {
  wlog "hook missing — patching"
  if [[ ! -x "$ENSURE" ]]; then
    wlog "missing $ENSURE"
    return 1
  fi
  if ! "$ENSURE" >>"$LOG" 2>&1; then
    wlog "ensure-xai-inference failed"
    return 1
  fi
  if ! hook_ok; then
    wlog "hook still missing after patch"
    return 1
  fi
  local ad
  ad="$(adapters_bin)"
  if [[ ! -x "$ad" ]]; then
    wlog "adapters.sh missing, hook patched but host not restarted"
    return 1
  fi
  wlog "restarting host"
  if ! "$ad" restart-host >>"$LOG" 2>&1; then
    wlog "restart-host failed (hook is on disk)"
    return 1
  fi
  wlog "recovered onto grok-session"
  return 0
}

wlog "started (check=${CHECK_INTERVAL}s)"
fails=0
while true; do
  refresh_grok_if_expired || true
  if hook_ok; then
    fails=0
  else
    if recover_once; then
      fails=0
    else
      fails=$((fails + 1))
      if [[ "$fails" -ge 3 ]]; then
        wlog "recover failed $fails times; backing off 60s"
        sleep 60
        fails=0
      fi
    fi
  fi
  sleep "$CHECK_INTERVAL"
done
