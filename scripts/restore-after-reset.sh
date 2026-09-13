#!/usr/bin/env bash
# After a Sand wipe: reinstall the host hook, CLIProxy v7, and Management Center
# from this repo. Secrets (claude login, Meta API keys) are not in git.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECKOUT="${GROK_BOT_SETUP_DIR:-$HOME/grok-bot-setup}"

if [[ -x "$ROOT/adapters.sh" ]]; then
  ADAPTERS="$ROOT/adapters.sh"
elif [[ -x "$CHECKOUT/adapters.sh" ]]; then
  ADAPTERS="$CHECKOUT/adapters.sh"
elif [[ -x "$ROOT/scripts/recover-host-services.sh" ]]; then
  echo "+ checkout unavailable; running narrow persisted host-service recovery" >&2
  exec "$ROOT/scripts/recover-host-services.sh" recover
elif [[ -x "$ROOT/recovery-runtime/current/scripts/recover-host-services.sh" ]]; then
  echo "+ checkout unavailable; running narrow persisted host-service recovery" >&2
  exec "$ROOT/recovery-runtime/current/scripts/recover-host-services.sh" recover
else
  echo "ERROR: no checkout or validated persisted recovery runtime found" >&2
  exit 1
fi

exec "$ADAPTERS" recover "$@"
