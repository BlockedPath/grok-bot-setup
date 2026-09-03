#!/usr/bin/env bash
# Desktop terminal on box@cursor ONLY. Not CoS chat.
# PR #5: copy session module, upgrade hook to pass hostOptions, restart-host once.
# No Pump Codex. No fleet-heavy --go. Watchdog stays.
set -euo pipefail
SETUP=/home/box/grok-bot-setup
cd "$SETUP"
git fetch https://github.com/BlockedPath/grok-bot-setup.git refs/pull/5/head
git checkout FETCH_HEAD -- xai-prompt-session.cjs scripts/ensure-xai-inference.sh
chmod +x scripts/ensure-xai-inference.sh
cp xai-prompt-session.cjs /home/box/sand-host/xai-prompt-session.cjs
bash scripts/ensure-xai-inference.sh
if ! grep -q '^SAND_XAI_DUMP_SESSION_KEYS=' /home/box/sand-data/xai-inference.env; then
  echo SAND_XAI_DUMP_SESSION_KEYS=1 >> /home/box/sand-data/xai-inference.env
fi
bash "$SETUP/adapters.sh" restart-host
echo NEXT: hard-refresh Grok Bot, ping CoS, then:
echo grep sand-xai /tmp/sand-host-manual.log
echo Comment hostOptions keys on GitHub PR 5
