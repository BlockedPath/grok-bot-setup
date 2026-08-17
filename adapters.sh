#!/usr/bin/env bash
# Grok Bot adapters — interactive CLI (default) + scriptable subcommands.
#
# Interactive (menu):
#   ./adapters.sh
#   ./adapters.sh menu
#
# Scriptable:
#   adapters.sh status | install | start | stop | use | restart-host | help
#
# Switching writes /home/box/sand-data/xai-inference.env and can restart the host.
set -euo pipefail

# Resolve script dir even when installed as an npm bin symlink
_script_dir() {
  local src="${BASH_SOURCE[0]}"
  local dir
  while [[ -L "$src" ]]; do
    dir="$(cd -P "$(dirname "$src")" && pwd)"
    src="$(readlink "$src")"
    [[ "$src" != /* ]] && src="$dir/$src"
  done
  cd -P "$(dirname "$src")" && pwd
}
ROOT="$(_script_dir)"

SAND_DATA="${SAND_DATA_ROOT:-$HOME/sand-data}"
SAND_HOST="${SAND_HOST_DIR:-$HOME/sand-host}"
ENV_FILE="${SAND_XAI_ENV_FILE:-$SAND_DATA/xai-inference.env}"
SETTINGS_FILE="${SAND_SETTINGS_FILE:-$SAND_DATA/settings.json}"

# Runtime trees from `install`. Prefer a stable home data dir (npm/npx safe);
# fall back to next-to-script if that layout already exists (repo checkout).
_adapters_data_dir() {
  if [[ -n "${ADAPTERS_DATA:-}" ]]; then
    printf '%s' "$ADAPTERS_DATA"
    return
  fi
  if [[ -d "$ROOT/cliproxy-api" || -d "$ROOT/grok-model-bridge" ]]; then
    printf '%s' "$ROOT"
    return
  fi
  printf '%s' "${XDG_DATA_HOME:-$HOME/.local/share}/grok-bot-adapters"
}
ADAPTERS_DATA="$(_adapters_data_dir)"
CLIPROXY_DIR="${CLIPROXY_DIR:-$ADAPTERS_DATA/cliproxy-api}"
LITELLM_DIR="${LITELLM_DIR:-$ADAPTERS_DATA/grok-model-bridge}"
CLIPROXY_BIN="${CLIPROXY_BIN:-$HOME/go/bin/server}"
CLIPROXY_PORT="${CLIPROXY_PORT:-8317}"
LITELLM_PORT="${LITELLM_PORT:-4000}"
OPENAI_OAUTH_PORT="${OPENAI_OAUTH_PORT:-10531}"
CLIPROXY_KEY="${CLIPROXY_KEY:-sand-cliproxy}"
CLIPROXY_MGMT_KEY_FILE="${CLIPROXY_MGMT_KEY_FILE:-$CLIPROXY_DIR/management.key}"
CLIPROXY_PANEL_REPO="${CLIPROXY_PANEL_REPO:-https://github.com/router-for-me/Cli-Proxy-API-Management-Center}"
LITELLM_KEY_DEFAULT="sk-local-bridge-change-me"

# 1 when running the full interactive menu loop
INTERACTIVE_MENU=0

log()  { printf '+ %s\n' "$*"; }
warn() { printf '! %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# Resolve a path for interactive I/O. Prefer a real TTY; fall back to stdout/stdin.
_TTY_OUT=""
_TTY_IN=""
init_tty() {
  if [[ -n "${_TTY_OUT:-}" ]]; then
    return 0
  fi
  if [[ -c /dev/tty ]] && { : >/dev/tty; } 2>/dev/null; then
    _TTY_OUT=/dev/tty
    _TTY_IN=/dev/tty
  elif [[ -t 1 ]]; then
    _TTY_OUT=/dev/stdout
    _TTY_IN=/dev/stdin
  else
    _TTY_OUT=/dev/stderr
    _TTY_IN=/dev/stdin
  fi
}

tty_path() {
  # legacy name used as "out" target in some call sites
  init_tty
  printf '%s' "$_TTY_OUT"
}

tty_in() {
  init_tty
  printf '%s' "$_TTY_IN"
}

tty_echo() {
  init_tty
  printf '%s\n' "$*" >"$_TTY_OUT"
}

pause() {
  init_tty
  printf '\nPress Enter to continue... ' >"$_TTY_OUT"
  # shellcheck disable=SC2162
  read -r _ <"$_TTY_IN" || true
  printf '\n' >"$_TTY_OUT"
}

current_provider_summary() {
  local model="?" base="?" provider="?" thinking="?" effort="?"
  if [[ -f "$ENV_FILE" ]]; then
    model="$(grep -E '^SAND_XAI_MODEL=' "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- || true)"
    base="$(grep -E '^SAND_XAI_BASE_URL=' "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- || true)"
    provider="$(grep -E '^SAND_INFERENCE_PROVIDER=' "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- || true)"
    thinking="$(grep -E '^SAND_XAI_THINKING=' "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- || true)"
    effort="$(grep -E '^SAND_XAI_REASONING_EFFORT=' "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- || true)"
  fi
  model="${model:-?}"
  base="${base:-(default / session)}"
  provider="${provider:-?}"
  thinking="${thinking:-?}"
  effort="${effort:-(none)}"
  printf 'provider=%s  model=%s  effort=%s  thinking=%s  base=%s' \
    "$provider" "$model" "$effort" "$thinking" "$base"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

# Some checkouts / copies land the Go binary as 0644. Restore +x if present.
ensure_cliproxy_bin() {
  if [[ -x "$CLIPROXY_BIN" ]]; then
    return 0
  fi
  if [[ -f "$CLIPROXY_BIN" ]]; then
    chmod +x "$CLIPROXY_BIN" 2>/dev/null || true
    [[ -x "$CLIPROXY_BIN" ]] && return 0
  fi
  return 1
}

# ── process helpers (avoid pgrep -f self-match) ─────────────────────────────
pids_matching() {
  # $1 = substring that must appear in cmdline
  python3 - "$1" <<'PY'
import os, sys
needle = sys.argv[1]
for pid in os.listdir("/proc"):
    if not pid.isdigit():
        continue
    try:
        raw = open(f"/proc/{pid}/cmdline", "rb").read()
    except Exception:
        continue
    if not raw:
        continue
    cmd = raw.replace(b"\0", b" ").decode("utf-8", "replace")
    # skip this python helper and outer bash when they only match via argv
    if "pids_matching" in cmd or "adapters.sh" in cmd:
        continue
    if needle in cmd:
        print(pid)
PY
}

kill_pids() {
  local pid
  for pid in "$@"; do
    [[ -n "$pid" ]] || continue
    kill "$pid" 2>/dev/null || true
  done
}

port_listening() {
  local port="$1"
  ss -tln 2>/dev/null | grep -qE ":${port}[[:space:]]" || return 1
}

wait_http() {
  local url="$1" auth="${2:-}" tries="${3:-20}"
  local i code
  for i in $(seq 1 "$tries"); do
    if [[ -n "$auth" ]]; then
      code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 -H "Authorization: Bearer ${auth}" "$url" 2>/dev/null || echo 000)
    else
      code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$url" 2>/dev/null || echo 000)
    fi
    if [[ "$code" =~ ^[23] ]]; then
      return 0
    fi
    sleep 0.5
  done
  return 1
}

# ── status ──────────────────────────────────────────────────────────────────
cmd_status() {
  echo "=== Grok Bot inference env ==="
  if [[ -f "$ENV_FILE" ]]; then
    sed -E 's/((KEY|TOKEN|SECRET|PASSWORD)=).*/\1***/' "$ENV_FILE"
  else
    echo "(missing) $ENV_FILE"
  fi
  echo
  if [[ -f "$SETTINGS_FILE" ]]; then
    python3 - "$SETTINGS_FILE" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
m = s.get("agentDefaultModel") or {}
print("=== settings.agentDefaultModel ===")
print(json.dumps(m, indent=2))
PY
  fi
  echo
  echo "=== adapters ==="
  printf '%-16s %-8s %s\n' "adapter" "port" "state"
  printf '%-16s %-8s %s\n' "--------" "----" "-----"

  local state
  if port_listening "$CLIPROXY_PORT"; then state="UP"; else state="down"; fi
  printf '%-16s %-8s %s\n' "CLIProxyAPI" "$CLIPROXY_PORT" "$state  (Claude OAuth)"

  if port_listening "$LITELLM_PORT"; then state="UP"; else state="down"; fi
  printf '%-16s %-8s %s\n' "LiteLLM" "$LITELLM_PORT" "$state  (multi-provider)"

  if port_listening "$OPENAI_OAUTH_PORT"; then state="UP"; else state="down"; fi
  printf '%-16s %-8s %s\n' "openai-oauth" "$OPENAI_OAUTH_PORT" "$state  (ChatGPT/Codex)"

  if port_listening 1340; then state="UP"; else state="down"; fi
  printf '%-16s %-8s %s\n' "sand-host" "1340" "$state  (Grok Bot gateway)"

  echo
  echo "=== install bits ==="
  ensure_cliproxy_bin && echo "cliproxy bin: OK ($CLIPROXY_BIN)" || echo "cliproxy bin: MISSING ($CLIPROXY_BIN)"
  local pidfile="$CLIPROXY_DIR/scripts/watchdog.pid" pid
  if [[ -f "$pidfile" ]] && pid="$(cat "$pidfile" 2>/dev/null || true)" && [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
    echo "cliproxy watchdog: running (pid $pid)"
  else
    echo "cliproxy watchdog: not running"
  fi
  command -v litellm >/dev/null 2>&1 && echo "litellm:     OK ($(command -v litellm))" || echo "litellm:     not on PATH (uvx fallback ok)"
  command -v npx >/dev/null 2>&1 && echo "npx:         OK" || echo "npx:         MISSING"
  [[ -f "$HOME/.claude/.credentials.json" ]] && echo "claude oauth: present" || echo "claude oauth: missing (claude login)"
  [[ -f "$HOME/.codex/auth.json" ]] && echo "codex oauth:  present" || echo "codex oauth:  missing (codex login)"
  [[ -f "$HOME/.grok/auth.json" ]] && echo "grok oauth:   present" || echo "grok oauth:   missing (grok login)"
  if [[ -s "$CLIPROXY_MGMT_KEY_FILE" ]]; then
    echo "management UI: http://127.0.0.1:${CLIPROXY_PORT}/management.html"
    echo "management key: $CLIPROXY_MGMT_KEY_FILE"
  else
    echo "management UI: not configured (adapters install cliproxy)"
  fi
  local cp_auth_dir="${CLIPROXY_AUTH_DIR:-$HOME/.cli-proxy-api}"
  if [[ -f "$cp_auth_dir/claude-pro-local.json" ]]; then
    python3 - "$cp_auth_dir/claude-pro-local.json" <<'PY'
import json, sys
from datetime import datetime, timezone
try:
    d = json.load(open(sys.argv[1]))
    exp = d.get("expired") or ""
    if exp:
        t = datetime.fromisoformat(exp.replace("Z", "+00:00"))
        mins = (t - datetime.now(timezone.utc)).total_seconds() / 60
        state = "OK" if mins > 0 else "EXPIRED"
        print(f"claude token: {state} (expires in {int(mins)}m)")
except Exception:
    pass
PY
  fi
  echo
  echo "=== host inference hook ==="
  if [[ -f "$SAND_HOST/xai-prompt-session.cjs" ]]; then
    echo "session module: OK ($SAND_HOST/xai-prompt-session.cjs)"
  else
    echo "session module: MISSING ($SAND_HOST/xai-prompt-session.cjs)"
    echo "  sand will ignore xai-inference.env until: adapters patch-host"
  fi
  if [[ -f "$SAND_HOST/host-main.cjs" ]] && grep -q createXaiPromptSession "$SAND_HOST/host-main.cjs"; then
    echo "createSession hook: OK"
  else
    echo "createSession hook: MISSING — stock Cursor path is still active"
    echo "  fix: adapters patch-host && adapters restart-host"
  fi
}

# ── install ─────────────────────────────────────────────────────────────────
write_cliproxy_tree() {
  local cp_auth_dir="${CLIPROXY_AUTH_DIR:-$HOME/.cli-proxy-api}"
  mkdir -p "$CLIPROXY_DIR/scripts" "$cp_auth_dir"
  CLIPROXY_MGMT_KEY="$(ensure_cliproxy_mgmt_key)"
  if [[ ! -f "$CLIPROXY_DIR/config.yaml" ]]; then
    cat >"$CLIPROXY_DIR/config.yaml" <<EOF
host: "127.0.0.1"
port: ${CLIPROXY_PORT}
auth-dir: "${cp_auth_dir}"
api-keys:
  - "${CLIPROXY_KEY}"
debug: true
logging-to-file: true
request-retry: 2
disable-cooling: true
ws-auth: false
streaming:
  bootstrap-retries: 3
remote-management:
  allow-remote: false
  secret-key: "${CLIPROXY_MGMT_KEY}"
  disable-control-panel: false
  panel-github-repository: "${CLIPROXY_PANEL_REPO}"
EOF
    log "wrote $CLIPROXY_DIR/config.yaml"
  elif ! grep -q '^streaming:' "$CLIPROXY_DIR/config.yaml" 2>/dev/null; then
    # Upgrade older configs in place (auth retry before first streaming byte)
    cat >>"$CLIPROXY_DIR/config.yaml" <<'EOF'
streaming:
  bootstrap-retries: 3
EOF
    log "added streaming.bootstrap-retries to $CLIPROXY_DIR/config.yaml"
  fi
  patch_cliproxy_management_config
  ensure_cliproxy_compat_providers
  # Bidirectional, freshest-wins sync between Claude Code OAuth credentials and
  # CLIProxyAPI's auth file. Either side may rotate tokens (Claude Code CLI on
  # use, CLIProxyAPI via its built-in auto-refresh), and every rotation revokes
  # the other side's token — so the freshest token set must win in both files.
  cat >"$CLIPROXY_DIR/scripts/sync-claude-auth.sh" <<'EOF'
#!/usr/bin/env bash
# Sync Claude Code OAuth tokens with CLIProxyAPI auth-dir (bidirectional).
#
# Both Claude Code (~/.claude/.credentials.json) and CLIProxyAPI can refresh the
# OAuth token; each refresh rotates tokens and revokes what the other side
# holds. This script copies the freshest token set into BOTH files and, when the
# freshest access token is expired (or about to expire), refreshes it via
# Anthropic's OAuth endpoint itself. Safe to run repeatedly (flock-guarded).
#
# Usage: sync-claude-auth.sh [--refresh | --no-refresh]
set -euo pipefail
CREDS="${CLAUDE_CREDENTIALS:-$HOME/.claude/.credentials.json}"
AUTH_DIR="${CLIPROXY_AUTH_DIR:-$HOME/.cli-proxy-api}"
OUT="$AUTH_DIR/claude-pro-local.json"
LOCK="$AUTH_DIR/.claude-sync.lock"
FORCE_REFRESH="no"
case "${1:-}" in
  --refresh|--force) FORCE_REFRESH="yes" ;;
  --no-refresh) FORCE_REFRESH="never" ;;
  "") ;;
  *) echo "usage: $(basename "$0") [--refresh|--no-refresh]" >&2; exit 2 ;;
esac
mkdir -p "$AUTH_DIR"

if ! command -v python3 >/dev/null 2>&1; then
  echo "sync-claude-auth: python3 not found" >&2
  exit 1
fi

FORCE_REFRESH="$FORCE_REFRESH" REFRESH_AHEAD="${CLAUDE_REFRESH_AHEAD:-300}" \
  python3 - "$CREDS" "$OUT" "$LOCK" <<'PY'
