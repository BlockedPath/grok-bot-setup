#!/usr/bin/env bash
# Smashable tests for grok oauth keepalive (M1–M5). Never live login, never --go, never restart-host.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0

WORKDIR="$(mktemp -d /tmp/grok-auth-keepalive.XXXXXX)"
trap 'rm -rf "$WORKDIR"' EXIT

OUT_DIR="$WORKDIR/out"
mkdir -p "$OUT_DIR" "$WORKDIR/grok" "$WORKDIR/bin" "$WORKDIR/sand-host" \
         "$WORKDIR/agent-data/agents/test/automations/grok-session-recover" \
         "$WORKDIR/watchdog"

assert_exit() {
  local want="$1"
  local name="$2"
  shift 2
  local rc=0
  local tag
  tag="$(printf '%s' "$name" | tr -c 'A-Za-z0-9' '_')"
  local stdout="$OUT_DIR/${tag}.stdout"
  local stderr="$OUT_DIR/${tag}.stderr"
  "$@" >"$stdout" 2>"$stderr" || rc=$?
  if [[ "$rc" -eq "$want" ]]; then
    printf 'ok  %s (exit %s)\n' "$name" "$rc"
    PASS=$((PASS + 1))
  else
    printf 'FAIL %s (want %s got %s)\n' "$name" "$want" "$rc"
    sed 's/^/  out: /' "$stdout" | tail -20
    sed 's/^/  err: /' "$stderr" | tail -20
    FAIL=$((FAIL + 1))
  fi
}

assert_grep() {
  local file="$1"
  local needle="$2"
  local name="$3"
  if grep -q -- "$needle" "$file"; then
    printf 'ok  %s\n' "$name"
    PASS=$((PASS + 1))
  else
    printf 'FAIL %s (missing %s in %s)\n' "$name" "$needle" "$file"
    sed 's/^/  /' "$file" | tail -20
    FAIL=$((FAIL + 1))
  fi
}

assert_not_grep() {
  local file="$1"
  local needle="$2"
  local name="$3"
  if grep -q -- "$needle" "$file"; then
    printf 'FAIL %s (found %s in %s)\n' "$name" "$needle" "$file"
    sed 's/^/  /' "$file" | tail -20
    FAIL=$((FAIL + 1))
  else
    printf 'ok  %s\n' "$name"
    PASS=$((PASS + 1))
  fi
}

write_auth() {
  local dest="$1"
  local expires_at="$2"
  python3 - "$dest" "$expires_at" <<'PY'
import json, sys
dest, expires_at = sys.argv[1], sys.argv[2]
obj = {
    "https://auth.x.ai": {
        "key": "TEST_KEY_DO_NOT_LEAK",
        "refresh_token": "TEST_REFRESH_DO_NOT_LEAK",
        "expires_at": expires_at,
        "auth_mode": "oidc",
        "email": "secret@example.com",
    }
}
with open(dest, "w") as f:
    json.dump(obj, f)
PY
}

iso_offset() {
  python3 - "$1" <<'PY'
import datetime, sys
delta = int(sys.argv[1])
dt = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(seconds=delta)
print(dt.replace(microsecond=0).isoformat().replace("+00:00", "Z"))
PY
}

STATUS="$ROOT/bin/grok-auth-status"
REFRESH="$ROOT/scripts/refresh-grok-if-expired.sh"
CUTOVER="$ROOT/bin/grok-auth-cutover-status"
TOKEN_PY="$ROOT/scripts/token-expired.py"

export FLEET_ALLOW_TEST_OVERRIDES=1
export GROK_AUTH_FILE="$WORKDIR/grok/auth.json"
unset XAI_API_KEY GROK_CODE_XAI_API_KEY GROK_XAI_API_KEY GROK_SESSION_TOKEN || true

# --- token-expired.py (kept module) ---
write_auth "$GROK_AUTH_FILE" "$(iso_offset -3600)"
assert_exit 0 "token-expired.py expired prints 1" \
  python3 "$TOKEN_PY" "$GROK_AUTH_FILE"
assert_grep "$OUT_DIR/token_expired_py_expired_prints_1.stdout" '^1$' "token-expired.py expired -> 1"

write_auth "$GROK_AUTH_FILE" "$(iso_offset 36000)"
assert_exit 0 "token-expired.py ok prints 0" \
  python3 "$TOKEN_PY" "$GROK_AUTH_FILE"
assert_grep "$OUT_DIR/token_expired_py_ok_prints_0.stdout" '^0$' "token-expired.py ok -> 0"

