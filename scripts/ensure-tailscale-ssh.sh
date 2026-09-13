#!/usr/bin/env bash
# Monitor, snapshot and provenance-gated recovery for Tailscale + OpenSSH.
# Policy: VPN Running, Tailscale RunSSH=false, normal OpenSSH on port 22.
set -uo pipefail

MODE="${1:-monitor}"
HOME_DIR="${RECOVERY_HOME:-$HOME}"
PERSIST="${GROK_BOT_TS_SSH_PERSIST:-$HOME_DIR/.local/share/grok-bot-persist/tailscale-ssh}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_HELPER="${RECOVERY_STATE_HELPER:-$SCRIPT_DIR/recovery-state.py}"
MACHINE_ID_FILE="${RECOVERY_MACHINE_ID_FILE:-/etc/machine-id}"
BOOT_ID_FILE="${RECOVERY_BOOT_ID_FILE:-/proc/sys/kernel/random/boot_id}"
MAX_AGE="${RECOVERY_PROVENANCE_MAX_AGE:-86400}"
LOCK_TIMEOUT="${RECOVERY_LOCK_TIMEOUT:-30}"
APPROVE_SENSITIVE="${GROK_APPROVE_SENSITIVE_RESTORE:-0}"

TS_BIN="${TAILSCALE_BIN:-/usr/bin/tailscale}"
TAILSCALED_BIN="${TAILSCALED_BIN:-/usr/sbin/tailscaled}"
SSHD_BIN="${SSHD_BIN:-/usr/sbin/sshd}"
SS_BIN="${SS_BIN:-ss}"
STATE_FILE="${TAILSCALE_STATE_FILE:-/var/lib/tailscale/tailscaled.state}"
SSH_DIR="${OPENSSH_CONFIG_DIR:-/etc/ssh}"
SSHD_CONFIG="${SSHD_CONFIG:-$SSH_DIR/sshd_config}"
AUTHORIZED_KEYS="${AUTHORIZED_KEYS_FILE:-$HOME_DIR/.ssh/authorized_keys}"
SYSTEM_OWNER="${RECOVERY_SYSTEM_OWNER:-root:root}"
RESTORED=0
CREATED_TARGETS=()

log() { printf '+ %s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; return 1; }

with_lock() {
  local rc
  mkdir -p "$PERSIST" || { fail "cannot create Tailscale/OpenSSH persist directory"; return 1; }
  exec 9>"$PERSIST/.recovery.lock" || { fail "cannot open Tailscale/OpenSSH recovery lock"; return 1; }
  flock -w "$LOCK_TIMEOUT" 9 || { fail "timed out waiting for Tailscale/OpenSSH recovery lock"; return 1; }
  "$@"
  rc=$?
  flock -u 9 || true
  exec 9>&-
  return "$rc"
}

priv() {
  if [[ "${RECOVERY_NO_SUDO:-0}" == "1" ]]; then
    "$@"
  else
    "${RECOVERY_SUDO_BIN:-sudo}" "$@"
  fi
}

backend_state() {
  priv "$TS_BIN" status --json 2>/dev/null |
    python3 -c 'import json,sys; print(json.load(sys.stdin).get("BackendState", ""))' 2>/dev/null
}

runssh_value() {
  priv "$TS_BIN" debug prefs 2>/dev/null |
    python3 -c 'import json,sys; v=json.load(sys.stdin).get("RunSSH"); print("true" if v is True else "false" if v is False else "")' 2>/dev/null
}

sshd_port() {
  priv "$SSHD_BIN" -T -f "$SSHD_CONFIG" 2>/dev/null |
    awk '$1 == "port" { print $2; exit }'
}

port_22_listening() {
  priv "$SS_BIN" -tlnp 2>/dev/null | awk '
    NR > 1 {
      address=$4
      if (address ~ /(^|[\]:.])22$/ && $0 ~ /sshd/) found=1
    }
    END { exit(found ? 0 : 1) }
  '
}

host_keys_ok() {
  local private found=0
  for private in "$SSH_DIR"/ssh_host_*_key; do
    [[ -f "$private" ]] || continue
    found=1
    [[ -f "$private.pub" ]] || return 1
  done
  [[ "$found" -eq 1 ]]
}

