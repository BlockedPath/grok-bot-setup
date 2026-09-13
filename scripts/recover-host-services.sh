#!/usr/bin/env bash
# Orchestrate optional Moshi and Tailscale/OpenSSH guards without masking errors.
set -uo pipefail

MODE="${1:-recover}"
SCRIPT_DIR="${GROK_RECOVERY_SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
SOURCE_DIR="${GROK_RECOVERY_SOURCE_DIR:-$SCRIPT_DIR}"
HOME_DIR="${RECOVERY_HOME:-$HOME}"
LOCK_TIMEOUT="${RECOVERY_LOCK_TIMEOUT:-30}"
PERSIST_ROOT="${GROK_BOT_PERSIST_ROOT:-$HOME_DIR/.local/share/grok-bot-persist}"
DENY_FILE="${GROK_RECOVERY_DENY_FILE:-$PERSIST_ROOT/.recovery-denied}"
DENY_OWNER=orchestrator
export GROK_RECOVERY_DENY_FILE="$DENY_FILE"
RESTORED=0

run_component() {
  local name="$1" script="$2" enabled="$3" mode="${4:-$MODE}" rc
  if [[ "$enabled" != "1" ]]; then
    printf '+ SKIP: %s is not installed or enrolled for recovery\n' "$name"
    return 0
  fi
  [[ -x "$script" ]] || {
    printf 'ERROR: enabled %s recovery script is missing: %s\n' "$name" "$script" >&2
    return 1
  }
  "$script" "$mode"
  rc=$?
  case "$rc" in
    0) return 0 ;;
    10) RESTORED=1; return 0 ;;
    *)
      printf 'ERROR: %s recovery failed with exit %s\n' "$name" "$rc" >&2
      return "$rc"
      ;;
  esac
}

component_enabled() {
  local persist="$1" binary="$2"
  [[ "${GROK_RECOVERY_FORCE_COMPONENTS:-0}" == "1" ||
     -d "$persist" || -x "$binary" ]]
}

preserve_runtime() {
  local runtime="$PERSIST_ROOT/recovery-runtime"
  local helper="$SOURCE_DIR/recovery-state.py"
  local files=(
    recovery-state.py
    recover-host-services.sh
    ensure-moshi.sh
    ensure-tailscale-ssh.sh
    restore-after-reset.sh
  )
  local file args=()
  [[ -f "$helper" ]] || {
    printf 'ERROR: recovery runtime helper missing: %s\n' "$helper" >&2
    return 1
  }
  for file in "${files[@]}"; do
    [[ -f "$SOURCE_DIR/$file" ]] || {
      printf 'ERROR: recovery runtime source missing: %s\n' "$SOURCE_DIR/$file" >&2
      return 1
    }
    case "$file" in
      *.sh) bash -n "$SOURCE_DIR/$file" || return ;;
      *.py) python3 -m py_compile "$SOURCE_DIR/$file" || return ;;
    esac
    args+=("--file" "scripts/$file=$SOURCE_DIR/$file")
  done
  python3 "$helper" create --component host-recovery-runtime \
    --persist "$runtime" "${args[@]}" >/dev/null || {
      printf 'ERROR: recovery runtime snapshot creation failed\n' >&2
      return 1
    }
  printf '+ validated recovery runtime snapshot: %s/current\n' "$runtime"
}

deny_recovery() {
  local temporary
  mkdir -p "$(dirname "$DENY_FILE")" || return 1
  if [[ -e "$DENY_FILE" || -L "$DENY_FILE" ]]; then
    [[ -f "$DENY_FILE" && "$(cat "$DENY_FILE" 2>/dev/null)" == "$DENY_OWNER" ]]
    return
  fi
  temporary="$(mktemp "$(dirname "$DENY_FILE")/.recovery-denied.XXXXXX")" || return 1
  if ! printf '%s\n' "$DENY_OWNER" >"$temporary" ||
     ! chmod 600 "$temporary" ||
     ! ln "$temporary" "$DENY_FILE"; then
    rm -f "$temporary"
    return 1
  fi
  rm -f "$temporary"
  [[ -f "$DENY_FILE" ]]
}