import fcntl, json, os, sys, time, urllib.error, urllib.request
from datetime import datetime, timezone
from pathlib import Path

creds_path, out_path, lock_path = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
force = os.environ.get("FORCE_REFRESH", "no")
try:
    refresh_ahead = float(os.environ.get("REFRESH_AHEAD", "300"))
except ValueError:
    refresh_ahead = 300.0

# Same endpoint + public client_id CLIProxyAPI v6 uses for OAuth refresh.
TOKEN_URL = "https://api.anthropic.com/v1/oauth/token"
CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"


def now_ms():
    return int(time.time() * 1000)


def parse_ms(value):
    if value is None:
        return 0
    try:
        v = float(value)
    except (TypeError, ValueError):
        return 0
    if v <= 0:
        return 0
    return int(v * 1000) if v < 1e12 else int(v)


def parse_rfc3339(value):
    if not value:
        return 0
    try:
        return int(datetime.fromisoformat(str(value).replace("Z", "+00:00")).timestamp() * 1000)
    except ValueError:
        return 0


def atomic_write(path, text):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(text)
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def http_json(url, payload, timeout=30):
    req = urllib.request.Request(
        url,
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json", "Accept": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, json.loads(resp.read().decode() or "{}")
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", "replace")
        try:
            return e.code, json.loads(body)
        except Exception:
            return e.code, {"error": body}
    except Exception as e:
        return 0, {"error": str(e)}


def read_creds():
    """Returns (creds_dict, oauth_dict) or None."""
    if not creds_path.is_file():
        return None
    try:
        data = json.loads(creds_path.read_text())
    except Exception:
        return None
    if not isinstance(data, dict):
        return None
    oauth = data.get("claudeAiOauth")
    if isinstance(oauth, dict) and oauth.get("accessToken"):
        return data, oauth
    if data.get("accessToken"):
        return data, data
    return None


def read_auth_file():
    if not out_path.is_file():
        return None
    try:
        data = json.loads(out_path.read_text())
    except Exception:
        return None
    if not isinstance(data, dict):
        return None
    if not (data.get("access_token") or data.get("refresh_token")):
        return None
    return data


def oauth_expiry_ms(oauth):
    if oauth.get("expiresAt") is not None:
        return parse_ms(oauth.get("expiresAt"))
    return parse_rfc3339(oauth.get("expired"))


def write_auth_file(at, rt, exp_ms, email):
    payload = {
        "type": "claude",
        "email": email,
        "access_token": at,
        "refresh_token": rt or "",
        "expired": datetime.fromtimestamp(exp_ms / 1000, tz=timezone.utc).isoformat().replace("+00:00", "Z"),
        "last_refresh": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "id_token": "",
    }
    atomic_write(out_path, json.dumps(payload, indent=2) + "\n")


def write_creds(creds, oauth, at, rt, exp_ms):
    # Preserve every unrelated field; only touch the token fields.
    orig_exp = oauth.get("expiresAt")
    in_seconds = isinstance(orig_exp, (int, float)) and 0 < orig_exp < 1e12
    oauth["accessToken"] = at
    oauth["refreshToken"] = rt
    oauth["expiresAt"] = exp_ms / 1000.0 if in_seconds else exp_ms
    rt_exp = oauth.get("refreshTokenExpiresAt")
    if rt_exp:
        # Anthropic rotates the refresh token on every refresh with a fresh
        # ~30d window; keep the CLI's expiry estimate in line with it.
        rt_seconds = isinstance(rt_exp, (int, float)) and 0 < rt_exp < 1e12
        rt_exp_ms = exp_ms + 29 * 24 * 3600 * 1000
        oauth["refreshTokenExpiresAt"] = rt_exp_ms / 1000.0 if rt_seconds else rt_exp_ms
    if isinstance(creds.get("claudeAiOauth"), dict):
        creds["claudeAiOauth"] = oauth
    atomic_write(creds_path, json.dumps(creds, indent=2) + "\n")


def do_refresh(rt):
    status, data = http_json(
        TOKEN_URL,
        {"client_id": CLIENT_ID, "grant_type": "refresh_token", "refresh_token": rt},
    )
    if status != 200 or not isinstance(data, dict) or not data.get("access_token"):
        err = ""
        if isinstance(data, dict):
            err = data.get("error_description") or data.get("error") or json.dumps(data)
        return None, str(err or f"HTTP {status}")
    at = data["access_token"]
    new_rt = data.get("refresh_token") or rt
    expires_in = int(data.get("expires_in") or 3600)
    acc = data.get("account") or {}
    email = acc.get("email_address") if isinstance(acc, dict) else ""
    return (at, new_rt, now_ms() + expires_in * 1000, email), None


def iso(exp_ms):
    return datetime.fromtimestamp(exp_ms / 1000, tz=timezone.utc).isoformat().replace("+00:00", "Z")


def main():
    # Serialize concurrent syncs so a refresh never races itself.
    with open(lock_path, "w") as lf:
        try:
            fcntl.flock(lf, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            print("sync-claude-auth: another sync is running, skipping")
            return 0

        creds_entry = read_creds()
        auth_entry = read_auth_file()

        if creds_entry is None and auth_entry is None:
            print(f"sync-claude-auth: no Claude credentials ({creds_path}) — run: claude login")
            return 0

        if creds_entry is not None:
            creds, oauth = creds_entry
            c_at, c_rt = oauth.get("accessToken") or "", oauth.get("refreshToken") or ""
            c_exp = oauth_expiry_ms(oauth)
            c_email = oauth.get("emailAddress") or oauth.get("email") or "claude-pro@local"
        else:
            creds, oauth, c_at, c_rt, c_exp, c_email = None, None, "", "", 0, "claude-pro@local"

        if auth_entry is not None:
            a_at = auth_entry.get("access_token") or ""
            a_rt = auth_entry.get("refresh_token") or ""
            a_exp = parse_rfc3339(auth_entry.get("expired"))
            a_email = auth_entry.get("email") or "claude-pro@local"
        else:
            a_at, a_rt, a_exp, a_email = "", "", 0, "claude-pro@local"

        # Later access-token expiry => the token set that was rotated most
        # recently, i.e. the one still valid on both sides.
        if c_at and (c_exp > a_exp or not a_at):
            at, rt, email, exp_ms = c_at, c_rt, c_email, c_exp
        elif a_at:
            at, rt, email, exp_ms = a_at, a_rt, a_email, a_exp
        else:
            print("sync-claude-auth: no usable tokens found — run: claude login")
            return 1

        refreshed = False
        near_expiry = exp_ms and exp_ms - now_ms() < refresh_ahead * 1000
        if rt and force == "yes" or (force == "no" and near_expiry and rt):
            result, err = do_refresh(rt)
            if result is not None:
                at, rt, exp_ms, new_email = result
                email = new_email or email
                refreshed = True
                print(f"sync-claude-auth: refreshed OAuth token (expires {iso(exp_ms)})")
            else:
                print(f"sync-claude-auth: refresh failed: {err} — run 'claude login' if this persists")

        # Converge both files on the freshest token set.
        if auth_entry is None or a_at != at or a_rt != rt:
            write_auth_file(at, rt, exp_ms, email)
            print(f"sync-claude-auth: wrote {out_path}")
        if creds is not None and (c_at != at or c_rt != rt):
            write_creds(creds, oauth, at, rt, exp_ms)
            print(f"sync-claude-auth: wrote {creds_path}")

        state = "refreshed" if refreshed else "in sync"
        print(f"sync-claude-auth: {state}, access token expires {iso(exp_ms)}")
        return 0


sys.exit(main())
PY
EOF
  # Watchdog: keeps the server up and re-syncs tokens while it runs.
  cat >"$CLIPROXY_DIR/scripts/watchdog.sh" <<'EOF'
#!/usr/bin/env bash
# CLIProxyAPI watchdog: keep the server alive and Claude OAuth tokens synced.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${CLIPROXY_BIN:-$HOME/go/bin/server}"
CONFIG="${CLIPROXY_CONFIG:-$ROOT/config.yaml}"
LOG="${CLIPROXY_LOG:-/tmp/cliproxy.log}"
PORT="${CLIPROXY_PORT:-8317}"
KEY="${CLIPROXY_KEY:-sand-cliproxy}"
CHECK_INTERVAL="${CLIPROXY_CHECK_INTERVAL:-10}"
SYNC_INTERVAL="${CLIPROXY_SYNC_INTERVAL:-60}"
PIDFILE="$ROOT/scripts/watchdog.pid"
SERVER_PIDFILE="$ROOT/scripts/server.pid"

wlog() { echo "watchdog: $(date -u +%FT%TZ) $*" >>"$LOG"; }

echo $$ >"$PIDFILE"
trap 'rm -f "$PIDFILE"' EXIT

sync_auth() {
  "$ROOT/scripts/sync-claude-auth.sh" >>"$LOG" 2>&1 || true
}

is_ready() {
  curl -sf -m 2 -H "Authorization: Bearer $KEY" \
    "http://127.0.0.1:$PORT/v1/models" >/dev/null 2>&1
}

start_server() {
  if [[ ! -x "$BIN" && -f "$BIN" ]]; then
    chmod +x "$BIN" 2>/dev/null || true
  fi
  if [[ ! -x "$BIN" ]]; then
    wlog "binary missing at $BIN — run: adapters.sh install cliproxy"
    return 1
  fi
  wlog "starting server"
  nohup "$BIN" -config "$CONFIG" >>"$LOG" 2>&1 &
  echo $! >"$SERVER_PIDFILE"
  return 0
}

wlog "started (check=${CHECK_INTERVAL}s sync=${SYNC_INTERVAL}s)"
sync_auth
if ! is_ready; then
  start_server || true
fi

last_sync="$(date +%s)"
fails=0
while true; do
  sleep "$CHECK_INTERVAL"
  now="$(date +%s)"

  if ! is_ready; then
    # Token may have been revoked by a Claude Code CLI refresh; resync first,
    # then restart the server only if it is genuinely down.
    sync_auth
    sleep 1
    if ! is_ready; then
      fails=$((fails + 1))
      if [[ "$fails" -le 3 ]]; then
        start_server || true
      else
        wlog "server down after 3 attempts; backing off 60s"
        sleep 60
        fails=0
      fi
    else
      fails=0
    fi
  fi

  if (( now - last_sync >= SYNC_INTERVAL )); then
    sync_auth
    last_sync="$now"
  fi
done
EOF
  cat >"$CLIPROXY_DIR/scripts/start.sh" <<EOF
#!/usr/bin/env bash
# Start CLIProxyAPI for Claude OAuth (Opus etc.) with tool support.
# Ensures the watchdog is running; it supervises the server and keeps the
# Claude OAuth token synced bidirectionally while the proxy is up.
set -euo pipefail
ROOT="\$(cd "\$(dirname "\$0")/.." && pwd)"
BIN="\${CLIPROXY_BIN:-\$HOME/go/bin/server}"
LOG="\${CLIPROXY_LOG:-/tmp/cliproxy.log}"
PORT="\${CLIPROXY_PORT:-${CLIPROXY_PORT}}"
KEY="\${CLIPROXY_KEY:-${CLIPROXY_KEY}}"
PIDFILE="\$ROOT/scripts/watchdog.pid"

"\$ROOT/scripts/sync-claude-auth.sh" || true

if [ ! -x "\$BIN" ] && [ -f "\$BIN" ]; then
  chmod +x "\$BIN" 2>/dev/null || true
fi
if [ ! -x "\$BIN" ]; then
  echo "CLIProxyAPI binary not found at \$BIN" >&2
  echo "Install: go install github.com/router-for-me/CLIProxyAPI/v6/cmd/server@latest" >&2
  exit 1
fi

if [ -f "\$PIDFILE" ] && kill -0 "\$(cat "\$PIDFILE" 2>/dev/null)" 2>/dev/null; then
  echo "watchdog already running (pid \$(cat "\$PIDFILE"))"
else
  rm -f "\$PIDFILE"
  nohup "\$ROOT/scripts/watchdog.sh" >>"\$LOG" 2>&1 &
  echo "watchdog pid \$! log \$LOG"
fi

for i in \$(seq 1 30); do
  if curl -sf -m 1 -H "Authorization: Bearer \${KEY}" "http://127.0.0.1:\${PORT}/v1/models" >/dev/null; then
    echo "listening on http://127.0.0.1:\${PORT}/v1"
    exit 0
  fi
  sleep 0.5
done
echo "failed to become ready; see \$LOG" >&2
exit 1
EOF
  chmod +x "$CLIPROXY_DIR/scripts/start.sh" "$CLIPROXY_DIR/scripts/sync-claude-auth.sh" "$CLIPROXY_DIR/scripts/watchdog.sh"
}

cliproxy_bin_version() {
  local out
  [[ -x "$CLIPROXY_BIN" ]] || return 1
  out="$("$CLIPROXY_BIN" --help 2>&1 | head -1 || true)"
  printf '%s' "$out"
}

cliproxy_bin_is_v7() {
  local out
  out="$(cliproxy_bin_version 2>/dev/null || true)"
  [[ "$out" == *"Version:"* ]] || return 1
  [[ "$out" == *"Version: dev"* ]] && return 1
  if [[ "$out" =~ Version:\ *v?([0-9]+) ]]; then
    [[ "${BASH_REMATCH[1]}" -ge 7 ]]
    return
  fi
  return 1
}

ensure_cliproxy_mgmt_key() {
  mkdir -p "$(dirname "$CLIPROXY_MGMT_KEY_FILE")"
  if [[ -n "${CLIPROXY_MGMT_KEY:-}" ]]; then
    # Keep a previously persisted key if the caller didn't override.
    :
  elif [[ -s "$CLIPROXY_MGMT_KEY_FILE" ]]; then
    CLIPROXY_MGMT_KEY="$(tr -d '[:space:]' <"$CLIPROXY_MGMT_KEY_FILE")"
  else
    CLIPROXY_MGMT_KEY="sand-mgmt-$(python3 -c 'import secrets; print(secrets.token_urlsafe(18))')"
    warn "generated management key → $CLIPROXY_MGMT_KEY_FILE"
  fi
  # Refuse to persist a value that accidentally captured log lines.
  if [[ "$CLIPROXY_MGMT_KEY" == *$'\n'* || "$CLIPROXY_MGMT_KEY" == *'+ '* ]]; then
    CLIPROXY_MGMT_KEY="sand-mgmt-$(python3 -c 'import secrets; print(secrets.token_urlsafe(18))')"
    warn "regenerated management key (previous value was not a key)"
  fi
  printf '%s\n' "$CLIPROXY_MGMT_KEY" >"$CLIPROXY_MGMT_KEY_FILE"
  chmod 600 "$CLIPROXY_MGMT_KEY_FILE" 2>/dev/null || true
  printf '%s' "$CLIPROXY_MGMT_KEY"
}

patch_cliproxy_management_config() {
  local cfg="$CLIPROXY_DIR/config.yaml" key
  [[ -f "$cfg" ]] || return 0
  key="$(ensure_cliproxy_mgmt_key)"
  CLIPROXY_MGMT_KEY="$key" CLIPROXY_PANEL_REPO="$CLIPROXY_PANEL_REPO" python3 - "$cfg" <<'PY'
import os, pathlib, re, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text()
key = os.environ["CLIPROXY_MGMT_KEY"]
repo = os.environ.get("CLIPROXY_PANEL_REPO", "https://github.com/router-for-me/Cli-Proxy-API-Management-Center")
# cliproxy hashes a plaintext secret-key on first start. Keep an existing bcrypt hash.
existing = ""
m = re.search(r'^[ \t]*secret-key:[ \t]*["\']?([^"\'\n]+)', text, re.M)
if m:
    existing = m.group(1).strip()
yaml_key = existing if existing.startswith(("$2a$", "$2b$", "$2y$")) else key
block = (
    "remote-management:\n"
    "  allow-remote: false\n"
    f'  secret-key: "{yaml_key}"\n'
    "  disable-control-panel: false\n"
    f'  panel-github-repository: "{repo}"\n'
)
# Replace a possibly-broken remote-management mapping (multiline secret-key etc.)
new, n = re.subn(
    r"^remote-management:\n(?:[ \t]+.*\n)*",
    block,
    text,
    count=1,
    flags=re.M,
)
if n == 0:
    new = text.rstrip() + "\n" + block
    n = 1
if re.search(r"^logging-to-file:", new, re.M):
    new2, n2 = re.subn(r"^(logging-to-file:[ \t]*).*$", r"\1true", new, count=1, flags=re.M)
    if n2:
        new = new2
if new != text:
    path.write_text(new)
    print("patched", path)
else:
    print("management config already set")
PY
}

# Ensure Meta + DeepSeek openai-compat entries exist (model aliases filled).
# Keys come from MODEL_API_KEY / META_API_KEY / DEEPSEEK_API_KEY when the
# current value is empty or a CHANGE_ME placeholder.
ensure_cliproxy_compat_providers() {
  local cfg="$CLIPROXY_DIR/config.yaml"
  local tmpl="$ROOT/examples/cliproxy-openai-compat.yaml"
  [[ -f "$cfg" ]] || return 0
  [[ -f "$tmpl" ]] || return 0
  python3 - "$cfg" "$tmpl" <<'PY'
import os, re, sys
from pathlib import Path

cfg_path, tmpl_path = Path(sys.argv[1]), Path(sys.argv[2])
text = cfg_path.read_text()
tmpl = tmpl_path.read_text()
changed = False

def extract_provider(src, name):
    # From "  - name: NAME" through the next "  - name:" or EOF inside openai-compatibility
    pat = re.compile(
        r"(^[ \t]*- name: %s\n(?:^[ \t]+.*\n)*)" % re.escape(name),
        re.M,
    )
    m = pat.search(src)
    return m.group(1) if m else ""

def upsert_alias_block(block, model_id):
    if re.search(r"name: %s\b" % re.escape(model_id), block):
        # force non-empty alias
        block2, n = re.subn(
            r"(- name: %s\n[ \t]*alias: )(\"\"|''|\s*)$" % re.escape(model_id),
            r'\1%s' % model_id,
            block,
            flags=re.M,
        )
        return block2, n > 0
    add = (
        f"      - name: {model_id}\n"
        f"        alias: {model_id}\n"
    )
    if re.search(r"^    models:\s*$", block, re.M):
        return re.sub(r"^(    models:\s*\n)", r"\1" + add, block, count=1, flags=re.M), True
    if not block.endswith("\n"):
        block += "\n"
    return block + add, True

def apply_key(block, env_names, placeholder_substr):
    key = ""
    for n in env_names:
        v = os.environ.get(n) or ""
        if v and not v.upper().startswith("CHANGE_ME"):
            key = v
            break
    if not key:
        return block, False
    m = re.search(r"^([ \t]*- api-key: )(.+)$", block, re.M)
    if not m:
        return block, False
    current = m.group(2).strip().strip('"').strip("'")
    if current and "CHANGE_ME" not in current.upper() and placeholder_substr not in current:
        return block, False
    return re.sub(r"^([ \t]*- api-key: ).+$", r"\1" + key, block, count=1, flags=re.M), True

# Pull provider templates from the example file.
meta_t = extract_provider(tmpl, "Meta Model API")
ds_t = extract_provider(tmpl, "Deepseek")

if "openai-compatibility:" not in text:
    extra = "\nopenai-compatibility:\n"
    if meta_t:
        extra += meta_t
    if ds_t:
        extra += ds_t
    text = text.rstrip() + extra
    changed = True

for name, tmpl_block, env_names, placeholder, models in (
    ("Meta Model API", meta_t, ("MODEL_API_KEY", "META_API_KEY"), "CHANGE_ME_META",
     ("muse-spark-1.1", "muse-spark-1.2", "muse-spark-1.2-contributor")),
    ("Deepseek", ds_t, ("DEEPSEEK_API_KEY",), "CHANGE_ME_DEEPSEEK",
     ("deepseek-v4-flash", "deepseek-v4-pro")),
):
    block = extract_provider(text, name)
    if not block:
        if tmpl_block:
            if not text.endswith("\n"):
                text += "\n"
            text += tmpl_block
            block = tmpl_block
            changed = True
        else:
            continue
    new_block = block
    for mid in models:
        new_block, did = upsert_alias_block(new_block, mid)
        changed = changed or did
    new_block, did = apply_key(new_block, env_names, placeholder)
    changed = changed or did
    if new_block != block:
        text = text.replace(block, new_block, 1)
        changed = True

if changed:
    cfg_path.write_text(text)
    print("updated openai-compatibility providers")
else:
    print("openai-compatibility providers already set")
PY
}

install_cliproxy_release() {
  # Official v7+ Linux build. go install of v7 needs Go 1.26; this image is older.
  need_cmd curl
  need_cmd tar
  local arch tag url tmp extract bin
  case "$(uname -m)" in
    x86_64|amd64) arch="linux_amd64" ;;
    aarch64|arm64) arch="linux_aarch64" ;;
    *) die "unsupported arch $(uname -m) for CLIProxyAPI release" ;;
  esac
  tag="$(
    curl -fsSIL https://github.com/router-for-me/CLIProxyAPI/releases/latest \
      | tr -d '\r' \
      | awk -F/ 'tolower($1)=="location:" {print $NF; exit}'
  )"
  tag="${tag:-v7.2.131}"
  tag="${tag#v}"
  url="https://github.com/router-for-me/CLIProxyAPI/releases/download/v${tag}/CLIProxyAPI_${tag}_${arch}.tar.gz"
  log "download $url"
  tmp="$(mktemp -d)"
  curl -fL --retry 3 -o "$tmp/cliproxy.tgz" "$url"
  mkdir -p "$tmp/extract"
  tar -xzf "$tmp/cliproxy.tgz" -C "$tmp/extract"
  bin="$(
    find "$tmp/extract" -type f \( -name 'CLIProxyAPI' -o -name 'cli-proxy-api' -o -name 'server' \) \
      | head -1
  )"
  [[ -n "$bin" ]] || die "release tarball had no CLIProxyAPI binary"
  mkdir -p "$(dirname "$CLIPROXY_BIN")"
  if [[ -f "$CLIPROXY_BIN" ]]; then
    cp -f "$CLIPROXY_BIN" "${CLIPROXY_BIN}.bak" 2>/dev/null || true
  fi
  cp -f "$bin" "$CLIPROXY_BIN"
  chmod +x "$CLIPROXY_BIN"
  rm -rf "$tmp"
  log "installed $CLIPROXY_BIN ($(cliproxy_bin_version || echo v${tag}))"
}