check_health() {
  local failed=0 backend runssh port
  [[ -x "$TS_BIN" ]] || { fail "Tailscale client missing at $TS_BIN"; failed=1; }
  [[ -x "$TAILSCALED_BIN" ]] || { fail "tailscaled missing at $TAILSCALED_BIN"; failed=1; }
  [[ -x "$SSHD_BIN" ]] || { fail "OpenSSH server missing at $SSHD_BIN"; failed=1; }
  [[ -s "$STATE_FILE" ]] || { fail "Tailscale state missing at $STATE_FILE"; failed=1; }
  [[ -f "$SSHD_CONFIG" ]] || { fail "OpenSSH config missing at $SSHD_CONFIG"; failed=1; }
  host_keys_ok || { fail "OpenSSH host-key set is missing or partial"; failed=1; }
  [[ -f "$AUTHORIZED_KEYS" ]] || { fail "authorized_keys is missing at $AUTHORIZED_KEYS"; failed=1; }

  if [[ -x "$TS_BIN" ]]; then
    backend="$(backend_state || true)"
    [[ "$backend" == "Running" ]] || {
      fail "Tailscale VPN is not Running (BackendState=${backend:-unknown})"
      failed=1
    }
    runssh="$(runssh_value || true)"
    [[ "$runssh" == "false" ]] || {
      fail "Tailscale RunSSH must be false (observed ${runssh:-unknown})"
      failed=1
    }
  fi
  if [[ -x "$SSHD_BIN" && -f "$SSHD_CONFIG" ]]; then
    port="$(sshd_port || true)"
    [[ "$port" == "22" ]] || {
      fail "effective OpenSSH port must remain 22 (observed ${port:-unknown})"
      failed=1
    }
  fi
  port_22_listening || {
    fail "normal OpenSSH is not listening on port 22"
    failed=1
  }
  return "$failed"
}

snapshot_args() {
  SNAPSHOT_FILES=(
    "--file" "tailscale/tailscaled.state=$STATE_FILE"
    "--file" "ssh/sshd_config=$SSHD_CONFIG"
    "--file" "box-ssh/authorized_keys=$AUTHORIZED_KEYS"
  )
  local file
  for file in "$SSH_DIR"/ssh_host_*; do
    [[ -f "$file" ]] || continue
    SNAPSHOT_FILES+=("--file" "ssh/$(basename "$file")=$file")
  done
}

private_key_modes_ok() {
  local key mode
  for key in "$SSH_DIR"/ssh_host_*_key; do
    [[ -f "$key" ]] || continue
    mode="$(priv stat -c '%a' "$key" 2>/dev/null)" || return 1
    # Group/other permission digits must both be zero.
    [[ "$mode" =~ ^[0-7]00$ ]] || return 1
  done
}

create_snapshot() {
  check_health || {
    fail "refusing to snapshot unhealthy Tailscale/OpenSSH state"
    return 1
  }
  [[ -s "$STATE_FILE" ]] || {
    fail "refusing snapshot without nonempty Tailscale state at $STATE_FILE"
    return 1
  }
  [[ -f "$AUTHORIZED_KEYS" ]] || {
    fail "refusing snapshot without explicit authorized_keys at $AUTHORIZED_KEYS"
    return 1
  }
  snapshot_args
  local host_key_count=0 entry
  for entry in "${SNAPSHOT_FILES[@]}"; do
    [[ "$entry" == ssh/ssh_host_*=* ]] && host_key_count=$((host_key_count + 1))
  done
  [[ "$host_key_count" -gt 0 ]] || {
    fail "refusing snapshot without OpenSSH host keys"
    return 1
  }
  private_key_modes_ok || {
    fail "refusing snapshot with overly permissive OpenSSH private host keys"
    return 1
  }

  # Root-owned sources are copied into a private, user-owned staging tree.
  # The generic snapshot helper never needs elevated privileges and therefore
  # cannot leave a root-owned current symlink behind.
  mkdir -p "$PERSIST"
  local input_stage spec logical source target rc index
  local staged_args=()
  input_stage="$(mktemp -d "$PERSIST/.snapshot-input.XXXXXX")" || return
  chmod 700 "$input_stage"
  index=1
  while [[ "$index" -lt "${#SNAPSHOT_FILES[@]}" ]]; do
    spec="${SNAPSHOT_FILES[$index]}"
    logical="${spec%%=*}"
    source="${spec#*=}"
    target="$input_stage/$logical"
    mkdir -p "$(dirname "$target")"
    if ! priv cp -p "$source" "$target"; then
      rm -rf "$input_stage"
      fail "could not stage protected recovery source $source"
      return 1
    fi
    priv chown "$(id -u):$(id -g)" "$target" || {
      rm -rf "$input_stage"
      return 1
    }
    staged_args+=("--file" "$logical=$target")
    index=$((index + 2))
  done
  python3 "$STATE_HELPER" create \
    --component tailscale-openssh --persist "$PERSIST" "${staged_args[@]}" >/dev/null
  rc=$?
  rm -rf "$input_stage"
  if [[ "$rc" -ne 0 ]]; then
    fail "Tailscale/OpenSSH snapshot creation failed"
    return "$rc"
  fi
  log "validated Tailscale/OpenSSH snapshot"
}

