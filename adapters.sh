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

# Project root (directory containing this script)
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SAND_DATA="${SAND_DATA_ROOT:-$HOME/sand-data}"
SAND_HOST="${SAND_HOST_DIR:-$HOME/sand-host}"
ENV_FILE="${SAND_XAI_ENV_FILE:-$SAND_DATA/xai-inference.env}"
SETTINGS_FILE="${SAND_SETTINGS_FILE:-$SAND_DATA/settings.json}"

# Local runtime trees created by `install` (not shipped in the repo)
CLIPROXY_DIR="${CLIPROXY_DIR:-$ROOT/cliproxy-api}"
LITELLM_DIR="${LITELLM_DIR:-$ROOT/grok-model-bridge}"
CLIPROXY_BIN="${CLIPROXY_BIN:-$HOME/go/bin/server}"
CLIPROXY_PORT="${CLIPROXY_PORT:-8317}"
LITELLM_PORT="${LITELLM_PORT:-4000}"
OPENAI_OAUTH_PORT="${OPENAI_OAUTH_PORT:-10531}"
CLIPROXY_KEY="${CLIPROXY_KEY:-sand-cliproxy}"
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
  local model="?" base="?" provider="?"
  if [[ -f "$ENV_FILE" ]]; then
    model="$(grep -E '^SAND_XAI_MODEL=' "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- || true)"
    base="$(grep -E '^SAND_XAI_BASE_URL=' "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- || true)"
    provider="$(grep -E '^SAND_INFERENCE_PROVIDER=' "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- || true)"
  fi
  model="${model:-?}"
  base="${base:-(default / session)}"
  provider="${provider:-?}"
  printf 'provider=%s  model=%s  base=%s' "$provider" "$model" "$base"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
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
  [[ -x "$CLIPROXY_BIN" ]] && echo "cliproxy bin: OK ($CLIPROXY_BIN)" || echo "cliproxy bin: MISSING ($CLIPROXY_BIN)"
  command -v litellm >/dev/null 2>&1 && echo "litellm:     OK ($(command -v litellm))" || echo "litellm:     not on PATH (uvx fallback ok)"
  command -v npx >/dev/null 2>&1 && echo "npx:         OK" || echo "npx:         MISSING"
  [[ -f "$HOME/.claude/.credentials.json" ]] && echo "claude oauth: present" || echo "claude oauth: missing (claude login)"
  [[ -f "$HOME/.codex/auth.json" ]] && echo "codex oauth:  present" || echo "codex oauth:  missing (codex login)"
  [[ -f "$HOME/.grok/auth.json" ]] && echo "grok oauth:   present" || echo "grok oauth:   missing (grok login)"
}

# ── install ─────────────────────────────────────────────────────────────────
write_cliproxy_tree() {
  mkdir -p "$CLIPROXY_DIR/scripts" "$HOME/.cli-proxy-api"
  if [[ ! -f "$CLIPROXY_DIR/config.yaml" ]]; then
    cat >"$CLIPROXY_DIR/config.yaml" <<EOF
host: "127.0.0.1"
port: ${CLIPROXY_PORT}
auth-dir: "~/.cli-proxy-api"
api-keys:
  - "${CLIPROXY_KEY}"
debug: true
logging-to-file: false
request-retry: 2
disable-cooling: true
ws-auth: false
remote-management:
  allow-remote: false
  secret-key: ""
  disable-control-panel: true
EOF
    log "wrote $CLIPROXY_DIR/config.yaml"
  fi
  cat >"$CLIPROXY_DIR/scripts/sync-claude-auth.sh" <<'EOF'
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
EOF
  cat >"$CLIPROXY_DIR/scripts/start.sh" <<EOF
#!/usr/bin/env bash
# Start CLIProxyAPI for Claude OAuth (Opus etc.) with tool support.
set -euo pipefail
ROOT="\$(cd "\$(dirname "\$0")/.." && pwd)"
BIN="\${CLIPROXY_BIN:-\$HOME/go/bin/server}"
CONFIG="\${CLIPROXY_CONFIG:-\$ROOT/config.yaml}"
LOG="\${CLIPROXY_LOG:-/tmp/cliproxy.log}"
PORT=${CLIPROXY_PORT}
KEY="${CLIPROXY_KEY}"

"\$ROOT/scripts/sync-claude-auth.sh"

if [ ! -x "\$BIN" ]; then
  echo "CLIProxyAPI binary not found at \$BIN" >&2
  echo "Install: go install github.com/router-for-me/CLIProxyAPI/v6/cmd/server@latest" >&2
  exit 1
fi

if command -v fuser >/dev/null 2>&1; then
  fuser -k "\${PORT}/tcp" 2>/dev/null || true
  sleep 0.3
fi

nohup "\$BIN" -config "\$CONFIG" >>"\$LOG" 2>&1 &
echo "CLIProxyAPI pid \$! log \$LOG"
for i in 1 2 3 4 5 6 7 8 9 10; do
  if curl -sf -m 1 -H "Authorization: Bearer \${KEY}" "http://127.0.0.1:\${PORT}/v1/models" >/dev/null; then
    echo "listening on http://127.0.0.1:\${PORT}/v1"
    exit 0
  fi
  sleep 0.5
done
echo "failed to become ready; see \$LOG" >&2
exit 1
EOF
  chmod +x "$CLIPROXY_DIR/scripts/start.sh" "$CLIPROXY_DIR/scripts/sync-claude-auth.sh"
}