install_cliproxy() {
  log "install CLIProxyAPI (v7+ for Management Center)"
  if cliproxy_bin_is_v7; then
    log "binary already v7+: $CLIPROXY_BIN ($(cliproxy_bin_version))"
  else
    if ! install_cliproxy_release; then
      warn "release download failed; trying go install v7"
      need_cmd go
      log "go install github.com/router-for-me/CLIProxyAPI/v7/cmd/server@latest"
      GOBIN="$(dirname "$CLIPROXY_BIN")" go install github.com/router-for-me/CLIProxyAPI/v7/cmd/server@latest
      chmod +x "$CLIPROXY_BIN" 2>/dev/null || true
    fi
    ensure_cliproxy_bin || die "CLIProxyAPI install did not produce an executable at $CLIPROXY_BIN"
  fi
  write_cliproxy_tree
  log "CLIProxyAPI install OK ($CLIPROXY_DIR)"
  log "Management Center: http://127.0.0.1:${CLIPROXY_PORT}/management.html"
  log "management key: $CLIPROXY_MGMT_KEY_FILE"
  if [[ ! -f "$HOME/.claude/.credentials.json" ]]; then
    warn "no Claude OAuth yet — run: claude login  (then: adapters.sh start cliproxy)"
  fi
}

write_litellm_tree() {
  mkdir -p "$LITELLM_DIR/scripts" "$LITELLM_DIR/logs"
  if [[ ! -f "$LITELLM_DIR/.env" ]]; then
    cat >"$LITELLM_DIR/.env" <<EOF
LITELLM_MASTER_KEY=${LITELLM_KEY_DEFAULT}

# Grok auth: leave GROK_SESSION_TOKEN empty to auto-load from ~/.grok/auth.json
# (created by \`grok login\`). Or set it explicitly:
# GROK_SESSION_TOKEN=
# GROK_AUTH_FILE=\$HOME/.grok/auth.json

# Optional other backends
ANTHROPIC_API_KEY=sk-ant-PLACEHOLDER
GEMINI_API_KEY=PLACEHOLDER
EOF
    log "wrote $LITELLM_DIR/.env (edit API keys as needed)"
  fi
  if [[ ! -f "$LITELLM_DIR/config.yaml" ]]; then
    cat >"$LITELLM_DIR/config.yaml" <<'EOF'
model_list:
  # Grok CLI session auth → cli-chat-proxy (primary)
  # Token loaded from ~/.grok/auth.json by scripts/start.sh
  - model_name: grok
    litellm_params:
      model: openai/grok-4.5
      api_base: https://cli-chat-proxy.grok.com/v1
      api_key: os.environ/GROK_SESSION_TOKEN
      extra_headers:
        X-XAI-Token-Auth: xai-grok-cli
        x-grok-client-version: "1.0.0"
        x-grok-model-override: grok-4.5
        User-Agent: grok-cli/1.0.0

  - model_name: grok-4.5
    litellm_params:
      model: openai/grok-4.5
      api_base: https://cli-chat-proxy.grok.com/v1
      api_key: os.environ/GROK_SESSION_TOKEN
      extra_headers:
        X-XAI-Token-Auth: xai-grok-cli
        x-grok-client-version: "1.0.0"
        x-grok-model-override: grok-4.5
        User-Agent: grok-cli/1.0.0

  # Anthropic Console API keys only (sk-ant-api…), NOT Claude Pro/Max OAuth.
  - model_name: claude-opus-5
    litellm_params:
      model: anthropic/claude-opus-5
      api_key: os.environ/ANTHROPIC_API_KEY

  - model_name: claude-sonnet
    litellm_params:
      model: anthropic/claude-sonnet-5
      api_key: os.environ/ANTHROPIC_API_KEY

  - model_name: claude-sonnet-4-5
    litellm_params:
      model: anthropic/claude-sonnet-4-5
      api_key: os.environ/ANTHROPIC_API_KEY

  - model_name: claude-sonnet-5
    litellm_params:
      model: anthropic/claude-sonnet-5
      api_key: os.environ/ANTHROPIC_API_KEY

  - model_name: claude-haiku-4-5
    litellm_params:
      model: anthropic/claude-haiku-4-5
      api_key: os.environ/ANTHROPIC_API_KEY

  - model_name: gemini-flash
    litellm_params:
      model: gemini/gemini-2.5-flash
      api_key: os.environ/GEMINI_API_KEY

litellm_settings:
  drop_params: true
  num_retries: 2
  request_timeout: 120

general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
EOF
    log "wrote $LITELLM_DIR/config.yaml"
  fi
  cat >"$LITELLM_DIR/scripts/start.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ ! -f .env ]]; then
  echo "Missing .env — run: adapters.sh install litellm" >&2
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
  export GROK_SESSION_TOKEN="missing-grok-session-token"
fi

if command -v litellm >/dev/null 2>&1; then
  LITELLM_BIN=(litellm)
elif command -v uvx >/dev/null 2>&1; then
  LITELLM_BIN=(uvx --from 'litellm[proxy]' litellm)
elif [[ -x "$ROOT/.venv/bin/litellm" ]]; then
  LITELLM_BIN=("$ROOT/.venv/bin/litellm")
else
  echo "litellm not found. Install with: adapters.sh install litellm" >&2
  exit 1
fi

echo "Using Grok session auth from ${GROK_AUTH_FILE}"
echo "Starting LiteLLM proxy on http://127.0.0.1:4000 ..."
exec "${LITELLM_BIN[@]}" --config "$ROOT/config.yaml" --host 127.0.0.1 --port 4000
EOF
  chmod +x "$LITELLM_DIR/scripts/start.sh"
  : >"$LITELLM_DIR/logs/.gitkeep" 2>/dev/null || true
}

install_litellm() {
  log "install LiteLLM bridge"
  need_cmd uv
  if ! command -v litellm >/dev/null 2>&1; then
    log "uv tool install 'litellm[proxy]'"
    uv tool install 'litellm[proxy]'
  else
    log "litellm already on PATH: $(command -v litellm)"
  fi
  write_litellm_tree
  log "LiteLLM install OK ($LITELLM_DIR) — edit .env for Anthropic/Gemini keys"
}

install_openai_oauth() {
  log "install openai-oauth (npx package; no global install required)"
  need_cmd npx
  # Warm the npx cache so first start is faster
  log "warming npx openai-oauth@latest --help"
  npx --yes openai-oauth@latest --help >/dev/null 2>&1 || true
  log "openai-oauth install OK"
  if [[ ! -f "$HOME/.codex/auth.json" ]]; then
    warn "no Codex OAuth yet — run one of:"
    warn "  codex login"
    warn "  codex login --device-auth"
    warn "  npx openai-oauth@latest login"
  fi
}

# ── login agents (claude / grok / codex CLIs) ───────────────────────────────
has_cmd() { command -v "$1" >/dev/null 2>&1; }

# grok may live only under ~/.grok/bin
resolve_grok_bin() {
  if has_cmd grok; then command -v grok; return; fi
  if [[ -x "$HOME/.grok/bin/grok" ]]; then printf '%s' "$HOME/.grok/bin/grok"; return; fi
  return 1
}

login_agent_status_line() {
  # name | bin_ok | auth_ok | detail
  local name="$1"
  case "$name" in
    claude)
      if has_cmd claude; then
        if [[ -f "$HOME/.claude/.credentials.json" ]]; then
          echo "OK|claude CLI + credentials"
        else
          echo "BIN|claude CLI installed, not logged in (claude login)"
        fi
      else
        echo "MISS|claude CLI not installed"
      fi
      ;;
    grok)
      if resolve_grok_bin >/dev/null; then
        if [[ -f "$HOME/.grok/auth.json" ]]; then
          echo "OK|grok CLI + session auth"
        else
          echo "BIN|grok CLI installed, not logged in (grok login)"
        fi
      else
        echo "MISS|grok CLI not installed"
      fi
      ;;
    codex)
      if has_cmd codex; then
        if [[ -f "$HOME/.codex/auth.json" ]]; then
          echo "OK|codex CLI + auth.json"
        else
          echo "BIN|codex CLI installed, not logged in (codex login)"
        fi
      else
        echo "MISS|codex CLI not installed"
      fi
      ;;
    cliproxy)
      if ensure_cliproxy_bin; then
        echo "OK|CLIProxy binary $CLIPROXY_BIN"
      else
        echo "MISS|CLIProxy binary missing"
      fi
      ;;
    litellm)
      if has_cmd litellm || has_cmd uvx || has_cmd uv; then
        if has_cmd litellm; then
          echo "OK|litellm on PATH"
        else
          echo "BIN|uv/uvx present (litellm via uvx fallback)"
        fi
      else
        echo "MISS|litellm/uv not available"
      fi
      ;;
    npx)
      if has_cmd npx; then echo "OK|npx available"; else echo "MISS|npx/node missing"; fi
      ;;
    go)
      if has_cmd go; then echo "OK|go available"; else echo "MISS|go missing (needed for CLIProxy install)"; fi
      ;;
  esac
}

