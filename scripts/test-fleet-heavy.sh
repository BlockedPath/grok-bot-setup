#!/usr/bin/env bash
# Smashable tests for bin/fleet-heavy. Never call live adapters or --go on the host.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FLEET="$ROOT/bin/fleet-heavy"
PASS=0
FAIL=0

assert_exit() {
  local want="$1"
  local name="$2"
  shift 2
  local rc=0
  "$@" >/tmp/fleet-test-out 2>/tmp/fleet-test-err || rc=$?
  if [[ "$rc" -eq "$want" ]]; then
    printf 'ok  %s (exit %s)\n' "$name" "$rc"
    PASS=$((PASS + 1))
  else
    printf 'FAIL %s (want %s got %s)\n' "$name" "$want" "$rc"
    sed 's/^/  out: /' /tmp/fleet-test-out | tail -20
    sed 's/^/  err: /' /tmp/fleet-test-err | tail -20
    FAIL=$((FAIL + 1))
  fi
}

assert_not_in() {
  local needle="$1"
  local file="$2"
  local name="$3"
  if grep -q -- "$needle" "$file"; then
    printf 'FAIL %s (found %s in %s)\n' "$name" "$needle" "$file"
    FAIL=$((FAIL + 1))
  else
    printf 'ok  %s\n' "$name"
    PASS=$((PASS + 1))
  fi
}

WORKDIR="$(mktemp -d /tmp/fleet-heavy-test.XXXXXX)"
trap 'rm -rf "$WORKDIR"' EXIT

mkdir -p "$WORKDIR/agent-data/agent-transcripts/tiny" \
         "$WORKDIR/agent-data/agents/test/automations/grok-session-recover" \
         "$WORKDIR/watchdog" \
         "$WORKDIR/grok"
printf '{}\n' > "$WORKDIR/grok/auth.json"
printf 'paused chat\n' > "$WORKDIR/agent-data/agent-transcripts/tiny/tiny.jsonl"
touch -d "10 minutes ago" "$WORKDIR/agent-data/agent-transcripts/tiny/tiny.jsonl"
printf '%s\n' '{"name":"Grok-session recover","enabled":false}' \
  > "$WORKDIR/agent-data/agents/test/automations/grok-session-recover/automation.json"

cat > "$WORKDIR/stub-adapters" << 'STUB'
#!/usr/bin/env bash
log="${FLEET_STUB_LOG:-/tmp/fleet-stub.log}"
printf '%s\n' "$*" >> "$log"
if [[ "${1:-}" == "status" ]]; then
  echo "provider: cursor"
  echo "host: up"
  echo "grok oauth: present"
  exit 0
fi
if [[ "${1:-}" == "use" ]]; then
  echo "STUB_USE $*"
  exit 0
fi
echo "STUB $*"
STUB
chmod +x "$WORKDIR/stub-adapters" "$FLEET" "$ROOT/bin/fleet-status"

# Harness overrides are gated. Without the allow flag they must be ignored.
export FLEET_ALLOW_TEST_OVERRIDES=1
export FLEET_FORCE_OUTSIDE=1
export FLEET_ADAPTERS="$WORKDIR/stub-adapters"
export FLEET_AGENT_DATA="$WORKDIR/agent-data"
export FLEET_TRANSCRIPTS="$WORKDIR/agent-data/agent-transcripts"
export FLEET_GROK_AUTH="$WORKDIR/grok/auth.json"
export FLEET_WATCHDOG_PIDFILE="$WORKDIR/watchdog/watchdog.pid"
export FLEET_HOT_SECONDS=15
export FLEET_STUB_LOG="$WORKDIR/stub.log"
: > "$FLEET_STUB_LOG"

assert_exit 2 "refuse without --i-am-outside-chat" \
  env FLEET_FORCE_OUTSIDE=1 "$FLEET"

assert_exit 2 "refuse if inside sand-host" \
  env FLEET_FORCE_OUTSIDE=0 FLEET_FORCE_INSIDE=1 "$FLEET" --i-am-outside-chat

# Prod must ignore FORCE_INSIDE without the allow flag.
# Without overrides, this VPS lacks office agent-data → refuse missing state, NOT sand-host.
assert_exit 2 "FORCE_INSIDE ignored without allow flag" \
  env -u FLEET_ALLOW_TEST_OVERRIDES FLEET_FORCE_INSIDE=1 "$FLEET" --i-am-outside-chat
if grep -q 'running under sand-host' /tmp/fleet-test-err; then
  printf 'FAIL FORCE_INSIDE without allow still tripped sand gate\n'
  FAIL=$((FAIL + 1))
else
  printf 'ok  FORCE_INSIDE without allow did not trip sand gate\n'
  PASS=$((PASS + 1))
fi
assert_exit 2 "allow+FORCE_INSIDE still refuses" \
  env FLEET_ALLOW_TEST_OVERRIDES=1 FLEET_FORCE_OUTSIDE=0 FLEET_FORCE_INSIDE=1 \
  "$FLEET" --i-am-outside-chat