install_cliproxy() {
  log "install CLIProxyAPI"
  need_cmd go
  if [[ ! -x "$CLIPROXY_BIN" ]]; then
    log "go install github.com/router-for-me/CLIProxyAPI/v6/cmd/server@latest"
    GOBIN="$(dirname "$CLIPROXY_BIN")" go install github.com/router-for-me/CLIProxyAPI/v6/cmd/server@latest
  else
    log "binary already present: $CLIPROXY_BIN"
  fi
  write_cliproxy_tree
  log "CLIProxyAPI install OK ($CLIPROXY_DIR)"
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
      if [[ -x "$CLIPROXY_BIN" ]]; then
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
    login-agents|logins)
      # install any missing login CLIs without prompting
      has_cmd claude || install_claude_cli
      resolve_grok_bin >/dev/null || install_grok_cli
      has_cmd codex || install_codex_cli
      ;;
    *) die "unknown install target: $target (all|cliproxy|litellm|openai-oauth|claude|grok|codex|login-agents)" ;;
  esac
  echo
  log "done. Next: adapters.sh start …  or  adapters.sh use <profile>"
}

# ── start / stop ────────────────────────────────────────────────────────────
start_cliproxy() {
  log "start CLIProxyAPI on :$CLIPROXY_PORT"
  if port_listening "$CLIPROXY_PORT"; then
    log "already listening on $CLIPROXY_PORT"
    return 0
  fi
  [[ -x "$CLIPROXY_BIN" ]] || die "CLIProxyAPI binary missing — run: adapters.sh install cliproxy"
  write_cliproxy_tree
  "$CLIPROXY_DIR/scripts/start.sh"
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
  local pids
  # Prefer fuser when available
  if command -v fuser >/dev/null 2>&1; then
    fuser -k "${port}/tcp" 2>/dev/null || true
  fi
  # Also kill known process patterns
  case "$label" in
    cliproxy)
      mapfile -t pids < <(pids_matching "CLIProxyAPI\|/go/bin/server -config\|cliproxy-api/config")
      # server -config is the real binary name path
      mapfile -t pids < <(pids_matching "$CLIPROXY_DIR/config.yaml")
      kill_pids "${pids[@]:-}"
      mapfile -t pids < <(pids_matching "go/bin/server")
      # only kill if cmdline has cliproxy config
      local pid cmd
      for pid in "${pids[@]:-}"; do
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
  local identity="${WRITE_IDENTITY:-1}"
  local comment="${WRITE_COMMENT:-Grok Bot custom inference}"

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
    echo "SAND_XAI_IDENTITY=${identity}"
  } >"$ENV_FILE"
  chmod 600 "$ENV_FILE" 2>/dev/null || true
  log "wrote $ENV_FILE"
  sed -E 's/((KEY|TOKEN|SECRET|PASSWORD)=).*/\1***/' "$ENV_FILE" | sed 's/^/  /'
}