install_claude_cli() {
  log "install Claude Code CLI"
  if has_cmd claude; then
    log "already installed: $(command -v claude)"
    return 0
  fi
  # Official installer (same family as Anthropic's published install path)
  if has_cmd curl; then
    log "curl -fsSL https://claude.ai/install.sh | bash"
    curl -fsSL https://claude.ai/install.sh | bash
  elif has_cmd npm; then
    log "npm install -g @anthropic-ai/claude-code"
    npm install -g @anthropic-ai/claude-code
  else
    die "need curl or npm to install Claude Code"
  fi
  hash -r 2>/dev/null || true
  # common install locations
  export PATH="$HOME/.local/bin:$PATH"
  if has_cmd claude; then
    log "claude installed: $(command -v claude)"
  else
    warn "claude may not be on PATH yet — open a new shell or: export PATH=\"\$HOME/.local/bin:\$PATH\""
  fi
}

install_grok_cli() {
  log "install Grok CLI"
  if resolve_grok_bin >/dev/null; then
    log "already installed: $(resolve_grok_bin)"
    return 0
  fi
  need_cmd curl
  log "curl -fsSL https://x.ai/cli/install.sh | bash"
  curl -fsSL https://x.ai/cli/install.sh | bash
  export PATH="$HOME/.grok/bin:$HOME/.local/bin:$PATH"
  hash -r 2>/dev/null || true
  if resolve_grok_bin >/dev/null; then
    log "grok installed: $(resolve_grok_bin)"
  else
    warn "grok install finished but binary not found — check https://x.ai/cli"
  fi
}

install_herdr() {
  log "install herdr (agent runtime — herdr.dev)"
  if has_cmd herdr; then
    log "already installed: $(command -v herdr)"
    return 0
  fi
  need_cmd curl
  log "curl -fsSL https://herdr.dev/install.sh | sh"
  curl -fsSL https://herdr.dev/install.sh | sh
  export PATH="$HOME/.local/bin:$PATH"
  hash -r 2>/dev/null || true
  if has_cmd herdr; then
    log "herdr installed: $(command -v herdr)"
  else
    warn "herdr install finished but binary not found — check https://herdr.dev"
  fi
}

install_ghostty() {
  local version="${GHOSTTY_VERSION:-1.3.1}"
  log "install ghostty $version (terminal emulator — ghostty.org)"
  if has_cmd ghostty; then
    log "already installed: $(command -v ghostty)"
    return 0
  fi
  need_cmd curl
  need_cmd apt-get
  local arch codename asset url deb
  case "$(uname -m)" in
    x86_64|amd64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) die "unsupported architecture for ghostty: $(uname -m)" ;;
  esac
  # Map distro → release asset suffix (mkasberg/ghostty-ubuntu publishes per-codename debs)
  codename="trixie"
  if [[ -r /etc/os-release ]]; then
    local id vid
    id="$(. /etc/os-release; printf '%s' "$ID")"
    vid="$(. /etc/os-release; printf '%s' "$VERSION_CODENAME")"
    if [[ "$id" == "ubuntu" ]]; then
      codename="$(. /etc/os-release; printf '%s' "$VERSION_ID")"   # 24.04 / 25.10 / 26.04
    elif [[ -n "$vid" ]]; then
      codename="$vid"                                                 # trixie / bookworm
    fi
  fi
  asset="ghostty_${version}-0.ppa2_${arch}_${codename}.deb"
  url="https://github.com/mkasberg/ghostty-ubuntu/releases/download/${version}-0-ppa2/${asset}"
  deb="$(mktemp --suffix=.deb)"
  log "curl -fsSL -o $deb $url"
  if ! curl -fsSL -o "$deb" "$url"; then
    rm -f "$deb"
    die "ghostty download failed: $url (no build for $codename? set GHOSTTY_VERSION or use trixie/24.04)"
  fi
  log "sudo apt-get install -y $deb"
  if ! sudo apt-get install -y "$deb"; then
    rm -f "$deb"
    die "ghostty install failed"
  fi
  rm -f "$deb"
  hash -r 2>/dev/null || true
  if has_cmd ghostty; then
    log "ghostty installed: $(command -v ghostty)"
  else
    warn "ghostty install finished but binary not found"
  fi
}

install_codex_cli() {
  log "install Codex CLI"
  if has_cmd codex; then
    log "already installed: $(command -v codex)"
    return 0
  fi
  if has_cmd npm; then
    log "npm install -g @openai/codex"
    npm install -g @openai/codex
  elif has_cmd npx; then
    # fallback: use openai-oauth path + instruct user
    warn "npm not found; warming openai-oauth instead (codex CLI optional for ChatGPT path)"
    install_openai_oauth
    return 0
  else
    die "need npm to install codex CLI"
  fi
  export PATH="$HOME/.local/bin:$PATH"
  hash -r 2>/dev/null || true
  if has_cmd codex; then
    log "codex installed: $(command -v codex)"
  else
    warn "codex may not be on PATH yet"
  fi
}

offer_login_if_bin_present() {
  # $1 = agent name
  local name="$1" ans
  case "$name" in
    claude)
      if has_cmd claude && [[ ! -f "$HOME/.claude/.credentials.json" ]]; then
        ans="$(prompt_line "claude is installed but not logged in. Run 'claude login' guidance now?" "Y")"
        case "${ans,,}" in
          y|yes|"")
            tty_echo "Run in a terminal with a browser (or device flow):"
            tty_echo "  claude login"
            tty_echo "Then re-open this menu / start cliproxy."
            ;;
        esac
      fi
      ;;
    grok)
      if resolve_grok_bin >/dev/null && [[ ! -f "$HOME/.grok/auth.json" ]]; then
        ans="$(prompt_line "grok is installed but not logged in. Show login command?" "Y")"
        case "${ans,,}" in
          y|yes|"")
            tty_echo "  grok login"
            tty_echo "  # headless: grok login --device-auth"
            ;;
        esac
      fi
      ;;
    codex)
      if has_cmd codex && [[ ! -f "$HOME/.codex/auth.json" ]]; then
        ans="$(prompt_line "codex is installed but not logged in. Show login command?" "Y")"
        case "${ans,,}" in
          y|yes|"")
            tty_echo "  codex login"
            tty_echo "  # headless: codex login --device-auth"
            tty_echo "  # or: npx openai-oauth@latest login"
            ;;
        esac
      fi
      ;;
  esac
}

# Interactive: list missing login/tool deps and offer install for each.
ensure_login_agents_interactive() {
  init_tty
  local agents=(claude grok codex cliproxy litellm npx go)
  local missing=()
  local need_login=()
  local name st detail

  {
    echo
    echo "── Login agents & tools ──"
  } >"$_TTY_OUT"

  for name in "${agents[@]}"; do
    st="$(login_agent_status_line "$name")"
    detail="${st#*|}"
    st="${st%%|*}"
    case "$st" in
      OK)   printf '  ✓ %-10s %s\n' "$name" "$detail" >"$_TTY_OUT" ;;
      BIN)
        printf '  ~ %-10s %s\n' "$name" "$detail" >"$_TTY_OUT"
        need_login+=("$name")
        ;;
      MISS)
        printf '  ✗ %-10s %s\n' "$name" "$detail" >"$_TTY_OUT"
        missing+=("$name")
        ;;
    esac
  done

  if [[ ${#missing[@]} -eq 0 && ${#need_login[@]} -eq 0 ]]; then
    log "all login agents / tools look good"
    return 0
  fi

  local ans item
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo >"$_TTY_OUT"
    tty_echo "Missing installs: ${missing[*]}"
    ans="$(prompt_line "Install missing tools now?" "Y")"
    case "${ans,,}" in
      y|yes|"")
        for item in "${missing[@]}"; do
          ans="$(prompt_line "Install $item?" "Y")"
          case "${ans,,}" in
            y|yes|"")
              case "$item" in
                claude) install_claude_cli || warn "claude install failed" ;;
                grok) install_grok_cli || warn "grok install failed" ;;
                codex) install_codex_cli || warn "codex install failed" ;;
                cliproxy) install_cliproxy || warn "cliproxy install failed" ;;
                litellm) install_litellm || warn "litellm install failed" ;;
                openai-oauth) install_openai_oauth || warn "openai-oauth install failed" ;;
                npx|go)
                  warn "cannot auto-install system package '$item' — install node/npm or go via your package manager"
                  ;;
                *) warn "no installer for $item" ;;
              esac
              ;;
            *) log "skipped $item" ;;
          esac
        done
        ;;
      *) log "skipped auto-install of missing tools" ;;
    esac
  fi

  # After install, re-check login-needed agents
  for item in claude grok codex; do
    offer_login_if_bin_present "$item"
  done
  # also for any that were already BIN
  for item in "${need_login[@]:-}"; do
    offer_login_if_bin_present "$item"
  done
}

cmd_check_login_agents() {
  # non-interactive status only
  local agents=(claude grok codex cliproxy litellm npx go)
  local name st detail
  printf '%-12s %-6s %s\n' "agent" "state" "detail"
  printf '%-12s %-6s %s\n' "-----" "-----" "------"
  for name in "${agents[@]}"; do
    st="$(login_agent_status_line "$name")"
    detail="${st#*|}"
    st="${st%%|*}"
    printf '%-12s %-6s %s\n' "$name" "$st" "$detail"
  done
}

cmd_install() {
  local target="${1:-all}"
  case "$target" in
    all)
      install_cliproxy
      install_litellm
      install_openai_oauth
      ;;
    cliproxy|cliproxy-api) install_cliproxy ;;
    litellm|bridge|grok-model-bridge) install_litellm ;;
    openai-oauth|chatgpt) install_openai_oauth ;;
    # login CLIs
    claude|claude-cli) install_claude_cli ;;
    grok|grok-cli) install_grok_cli ;;
    codex|codex-cli) install_codex_cli ;;
    herdr|herdr-cli) install_herdr ;;
    ghostty|ghostty-term) install_ghostty ;;
    login-agents|logins)
      # install any missing login CLIs without prompting
      has_cmd claude || install_claude_cli
      resolve_grok_bin >/dev/null || install_grok_cli
      has_cmd codex || install_codex_cli
      ;;
    *) die "unknown install target: $target (all|cliproxy|litellm|openai-oauth|claude|grok|codex|herdr|ghostty|login-agents)" ;;
  esac
  echo
  log "done. Next: adapters.sh start …  or  adapters.sh use <profile>"
}

# ── start / stop ────────────────────────────────────────────────────────────
cliproxy_watchdog_alive() {
  local pidfile="$CLIPROXY_DIR/scripts/watchdog.pid" pid
  [[ -f "$pidfile" ]] || return 1
  pid="$(cat "$pidfile" 2>/dev/null || true)"
  [[ -n "$pid" && "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null
}

start_cliproxy() {
  log "start CLIProxyAPI on :$CLIPROXY_PORT"
  ensure_cliproxy_bin || die "CLIProxyAPI binary missing — run: adapters.sh install cliproxy"
  write_cliproxy_tree
  # Ensure the watchdog runs; it supervises the server and keeps the Claude
  # OAuth token synced bidirectionally while the proxy is up.
  if cliproxy_watchdog_alive; then
    log "watchdog already running"
  else
    rm -f "$CLIPROXY_DIR/scripts/watchdog.pid"
    nohup "$CLIPROXY_DIR/scripts/watchdog.sh" >>/tmp/cliproxy.log 2>&1 &
    log "watchdog started (pid $!)"
  fi
  if wait_http "http://127.0.0.1:${CLIPROXY_PORT}/v1/models" "$CLIPROXY_KEY" 30; then
    log "CLIProxyAPI ready http://127.0.0.1:${CLIPROXY_PORT}/v1"
  else
    warn "CLIProxyAPI did not become ready — see /tmp/cliproxy.log"
    tail -20 /tmp/cliproxy.log 2>/dev/null || true
    return 1
  fi
}

start_litellm() {
  log "start LiteLLM on :$LITELLM_PORT"
  if port_listening "$LITELLM_PORT"; then
    log "already listening on $LITELLM_PORT"
    return 0
  fi
  write_litellm_tree
  # start.sh is exec; run detached
  mkdir -p "$LITELLM_DIR/logs"
  : >"$LITELLM_DIR/logs/bridge.log"
  nohup "$LITELLM_DIR/scripts/start.sh" >>"$LITELLM_DIR/logs/bridge.log" 2>&1 &
  local master="$LITELLM_KEY_DEFAULT"
  if [[ -f "$LITELLM_DIR/.env" ]]; then
    master="$(grep -E '^LITELLM_MASTER_KEY=' "$LITELLM_DIR/.env" | head -1 | cut -d= -f2- || true)"
    master="${master:-$LITELLM_KEY_DEFAULT}"
  fi
  if wait_http "http://127.0.0.1:${LITELLM_PORT}/v1/models" "$master" 30; then
    log "LiteLLM ready http://127.0.0.1:${LITELLM_PORT}/v1"
  else
    warn "LiteLLM did not become ready — see $LITELLM_DIR/logs/bridge.log"
    tail -20 "$LITELLM_DIR/logs/bridge.log" 2>/dev/null || true
    return 1
  fi
}

start_openai_oauth() {
  log "start openai-oauth on :$OPENAI_OAUTH_PORT"
  if port_listening "$OPENAI_OAUTH_PORT"; then
    log "already listening on $OPENAI_OAUTH_PORT"
    return 0
  fi
  need_cmd npx
  if [[ ! -f "$HOME/.codex/auth.json" ]]; then
    die "no ~/.codex/auth.json — run: codex login  (or npx openai-oauth@latest login)"
  fi
  npx --yes openai-oauth@latest --detach --host 127.0.0.1 --port "$OPENAI_OAUTH_PORT"
  if wait_http "http://127.0.0.1:${OPENAI_OAUTH_PORT}/v1/models" "openai-oauth" 30; then
    log "openai-oauth ready http://127.0.0.1:${OPENAI_OAUTH_PORT}/v1"
  else
    die "openai-oauth failed to become ready"
  fi
}

cmd_start() {
  local target="${1:-all}"
  case "$target" in
    all)
      start_cliproxy || warn "cliproxy start failed"
      start_litellm || warn "litellm start failed"
      start_openai_oauth || warn "openai-oauth start failed"
      ;;
    cliproxy|cliproxy-api|claude) start_cliproxy ;;
    litellm|bridge) start_litellm ;;
    openai-oauth|codex|chatgpt) start_openai_oauth ;;
    *) die "unknown start target: $target" ;;
  esac
}