invalidate_reset() {
  python3 "$STATE_HELPER" invalidate-provenance --persist "$PERSIST" || {
    fail "could not invalidate Tailscale/OpenSSH reset authority"
    return 1
  }
}

arm_reset() {
  python3 "$STATE_HELPER" prepare \
    --component tailscale-openssh --persist "$PERSIST" \
    --machine-id-file "$MACHINE_ID_FILE" --boot-id-file "$BOOT_ID_FILE" >/dev/null || {
      fail "could not record Tailscale/OpenSSH reset authority"
      return 1
    }
  log "recorded Tailscale/OpenSSH reset provenance"
}

prepare_reset() {
  invalidate_reset || return
  create_snapshot || return
  arm_reset
}

release_for_recovery() {
  python3 "$STATE_HELPER" verify-provenance \
    --component tailscale-openssh --persist "$PERSIST" \
    --machine-id-file "$MACHINE_ID_FILE" --boot-id-file "$BOOT_ID_FILE" \
    --max-age "$MAX_AGE"
}

consume_provenance() {
  python3 "$STATE_HELPER" consume \
    --component tailscale-openssh --persist "$PERSIST" \
    --machine-id-file "$MACHINE_ID_FILE" --boot-id-file "$BOOT_ID_FILE" \
    --max-age "$MAX_AGE" >/dev/null
}

path_present() {
  [[ -e "$1" || -L "$1" ]]
}

preflight_target() {
  local target="$1"
  if [[ -L "$target" && ! -e "$target" ]]; then
    fail "dangling symlink is ambiguous; refusing recovery: $target"
    return 1
  fi
  if ! path_present "$target" && [[ "$APPROVE_SENSITIVE" != "1" ]]; then
    fail "explicit approval required to restore deleted sensitive file: $target"
    return 1
  fi
}

publish_absent() {
  local source="$1" target="$2" mode="${3:-}" owner="${4:-}"
  [[ -f "$source" ]] || {
    fail "validated snapshot is missing $source"
    return 1
  }
  path_present "$target" && return 0
  local args=(publish --source "$source" --target "$target")
  [[ -n "$mode" ]] && args+=(--mode "$mode")
  [[ -n "$owner" ]] && args+=(--owner "$owner")
  priv python3 "$STATE_HELPER" "${args[@]}" || {
    fail "no-replace publication failed for $target"
    return 1
  }
  CREATED_TARGETS+=("$target")
  RESTORED=1
  log "restored missing $target"
}

validate_host_keys_plan() {
  local release="$1" snapshot_keys=() live_count=0 matched_count=0 file target
  for file in "$release"/ssh/ssh_host_*; do
    [[ -f "$file" ]] || continue
    snapshot_keys+=("$file")
    target="$SSH_DIR/$(basename "$file")"
    [[ -e "$target" ]] && matched_count=$((matched_count + 1))
  done
  [[ "${#snapshot_keys[@]}" -gt 0 ]] || {
    fail "validated snapshot contains no OpenSSH host keys"
    return 1
  }
  for file in "$SSH_DIR"/ssh_host_*; do
    [[ -f "$file" ]] && live_count=$((live_count + 1))
  done
  if [[ "$live_count" -gt 0 &&
        ( "$live_count" -ne "${#snapshot_keys[@]}" ||
          "$matched_count" -ne "${#snapshot_keys[@]}" ) ]]; then
    fail "partial or replaced live OpenSSH host-key set is ambiguous; refusing overwrite"
    return 1
  fi
  if [[ "$live_count" -eq 0 ]]; then
    for file in "${snapshot_keys[@]}"; do
      preflight_target "$SSH_DIR/$(basename "$file")" || return
    done
  fi
}

restore_host_keys() {
  local release="$1" file
  local live_count=0
  for file in "$SSH_DIR"/ssh_host_*; do
    [[ -f "$file" ]] && live_count=$((live_count + 1))
  done
  if [[ "$live_count" -eq 0 ]]; then
    for file in "$release"/ssh/ssh_host_*; do
      [[ -f "$file" ]] || continue
      publish_absent "$file" "$SSH_DIR/$(basename "$file")" "" "$SYSTEM_OWNER" || return
    done
  fi
}

