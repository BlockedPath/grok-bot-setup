#!/usr/bin/env bash
# One-shot after a VM / Sand wipe.
#   curl -fsSL https://raw.githubusercontent.com/BlockedPath/grok-bot-setup/main/scripts/bootstrap.sh | bash
set -euo pipefail

REPO_URL="${GROK_BOT_SETUP_REPO:-https://github.com/BlockedPath/grok-bot-setup.git}"
DEST="${GROK_BOT_SETUP_DIR:-$HOME/grok-bot-setup}"
REF="${GROK_BOT_SETUP_REF:-main}"

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
  # Never erase local fixes or switch branches behind the user's back.
  current_ref="$(git -C "$DEST" symbolic-ref --short HEAD)"
  [[ "$current_ref" == "$REF" ]] || {
    echo "ERROR: checkout is on $current_ref, requested $REF; resolve explicitly before recovery" >&2
    exit 1
  }
  [[ -z "$(git -C "$DEST" status --porcelain)" ]] || {
    echo "ERROR: local changes present; commit/back up them before recovery" >&2
    exit 1
  }
  git -C "$DEST" merge --ff-only "origin/$REF"
elif [[ -f "$DEST/adapters.sh" ]]; then
  echo "+ using existing $DEST"
else
  echo "+ cloning $REPO_URL → $DEST"
  mkdir -p "$(dirname "$DEST")"
  git clone --branch "$REF" --depth 1 "$REPO_URL" "$DEST"
fi

chmod +x "$DEST/adapters" "$DEST/adapters.sh" "$DEST/scripts/"*.sh 2>/dev/null || true
exec "$DEST/adapters.sh" recover
