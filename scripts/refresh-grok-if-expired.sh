#!/usr/bin/env bash
# Silent grok CLI ping when ~/.grok/auth.json access token is expired.
# Never prints tokens, env files, or keys. Never deletes the login file.
# Never runs grok login interactively.
set -u
auth="$HOME/.grok/auth.json"
[[ -f "$auth" ]] || exit 0
command -v grok >/dev/null 2>&1 || exit 0
py="$HOME/.local/share/grok-bot-adapters/host-hook-watchdog/token-expired.py"
[[ -f "$py" ]] || py="$(dirname "$0")/token-expired.py"
[[ -f "$py" ]] || exit 0
expired="$(python3 "$py" "$auth" 2>/dev/null || echo 0)"
[[ "$expired" == "1" ]] || exit 0
grok models >/dev/null 2>&1 || true
