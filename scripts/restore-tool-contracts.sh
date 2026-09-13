#!/usr/bin/env bash
# Restore inference/tool fixes only. Never restart services or modify auth/network settings.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -f "$ROOT/SHA256SUMS" ]]; then
  (cd "$ROOT" && sha256sum --check --status SHA256SUMS) || {
    echo "ERROR: recovery snapshot checksum mismatch; refusing restore" >&2
    exit 1
  }
fi
node --check "$ROOT/xai-prompt-session.cjs"
node "$ROOT/tests/machine-id.cjs"
node "$ROOT/tests/end-turn.cjs"
# Override source explicitly: never fall back to a possibly reset checkout.
XAI_SESSION_SRC="$ROOT/xai-prompt-session.cjs" \
XAI_ENSURE_SCRIPT="$ROOT/scripts/ensure-xai-inference.sh" \
  bash "$ROOT/scripts/verify-tool-patch.sh"