# --- M1 probe ---
write_auth "$GROK_AUTH_FILE" "$(iso_offset 36000)"
assert_exit 0 "M1 ok exit 0" env GROK_AUTH_FILE="$GROK_AUTH_FILE" "$STATUS"
assert_grep "$OUT_DIR/M1_ok_exit_0.stdout" 'status=ok' "M1 ok status"
assert_grep "$OUT_DIR/M1_ok_exit_0.stdout" 'has_key=true' "M1 ok has_key"
assert_grep "$OUT_DIR/M1_ok_exit_0.stdout" 'exists=yes' "M1 ok exists"
assert_not_grep "$OUT_DIR/M1_ok_exit_0.stdout" 'TEST_KEY_DO_NOT_LEAK' "M1 ok does not print key"
assert_not_grep "$OUT_DIR/M1_ok_exit_0.stderr" 'TEST_KEY_DO_NOT_LEAK' "M1 ok stderr no key"
assert_not_grep "$OUT_DIR/M1_ok_exit_0.stdout" 'TEST_REFRESH_DO_NOT_LEAK' "M1 ok does not print refresh"
assert_not_grep "$OUT_DIR/M1_ok_exit_0.stdout" 'secret@example.com' "M1 ok does not print email"

write_auth "$GROK_AUTH_FILE" "$(iso_offset 1800)"
assert_exit 1 "M1 soon exit 1" env GROK_AUTH_FILE="$GROK_AUTH_FILE" "$STATUS"
assert_grep "$OUT_DIR/M1_soon_exit_1.stdout" 'status=soon' "M1 soon status"

write_auth "$GROK_AUTH_FILE" "$(iso_offset -7200)"
assert_exit 2 "M1 expired exit 2" env GROK_AUTH_FILE="$GROK_AUTH_FILE" "$STATUS"
assert_grep "$OUT_DIR/M1_expired_exit_2.stdout" 'status=EXPIRED' "M1 expired status"
assert_grep "$OUT_DIR/M1_expired_exit_2.stdout" 'seconds_left=' "M1 expired seconds_left"
assert_not_grep "$OUT_DIR/M1_expired_exit_2.stdout" 'TEST_KEY_DO_NOT_LEAK' "M1 expired does not print key"

assert_exit 2 "M1 missing file exit 2" env GROK_AUTH_FILE="$WORKDIR/missing-auth.json" "$STATUS"
assert_grep "$OUT_DIR/M1_missing_file_exit_2.stdout" 'status=EXPIRED' "M1 missing status EXPIRED"
assert_grep "$OUT_DIR/M1_missing_file_exit_2.stdout" 'exists=no' "M1 missing exists=no"

# --- M2 refresh ---
write_auth "$GROK_AUTH_FILE" "$(iso_offset 36000)"
assert_exit 0 "M2 skip when ok" env GROK_AUTH_FILE="$GROK_AUTH_FILE" "$REFRESH"
assert_grep "$OUT_DIR/M2_skip_when_ok.stdout" 'skip' "M2 prints skip"

# stub grok that rewrites expires_at into the future
cat > "$WORKDIR/bin/grok" << 'STUB'
#!/usr/bin/env bash
set -euo pipefail
auth="${GROK_AUTH_FILE:-}"
[[ -n "$auth" && -f "$auth" ]] || exit 1
python3 - "$auth" <<'PY'
import datetime, json, sys
path = sys.argv[1]
data = json.loads(open(path).read())
future = (datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(hours=10)).replace(microsecond=0)
iso = future.isoformat().replace("+00:00", "Z")
for v in data.values():
    if isinstance(v, dict) and "expires_at" in v:
        v["expires_at"] = iso
open(path, "w").write(json.dumps(data))
PY
STUB
chmod +x "$WORKDIR/bin/grok"

write_auth "$GROK_AUTH_FILE" "$(iso_offset -3600)"
assert_exit 0 "M2 refresh stub rewrites expiry" \
  env PATH="$WORKDIR/bin:$PATH" GROK_AUTH_FILE="$GROK_AUTH_FILE" "$REFRESH"
assert_exit 0 "M1 ok after stub refresh" env GROK_AUTH_FILE="$GROK_AUTH_FILE" "$STATUS"

# stub grok that no-ops
cat > "$WORKDIR/bin/grok" << 'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$WORKDIR/bin/grok"
write_auth "$GROK_AUTH_FILE" "$(iso_offset -3600)"
assert_exit 3 "M2 refresh-failed when grok no-ops" \
  env PATH="$WORKDIR/bin:$PATH" GROK_AUTH_FILE="$GROK_AUTH_FILE" "$REFRESH"
assert_grep "$OUT_DIR/M2_refresh_failed_when_grok_no_ops.stdout" 'refresh-failed' "M2 prints refresh-failed"

