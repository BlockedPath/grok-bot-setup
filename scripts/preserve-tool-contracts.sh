#!/usr/bin/env bash
# Verified, versioned local recovery copy outside both checkout and sand-host.
# A full VM wipe still requires the off-VM Git backup documented in TOOL_FIX_RECOVERY.md.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE="${GROK_TOOL_FIX_BACKUP_DIR:-$HOME/.local/share/grok-bot-persist/tool-contracts}"
mkdir -p "$BASE/releases"
BASE="$(cd "$BASE" && pwd)"
stage="$(mktemp -d "$BASE/releases/.staging.XXXXXX")"
trap '[[ -z "${stage:-}" ]] || rm -rf -- "$stage"' EXIT
mkdir -p "$stage/scripts" "$stage/tests"
files=(
  xai-prompt-session.cjs
  scripts/ensure-xai-inference.sh
  scripts/verify-tool-patch.sh
  scripts/restore-tool-contracts.sh
  scripts/preserve-tool-contracts.sh
  tests/machine-id.cjs
  tests/end-turn.cjs
)
for file in "${files[@]}"; do
  cp "$ROOT/$file" "$stage/$file"
done
node --check "$stage/xai-prompt-session.cjs"
node "$stage/tests/machine-id.cjs"
node "$stage/tests/end-turn.cjs"
for file in "$stage/scripts/"*.sh; do bash -n "$file"; done
(cd "$stage" && sha256sum "${files[@]}" > SHA256SUMS)
release="$(sha256sum "$stage/SHA256SUMS" | cut -d ' ' -f 1)"
if [[ -d "$BASE/releases/$release" ]]; then
  (cd "$BASE/releases/$release" && sha256sum --check --status SHA256SUMS)
else
  mv "$stage" "$BASE/releases/$release"
  stage=""
fi
python3 - "$BASE" "$release" <<'PY'
import os, pathlib, sys
base, release = pathlib.Path(sys.argv[1]), sys.argv[2]
link = base / ('.current-' + str(os.getpid()))
try:
    link.symlink_to('releases/' + release)
    os.replace(link, base / 'current')
finally:
    if link.is_symlink():
        link.unlink()
PY
printf 'Verified recovery snapshot: %s/releases/%s\n' "$BASE" "$release"
printf 'Restore (no restart): bash %s/current/scripts/restore-tool-contracts.sh\n' "$BASE"