stop_port_procs() {
  local port="$1" label="$2"
  local pids pid cmd pidfile wpid spid
  case "$label" in
    cliproxy)
      # Kill the watchdog first so it does not respawn the server.
      pidfile="$CLIPROXY_DIR/scripts/watchdog.pid"
      if [[ -f "$pidfile" ]]; then
        wpid="$(cat "$pidfile" 2>/dev/null || true)"
        if [[ -n "$wpid" && "$wpid" =~ ^[0-9]+$ ]]; then
          kill "$wpid" 2>/dev/null || true
        fi
        rm -f "$pidfile"
      fi
      mapfile -t pids < <(pids_matching "$CLIPROXY_DIR/scripts/watchdog.sh")
      kill_pids "${pids[@]:-}"
      pidfile="$CLIPROXY_DIR/scripts/server.pid"
      if [[ -f "$pidfile" ]]; then
        spid="$(cat "$pidfile" 2>/dev/null || true)"
        if [[ -n "$spid" && "$spid" =~ ^[0-9]+$ ]]; then
          kill "$spid" 2>/dev/null || true
        fi
        rm -f "$pidfile"
      fi
      ;;
  esac
  # Prefer fuser when available
  if command -v fuser >/dev/null 2>&1; then
    fuser -k "${port}/tcp" 2>/dev/null || true
  fi
  # Also kill known process patterns
  case "$label" in
    cliproxy)
      mapfile -t pids < <(pids_matching "$CLIPROXY_DIR/config.yaml")
      kill_pids "${pids[@]:-}"
      mapfile -t pids < <(pids_matching "go/bin/server")
      # only kill if cmdline has cliproxy config
      for pid in "${pids[@]:-}"; do
        [[ -r "/proc/$pid/cmdline" ]] || continue
        cmd=$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null || true)
        if [[ "$cmd" == *cliproxy* || "$cmd" == *CLIProxy* || "$cmd" == *"$CLIPROXY_DIR"* ]]; then
          kill "$pid" 2>/dev/null || true
        fi
      done
      ;;
    litellm)
      mapfile -t pids < <(pids_matching "litellm --config")
      kill_pids "${pids[@]:-}"
      mapfile -t pids < <(pids_matching "grok-model-bridge/config.yaml")
      kill_pids "${pids[@]:-}"
      ;;
    openai-oauth)
      mapfile -t pids < <(pids_matching "openai-oauth")
      kill_pids "${pids[@]:-}"
      npx --yes openai-oauth@latest stop 2>/dev/null || true
      ;;
  esac
  sleep 0.4
  if port_listening "$port"; then
    warn "$label still listening on $port"
  else
    log "$label stopped (port $port free)"
  fi
}

cmd_stop() {
  local target="${1:-all}"
  case "$target" in
    all)
      stop_port_procs "$CLIPROXY_PORT" cliproxy
      stop_port_procs "$LITELLM_PORT" litellm
      stop_port_procs "$OPENAI_OAUTH_PORT" openai-oauth
      ;;
    cliproxy|cliproxy-api|claude) stop_port_procs "$CLIPROXY_PORT" cliproxy ;;
    litellm|bridge) stop_port_procs "$LITELLM_PORT" litellm ;;
    openai-oauth|codex|chatgpt) stop_port_procs "$OPENAI_OAUTH_PORT" openai-oauth ;;
    *) die "unknown stop target: $target" ;;
  esac
}

# ── write env + settings ────────────────────────────────────────────────────
write_env_file() {
  # args as KEY=VAL pairs via env vars set by caller into associative-like exports
  local provider="${WRITE_PROVIDER:-xai}"
  local base="${WRITE_BASE_URL:-}"
  local model="${WRITE_MODEL:-}"
  local key="${WRITE_API_KEY:-}"
  local thinking="${WRITE_THINKING:-disabled}"
  # Prefer explicit WRITE_*; fall back to flags from parse_use_flags
  local effort="${WRITE_REASONING_EFFORT:-${OPT_REASONING_EFFORT:-}}"
  local identity="${WRITE_IDENTITY:-1}"
  local comment="${WRITE_COMMENT:-Grok Bot custom inference}"

  # If an effort is set, thinking must be on for the host to send reasoning_effort
  if [[ -n "$effort" && "$thinking" != "enabled" && "$thinking" != "true" && "$thinking" != "1" ]]; then
    thinking="enabled"
  fi

  mkdir -p "$(dirname "$ENV_FILE")"
  umask 077
  {
    echo "# ${comment}"
    echo "# Generated by adapters.sh $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "SAND_INFERENCE_PROVIDER=${provider}"
    if [[ -n "$key" ]]; then
      echo "XAI_API_KEY=${key}"
    fi
    if [[ -n "$base" ]]; then
      echo "SAND_XAI_BASE_URL=${base}"
    fi
    if [[ -n "$model" ]]; then
      echo "SAND_XAI_MODEL=${model}"
    fi
    echo "SAND_XAI_THINKING=${thinking}"
    if [[ -n "$effort" ]]; then
      echo "SAND_XAI_REASONING_EFFORT=${effort}"
    fi
    echo "SAND_XAI_IDENTITY=${identity}"
  } >"$ENV_FILE"
  chmod 600 "$ENV_FILE" 2>/dev/null || true
  log "wrote $ENV_FILE"
  sed -E 's/((KEY|TOKEN|SECRET|PASSWORD)=).*/\1***/' "$ENV_FILE" | sed 's/^/  /'
}

patch_settings_model() {
  local model="$1"
  local effort="${2:-}"
  [[ -f "$SETTINGS_FILE" ]] || return 0
  python3 - "$SETTINGS_FILE" "$model" "$effort" <<'PY'
import json, sys
path, model, effort = sys.argv[1], sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else ""
with open(path) as f:
    data = json.load(f)
adm = data.get("agentDefaultModel") or {}
if model:
    adm["modelId"] = model
if "maxMode" not in adm:
    adm["maxMode"] = True
params = list(adm.get("parameters") or [])
if effort:
    params = [p for p in params if not (isinstance(p, dict) and p.get("id") in ("effort", "reasoning_effort"))]
    params.append({"id": "effort", "value": effort})
adm["parameters"] = params
data["agentDefaultModel"] = adm
with open(path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
msg = f"updated agentDefaultModel.modelId -> {model or adm.get('modelId')}"
if effort:
    msg += f" effort={effort}"
print(msg)
PY
}

# Upsert keys in existing xai-inference.env without wiping the rest
upsert_env_keys() {
  # usage: upsert_env_keys KEY=val KEY=val ...
  python3 - "$ENV_FILE" "$@" <<'PY'
import sys
from pathlib import Path
path = Path(sys.argv[1])
updates = {}
for pair in sys.argv[2:]:
    if "=" not in pair:
        continue
    k, _, v = pair.partition("=")
    updates[k] = v
lines = path.read_text().splitlines() if path.is_file() else []
out = []
seen = set()
for line in lines:
    raw = line.strip()
    if not raw or raw.startswith("#") or "=" not in raw:
        out.append(line)
        continue
    k, _, _ = raw.partition("=")
    k = k.replace("export ", "").strip()
    if k in updates:
        out.append(f"{k}={updates[k]}")
        seen.add(k)
    else:
        out.append(line)
for k, v in updates.items():
    if k not in seen:
        out.append(f"{k}={v}")
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text("\n".join(out) + "\n")
print(f"updated {path}")
PY
  chmod 600 "$ENV_FILE" 2>/dev/null || true
}

prompt_reasoning_effort() {
  # prints effort or empty for disabled thinking
  init_tty
  local current=""
  if [[ -f "$ENV_FILE" ]]; then
    current="$(grep -E '^SAND_XAI_REASONING_EFFORT=' "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- || true)"
  fi
  {
    echo
    echo "Reasoning effort (Grok / thinking models):"
    echo "  1) high     — best quality, solo hard tasks (default for Grok 4.6)"
    echo "  2) medium   — safer for multi-agent / group chats  [recommended for groups]"
    echo "  3) low      — faster, less thinking"
    echo "  4) xhigh    — max effort (Grok 4.6+)"
    echo "  5) off      — disable thinking (SAND_XAI_THINKING=disabled)"
    if [[ -n "$current" ]]; then
      echo "  6) keep current ($current)"
    fi
  } >"$_TTY_OUT"
  local choice
  choice="$(prompt_line "Choose" "${current:-1}")"
  # allow typing the level directly
  case "$(printf '%s' "$choice" | tr '[:upper:]' '[:lower:]')" in
    1|high|"") printf '%s' "high" ;;
    2|medium|med) printf '%s' "medium" ;;
    3|low) printf '%s' "low" ;;
    4|xhigh|extra|max) printf '%s' "xhigh" ;;
    5|off|disabled|none) printf '%s' "off" ;;
    6|keep)
      if [[ -n "$current" ]]; then printf '%s' "$current"
      else printf '%s' "high"; fi
      ;;
    high|medium|low|xhigh|minimal) printf '%s' "$(printf '%s' "$choice" | tr '[:upper:]' '[:lower:]')" ;;
    *) die "invalid effort: $choice (high|medium|low|xhigh|off)" ;;
  esac
}

# Interactive or scriptable: set effort on current provider (keeps model/base/key)
cmd_set_effort() {
  local effort="${1:-}"
  local no_restart=0
  shift || true
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --no-restart) no_restart=1; shift ;;
      *) die "unknown flag: $1" ;;
    esac
  done

  if [[ -z "$effort" ]]; then
    effort="$(prompt_reasoning_effort)"
  fi
  effort="$(printf '%s' "$effort" | tr '[:upper:]' '[:lower:]')"

  local thinking="enabled"
  local settings_effort="$effort"
  case "$effort" in
    off|disabled|none|false|0)
      thinking="disabled"
      settings_effort=""
      # remove effort key by rewriting file carefully
      if [[ -f "$ENV_FILE" ]]; then
        upsert_env_keys "SAND_XAI_THINKING=disabled"
        # drop REASONING_EFFORT line
        python3 - "$ENV_FILE" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
lines = [ln for ln in p.read_text().splitlines() if not ln.strip().startswith("SAND_XAI_REASONING_EFFORT=")]
p.write_text("\n".join(lines) + "\n")
PY
      else
        WRITE_COMMENT="effort off" WRITE_PROVIDER=xai WRITE_MODEL="grok-4.6" \
        WRITE_THINKING=disabled WRITE_REASONING_EFFORT="" write_env_file
      fi
      log "thinking=disabled (no reasoning_effort)"
      ;;
    high|medium|low|xhigh|minimal)
      if [[ ! -f "$ENV_FILE" ]]; then
        WRITE_COMMENT="Grok session + effort" WRITE_PROVIDER=xai WRITE_MODEL="grok-4.6" \
        WRITE_THINKING=enabled WRITE_REASONING_EFFORT="$effort" write_env_file
      else
        upsert_env_keys "SAND_XAI_THINKING=enabled" "SAND_XAI_REASONING_EFFORT=$effort"
      fi
      log "thinking=enabled effort=$effort"
      ;;
    *) die "effort must be high|medium|low|xhigh|off (got: $effort)" ;;
  esac

  # Keep model id; patch effort in settings
  local model=""
  if [[ -f "$ENV_FILE" ]]; then
    model="$(grep -E '^SAND_XAI_MODEL=' "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- || true)"
  fi
  model="${model:-grok-4.6}"
  if [[ -n "$settings_effort" ]]; then
    patch_settings_model "$model" "$settings_effort"
  else
    patch_settings_model "$model" ""
  fi

  log "current: $(current_provider_summary)"
  sed -E 's/((KEY|TOKEN|SECRET|PASSWORD)=).*/\1***/' "$ENV_FILE" 2>/dev/null | sed 's/^/  /' || true

  if [[ "$no_restart" -eq 1 ]]; then
    warn "skipped host restart (--no-restart)"
    return 0
  fi
  if [[ "$INTERACTIVE_MENU" -eq 1 ]]; then
    local ans
    ans="$(prompt_line "Restart host so effort applies now?" "Y")"
    case "${ans,,}" in
      y|yes|"") cmd_restart_host ;;
      *) warn "restart later: adapters restart-host" ;;
    esac
  else
    cmd_restart_host
  fi
}

# ── CLIProxy / current-gateway model list + switch ──────────────────────────
current_env_val() {
  local key="$1"
  [[ -f "$ENV_FILE" ]] || return 0
  grep -E "^${key}=" "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- || true
}

inference_models_url() {
  local base
  base="$(current_env_val SAND_XAI_BASE_URL)"
  base="${base:-http://127.0.0.1:${CLIPROXY_PORT}/v1}"
  printf '%s' "${base%/}/models"
}

inference_models_key() {
  local key
  key="$(current_env_val XAI_API_KEY)"
  printf '%s' "${key:-$CLIPROXY_KEY}"
}

# Prints "owner<TAB>id" lines. Empty stdout + nonzero if the gateway is down.
fetch_gateway_models() {
  local url key
  url="$(inference_models_url)"
  key="$(inference_models_key)"
  MODELS_URL="$url" MODELS_KEY="$key" python3 - <<'PY'
import json, os, sys, urllib.error, urllib.request
url = os.environ["MODELS_URL"]
key = os.environ.get("MODELS_KEY") or ""
req = urllib.request.Request(url, headers={"Authorization": f"Bearer {key}"})
try:
    with urllib.request.urlopen(req, timeout=12) as resp:
        data = json.loads(resp.read().decode() or "{}")
except Exception as e:
    print(f"fetch failed: {e}", file=sys.stderr)
    sys.exit(1)
rows = []
for m in data.get("data") or []:
    if isinstance(m, dict) and m.get("id"):
        rows.append((str(m.get("owned_by") or "other"), str(m["id"])))
rows.sort(key=lambda r: (r[0].lower(), r[1].lower()))
for owner, mid in rows:
    print(f"{owner}\t{mid}")
PY
}

cmd_list_models() {
  local current rows
  current="$(current_env_val SAND_XAI_MODEL)"
  echo "=== models at $(inference_models_url) ==="
  if [[ -n "$current" ]]; then
    echo "current: $current"
    echo
  fi
  rows="$(fetch_gateway_models)" || die "could not list models — is CLIProxy up?  adapters start cliproxy"
  [[ -n "$rows" ]] || die "gateway returned no models"
  CURRENT_MODEL="$current" MODELS_ROWS="$rows" python3 - <<'PY'
import os
current = os.environ.get("CURRENT_MODEL") or ""
cur = None
n = 0
for line in (os.environ.get("MODELS_ROWS") or "").splitlines():
    if not line or "\t" not in line:
        continue
    owner, mid = line.split("\t", 1)
    if owner != cur:
        print(f"\n{owner}")
        cur = owner
    n += 1
    mark = "  ← current" if mid == current else ""
    print(f"  {n:3d}) {mid}{mark}")
print(f"\n{n} models")
PY
}

prompt_gateway_model() {
  init_tty
  local current rows choice
  current="$(current_env_val SAND_XAI_MODEL)"
  rows="$(fetch_gateway_models)" || die "could not list models — is CLIProxy up?  adapters start cliproxy"
  [[ -n "$rows" ]] || die "gateway returned no models"
  local tmp
  tmp="$(mktemp)"
  printf '%s\n' "$rows" >"$tmp"
  {
    echo
    echo "CLIProxy / gateway models  ($(inference_models_url))"
    if [[ -n "$current" ]]; then
      echo "current: $current"
    fi
  } >"$_TTY_OUT"
  python3 - "$tmp" "$current" >"$_TTY_OUT" <<'PY'
import sys
path, current = sys.argv[1], sys.argv[2]
cur = None
n = 0
for line in open(path):
    line = line.rstrip("\n")
    if not line or "\t" not in line:
        continue
    owner, mid = line.split("\t", 1)
    if owner != cur:
        print(f"\n{owner}")
        cur = owner
    n += 1
    mark = "  ← current" if mid == current else ""
    print(f"  {n:3d}) {mid}{mark}")
print()
print("Type a number or a model id.")
PY
  choice="$(prompt_line "Model" "${current:-}")"
  if [[ -z "$choice" ]]; then
    rm -f "$tmp"
    die "model is required"
  fi
  if [[ "$choice" =~ ^[0-9]+$ ]]; then
    local picked
    picked="$(
      python3 - "$tmp" "$choice" <<'PY'
import sys
path, n = sys.argv[1], int(sys.argv[2])
i = 0
for line in open(path):
    line = line.rstrip("\n")
    if not line or "\t" not in line:
        continue
    i += 1
    if i == n:
        print(line.split("\t", 1)[1])
        raise SystemExit(0)
raise SystemExit(1)
PY
    )" || { rm -f "$tmp"; die "invalid model number: $choice"; }
    rm -f "$tmp"
    printf '%s' "$picked"
    return 0
  fi
  rm -f "$tmp"
  printf '%s' "$choice"
}

