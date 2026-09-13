#!/usr/bin/env bash
# Monitor, snapshot and provenance-gated recovery for Moshi pairing state.
# Existing user/shared configuration is never overwritten.
set -uo pipefail

MODE="${1:-monitor}"
HOME_DIR="${MOSHI_HOME:-$HOME}"
PERSIST="${MOSHI_PERSIST:-$HOME_DIR/.local/share/grok-bot-persist/moshi}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_HELPER="${RECOVERY_STATE_HELPER:-$SCRIPT_DIR/recovery-state.py}"
MACHINE_ID_FILE="${RECOVERY_MACHINE_ID_FILE:-/etc/machine-id}"
BOOT_ID_FILE="${RECOVERY_BOOT_ID_FILE:-/proc/sys/kernel/random/boot_id}"
MAX_AGE="${RECOVERY_PROVENANCE_MAX_AGE:-604800}"

BIN="${MOSHI_BIN:-$HOME_DIR/.local/bin/moshi-hook}"
CONFIG_DIR="${MOSHI_CONFIG_DIR:-$HOME_DIR/.config/moshi}"
STATE_DIR="${MOSHI_STATE_DIR:-$HOME_DIR/.local/state/moshi}"
SECRETS="$STATE_DIR/secrets.json"
PAIRINGS="$CONFIG_DIR/host-pairings.json"
RESTORED=0

