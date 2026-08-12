#!/usr/bin/env bash
# Sync Claude Code OAuth tokens into CLIProxyAPI auth-dir format.
set -euo pipefail
CREDS="${CLAUDE_CREDENTIALS:-$HOME/.claude/.credentials.json}"
AUTH_DIR="${CLIPROXY_AUTH_DIR:-$HOME/.cli-proxy-api}"
OUT="$AUTH_DIR/claude-pro-local.json"
mkdir -p "$AUTH_DIR"
python3 - "$CREDS" "$OUT" <<'PY'
import json, sys
from pathlib import Path
from datetime import datetime, timezone
creds_path, out_path = Path(sys.argv[1]), Path(sys.argv[2])
creds = json.loads(creds_path.read_text())
oauth = creds.get("claudeAiOauth") or creds
if not oauth.get("accessToken"):
    raise SystemExit(f"no accessToken in {creds_path}")
expires_ms = oauth.get("expiresAt") or 0
if expires_ms > 1e12:
    exp = datetime.fromtimestamp(expires_ms / 1000, tz=timezone.utc)
else:
    exp = datetime.fromtimestamp(expires_ms, tz=timezone.utc) if expires_ms else datetime.now(timezone.utc)
auth = {
    "type": "claude",
    "email": "claude-pro@local",
    "access_token": oauth["accessToken"],
    "refresh_token": oauth.get("refreshToken") or "",
    "expired": exp.isoformat().replace("+00:00", "Z"),
    "last_refresh": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    "id_token": "",
}
out_path.write_text(json.dumps(auth, indent=2) + "\n")
print(f"wrote {out_path} expires={auth['expired']}")
PY