# Switch only the model id; keep current CLIProxy/base/key.
cmd_set_model() {
  local model="${1:-}"
  shift || true
  OPT_NO_RESTART="${OPT_NO_RESTART:-0}"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --model) model="${2:-}"; shift 2 ;;
      --no-restart) OPT_NO_RESTART=1; shift ;;
      --restart) OPT_NO_RESTART=0; shift ;;
      *) die "unknown flag: $1 (usage: adapters model <id> [--no-restart])" ;;
    esac
  done

  if [[ -z "$model" ]]; then
    if [[ "$INTERACTIVE_MENU" -eq 1 ]] || [[ -t 0 || -c /dev/tty ]]; then
      model="$(prompt_gateway_model)"
    else
      cmd_list_models
      die "usage: adapters model <id>   (or run adapters with no args and choose Change model)"
    fi
  fi
  [[ -n "$model" ]] || die "model is required"

  # Make sure we can reach the gateway that serves this catalog.
  local base
  base="$(current_env_val SAND_XAI_BASE_URL)"
  if [[ -z "$base" || "$base" == *":${CLIPROXY_PORT}/"* ]]; then
    start_cliproxy || warn "CLIProxy not running — model switch will still be written"
  fi

  if [[ ! -f "$ENV_FILE" ]] || [[ "$(current_env_val SAND_INFERENCE_PROVIDER)" == "cursor" ]] || [[ -z "$(current_env_val SAND_XAI_BASE_URL)" ]]; then
    WRITE_COMMENT="CLIProxy model ${model}" \
    WRITE_PROVIDER=xai WRITE_BASE_URL="http://127.0.0.1:${CLIPROXY_PORT}/v1" \
    WRITE_MODEL="$model" WRITE_API_KEY="$CLIPROXY_KEY" \
    WRITE_THINKING="$(current_env_val SAND_XAI_THINKING)" \
    WRITE_REASONING_EFFORT="$(current_env_val SAND_XAI_REASONING_EFFORT)" \
      write_env_file
  else
    upsert_env_keys "SAND_INFERENCE_PROVIDER=xai" "SAND_XAI_MODEL=$model"
    log "SAND_XAI_MODEL=$model"
  fi
  patch_settings_model "$model" "$(current_env_val SAND_XAI_REASONING_EFFORT)"
  ensure_host_inference || warn "host inference patch failed — provider env may be ignored"
  log "current: $(current_provider_summary)"
  after_use
}

# ── host restart ────────────────────────────────────────────────────────────
find_donor_pid() {
  python3 <<'PY'
from pathlib import Path
for p in Path("/proc").iterdir():
    if not p.name.isdigit():
        continue
    try:
        env = (p / "environ").read_bytes()
    except Exception:
        continue
    if b"SAND_INFERENCE_RENEWAL_CREDENTIAL=" in env and b"SAND_GATEWAY_TOKEN=" in env:
        # prefer an existing host-main if present
        try:
            cmd = (p / "cmdline").read_bytes()
        except Exception:
            cmd = b""
        print(p.name)
        if b"host-main.cjs" in cmd:
            break
PY
}

ensure_host_inference() {
  local script="$ROOT/scripts/ensure-xai-inference.sh"
  if [[ ! -f "$script" ]]; then
    warn "missing $script — cannot patch sand-host for custom providers"
    return 1
  fi
  chmod +x "$script" 2>/dev/null || true
  SAND_HOST_DIR="$SAND_HOST" bash "$script"
}

cmd_restart_host() {
  ensure_host_inference || warn "host inference patch failed — sand will keep using Cursor"
  log "restart sand host with full env (donor process)"
  local donor
  # Prefer a non-host donor so we can snapshot env, then kill host safely
  donor="$(
    python3 <<'PY'
from pathlib import Path
host_pid = None
other = None
for p in Path("/proc").iterdir():
    if not p.name.isdigit():
        continue
    try:
        env = (p / "environ").read_bytes()
        cmd = (p / "cmdline").read_bytes()
    except Exception:
        continue
    if b"SAND_INFERENCE_RENEWAL_CREDENTIAL=" not in env or b"SAND_GATEWAY_TOKEN=" not in env:
        continue
    if b"host-main.cjs" in cmd:
        host_pid = p.name
    else:
        other = p.name
        break
print(other or host_pid or "")
PY
  )"
  if [[ -z "$donor" ]]; then
    die "no process with SAND_INFERENCE_RENEWAL_CREDENTIAL — start host via supervisor/UI instead"
  fi
  log "donor pid=$donor"

  python3 - "$donor" "$SAND_HOST" "$ENV_FILE" <<'PY'
import os, signal, subprocess, sys, time
from pathlib import Path

donor, sand_host, env_file = sys.argv[1], sys.argv[2], sys.argv[3]

# Snapshot donor env FIRST (donor may be host-main itself)
raw = Path(f"/proc/{donor}/environ").read_bytes()
env = {}
for e in raw.split(b"\0"):
    if not e or b"=" not in e:
        continue
    k, v = e.split(b"=", 1)
    env[k.decode()] = v.decode("utf-8", "replace")

# Clear provider overrides — re-apply from xai-inference.env below
for k in (
    "XAI_API_KEY", "GROK_CODE_XAI_API_KEY", "GROK_XAI_API_KEY",
    "SAND_XAI_BASE_URL", "SAND_XAI_MODEL", "SAND_XAI_THINKING",
    "SAND_XAI_REASONING_EFFORT", "SAND_XAI_MAX_TOKENS", "SAND_XAI_PROMOTE_REASONING",
    "SAND_XAI_IDENTITY", "SAND_INFERENCE_PROVIDER", "OPENAI_API_KEY",
):
    env.pop(k, None)

env["SAND_PACKAGED"] = "1"
env["SAND_HOST_IN_BOX"] = "1"
env["SAND_HOST_LOG_FILE"] = "/tmp/sand-host-manual.log"
env["SAND_DATA_ROOT"] = os.environ.get(
    "SAND_DATA_ROOT", env.get("SAND_DATA_ROOT", str(Path.home() / "sand-data"))
)
env["SAND_XAI_ENV_FILE"] = env_file

if Path(env_file).is_file():
    for line in Path(env_file).read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        if line.startswith("export "):
            line = line[7:]
        k, _, v = line.partition("=")
        v = v.strip().strip('"').strip("'")
        env[k.strip()] = v

# Kill existing host-main.cjs only (after env snapshot)
for p in Path("/proc").iterdir():
    if not p.name.isdigit():
        continue
    try:
        c = (p / "cmdline").read_bytes()
    except Exception:
        continue
    if c.startswith(b"/exec-daemon/node") and b"host-main.cjs" in c:
        os.kill(int(p.name), signal.SIGTERM)
        print(f"killed host {p.name}", flush=True)

time.sleep(2)

node = "/exec-daemon/node"
host_main = str(Path(sand_host) / "host-main.cjs")
if not Path(host_main).is_file():
    raise SystemExit(f"missing {host_main}")

logf = open("/tmp/sand-host-manual.log", "a")
logf.write("\n--- adapters.sh restart-host ---\n")
logf.flush()
proc = subprocess.Popen(
    [node, host_main],
    cwd=sand_host,
    env=env,
    stdout=logf,
    stderr=logf,
    start_new_session=True,
)
print(f"spawned host pid={proc.pid}", flush=True)
time.sleep(3)
gw = Path(env["SAND_DATA_ROOT"]) / "gateway.json"
if gw.is_file():
    print(gw.read_text(), flush=True)
else:
    print("gateway.json not ready yet", flush=True)
PY

  if port_listening 1340; then
    log "host gateway listening on :1340"
    warn "If UI says Reconnecting: hard-refresh / reopen Grok Bot (gateway token may have changed)"
  else
    warn "port 1340 not up — check /tmp/sand-host-manual.log"
  fi
}

# ── interactive prompts ─────────────────────────────────────────────────────
# Read a line from the TTY when available (works even if stdin is piped).
prompt_line() {
  # $1=prompt  $2=default(optional)
  local prompt="$1" default="${2:-}" reply
  init_tty
  if [[ -n "$default" ]]; then
    printf '%s [%s]: ' "$prompt" "$default" >"$_TTY_OUT"
  else
    printf '%s: ' "$prompt" >"$_TTY_OUT"
  fi
  # shellcheck disable=SC2162
  IFS= read -r reply <"$_TTY_IN" || true
  if [[ -z "$reply" ]]; then
    reply="$default"
  fi
  printf '%s' "$reply"
}

prompt_secret() {
  # $1=prompt  (no echo)
  local prompt="$1" reply
  init_tty
  printf '%s: ' "$prompt" >"$_TTY_OUT"
  # shellcheck disable=SC2162
  IFS= read -r -s reply <"$_TTY_IN" || true
  printf '\n' >"$_TTY_OUT"
  printf '%s' "$reply"
}

prompt_deepseek_model() {
  # prints selected model id to stdout; prompts on TTY
  init_tty
  local current=""
  if [[ -f "$ENV_FILE" ]]; then
    current="$(grep -E '^SAND_XAI_MODEL=' "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- || true)"
  fi
  {
    echo
    echo "DeepSeek model:"
    echo "  1) deepseek-v4-flash     (fast, default)"
    echo "  2) deepseek-v4-pro"
    echo "  3) Other (type a model id)"
    if [[ -n "$current" ]]; then
      echo "  4) Keep current ($current)"
    fi
  } >"$_TTY_OUT"
  local choice
  choice="$(prompt_line "Choose 1-3${current:+/4}" "1")"
  case "$choice" in
    1|"") printf '%s' "deepseek-v4-flash" ;;
    2) printf '%s' "deepseek-v4-pro" ;;
    3)
      local custom
      custom="$(prompt_line "Model id" "${current:-deepseek-v4-flash}")"
      [[ -n "$custom" ]] || die "model id cannot be empty"
      printf '%s' "$custom"
      ;;
    4)
      if [[ -n "$current" ]]; then
        printf '%s' "$current"
      else
        die "no current model to keep"
      fi
      ;;
    *)
      # Allow typing a model id directly
      if [[ "$choice" == deepseek-* || "$choice" == *'/'* ]]; then
        printf '%s' "$choice"
      else
        die "invalid choice: $choice"
      fi
      ;;
  esac
}

prompt_deepseek_api_key() {
  # prints key to stdout
  init_tty
  local existing=""
  if [[ -f "$ENV_FILE" ]]; then
    existing="$(grep -E '^XAI_API_KEY=' "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- || true)"
  fi
  existing="${existing:-${DEEPSEEK_API_KEY:-${XAI_API_KEY:-}}}"

  if [[ -n "$existing" ]]; then
    local masked
    if [[ ${#existing} -gt 10 ]]; then
      masked="${existing:0:6}…${existing: -4}"
    else
      masked="(set, ${#existing} chars)"
    fi
    {
      echo
      echo "DeepSeek API key:"
      echo "  1) Keep current ($masked)"
      echo "  2) Enter a new key"
    } >"$_TTY_OUT"
    local choice
    choice="$(prompt_line "Choose 1-2" "1")"
    case "$choice" in
      1|"") printf '%s' "$existing"; return ;;
      2) ;;
      *) die "invalid choice: $choice" ;;
    esac
  else
    echo >"$_TTY_OUT"
    echo "DeepSeek API key required (from https://platform.deepseek.com )" >"$_TTY_OUT"
  fi

  local key
  key="$(prompt_secret "Paste DeepSeek API key (input hidden)")"
  [[ -n "$key" ]] || die "API key cannot be empty"
  printf '%s' "$key"
}

prompt_claude_model() {
  init_tty
  local current=""
  if [[ -f "$ENV_FILE" ]]; then
    current="$(grep -E '^SAND_XAI_MODEL=' "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- || true)"
  fi
  {
    echo
    echo "Claude model:"
    echo "  1) claude-opus-5          (strongest / default)"
    echo "  2) claude-sonnet-4-5"
    echo "  3) claude-sonnet          (sonnet-5 alias on LiteLLM)"
    echo "  4) claude-sonnet-5"
    echo "  5) claude-haiku-4-5"
    echo "  6) Other (type a model id)"
    if [[ -n "$current" && "$current" == claude-* ]]; then
      echo "  7) Keep current ($current)"
    fi
  } >"$_TTY_OUT"
  local choice
  choice="$(prompt_line "Choose 1-6${current:+/7}" "1")"
  case "$choice" in
    1|"") printf '%s' "claude-opus-5" ;;
    2) printf '%s' "claude-sonnet-4-5" ;;
    3) printf '%s' "claude-sonnet" ;;
    4) printf '%s' "claude-sonnet-5" ;;
    5) printf '%s' "claude-haiku-4-5" ;;
    6)
      local custom
      custom="$(prompt_line "Model id" "${current:-claude-opus-5}")"
      [[ -n "$custom" ]] || die "model id cannot be empty"
      printf '%s' "$custom"
      ;;
    7)
      if [[ -n "$current" ]]; then
        printf '%s' "$current"
      else
        die "no current Claude model to keep"
      fi
      ;;
    *)
      if [[ "$choice" == claude-* ]]; then
        printf '%s' "$choice"
      else
        die "invalid choice: $choice"
      fi
      ;;
  esac
}

# Prints: oauth | api_key
prompt_claude_auth_mode() {
  init_tty
  {
    echo
    echo "Claude auth:"
    echo "  1) Claude Pro/Max OAuth via CLIProxy  (claude login → :8317)  [recommended for agents]"
    echo "  2) Anthropic Console API key          (sk-ant-api… → LiteLLM :4000)"
  } >"$_TTY_OUT"
  local choice
  choice="$(prompt_line "Choose 1-2" "1")"
  case "$choice" in
    1|"") printf '%s' "oauth" ;;
    2) printf '%s' "api_key" ;;
    oauth|pro) printf '%s' "oauth" ;;
    api|api_key|key|console) printf '%s' "api_key" ;;
    *) die "invalid choice: $choice" ;;
  esac
}

prompt_claude_api_key() {
  # Anthropic Console API key (sk-ant-api…)
  init_tty
  local existing=""
  if [[ -f "$LITELLM_DIR/.env" ]]; then
    existing="$(grep -E '^ANTHROPIC_API_KEY=' "$LITELLM_DIR/.env" 2>/dev/null | head -1 | cut -d= -f2- || true)"
  fi
  existing="${existing:-${ANTHROPIC_API_KEY:-}}"
  # Ignore placeholders
  if [[ "$existing" == *PLACEHOLDER* || "$existing" == sk-ant-PLACEHOLDER ]]; then
    existing=""
  fi

  if [[ -n "$existing" ]]; then
    local masked
    if [[ ${#existing} -gt 12 ]]; then
      masked="${existing:0:10}…${existing: -4}"
    else
      masked="(set, ${#existing} chars)"
    fi
    {
      echo
      echo "Anthropic Console API key:"
      echo "  1) Keep current ($masked)"
      echo "  2) Enter a new key"
    } >"$_TTY_OUT"
    local choice
    choice="$(prompt_line "Choose 1-2" "1")"
    case "$choice" in
      1|"") printf '%s' "$existing"; return ;;
      2) ;;
      *) die "invalid choice: $choice" ;;
    esac
  else
    echo >"$_TTY_OUT"
    echo "Anthropic Console API key required (https://console.anthropic.com — sk-ant-api…)" >"$_TTY_OUT"
    echo "Note: Claude Pro/Max OAuth tokens (sk-ant-oat…) will not work here; pick auth option 1 instead." >"$_TTY_OUT"
  fi

  local key
  key="$(prompt_secret "Paste Anthropic API key (input hidden)")"
  [[ -n "$key" ]] || die "API key cannot be empty"
  if [[ "$key" == sk-ant-oat* ]]; then
    die "that looks like a Claude OAuth token (sk-ant-oat…). Use auth option 1 (CLIProxy) after: claude login"
  fi
  printf '%s' "$key"
}

