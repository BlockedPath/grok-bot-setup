#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ ! -f .env ]]; then
  echo "Missing .env — copy .env.example to .env and fill in your API keys." >&2
  exit 1
fi

set -a
# shellcheck disable=SC1091
source .env
set +a

if [[ -z "${LITELLM_MASTER_KEY:-}" ]]; then
  echo "LITELLM_MASTER_KEY is not set in .env" >&2
  exit 1
fi

# Load Grok CLI session token from auth.json (from `grok login`) when present.
# Optional: other backends (Claude/Gemini) still work without it.
GROK_AUTH_FILE="${GROK_AUTH_FILE:-$HOME/.grok/auth.json}"
if [[ -z "${GROK_SESSION_TOKEN:-}" && -f "$GROK_AUTH_FILE" ]]; then
  GROK_SESSION_TOKEN="$(
    python3 - "$GROK_AUTH_FILE" <<'PY' || true
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
try:
    data = json.loads(path.read_text())
except Exception:
    sys.exit(0)
entry = None
for k, v in data.items():
    if isinstance(v, dict) and v.get("key") and ("auth.x.ai" in k or v.get("auth_mode") == "oidc"):
        entry = v
        break
if entry is None:
    for v in data.values():
        if isinstance(v, dict) and v.get("key"):
            entry = v
            break
if not entry or not entry.get("key"):
    sys.exit(0)
expires = entry.get("expires_at")
if expires:
    try:
        from datetime import datetime, timezone
        exp = datetime.fromisoformat(expires.replace("Z", "+00:00"))
        secs = (exp - datetime.now(timezone.utc)).total_seconds()
        if secs <= 0:
            print("WARNING: Grok session token is expired; run: grok login", file=sys.stderr)
        elif secs < 3600:
            print(f"WARNING: Grok session token expires in {int(secs/60)}m", file=sys.stderr)
    except Exception:
        pass
print(entry["key"], end="")
PY
  )"
  export GROK_SESSION_TOKEN
fi

if [[ -z "${GROK_SESSION_TOKEN:-}" ]]; then
  echo "WARNING: no GROK_SESSION_TOKEN — 'grok' alias will fail until: grok login" >&2
  # Placeholder so LiteLLM env resolution does not crash at import for other models
  export GROK_SESSION_TOKEN="missing-grok-session-token"
fi

# Prefer uv-tool install on PATH; fall back to uvx / project venv.
if command -v litellm >/dev/null 2>&1; then
  LITELLM_BIN=(litellm)
elif command -v uvx >/dev/null 2>&1; then
  LITELLM_BIN=(uvx --from 'litellm[proxy]' litellm)
elif [[ -x "$ROOT/.venv/bin/litellm" ]]; then
  LITELLM_BIN=("$ROOT/.venv/bin/litellm")
else
  echo "litellm not found. Install with: uv tool install 'litellm[proxy]'" >&2
  exit 1
fi

echo "Using Grok session auth from ${GROK_AUTH_FILE}"
echo "Starting LiteLLM proxy on http://127.0.0.1:4000 ..."
exec "${LITELLM_BIN[@]}" --config "$ROOT/config.yaml" --host 127.0.0.1 --port 4000
