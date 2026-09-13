#!/usr/bin/env bash
# After a Sand wipe: reinstall the host hook, CLIProxy v7, and Management Center
# from this repo. Secrets (claude login, Meta API keys) are not in git.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECKOUT="${GROK_BOT_SETUP_DIR:-$HOME/grok-bot-setup}"

run_validated_runtime() {
  local base="$1" helper release
  helper="$base/current/scripts/recovery-state.py"
  [[ -f "$helper" ]] || return 1
  release="$(python3 "$helper" verify \
    --component host-recovery-runtime --persist "$base")" || return 1
  [[ -x "$release/scripts/recover-host-services.sh" ]] || return 1
  echo "+ checkout unavailable; running narrow validated host-service recovery" >&2
  exec "$release/scripts/recover-host-services.sh" recover
}

if [[ -x "$ROOT/adapters.sh" ]]; then
  ADAPTERS="$ROOT/adapters.sh"
elif [[ -x "$CHECKOUT/adapters.sh" ]]; then
  ADAPTERS="$CHECKOUT/adapters.sh"
else
  run_validated_runtime "$ROOT/recovery-runtime" ||
    run_validated_runtime "${GROK_RECOVERY_RUNTIME_DIR:-$HOME/.local/share/grok-bot-persist/recovery-runtime}" ||
    {
      # When this wrapper itself is inside releases/<id>/scripts.
      if [[ -f "$ROOT/manifest.json" ]]; then
        run_validated_runtime "$(cd "$ROOT/../.." && pwd)"
      else
        false
      fi
    } || {
      echo "ERROR: no checkout or validated persisted recovery runtime found" >&2
      exit 1
    }
fi

exec "$ADAPTERS" recover "$@"