allow_recovery() {
  [[ -f "$DENY_FILE" && "$(cat "$DENY_FILE" 2>/dev/null)" == "$DENY_OWNER" ]] ||
    return 1
  rm -f "$DENY_FILE" || return 1
  [[ ! -e "$DENY_FILE" && ! -L "$DENY_FILE" ]]
}

invalidate_all() {
  local failed=0
  run_component Moshi "$SCRIPT_DIR/ensure-moshi.sh" "$moshi_enabled" invalidate-reset || failed=1
  run_component Tailscale/OpenSSH "$SCRIPT_DIR/ensure-tailscale-ssh.sh" "$ts_enabled" invalidate-reset || failed=1
  [[ "$failed" -eq 0 ]]
}

prepare_all() {
  deny_recovery || {
    printf 'ERROR: could not block recovery before preparation\n' >&2
    return 1
  }
  # First revoke every old authority, even if an earlier revocation fails.
  invalidate_all || {
    printf 'ERROR: not all old reset authorities could be invalidated; preparation stopped\n' >&2
    return 1
  }
  run_component Moshi "$SCRIPT_DIR/ensure-moshi.sh" "$moshi_enabled" snapshot || return
  run_component Tailscale/OpenSSH "$SCRIPT_DIR/ensure-tailscale-ssh.sh" "$ts_enabled" snapshot || return
  preserve_runtime || return

  # Arm only after every snapshot/runtime is valid. Roll back all authority if
  # any marker write fails, and report rollback failure explicitly.
  run_component Moshi "$SCRIPT_DIR/ensure-moshi.sh" "$moshi_enabled" arm-reset || {
    invalidate_all || printf 'ERROR: failed to roll back reset authorities\n' >&2
    return 1
  }
  run_component Tailscale/OpenSSH "$SCRIPT_DIR/ensure-tailscale-ssh.sh" "$ts_enabled" arm-reset || {
    invalidate_all || printf 'ERROR: failed to roll back reset authorities\n' >&2
    return 1
  }
  allow_recovery || {
    printf 'ERROR: reset markers armed but recovery deny marker could not be cleared\n' >&2
    deny_recovery || true
    invalidate_all || printf 'ERROR: failed to invalidate armed reset markers\n' >&2
    return 1
  }
  printf '+ all enabled host recovery snapshots prepared atomically\n'
}

run_requested() {
  if [[ "$MODE" == "prepare-reset" ]]; then
    prepare_all
  else
    run_component Moshi "$SCRIPT_DIR/ensure-moshi.sh" "$moshi_enabled" || return
    run_component Tailscale/OpenSSH "$SCRIPT_DIR/ensure-tailscale-ssh.sh" "$ts_enabled"
  fi
}

with_global_lock() {
  local rc
  mkdir -p "$PERSIST_ROOT" || return 1
  exec 8>"$PERSIST_ROOT/.host-recovery.lock" || return 1
  flock -w "$LOCK_TIMEOUT" 8 || {
    printf 'ERROR: timed out waiting for host recovery lock\n' >&2
    return 1
  }
  run_requested
  rc=$?
  flock -u 8 || true
  exec 8>&-
  return "$rc"
}

MOSHI_PERSIST_PATH="${MOSHI_PERSIST:-$HOME_DIR/.local/share/grok-bot-persist/moshi}"
TS_PERSIST_PATH="${GROK_BOT_TS_SSH_PERSIST:-$HOME_DIR/.local/share/grok-bot-persist/tailscale-ssh}"
moshi_enabled=0
ts_enabled=0
component_enabled "$MOSHI_PERSIST_PATH" "${MOSHI_BIN:-$HOME_DIR/.local/bin/moshi-hook}" && moshi_enabled=1
component_enabled "$TS_PERSIST_PATH" "${TAILSCALE_BIN:-/usr/bin/tailscale}" && ts_enabled=1

case "$MODE" in
  monitor|check) run_requested || exit $? ;;
  *) with_global_lock || exit $? ;;
esac

[[ "$RESTORED" -eq 1 ]] && exit 10
exit 0