# Upsert KEY=VAL in a dotenv file
set_dotenv_key() {
  local file="$1" key="$2" val="$3"
  mkdir -p "$(dirname "$file")"
  if [[ ! -f "$file" ]]; then
    printf '%s=%s\n' "$key" "$val" >"$file"
    chmod 600 "$file" 2>/dev/null || true
    return
  fi
  python3 - "$file" "$key" "$val" <<'PY'
from pathlib import Path
import sys
path, key, val = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
lines = path.read_text().splitlines()
out, found = [], False
for line in lines:
    if line.startswith(f"{key}=") or line.startswith(f"export {key}="):
        out.append(f"{key}={val}")
        found = True
    else:
        out.append(line)
if not found:
    out.append(f"{key}={val}")
path.write_text("\n".join(out) + "\n")
PY
  chmod 600 "$file" 2>/dev/null || true
}

# Map user model pick → LiteLLM model_name alias (config.yaml)
claude_litellm_alias() {
  local model="$1"
  case "$model" in
    claude-opus-5|claude-opus-4*|claude-3-opus*) printf '%s' "claude-opus-5" ;;
    claude-sonnet-4-5|claude-sonnet-4.5) printf '%s' "claude-sonnet-4-5" ;;
    claude-sonnet-5|claude-sonnet) printf '%s' "claude-sonnet" ;;
    claude-haiku*) printf '%s' "$model" ;; # may need yaml entry
    *) printf '%s' "$model" ;;
  esac
}

# ── use profiles ────────────────────────────────────────────────────────────
parse_use_flags() {
  # sets: OPT_MODEL OPT_KEY OPT_BASE OPT_NO_RESTART OPT_THINKING OPT_REASONING_EFFORT OPT_AUTH
  OPT_MODEL=""
  OPT_KEY=""
  OPT_BASE=""
  OPT_NO_RESTART=0
  OPT_THINKING="disabled"
  OPT_REASONING_EFFORT=""
  OPT_AUTH="" # oauth | api_key (claude only)
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --model) OPT_MODEL="${2:-}"; shift 2 ;;
      --key) OPT_KEY="${2:-}"; shift 2 ;;
      --base-url|--base) OPT_BASE="${2:-}"; shift 2 ;;
      --thinking) OPT_THINKING="${2:-}"; shift 2 ;;
      --reasoning-effort|--effort|--reasoning)
        OPT_REASONING_EFFORT="${2:-}"; shift 2
        ;;
      --auth) OPT_AUTH="${2:-}"; shift 2 ;;
      --oauth) OPT_AUTH="oauth"; shift ;;
      --api-key|--console) OPT_AUTH="api_key"; shift ;;
      --no-restart) OPT_NO_RESTART=1; shift ;;
      --restart) OPT_NO_RESTART=0; shift ;;
      *) die "unknown flag: $1" ;;
    esac
  done
  normalize_thinking_flags
}

# Normalize --thinking / --reasoning-effort into host env values.
# Accepts --thinking low|medium|high as shorthand for enabled + effort.
normalize_thinking_flags() {
  local t="${OPT_THINKING:-disabled}"
  local t_lc
  t_lc="$(printf '%s' "$t" | tr '[:upper:]' '[:lower:]')"
  case "$t_lc" in
    low|medium|high|minimal|max|xhigh|ultra)
      OPT_REASONING_EFFORT="${OPT_REASONING_EFFORT:-$t_lc}"
      OPT_THINKING="enabled"
      ;;
    enabled|true|1|on)
      OPT_THINKING="enabled"
      ;;
    disabled|false|0|off|"")
      OPT_THINKING="disabled"
      ;;
    *)
      # pass through unknown tokens (host may understand them)
      OPT_THINKING="$t_lc"
      ;;
  esac
  if [[ -n "${OPT_REASONING_EFFORT:-}" ]]; then
    OPT_REASONING_EFFORT="$(printf '%s' "$OPT_REASONING_EFFORT" | tr '[:upper:]' '[:lower:]')"
    if [[ "$OPT_THINKING" == "disabled" ]]; then
      OPT_THINKING="enabled"
    fi
  fi
}

after_use() {
  if [[ "$OPT_NO_RESTART" -eq 1 ]]; then
    warn "skipped host restart (--no-restart). Run: adapters.sh restart-host"
    return 0
  fi
  if [[ "$INTERACTIVE_MENU" -eq 1 ]]; then
    local ans
    ans="$(prompt_line "Restart Grok Bot host now so the new provider applies?" "Y")"
    case "${ans,,}" in
      y|yes|"") cmd_restart_host ;;
      *) warn "skipped host restart. Choose Restart host from the menu when ready." ;;
    esac
  else
    cmd_restart_host
  fi
}

cmd_use() {
  local profile="${1:-}"
  shift || true
  [[ -n "$profile" ]] || die "usage: adapters.sh use <profile> [flags]"
  parse_use_flags "$@"
  # Stock host ignores xai-inference.env unless the session hook is present.
  if [[ "$profile" != "cursor" && "$profile" != "stock" ]]; then
    ensure_host_inference || warn "host inference patch failed — provider env will not be used"
  fi

  case "$profile" in
    deepseek)
      local key model
      # Interactive by default; flags skip the matching prompt.
      if [[ -n "$OPT_MODEL" ]]; then
        model="$OPT_MODEL"
      else
        model="$(prompt_deepseek_model)"
      fi
      if [[ -n "$OPT_KEY" ]]; then
        key="$OPT_KEY"
      else
        key="$(prompt_deepseek_api_key)"
      fi
      [[ -n "$model" ]] || die "model is required"
      [[ -n "$key" ]] || die "API key is required"
      log "DeepSeek model=$model"
      WRITE_COMMENT="DeepSeek direct" \
      WRITE_PROVIDER=xai WRITE_BASE_URL="https://api.deepseek.com/v1" \
      WRITE_MODEL="$model" WRITE_API_KEY="$key" WRITE_THINKING="$OPT_THINKING" \
        write_env_file
      patch_settings_model "$model"
      after_use
      ;;

    openrouter)
      local key model
      if [[ -n "$OPT_MODEL" ]]; then model="$OPT_MODEL"
      elif [[ "$INTERACTIVE_MENU" -eq 1 ]]; then model="$(prompt_line "OpenRouter model id" "openai/gpt-4o")"
      else model="openai/gpt-4o"; fi
      if [[ -n "$OPT_KEY" ]]; then key="$OPT_KEY"
      elif [[ -n "${OPENROUTER_API_KEY:-}" ]]; then key="$OPENROUTER_API_KEY"
      elif [[ "$INTERACTIVE_MENU" -eq 1 ]]; then key="$(prompt_secret "OpenRouter API key (hidden)")"
      else die "need --key or OPENROUTER_API_KEY"; fi
      [[ -n "$key" && -n "$model" ]] || die "model and key required"
      WRITE_COMMENT="OpenRouter" \
      WRITE_PROVIDER=xai WRITE_BASE_URL="https://openrouter.ai/api/v1" \
      WRITE_MODEL="$model" WRITE_API_KEY="$key" \
        write_env_file
      patch_settings_model "$model"
      after_use
      ;;

    openai)
      local key model
      if [[ -n "$OPT_MODEL" ]]; then model="$OPT_MODEL"
      elif [[ "$INTERACTIVE_MENU" -eq 1 ]]; then model="$(prompt_line "OpenAI model id" "gpt-4o")"
      else model="gpt-4o"; fi
      if [[ -n "$OPT_KEY" ]]; then key="$OPT_KEY"
      elif [[ -n "${OPENAI_API_KEY:-}" ]]; then key="$OPENAI_API_KEY"
      elif [[ "$INTERACTIVE_MENU" -eq 1 ]]; then key="$(prompt_secret "OpenAI API key (hidden)")"
      else die "need --key or OPENAI_API_KEY"; fi
      [[ -n "$key" && -n "$model" ]] || die "model and key required"
      WRITE_COMMENT="OpenAI Platform API" \
      WRITE_PROVIDER=xai WRITE_BASE_URL="https://api.openai.com/v1" \
      WRITE_MODEL="$model" WRITE_API_KEY="$key" \
        write_env_file
      patch_settings_model "$model"
      after_use
      ;;

    xai-api|xai)
      local key model
      if [[ -n "$OPT_MODEL" ]]; then model="$OPT_MODEL"
      elif [[ "$INTERACTIVE_MENU" -eq 1 ]]; then model="$(prompt_line "xAI model id" "grok-4.5")"
      else model="grok-4.5"; fi
      if [[ -n "$OPT_KEY" ]]; then key="$OPT_KEY"
      elif [[ -n "${XAI_API_KEY:-}" ]]; then key="$XAI_API_KEY"
      elif [[ "$INTERACTIVE_MENU" -eq 1 ]]; then key="$(prompt_secret "xAI API key (hidden)")"
      else die "need --key xai-... or XAI_API_KEY"; fi
      [[ -n "$key" && -n "$model" ]] || die "model and key required"
      WRITE_COMMENT="xAI Platform API" \
      WRITE_PROVIDER=xai WRITE_BASE_URL="https://api.x.ai/v1" \
      WRITE_MODEL="$model" WRITE_API_KEY="$key" \
        write_env_file
      patch_settings_model "$model"
      after_use
      ;;

    grok-session|grok)
      # Session auth: do NOT set XAI_API_KEY so module uses ~/.grok/auth.json
      local model effort
      if [[ -n "$OPT_MODEL" ]]; then model="$OPT_MODEL"
      elif [[ "$INTERACTIVE_MENU" -eq 1 ]]; then model="$(prompt_line "Grok model id" "grok-4.6")"
      else model="grok-4.6"; fi
      # Effort picker (interactive) or --effort flag
      if [[ -z "${OPT_REASONING_EFFORT:-}" && "$INTERACTIVE_MENU" -eq 1 ]]; then
        OPT_REASONING_EFFORT="$(prompt_reasoning_effort)"
      fi
      if [[ -z "${OPT_REASONING_EFFORT:-}" && -z "${OPT_THINKING:-}" ]]; then
        # non-interactive default: high for Grok 4.6
        OPT_REASONING_EFFORT="high"
        OPT_THINKING="enabled"
      fi
      if [[ "${OPT_REASONING_EFFORT:-}" == "off" || "${OPT_REASONING_EFFORT:-}" == "disabled" ]]; then
        OPT_THINKING="disabled"
        OPT_REASONING_EFFORT=""
      else
        OPT_THINKING="enabled"
      fi
      normalize_thinking_flags
      effort="${OPT_REASONING_EFFORT:-}"
      [[ -f "$HOME/.grok/auth.json" ]] || warn "no ~/.grok/auth.json — run: grok login"
      log "Grok model=$model thinking=$OPT_THINKING effort=${effort:-(none)}"
      WRITE_COMMENT="Grok CLI session (cli-chat-proxy)" \
      WRITE_PROVIDER=xai WRITE_BASE_URL="" WRITE_MODEL="$model" WRITE_API_KEY="" \
      WRITE_THINKING="$OPT_THINKING" WRITE_REASONING_EFFORT="$effort" \
        write_env_file
      patch_settings_model "$model" "$effort"
      after_use
      ;;

    cliproxy|claude|claude-oauth)
      local model auth_mode key alias master
      # 1) Model
      if [[ -n "$OPT_MODEL" ]]; then
        model="$OPT_MODEL"
      else
        model="$(prompt_claude_model)"
      fi
      [[ -n "$model" ]] || die "model is required"

      # 2) Auth mode (OAuth CLIProxy vs Console API key)
      if [[ -n "$OPT_AUTH" ]]; then
        auth_mode="$OPT_AUTH"
      elif [[ -n "$OPT_KEY" ]]; then
        # Providing --key implies console API path
        auth_mode="api_key"
      else
        auth_mode="$(prompt_claude_auth_mode)"
      fi

      case "$auth_mode" in
        oauth|cliproxy)
          log "Claude model=$model auth=CLIProxy OAuth"
          if [[ ! -f "$HOME/.claude/.credentials.json" ]]; then
            warn "no ~/.claude/.credentials.json — run: claude login"
          fi
          start_cliproxy || die "CLIProxyAPI not running — adapters.sh install cliproxy && start cliproxy"
          WRITE_COMMENT="Claude via CLIProxyAPI OAuth (claude login)" \
          WRITE_PROVIDER=xai WRITE_BASE_URL="http://127.0.0.1:${CLIPROXY_PORT}/v1" \
          WRITE_MODEL="$model" WRITE_API_KEY="$CLIPROXY_KEY" WRITE_THINKING="$OPT_THINKING" \
            write_env_file
          patch_settings_model "$model"
          after_use
          ;;
        api_key|console|key)
          if [[ -n "$OPT_KEY" ]]; then
            key="$OPT_KEY"
          else
            key="$(prompt_claude_api_key)"
          fi
          [[ -n "$key" ]] || die "Anthropic API key is required"
          log "Claude model=$model auth=Console API key → LiteLLM"
          # Persist key for LiteLLM anthropic/* backends
          if [[ ! -f "$LITELLM_DIR/.env" ]]; then
            install_litellm
          fi
          set_dotenv_key "$LITELLM_DIR/.env" "ANTHROPIC_API_KEY" "$key"
          if ! grep -qE '^LITELLM_MASTER_KEY=' "$LITELLM_DIR/.env" 2>/dev/null; then
            set_dotenv_key "$LITELLM_DIR/.env" "LITELLM_MASTER_KEY" "$LITELLM_KEY_DEFAULT"
          fi
          master="$(grep -E '^LITELLM_MASTER_KEY=' "$LITELLM_DIR/.env" | head -1 | cut -d= -f2-)"
          master="${master:-$LITELLM_KEY_DEFAULT}"
          alias="$(claude_litellm_alias "$model")"
          # Restart litellm so new ANTHROPIC_API_KEY is picked up
          stop_port_procs "$LITELLM_PORT" litellm || true
          start_litellm || die "LiteLLM failed to start — check $LITELLM_DIR/logs/bridge.log"
          WRITE_COMMENT="Claude via LiteLLM + Anthropic Console API key" \
          WRITE_PROVIDER=xai WRITE_BASE_URL="http://127.0.0.1:${LITELLM_PORT}/v1" \
          WRITE_MODEL="$alias" WRITE_API_KEY="$master" WRITE_THINKING="$OPT_THINKING" \
            write_env_file
          patch_settings_model "$alias"
          after_use
          ;;
        *)
          die "unknown Claude auth mode: $auth_mode (oauth|api_key)"
          ;;
      esac
      ;;

    litellm|bridge)
      local model key
      if [[ -n "$OPT_MODEL" ]]; then model="$OPT_MODEL"
      elif [[ "$INTERACTIVE_MENU" -eq 1 ]]; then
        model="$(prompt_line "LiteLLM model alias (from config.yaml)" "grok")"
      else model="grok"; fi
      if [[ -f "$LITELLM_DIR/.env" ]]; then
        key="$(grep -E '^LITELLM_MASTER_KEY=' "$LITELLM_DIR/.env" | head -1 | cut -d= -f2- || true)"
      fi
      key="${OPT_KEY:-${key:-$LITELLM_KEY_DEFAULT}}"
      start_litellm || die "LiteLLM not running"
      WRITE_COMMENT="LiteLLM multi-provider bridge" \
      WRITE_PROVIDER=xai WRITE_BASE_URL="http://127.0.0.1:${LITELLM_PORT}/v1" \
      WRITE_MODEL="$model" WRITE_API_KEY="$key" \
        write_env_file
      patch_settings_model "$model"
      after_use
      ;;

    openai-oauth|codex|chatgpt)
      local model
      if [[ -n "$OPT_MODEL" ]]; then model="$OPT_MODEL"
      elif [[ "$INTERACTIVE_MENU" -eq 1 ]]; then
        model="$(prompt_line "Codex/ChatGPT model id (from proxy /v1/models)" "gpt-5.4-mini")"
      else model="gpt-5.4-mini"; fi
      start_openai_oauth || die "openai-oauth not running"
      WRITE_COMMENT="ChatGPT/Codex OAuth via openai-oauth proxy" \
      WRITE_PROVIDER=xai WRITE_BASE_URL="http://127.0.0.1:${OPENAI_OAUTH_PORT}/v1" \
      WRITE_MODEL="$model" WRITE_API_KEY="openai-oauth" \
        write_env_file
      patch_settings_model "$model"
      after_use
      ;;

    direct)
      if [[ -z "$OPT_BASE" && "$INTERACTIVE_MENU" -eq 1 ]]; then
        OPT_BASE="$(prompt_line "Base URL (…/v1)" "")"
      fi
      if [[ -z "$OPT_MODEL" && "$INTERACTIVE_MENU" -eq 1 ]]; then
        OPT_MODEL="$(prompt_line "Model id" "")"
      fi
      if [[ -z "$OPT_KEY" && "$INTERACTIVE_MENU" -eq 1 ]]; then
        OPT_KEY="$(prompt_secret "API key (hidden)")"
      fi
      [[ -n "$OPT_BASE" ]] || die "direct requires --base-url URL"
      [[ -n "$OPT_MODEL" ]] || die "direct requires --model ID"
      [[ -n "$OPT_KEY" ]] || die "direct requires --key KEY"
      WRITE_COMMENT="Direct OpenAI-compatible provider" \
      WRITE_PROVIDER=xai WRITE_BASE_URL="$OPT_BASE" \
      WRITE_MODEL="$OPT_MODEL" WRITE_API_KEY="$OPT_KEY" WRITE_THINKING="$OPT_THINKING" \
        write_env_file
      patch_settings_model "$OPT_MODEL"
      after_use
      ;;

    cursor|stock)
      WRITE_COMMENT="Stock Cursor inference (no custom provider)" \
      WRITE_PROVIDER=cursor WRITE_BASE_URL="" WRITE_MODEL="" WRITE_API_KEY="" \
        write_env_file
      after_use
      ;;

    *)
      die "unknown profile: $profile
