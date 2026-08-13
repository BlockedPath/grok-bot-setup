#!/usr/bin/env bash
# One-shot after a VM / Sand wipe.
#   curl -fsSL https://raw.githubusercontent.com/BlockedPath/grok-bot-setup/main/scripts/bootstrap.sh | bash
set -euo pipefail

REPO_URL="${GROK_BOT_SETUP_REPO:-https://github.com/BlockedPath/grok-bot-setup.git}"
DEST="${GROK_BOT_SETUP_DIR:-$HOME/grok-bot-setup}"

# If this file is already inside a checkout, use that.
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
  _here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd 2>/dev/null || true)"
  if [[ -n "${_here:-}" && -f "$_here/adapters.sh" && -f "$_here/xai-prompt-session.cjs" ]]; then
    DEST="$_here"
  fi
fi

if [[ -d "$DEST/.git" ]]; then
  echo "+ updating $DEST"
  git -C "$DEST" fetch --prune origin
  git -C "$DEST" checkout main
  git -C "$DEST" reset --hard origin/main
elif [[ -f "$DEST/adapters.sh" ]]; then
  echo "+ using existing $DEST"
else
  echo "+ cloning $REPO_URL → $DEST"
  mkdir -p "$(dirname "$DEST")"
  git clone --branch main --depth 1 "$REPO_URL" "$DEST"
fi

chmod +x "$DEST/adapters" "$DEST/adapters.sh" "$DEST/scripts/"*.sh 2>/dev/null || true
exec "$DEST/adapters.sh" recover