rollback_created() {
  local index target failed=0
  for ((index=${#CREATED_TARGETS[@]} - 1; index >= 0; index--)); do
    target="${CREATED_TARGETS[$index]}"
    priv rm -f -- "$target" || failed=1
  done
  CREATED_TARGETS=()
  [[ "$failed" -eq 0 ]] || fail "failed to roll back partial Tailscale/OpenSSH recovery"
}

preflight_recovery() {
  local release="$1"
  [[ -f "$release/tailscale/tailscaled.state" &&
     -f "$release/ssh/sshd_config" &&
     -f "$release/box-ssh/authorized_keys" ]] || {
    fail "validated Tailscale/OpenSSH snapshot lacks required files"
    return 1
  }
  preflight_target "$STATE_FILE" || return
  preflight_target "$SSHD_CONFIG" || return
  preflight_target "$AUTHORIZED_KEYS" || return
  validate_host_keys_plan "$release"
}

start_command() {
  local command="$1" label="$2"
  [[ -n "$command" ]] || {
    fail "no $label start command configured"
    return 1
  }
  bash -c "$command"
}

recover() {
  if check_health; then
    if [[ -f "$PERSIST/reset-provenance.json" ]] &&
       release_for_recovery >/dev/null 2>&1; then
      consume_provenance || return
    fi
    log "Tailscale/OpenSSH healthy; no recovery needed"
    return 0
  fi

  local release
  release="$(release_for_recovery)" || {
    fail "Tailscale/OpenSSH recovery is ambiguous; prepare a reset while healthy or repair manually"
    return 2
  }

  # Validate the complete file plan before the first mutation. In particular,
  # host-key ambiguity cannot leave state/config partially restored.
  preflight_recovery "$release" || return 2

  # Restore only absent files. Existing state/config/key files are authoritative,
  # including an empty authorized_keys file representing deliberate revocation.
  publish_absent "$release/tailscale/tailscaled.state" "$STATE_FILE" 600 "$SYSTEM_OWNER" ||
    { rollback_created; return 1; }
  publish_absent "$release/ssh/sshd_config" "$SSHD_CONFIG" "" "$SYSTEM_OWNER" ||
    { rollback_created; return 1; }
  restore_host_keys "$release" || { rollback_created; return 1; }
  publish_absent "$release/box-ssh/authorized_keys" "$AUTHORIZED_KEYS" 600 \
    "${RECOVERY_USER_OWNER:-$(id -un):$(id -gn)}" || { rollback_created; return 1; }

  if [[ "$(backend_state || true)" != "Running" ]]; then
    start_command "${TAILSCALED_START_CMD:-sudo systemctl start tailscaled}" tailscaled || {
      fail "could not start tailscaled"
      return 3
    }
  fi
  if ! port_22_listening; then
    start_command "${OPENSSH_START_CMD:-sudo systemctl start ssh}" OpenSSH || {
      fail "could not start OpenSSH"
      return 4
    }
  fi

  local runssh
  runssh="$(runssh_value || true)"
  if [[ "$runssh" == "true" ]]; then
    priv "$TS_BIN" set --ssh=false >/dev/null 2>&1 || {
      fail "failed to disable Tailscale SSH"
      return 5
    }
    RESTORED=1
    log "disabled Tailscale SSH (RunSSH=false)"
  elif [[ "$runssh" != "false" ]]; then
    fail "cannot read Tailscale RunSSH preference"
    return 5
  fi
  [[ "$(runssh_value || true)" == "false" ]] || {
    fail "Tailscale RunSSH verification failed after set --ssh=false"
    return 5
  }

  check_health || {
    fail "Tailscale/OpenSSH remains unhealthy after recovery; provenance retained"
    return 6
  }
  consume_provenance || return
  log "Tailscale/OpenSSH recovery completed and provenance consumed"
  [[ "$RESTORED" -eq 1 ]] && return 10
  return 0
}

case "$MODE" in
  monitor|check) check_health ;;
  snapshot) with_lock create_snapshot ;;
  invalidate-reset) with_lock invalidate_reset ;;
  arm-reset) with_lock arm_reset ;;
  prepare-reset) with_lock prepare_reset ;;
  recover) with_lock recover ;;
  *)
    fail "usage: $0 monitor|snapshot|invalidate-reset|arm-reset|prepare-reset|recover"
    exit 64
    ;;
esac
