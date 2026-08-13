#!/usr/bin/env bash
# Re-install xai-prompt-session.cjs and re-inject the host-main.cjs hook.
# Safe to run after a host bundle upgrade. Does not restart the host.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# scripts/ lives next to the repo root when shipped; also accept being copied
# into ~/sand-host/scripts (dest dir only — source file is still the repo copy
# or an already-installed session module).
if [[ -f "$SCRIPT_DIR/../xai-prompt-session.cjs" ]]; then
  ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
elif [[ -f "$SCRIPT_DIR/../../setup/xai-prompt-session.cjs" ]]; then
  ROOT="$(cd "$SCRIPT_DIR/../../setup" && pwd)"
else
  ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
fi

SAND_HOST="${SAND_HOST_DIR:-$HOME/sand-host}"
SRC="${XAI_SESSION_SRC:-$ROOT/xai-prompt-session.cjs}"
DEST="$SAND_HOST/xai-prompt-session.cjs"
HOST_MAIN="$SAND_HOST/host-main.cjs"
BACKUP="$SAND_HOST/host-main.cjs.cursor-bak"

log() { printf '+ %s\n' "$*"; }
warn() { printf '! %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ -f "$HOST_MAIN" ]] || die "missing $HOST_MAIN"
if [[ ! -f "$SRC" && -f "$DEST" ]]; then
  SRC="$DEST"
fi
[[ -f "$SRC" ]] || die "missing $SRC (xai-prompt-session.cjs)"

mkdir -p "$SAND_HOST/scripts"
if [[ "$SRC" != "$DEST" ]]; then
  cp "$SRC" "$DEST"
  log "installed $DEST"
else
  log "session module already at $DEST"
fi

# Keep a copy of this installer next to the host so the documented path works.
if [[ "$(readlink -f "$0" 2>/dev/null || echo "$0")" != "$(readlink -f "$SAND_HOST/scripts/ensure-xai-inference.sh" 2>/dev/null || true)" ]]; then
  cp "$0" "$SAND_HOST/scripts/ensure-xai-inference.sh"
  chmod +x "$SAND_HOST/scripts/ensure-xai-inference.sh" 2>/dev/null || true
fi

python3 - "$HOST_MAIN" "$BACKUP" <<'PY'
import pathlib, shutil, sys

host_main = pathlib.Path(sys.argv[1])
backup = pathlib.Path(sys.argv[2])
text = host_main.read_text(encoding="utf-8", errors="surrogateescape")

if "createXaiPromptSession" in text:
    print("hook already present")
    raise SystemExit(0)

anchor_tail = "      const session = createCursorInferencePromptSession({"
needle = """      const requestedModel = resolveSandRequestedModel({
        sessionOptions,
        envModelOverride: process.env.SAND_AGENT_MODEL,
        storedDefaultModel: options2.getDefaultModel?.(),
        storedComputerUseModel: options2.getComputerUseModel?.(),
        storedBrowserUseModel: options2.getBrowserUseModel?.(),
        experimentModelOverride
      });
      const session = createCursorInferencePromptSession({"""

hook = """      const requestedModel = resolveSandRequestedModel({
        sessionOptions,
        envModelOverride: process.env.SAND_AGENT_MODEL,
        storedDefaultModel: options2.getDefaultModel?.(),
        storedComputerUseModel: options2.getComputerUseModel?.(),
        storedBrowserUseModel: options2.getBrowserUseModel?.(),
        experimentModelOverride
      });
      const inferenceProvider = (process.env.SAND_INFERENCE_PROVIDER || "xai").toLowerCase();
      if (inferenceProvider !== "cursor") {
        try {
          const { createXaiPromptSession } = require("./xai-prompt-session.cjs");
          return createXaiPromptSession({
            requestedModel,
            onRequestId,
            sessionOptions
          });
        } catch (xaiErr) {
          console.error("[sand-xai] failed to create xAI session, falling back to Cursor:", xaiErr);
        }
      }
      const session = createCursorInferencePromptSession({"""

if needle not in text:
    # Fallback: insert immediately before the unique createCursorInferencePromptSession call
    if text.count(anchor_tail) != 1:
        print("ERROR: could not find unique createCursorSandInference anchor", file=sys.stderr)
        raise SystemExit(2)
    text = text.replace(
        anchor_tail,
        """      const inferenceProvider = (process.env.SAND_INFERENCE_PROVIDER || "xai").toLowerCase();
      if (inferenceProvider !== "cursor") {
        try {
          const { createXaiPromptSession } = require("./xai-prompt-session.cjs");
          return createXaiPromptSession({
            requestedModel,
            onRequestId,
            sessionOptions
          });
        } catch (xaiErr) {
          console.error("[sand-xai] failed to create xAI session, falling back to Cursor:", xaiErr);
        }
      }
""" + anchor_tail,
        1,
    )
else:
    text = text.replace(needle, hook, 1)

if not backup.exists():
    shutil.copy2(host_main, backup)
    print(f"backed up {backup}")

host_main.write_text(text, encoding="utf-8", errors="surrogateescape")
print("injected createXaiPromptSession hook")
PY

if grep -q createXaiPromptSession "$HOST_MAIN"; then
  log "hook OK ($(grep -c createXaiPromptSession "$HOST_MAIN") refs)"
else
  die "hook injection failed"
fi
