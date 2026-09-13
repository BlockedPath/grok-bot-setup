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

python3 - "$HOST_MAIN" <<'PY'
import pathlib, sys
host_main = pathlib.Path(sys.argv[1])
text = host_main.read_text(encoding="utf-8", errors="surrogateescape")
old = 'SAND_DEFAULT_MODEL_ID = "grok-4.5"'
new = 'SAND_DEFAULT_MODEL_ID = process.env.SAND_AGENT_MODEL || process.env.SAND_XAI_MODEL || "grok-4.6"'
if old in text:
    host_main.write_text(text.replace(old, new, 1), encoding="utf-8", errors="surrogateescape")
    print("pinned SAND_DEFAULT_MODEL_ID to SAND_XAI_MODEL/grok-4.6")
elif "SAND_DEFAULT_MODEL_ID = process.env.SAND_AGENT_MODEL" in text:
    print("SAND_DEFAULT_MODEL_ID already follows env")
else:
    print("SAND_DEFAULT_MODEL_ID pin skipped (anchor missing)")
PY

python3 - "$HOST_MAIN" "$BACKUP" <<'PY'
import pathlib, shutil, sys

host_main = pathlib.Path(sys.argv[1])
backup = pathlib.Path(sys.argv[2])
text = host_main.read_text(encoding="utf-8", errors="surrogateescape")

if "createXaiPromptSession" in text:
    print("hook already present")
    raise SystemExit(0)

HOOK_BODY = """      const inferenceProvider = (process.env.SAND_INFERENCE_PROVIDER || "xai").toLowerCase();
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
"""

# Current host (2026-09): resolveSandRequestedModel -> inferenceOptions -> return createCursor...
needle_new = """      const requestedModel = resolveSandRequestedModel({
        sessionOptions,
        envModelOverride: options2.agentModelOverride,
        storedDefaultModel: options2.getDefaultModel?.(),
        storedComputerUseModel: options2.getComputerUseModel?.(),
        storedBrowserUseModel: options2.getBrowserUseModel?.(),
        experimentModelOverride
      });
      const inferenceOptions = {"""

hook_new = """      const requestedModel = resolveSandRequestedModel({
        sessionOptions,
        envModelOverride: options2.agentModelOverride,
        storedDefaultModel: options2.getDefaultModel?.(),
        storedComputerUseModel: options2.getComputerUseModel?.(),
        storedBrowserUseModel: options2.getBrowserUseModel?.(),
        experimentModelOverride
      });
""" + HOOK_BODY + """      const inferenceOptions = {"""

# Older host: resolveSandRequestedModel -> const session = createCursor...( {
needle_old = """      const requestedModel = resolveSandRequestedModel({
        sessionOptions,
        envModelOverride: process.env.SAND_AGENT_MODEL,
        storedDefaultModel: options2.getDefaultModel?.(),
        storedComputerUseModel: options2.getComputerUseModel?.(),
        storedBrowserUseModel: options2.getBrowserUseModel?.(),
        experimentModelOverride
      });
      const session = createCursorInferencePromptSession({"""

hook_old = """      const requestedModel = resolveSandRequestedModel({
        sessionOptions,
        envModelOverride: process.env.SAND_AGENT_MODEL,
        storedDefaultModel: options2.getDefaultModel?.(),
        storedComputerUseModel: options2.getComputerUseModel?.(),
        storedBrowserUseModel: options2.getBrowserUseModel?.(),
        experimentModelOverride
      });
""" + HOOK_BODY + """      const session = createCursorInferencePromptSession({"""

applied = None
if needle_new in text:
    text = text.replace(needle_new, hook_new, 1)
    applied = "needle_new"
elif needle_old in text:
    text = text.replace(needle_old, hook_old, 1)
    applied = "needle_old"
else:
    candidates = [
        "      return createCursorInferencePromptSession(inferenceOptions);",
        "      const session = createCursorInferencePromptSession({",
    ]
    for anchor in candidates:
        if text.count(anchor) == 1:
            idx = text.find(anchor)
            window = text[max(0, idx - 1200):idx]
            if "requestedModel" not in window:
                continue
            text = text.replace(anchor, HOOK_BODY + anchor, 1)
            applied = f"anchor:{anchor.strip()[:48]}"
            break
    if applied is None:
        print("ERROR: could not find createCursorSandInference inject anchor", file=sys.stderr)
        raise SystemExit(2)

if not backup.exists():
    shutil.copy2(host_main, backup)
    print(f"backed up {backup}")

host_main.write_text(text, encoding="utf-8", errors="surrogateescape")
print(f"injected createXaiPromptSession hook ({applied})")
PY

if grep -q createXaiPromptSession "$HOST_MAIN"; then
  log "hook OK ($(grep -c createXaiPromptSession "$HOST_MAIN") refs)"
else
  die "hook injection failed"
fi