log() { printf '+ %s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; return 1; }

json_file_ok() {
  [[ -s "$1" ]] &&
    python3 - "$1" <<'PY' >/dev/null 2>&1
import json, pathlib, sys
value = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
raise SystemExit(0 if isinstance(value, (dict, list)) else 1)
PY
}

daemon_ok() {
  if [[ -n "${MOSHI_DAEMON_CHECK_CMD:-}" ]]; then
    bash -c "$MOSHI_DAEMON_CHECK_CMD"
  else
    pgrep -f '[m]oshi-hook serve' >/dev/null 2>&1
  fi
}

paired_ok() {
  "$BIN" status 2>&1 | grep -Ei 'status:[[:space:]]+paired' >/dev/null
}

check_health() {
  local failed=0
  [[ -x "$BIN" ]] || { fail "Moshi binary missing at $BIN"; failed=1; }
  json_file_ok "$SECRETS" || { fail "Moshi secrets are missing or invalid at $SECRETS"; failed=1; }
  json_file_ok "$PAIRINGS" || { fail "Moshi pairings are missing or invalid at $PAIRINGS"; failed=1; }
  daemon_ok || { fail "Moshi daemon is not healthy"; failed=1; }
  if [[ -x "$BIN" ]]; then
    paired_ok || { fail "Moshi reports an unpaired or unreadable status"; failed=1; }
  fi
  return "$failed"
}

snapshot_args() {
  SNAPSHOT_FILES=(
    "--file" "bin/moshi-hook=$BIN"
    "--file" "state/secrets.json=$SECRETS"
    "--file" "config/host-pairings.json=$PAIRINGS"
  )
  local file logical
  if [[ -d "$CONFIG_DIR" ]]; then
    for file in "$CONFIG_DIR"/*; do
      [[ -f "$file" ]] || continue
      logical="config/$(basename "$file")"
      [[ "$logical" == "config/host-pairings.json" ]] && continue
      SNAPSHOT_FILES+=("--file" "$logical=$file")
    done
  fi
  local hook_specs=(
    "hooks/cursor-hooks.json=$HOME_DIR/.cursor/hooks.json"
    "hooks/grok-moshi-hooks.json=$HOME_DIR/.grok/hooks/moshi-hooks.json"
    "hooks/pi-moshi-hooks.ts=$HOME_DIR/.pi/agent/extensions/moshi-hooks.ts"
    "hooks/claude-settings.json=$HOME_DIR/.claude/settings.json"
    "hooks/codex-hooks.json=$HOME_DIR/.codex/hooks.json"
  )
  local spec source
  for spec in "${hook_specs[@]}"; do
    source="${spec#*=}"
    [[ -f "$source" ]] && SNAPSHOT_FILES+=("--file" "$spec")
  done
}

create_snapshot() {
  check_health || {
    fail "refusing to snapshot unhealthy Moshi state"
    return 1
  }
  snapshot_args
  python3 "$STATE_HELPER" create \
    --component moshi --persist "$PERSIST" "${SNAPSHOT_FILES[@]}" >/dev/null
  log "validated Moshi snapshot"
}

prepare_reset() {
  # A failed new preparation must not leave an older reset authorization active.
  rm -f "$PERSIST/reset-provenance.json"
  create_snapshot || return
  python3 "$STATE_HELPER" prepare \
    --component moshi --persist "$PERSIST" \
    --machine-id-file "$MACHINE_ID_FILE" --boot-id-file "$BOOT_ID_FILE" >/dev/null
  log "recorded Moshi reset provenance"
}

release_for_recovery() {
  python3 "$STATE_HELPER" verify-provenance \
    --component moshi --persist "$PERSIST" \
    --machine-id-file "$MACHINE_ID_FILE" --boot-id-file "$BOOT_ID_FILE" \
    --max-age "$MAX_AGE"
}

restore_absent() {
  local source="$1" target="$2" mode="${3:-}"
  [[ -f "$source" ]] || {
    fail "validated snapshot is missing $source"
    return 1
  }
  if [[ -e "$target" ]]; then
    # Nonempty or invalid live state may be a deliberate user change.
    return 0
  fi
  mkdir -p "$(dirname "$target")"
  cp -p "$source" "$target"
  [[ -n "$mode" ]] && chmod "$mode" "$target"
  RESTORED=1
  log "restored missing $target"
}

restore_optional_if_absent() {
  local release="$1" logical="$2" target="$3"
  [[ -f "$release/$logical" ]] || return 0
  [[ -e "$target" ]] && {
    if ! cmp -s "$release/$logical" "$target"; then
      log "preserved user-managed $target"
    fi
    return 0
  }
  restore_absent "$release/$logical" "$target"
}

start_daemon_if_needed() {
  daemon_ok && return 0
  [[ -x "$BIN" ]] || return 1
  if [[ -n "${MOSHI_START_CMD:-}" ]]; then
    bash -c "$MOSHI_START_CMD" || return 1
  else
    "$BIN" service install >/dev/null 2>&1 || return 1
  fi
  daemon_ok
}

consume_provenance() {
  python3 "$STATE_HELPER" consume \
    --component moshi --persist "$PERSIST" \
    --machine-id-file "$MACHINE_ID_FILE" --boot-id-file "$BOOT_ID_FILE" \
    --max-age "$MAX_AGE" >/dev/null
}

recover() {
  if check_health; then
    # A healthy post-reboot run consumes a prepared marker so it cannot be
    # reused later to undo a deliberate deletion.
    if [[ -f "$PERSIST/reset-provenance.json" ]] &&
       release_for_recovery >/dev/null 2>&1; then
      consume_provenance || return
    fi
    log "Moshi healthy; no recovery needed"
    return 0
  fi

  local release
  release="$(release_for_recovery)" || {
    fail "Moshi recovery is ambiguous; prepare a reset while healthy or repair/re-pair manually"
    return 2
  }

  # Existing files are never replaced. Invalid existing pairing data therefore
  # fails the final check instead of being silently replaced by an old pairing.
  restore_absent "$release/bin/moshi-hook" "$BIN" 755 || return
  restore_absent "$release/state/secrets.json" "$SECRETS" 600 || return
  restore_absent "$release/config/host-pairings.json" "$PAIRINGS" 600 || return

  local file
  if [[ -d "$release/config" ]]; then
    for file in "$release/config"/*; do
      [[ -f "$file" ]] || continue
      [[ "$(basename "$file")" == "host-pairings.json" ]] && continue
      restore_optional_if_absent "$release" "config/$(basename "$file")" \
        "$CONFIG_DIR/$(basename "$file")" || return
    done
  fi
  restore_optional_if_absent "$release" hooks/cursor-hooks.json "$HOME_DIR/.cursor/hooks.json" || return
  restore_optional_if_absent "$release" hooks/grok-moshi-hooks.json "$HOME_DIR/.grok/hooks/moshi-hooks.json" || return
  restore_optional_if_absent "$release" hooks/pi-moshi-hooks.ts "$HOME_DIR/.pi/agent/extensions/moshi-hooks.ts" || return
  restore_optional_if_absent "$release" hooks/claude-settings.json "$HOME_DIR/.claude/settings.json" || return
  restore_optional_if_absent "$release" hooks/codex-hooks.json "$HOME_DIR/.codex/hooks.json" || return

  start_daemon_if_needed || {
    fail "Moshi daemon could not be restored"
    return 3
  }
  check_health || {
    fail "Moshi remains unhealthy after recovery; provenance retained"
    return 4
  }
  consume_provenance || return
  log "Moshi recovery completed and provenance consumed"
  [[ "$RESTORED" -eq 1 ]] && return 10
  return 0
}

case "$MODE" in
  monitor|check) check_health ;;
  snapshot) create_snapshot ;;
  prepare-reset) prepare_reset ;;
  recover) recover ;;
  *)
    fail "usage: $0 monitor|snapshot|prepare-reset|recover"
    exit 64
    ;;
esac