if ! grep -q 'running under sand-host' /tmp/fleet-test-err; then
  printf 'FAIL allow+FORCE_INSIDE should refuse via sand gate\n'
  FAIL=$((FAIL + 1))
else
  printf 'ok  allow+FORCE_INSIDE refused via sand gate\n'
  PASS=$((PASS + 1))
fi
printf '%s\n' '{"name":"Grok-session recover","enabled":true}' \
  > "$WORKDIR/agent-data/agents/test/automations/grok-session-recover/automation.json"
assert_exit 2 "refuse if recover enabled" \
  "$FLEET" --i-am-outside-chat
printf '%s\n' 'NOT-JSON' \
  > "$WORKDIR/agent-data/agents/test/automations/grok-session-recover/automation.json"
assert_exit 2 "refuse if recover JSON invalid" \
  "$FLEET" --i-am-outside-chat
printf '%s\n' '{"name":"Grok-session recover","enabled":false}' \
  > "$WORKDIR/agent-data/agents/test/automations/grok-session-recover/automation.json"

echo "$$" > "$WORKDIR/watchdog/watchdog.pid"
assert_exit 2 "refuse if watchdog running" \
  "$FLEET" --i-am-outside-chat
rm -f "$WORKDIR/watchdog/watchdog.pid"

assert_exit 2 "refuse if no grok oauth" \
  env FLEET_GROK_AUTH="$WORKDIR/missing-auth.json" "$FLEET" --i-am-outside-chat

assert_exit 2 "refuse if transcripts missing" \
  env FLEET_TRANSCRIPTS="$WORKDIR/missing-transcripts" "$FLEET" --i-am-outside-chat

chmod 000 "$WORKDIR/agent-data"
assert_exit 2 "refuse if agent-data unreadable" \
  "$FLEET" --i-am-outside-chat
chmod 755 "$WORKDIR/agent-data"
# restore nested perms after parent chmod 000
chmod -R u+rwX "$WORKDIR/agent-data" 2>/dev/null || true

touch "$WORKDIR/agent-data/agent-transcripts/tiny/tiny.jsonl"
assert_exit 2 "refuse if jsonl hot" \
  env FLEET_HOT_SECONDS=60 "$FLEET" --i-am-outside-chat
touch -d "10 minutes ago" "$WORKDIR/agent-data/agent-transcripts/tiny/tiny.jsonl"

# Equality boundary: mtime == CUTOVER_T0 must refuse (at or after).
T0=$(( $(date +%s) - 30 ))
touch -d "@${T0}" "$WORKDIR/agent-data/agent-transcripts/tiny/tiny.jsonl"
assert_exit 2 "refuse if jsonl mtime equals cutover t0" \
  env FLEET_HOT_SECONDS=1 FLEET_CUTOVER_T0="$T0" \
  "$FLEET" --i-am-outside-chat
touch -d "10 minutes ago" "$WORKDIR/agent-data/agent-transcripts/tiny/tiny.jsonl"

# Strictly after T0, outside hot window.
touch -d "5 seconds ago" "$WORKDIR/agent-data/agent-transcripts/tiny/tiny.jsonl"
assert_exit 2 "refuse if jsonl mutated since cutover t0" \
  env FLEET_HOT_SECONDS=1 FLEET_CUTOVER_T0="$(( $(date +%s) - 30 ))" \
  "$FLEET" --i-am-outside-chat
touch -d "10 minutes ago" "$WORKDIR/agent-data/agent-transcripts/tiny/tiny.jsonl"

: > "$FLEET_STUB_LOG"
assert_exit 0 "dry-run succeeds" \
  "$FLEET" --i-am-outside-chat
assert_not_in "use grok-session" "$FLEET_STUB_LOG" "dry-run did not call adapters use"
if grep -q "^status$" "$FLEET_STUB_LOG"; then
  printf 'ok  dry-run called adapters status\n'
  PASS=$((PASS + 1))
else
  printf 'FAIL dry-run should call adapters status\n'
  FAIL=$((FAIL + 1))
fi

: > "$FLEET_STUB_LOG"
assert_exit 0 "go against stub adapters" \
  "$FLEET" --i-am-outside-chat --go
if grep -q "use grok-session --model grok-4.6 --effort medium" "$FLEET_STUB_LOG"; then
  printf 'ok  go called stub with medium effort\n'
  PASS=$((PASS + 1))
else
  printf 'FAIL go did not call stub use grok-session medium\n'
  cat "$FLEET_STUB_LOG"
  FAIL=$((FAIL + 1))
fi

if grep -q "adapters.sh" "$FLEET_STUB_LOG"; then
  printf 'FAIL stub log mentions adapters.sh\n'
  FAIL=$((FAIL + 1))
else
  printf 'ok  stub log has no live adapters.sh path\n'
  PASS=$((PASS + 1))
fi

: > "$FLEET_STUB_LOG"
assert_exit 0 "status without flag" \
  "$FLEET" status
assert_not_in "use grok-session" "$FLEET_STUB_LOG" "status did not call adapters use"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