profiles: deepseek claude cliproxy openrouter openai xai-api grok-session litellm openai-oauth direct cursor"
      ;;
  esac
}

# ── interactive menu ────────────────────────────────────────────────────────
menu_switch_provider() {
  local t choice
  t="$(tty_path)"
  while true; do
    {
      echo
      echo "── Switch Grok Bot provider ──"
      echo "  1) DeepSeek          (api.deepseek.com — asks model + key)"
      echo "  2) Claude            (OAuth CLIProxy or Console API key)"
      echo "  3) Grok session      (~/.grok/auth.json)"
      echo "  4) OpenAI            (Platform API key)"
      echo "  5) OpenRouter"
      echo "  6) xAI API key"
      echo "  7) LiteLLM bridge    (:4000 multi-provider)"
      echo "  8) ChatGPT / Codex  (:10531 openai-oauth)"
      echo "  9) Direct URL        (any OpenAI-compatible base)"
      echo " 10) Stock Cursor      (disable custom inference)"
      echo "  0) Back"
    } >"$t"
    choice="$(prompt_line "Choose" "0")"
    case "$choice" in
      0|b|back|"") return 0 ;;
      1) cmd_use deepseek; pause; return 0 ;;
      2) cmd_use claude; pause; return 0 ;;
      3) cmd_use grok-session; pause; return 0 ;;
      4) cmd_use openai; pause; return 0 ;;
      5) cmd_use openrouter; pause; return 0 ;;
      6) cmd_use xai-api; pause; return 0 ;;
      7) cmd_use litellm; pause; return 0 ;;
      8) cmd_use openai-oauth; pause; return 0 ;;
      9) cmd_use direct; pause; return 0 ;;
      10) cmd_use cursor; pause; return 0 ;;
      *) warn "invalid choice: $choice" ;;
    esac
  done
}

menu_pick_adapter_target() {
  # prints all|cliproxy|litellm|openai-oauth
  local t choice
  t="$(tty_path)"
  {
    echo
    echo "  1) All adapters"
    echo "  2) CLIProxy only   (:8317 Claude OAuth)"
    echo "  3) LiteLLM only    (:4000)"
    echo "  4) openai-oauth    (:10531 Codex)"
    echo "  0) Cancel"
  } >"$t"
  choice="$(prompt_line "Choose" "1")"
  case "$choice" in
    0|"") printf '%s' "" ;;
    1) printf '%s' "all" ;;
    2) printf '%s' "cliproxy" ;;
    3) printf '%s' "litellm" ;;
    4) printf '%s' "openai-oauth" ;;
    *) printf '%s' "all" ;;
  esac
}

menu_pick_install_target() {
  # prints all|cliproxy|litellm|openai-oauth|herdr|ghostty
  local t choice
  t="$(tty_path)"
  {
    echo
    echo "  1) All adapters"
    echo "  2) CLIProxy only   (:8317 Claude OAuth)"
    echo "  3) LiteLLM only    (:4000)"
    echo "  4) openai-oauth    (:10531 Codex)"
    echo "  5) herdr           (agent runtime — herdr.dev)"
    echo "  6) ghostty         (terminal emulator)"
    echo "  0) Cancel"
  } >"$t"
  choice="$(prompt_line "Choose" "1")"
  case "$choice" in
    0|"") printf '%s' "" ;;
    1) printf '%s' "all" ;;
    2) printf '%s' "cliproxy" ;;
    3) printf '%s' "litellm" ;;
    4) printf '%s' "openai-oauth" ;;
    5) printf '%s' "herdr" ;;
    6) printf '%s' "ghostty" ;;
    *) printf '%s' "all" ;;
  esac
}

cmd_menu() {
  INTERACTIVE_MENU=1
  local t choice target
  t="$(tty_path)"
  # Ensure OPT_* defaults for menu-driven use
  OPT_MODEL=""
  OPT_KEY=""
  OPT_BASE=""
  OPT_NO_RESTART=0
  OPT_THINKING="disabled"
  OPT_REASONING_EFFORT=""
  OPT_AUTH=""

  # On launch: check login agents; if missing, ask to install
  ensure_login_agents_interactive || true

  while true; do
    {
      echo
      echo "╔══════════════════════════════════════════════════╗"
      echo "║         Grok Bot — Inference Adapters            ║"
      echo "╚══════════════════════════════════════════════════╝"
      echo "  $(current_provider_summary)"
      echo
      echo "  1) Status"
      echo "  2) Switch provider     ← DeepSeek, Claude, Grok, …"
      echo "  3) Change model        ← list from CLIProxy / current gateway"
      echo "  4) Reasoning effort    ← high / medium / low / xhigh / off"
      echo "  5) Install adapters    (CLIProxy / LiteLLM / openai-oauth)"
      echo "  6) Start adapters"
      echo "  7) Stop adapters"
      echo "  8) Restart Grok Bot host"
      echo "  9) Check / install login agents  (claude, grok, codex, …)"
      echo "  h) Help"
      echo "  0) Quit"
    } >"$t"
    choice="$(prompt_line "Choose" "1")"
    case "$choice" in
      0|q|quit|exit)
        tty_echo "Bye."
        return 0
        ;;
      1|status|st)
        cmd_status
        echo
        cmd_check_login_agents
        pause
        ;;
      2|switch|use)
        menu_switch_provider
        ;;
      3|model|models|change-model)
        cmd_set_model || true
        pause
        ;;
      4|effort|reasoning)
        cmd_set_effort || true
        pause
        ;;
      5|install)
        target="$(menu_pick_install_target)"
        if [[ -n "$target" ]]; then
          cmd_install "$target" || true
          pause
        fi
        ;;
      6|start)
        target="$(menu_pick_adapter_target)"
        if [[ -n "$target" ]]; then
          cmd_start "$target" || true
          pause
        fi
        ;;
      7|stop)
        target="$(menu_pick_adapter_target)"
        if [[ -n "$target" ]]; then
          cmd_stop "$target" || true
          pause
        fi
        ;;
      8|restart)
        cmd_restart_host || true
        pause
        ;;
      9|logins|login-agents|check)
        ensure_login_agents_interactive || true
        pause
        ;;
      h|help)
        cmd_help
        pause
        ;;
      *)
        warn "invalid choice: $choice"
        ;;
    esac
  done
}

# ── help ────────────────────────────────────────────────────────────────────
cmd_help() {
  cat <<EOF
Grok Bot adapters CLI

INTERACTIVE (default)
  adapters                    # full menu
  adapters menu

MENU PATH
  1 Status
  2 Switch provider → DeepSeek / Claude / Grok / OpenAI / …
  3 Change model → list from CLIProxy / current gateway
  4 Reasoning effort → high / medium / low / xhigh / off
  5 Install adapters / tools (CLIProxy / LiteLLM / openai-oauth / herdr / ghostty)
  6 Start adapters
  7 Stop adapters
  8 Restart host
  9 Check / install login agents (claude, grok, codex)
  h Help
  0 Quit

On launch, the menu scans for login agents. If any are missing, it asks
whether to install them (one-by-one). If installed but not logged in, it
shows the login command.

SCRIPTABLE
  adapters status
  adapters check-logins
  adapters effort high|medium|low|xhigh|off [--no-restart]
  adapters install [all|cliproxy|litellm|openai-oauth|claude|grok|codex|herdr|ghostty|login-agents]
  adapters start   [all|cliproxy|litellm|openai-oauth]
  adapters stop    [all|cliproxy|litellm|openai-oauth]
  adapters use deepseek|claude|grok-session|openai|openrouter|…
  adapters models                    # list models from CLIProxy / current gateway
  adapters model <id> [--no-restart] # switch Sand to that model (keeps CLIProxy)
  adapters sync-claude [--refresh]   # bidirectional Claude OAuth token sync
  adapters restart-host
  adapters patch-host                 # re-inject host hook after a host upgrade
  adapters recover                    # after a sand reset: hook + CLIProxy + restart
  adapters management                 # print Management Center URL + key

  adapters use grok-session --model grok-4.6 --effort high
  adapters use grok-session --model grok-4.6 --effort medium   # safer multi-agent
  adapters effort medium                                        # change effort only
  adapters models
  adapters model gemini-3.6-flash-high
  adapters model claude-opus-5
  adapters use deepseek --model deepseek-v4-flash --key sk-... --no-restart

USE FLAGS
  --model ID
  --key KEY
  --base-url URL
  --auth oauth|api_key          (claude)
  --thinking enabled|disabled   (or low|medium|high shorthand)
  --effort / --reasoning-effort LEVEL   low|medium|high|xhigh
  --no-restart

Host multi-agent safety (xai-prompt-session.cjs):
  SAND_XAI_MAX_TOKENS=8192       # default completion cap (0 = omit)
  SAND_XAI_PROMOTE_REASONING=0   # do not feed reasoning back as chat content

Docs: ${ROOT}/docs/GUIDE_CUSTOM_INFERENCE.md
EOF
}

# Rebuild host hook + CLIProxy after a sand-host / sand-data wipe.
cmd_recover() {
  log "recover custom inference after a sand reset"
  chmod +x "$ROOT/adapters" "$ROOT/adapters.sh" "$ROOT/scripts/ensure-xai-inference.sh" 2>/dev/null || true
  mkdir -p "$HOME/.local/bin"
  cat >"$HOME/.local/bin/adapters" <<EOF
#!/bin/sh
exec "$ROOT/adapters.sh" "\$@"
EOF
  chmod +x "$HOME/.local/bin/adapters"
  log "PATH launcher $HOME/.local/bin/adapters → $ROOT/adapters.sh"

  if [[ ! -d "$SAND_HOST" || ! -f "$SAND_HOST/host-main.cjs" ]]; then
    warn "missing $SAND_HOST/host-main.cjs — wait for Sand to unpack the host, then re-run: adapters recover"
  else
    ensure_host_inference || warn "host inference patch failed"
  fi

  if [[ ! -f "$ENV_FILE" && -f "$ROOT/xai-inference.env.example" ]]; then
    mkdir -p "$(dirname "$ENV_FILE")"
    cp "$ROOT/xai-inference.env.example" "$ENV_FILE"
    chmod 600 "$ENV_FILE" 2>/dev/null || true
    log "seeded $ENV_FILE (Claude via CLIProxy — change with: adapters model …)"
  fi

  install_cliproxy
  start_cliproxy || warn "cliproxy start failed — adapters start cliproxy"

  if [[ -f "$ENV_FILE" ]]; then
    cmd_restart_host || warn "host restart failed"
  else
    warn "no $ENV_FILE — point Sand at a provider, e.g.:"
    warn "  adapters use claude --model claude-opus-5 --oauth"
  fi
  echo
  echo "Next (logins / paid keys are not in git):"
  echo "  claude login          # Claude Pro/Max OAuth"
  echo "  grok login            # Grok session"
  echo "  export MODEL_API_KEY=… DEEPSEEK_API_KEY=… && adapters recover"
  echo "  adapters models"
  echo "  adapters model muse-spark-1.2-contributor"
  echo
  cmd_status || true
}

# ── main ────────────────────────────────────────────────────────────────────
main() {
  # No args → interactive menu
  if [[ $# -eq 0 ]]; then
    cmd_menu
    return
  fi
  local cmd="$1"
  shift || true
  case "$cmd" in
    menu|interactive|ui)
      cmd_menu
      ;;
    help|-h|--help) cmd_help ;;
    status|st) cmd_status ;;
    check-logins|check|logins) cmd_check_login_agents ;;
    sync-claude|sync-auth|refresh-auth)
      write_cliproxy_tree
      "$CLIPROXY_DIR/scripts/sync-claude-auth.sh" "${1:-}"
      ;;
    effort|set-effort|reasoning-effort) cmd_set_effort "$@" ;;
    install) cmd_install "${1:-all}" ;;
    start) cmd_start "${1:-all}" ;;
    stop) cmd_stop "${1:-all}" ;;
    use|switch) cmd_use "$@" ;;
    models|list-models|ls-models) cmd_list_models ;;
    model|set-model|use-model) cmd_set_model "$@" ;;
    restart-host|restart) cmd_restart_host ;;
    patch-host|ensure-host|inject-hook) ensure_host_inference ;;
    recover|restore|bootstrap) cmd_recover ;;
    management|mgmt|cliproxy-ui)
      ensure_cliproxy_mgmt_key >/dev/null
      echo "Management Center  http://127.0.0.1:${CLIPROXY_PORT}/management.html"
      echo "API address        http://127.0.0.1:${CLIPROXY_PORT}"
      echo "management key     $(tr -d '[:space:]' <"$CLIPROXY_MGMT_KEY_FILE")"
      echo "key file           $CLIPROXY_MGMT_KEY_FILE"
      echo
      echo "This is NOT the proxy API key (${CLIPROXY_KEY})."
      echo "From this box's browser, localhost is enough (allow-remote is off)."
      ;;
    *)
      if [[ "$cmd" == -* ]]; then
        die "unknown option: $cmd (try: adapters.sh help)"
      fi
      die "unknown command: $cmd (try: adapters.sh   or   adapters.sh help)"
      ;;
  esac
}

main "$@"
