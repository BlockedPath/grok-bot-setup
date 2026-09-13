#!/usr/bin/env bash
# Orchestrate optional Moshi and Tailscale/OpenSSH guards without masking errors.
set -uo pipefail

MODE="${1:-recover}"
SCRIPT_DIR="${GROK_RECOVERY_SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
SOURCE_DIR="${GROK_RECOVERY_SOURCE_DIR:-$SCRIPT_DIR}"
HOME_DIR="${RECOVERY_HOME:-$HOME}"
RESTORED=0

run_component() {
  local name="$1" script="$2" enabled="$3" rc
  if [[ "$enabled" != "1" ]]; then
    printf '+ SKIP: %s is not installed or enrolled for recovery\n' "$name"
    return 0
  fi
  [[ -x "$script" ]] || {
    printf 'ERROR: enabled %s recovery script is missing: %s\n' "$name" "$script" >&2
    return 1
  }
  "$script" "$MODE"
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
  local persist_root="${GROK_BOT_PERSIST_ROOT:-$HOME_DIR/.local/share/grok-bot-persist}"
  local runtime="$persist_root/recovery-runtime"
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
    --persist "$runtime" "${args[@]}" >/dev/null
  printf '+ validated recovery runtime snapshot: %s/current\n' "$runtime"
}

MOSHI_PERSIST_PATH="${MOSHI_PERSIST:-$HOME_DIR/.local/share/grok-bot-persist/moshi}"
TS_PERSIST_PATH="${GROK_BOT_TS_SSH_PERSIST:-$HOME_DIR/.local/share/grok-bot-persist/tailscale-ssh}"
moshi_enabled=0
ts_enabled=0
component_enabled "$MOSHI_PERSIST_PATH" "${MOSHI_BIN:-$HOME_DIR/.local/bin/moshi-hook}" && moshi_enabled=1
component_enabled "$TS_PERSIST_PATH" "${TAILSCALE_BIN:-/usr/bin/tailscale}" && ts_enabled=1

run_component Moshi "$SCRIPT_DIR/ensure-moshi.sh" "$moshi_enabled" || exit $?
run_component Tailscale/OpenSSH "$SCRIPT_DIR/ensure-tailscale-ssh.sh" "$ts_enabled" || exit $?
if [[ "$MODE" == "prepare-reset" ]]; then
  preserve_runtime || exit $?
fi

[[ "$RESTORED" -eq 1 ]] && exit 10
exit 0