patch_settings_model() {
  local model="$1"
  [[ -f "$SETTINGS_FILE" ]] || return 0
  python3 - "$SETTINGS_FILE" "$model" <<'PY'
import json, sys
path, model = sys.argv[1], sys.argv[2]
with open(path) as f:
    data = json.load(f)
adm = data.get("agentDefaultModel") or {}
adm["modelId"] = model
if "maxMode" not in adm:
    adm["maxMode"] = True
if "parameters" not in adm:
    adm["parameters"] = []
data["agentDefaultModel"] = adm
with open(path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
print(f"updated agentDefaultModel.modelId -> {model}")
PY
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

cmd_restart_host() {
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
    echo "  2) deepseek-chat"
    echo "  3) deepseek-reasoner"
    echo "  4) deepseek-coder"
    echo "  5) Other (type a model id)"
    if [[ -n "$current" ]]; then
      echo "  6) Keep current ($current)"
    fi
  } >"$_TTY_OUT"
  local choice
  choice="$(prompt_line "Choose 1-5${current:+/6}" "1")"
  case "$choice" in
    1|"") printf '%s' "deepseek-v4-flash" ;;
    2) printf '%s' "deepseek-chat" ;;
    3) printf '%s' "deepseek-reasoner" ;;
    4) printf '%s' "deepseek-coder" ;;
    5)
      local custom
      custom="$(prompt_line "Model id" "${current:-deepseek-v4-flash}")"
      [[ -n "$custom" ]] || die "model id cannot be empty"
      printf '%s' "$custom"
      ;;
    6)
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
  # sets: OPT_MODEL OPT_KEY OPT_BASE OPT_NO_RESTART OPT_THINKING OPT_AUTH
  OPT_MODEL=""
  OPT_KEY=""
  OPT_BASE=""
  OPT_NO_RESTART=0
  OPT_THINKING="disabled"
  OPT_AUTH="" # oauth | api_key (claude only)
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --model) OPT_MODEL="${2:-}"; shift 2 ;;
      --key) OPT_KEY="${2:-}"; shift 2 ;;
      --base-url|--base) OPT_BASE="${2:-}"; shift 2 ;;
      --thinking) OPT_THINKING="${2:-}"; shift 2 ;;
      --auth) OPT_AUTH="${2:-}"; shift 2 ;;
      --oauth) OPT_AUTH="oauth"; shift ;;
      --api-key|--console) OPT_AUTH="api_key"; shift ;;
      --no-restart) OPT_NO_RESTART=1; shift ;;
      --restart) OPT_NO_RESTART=0; shift ;;
      *) die "unknown flag: $1" ;;
    esac
  done
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
      local model
      if [[ -n "$OPT_MODEL" ]]; then model="$OPT_MODEL"
      elif [[ "$INTERACTIVE_MENU" -eq 1 ]]; then model="$(prompt_line "Grok model id" "grok-4.5")"
      else model="grok-4.5"; fi
      [[ -f "$HOME/.grok/auth.json" ]] || warn "no ~/.grok/auth.json — run: grok login"
      WRITE_COMMENT="Grok CLI session (cli-chat-proxy)" \
      WRITE_PROVIDER=xai WRITE_BASE_URL="" WRITE_MODEL="$model" WRITE_API_KEY="" \
        write_env_file
      patch_settings_model "$model"
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
      echo "  3) Install adapters    (CLIProxy / LiteLLM / openai-oauth)"
      echo "  4) Start adapters"
      echo "  5) Stop adapters"
      echo "  6) Restart Grok Bot host"
      echo "  7) Check / install login agents  (claude, grok, codex, …)"
      echo "  8) Help"
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
      3|install)
        target="$(menu_pick_adapter_target)"
        if [[ -n "$target" ]]; then
          cmd_install "$target" || true
          pause
        fi
        ;;
      4|start)
        target="$(menu_pick_adapter_target)"
        if [[ -n "$target" ]]; then
          cmd_start "$target" || true
          pause
        fi
        ;;
      5|stop)
        target="$(menu_pick_adapter_target)"
        if [[ -n "$target" ]]; then
          cmd_stop "$target" || true
          pause
        fi
        ;;
      6|restart)
        cmd_restart_host || true
        pause
        ;;
      7|logins|login-agents|check)
        ensure_login_agents_interactive || true
        pause
        ;;
      8|help|h)
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
  cat <<'EOF'
Grok Bot adapters CLI

INTERACTIVE (default)
  adapters.sh                 # full menu
  adapters.sh menu

MENU PATH
  1 Status
  2 Switch provider → DeepSeek / Claude / Grok / OpenAI / …
  3 Install adapters (CLIProxy / LiteLLM / openai-oauth)
  4 Start adapters
  5 Stop adapters
  6 Restart host
  7 Check / install login agents (claude, grok, codex) — asks if missing
  8 Help
  0 Quit

On launch, the menu scans for login agents. If any are missing, it asks
whether to install them (one-by-one). If installed but not logged in, it
shows the login command.

SCRIPTABLE
  adapters.sh status
  adapters.sh check-logins              # list login agent status
  adapters.sh install [all|cliproxy|litellm|openai-oauth|claude|grok|codex|login-agents]
  adapters.sh start   [all|cliproxy|litellm|openai-oauth]
  adapters.sh stop    [all|cliproxy|litellm|openai-oauth]
  adapters.sh use deepseek|claude|grok-session|openai|openrouter|…
  adapters.sh restart-host

  adapters.sh use deepseek              # prompts model + API key
  adapters.sh use claude                # prompts model + OAuth or Console key

Docs: /workspace/setup/docs/GUIDE_CUSTOM_INFERENCE.md
EOF
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
    install) cmd_install "${1:-all}" ;;
    start) cmd_start "${1:-all}" ;;
    stop) cmd_stop "${1:-all}" ;;
    use|switch) cmd_use "$@" ;;
    restart-host|restart) cmd_restart_host ;;
    *)
      if [[ "$cmd" == -* ]]; then
        die "unknown option: $cmd (try: adapters.sh help)"
      fi
      die "unknown command: $cmd (try: adapters.sh   or   adapters.sh help)"
      ;;
  esac
}

main "$@"