assert_not_grep "$REFRESH" 'grok login' "M2 script does not invoke grok login"
assert_not_grep "$REFRESH" 'rm ' "M2 script does not rm (auth.json)"

# --- M3 hook fail-closed (node) ---
assert_exit 0 "M3 node tests" node "$ROOT/scripts/test-grok-auth-keepalive.js"

# --- M5 cutover status ---
printf 'createXaiPromptSession(options)\n' > "$WORKDIR/sand-host/host-main.cjs"
printf '// session module\n' > "$WORKDIR/sand-host/xai-prompt-session.cjs"
printf '%s\n' '{"name":"Grok-session recover","enabled":false}' \
  > "$WORKDIR/agent-data/agents/test/automations/grok-session-recover/automation.json"
rm -f "$WORKDIR/watchdog/watchdog.pid"
write_auth "$GROK_AUTH_FILE" "$(iso_offset 36000)"

assert_exit 0 "M5 ok when oauth ok" \
  env FLEET_ALLOW_TEST_OVERRIDES=1 \
      GROK_AUTH_FILE="$GROK_AUTH_FILE" \
      SAND_HOST_DIR="$WORKDIR/sand-host" \
      FLEET_AGENT_DATA="$WORKDIR/agent-data" \
      FLEET_WATCHDOG_PIDFILE="$WORKDIR/watchdog/watchdog.pid" \
      "$CUTOVER"
assert_grep "$OUT_DIR/M5_ok_when_oauth_ok.stdout" 'hook: present' "M5 hook present"
assert_grep "$OUT_DIR/M5_ok_when_oauth_ok.stdout" 'watchdog: down' "M5 watchdog down"
assert_grep "$OUT_DIR/M5_ok_when_oauth_ok.stdout" 'recover: paused' "M5 recover paused"

write_auth "$GROK_AUTH_FILE" "$(iso_offset -60)"
assert_exit 2 "M5 non-zero when oauth expired" \
  env FLEET_ALLOW_TEST_OVERRIDES=1 \
      GROK_AUTH_FILE="$GROK_AUTH_FILE" \
      SAND_HOST_DIR="$WORKDIR/sand-host" \
      FLEET_AGENT_DATA="$WORKDIR/agent-data" \
      FLEET_WATCHDOG_PIDFILE="$WORKDIR/watchdog/watchdog.pid" \
      "$CUTOVER"

echo "$$" > "$WORKDIR/watchdog/watchdog.pid"
write_auth "$GROK_AUTH_FILE" "$(iso_offset 36000)"
assert_exit 0 "M5 reports watchdog alive (does not start it)" \
  env FLEET_ALLOW_TEST_OVERRIDES=1 \
      GROK_AUTH_FILE="$GROK_AUTH_FILE" \
      SAND_HOST_DIR="$WORKDIR/sand-host" \
      FLEET_AGENT_DATA="$WORKDIR/agent-data" \
      FLEET_WATCHDOG_PIDFILE="$WORKDIR/watchdog/watchdog.pid" \
      "$CUTOVER"
assert_grep "$OUT_DIR/M5_reports_watchdog_alive__does_not_start_it_.stdout" 'watchdog: alive' "M5 watchdog alive"

assert_exit 2 "M5 refuses --go" \
  env FLEET_ALLOW_TEST_OVERRIDES=1 \
      GROK_AUTH_FILE="$GROK_AUTH_FILE" \
      SAND_HOST_DIR="$WORKDIR/sand-host" \
      FLEET_AGENT_DATA="$WORKDIR/agent-data" \
      FLEET_WATCHDOG_PIDFILE="$WORKDIR/watchdog/watchdog.pid" \
      "$CUTOVER" --go

assert_not_grep "$CUTOVER" 'restart-host' "M5 does not restart-host"
assert_not_grep "$CUTOVER" 'adapters.sh recover' "M5 does not call recover"
assert_not_grep "$CUTOVER" 'fleet-heavy' "M5 does not call fleet-heavy"

# --- docs ---
assert_grep "$ROOT/docs/GROK_AUTH_KEEPALIVE.md" 'Two-door' "M4 names two-door rule"
assert_grep "$ROOT/docs/GROK_AUTH_KEEPALIVE.md" 'grok login --device-auth' "M4 names human login"
assert_grep "$ROOT/docs/GROK_AUTH_KEEPALIVE.md" 'M1' "M4 names M1"
assert_grep "$ROOT/docs/GROK_AUTH_KEEPALIVE.md" 'Do not' "M4 has do-not for recover/watchdog"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
if [[ "$FAIL" -ne 0 ]]; then
  exit 1
fi
exit 0
