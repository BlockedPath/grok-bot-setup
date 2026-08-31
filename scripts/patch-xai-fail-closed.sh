#!/usr/bin/env bash
# Flip createXaiPromptSession catch from Cursor fallback → fail-closed throw.
# Safe to re-run. Does not restart the host.
set -euo pipefail
HOST_MAIN="${1:-${SAND_HOST_MAIN:-$HOME/sand-host/host-main.cjs}}"
[[ -f "$HOST_MAIN" ]] || { echo "missing $HOST_MAIN" >&2; exit 1; }
python3 - "$HOST_MAIN" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
text = p.read_text(encoding="utf-8", errors="surrogateescape")
old = 'console.error("[sand-xai] failed to create xAI session, falling back to Cursor:", xaiErr);'
# tolerate whitespace variants already fail-closed
if "fail-closed, no Cursor fallback" in text:
    print("already fail-closed")
    raise SystemExit(0)
if old not in text:
    # try multiline catch body: log then fall through
    import re
    pat = re.compile(
        r'console\.error\(\s*"\[sand-xai\] failed to create xAI session, falling back to Cursor:"\s*,\s*xaiErr\s*\);\s*',
        re.M,
    )
    if not pat.search(text):
        print("ERROR: Cursor-fallback catch not found — inspect hook manually", file=sys.stderr)
        raise SystemExit(2)
    text2, n = pat.subn(
        'console.error("[sand-xai] failed to create xAI session (fail-closed, no Cursor fallback):", xaiErr);\n          throw xaiErr;\n',
        text,
        count=2,
    )
else:
    text2 = text.replace(
        old,
        'console.error("[sand-xai] failed to create xAI session (fail-closed, no Cursor fallback):", xaiErr);\n          throw xaiErr;',
    )
    n = 1 if text2 != text else 0
if text2 == text:
    print("ERROR: no change applied", file=sys.stderr)
    raise SystemExit(2)
bak = p.with_suffix(p.suffix + ".bak-failclosed")
bak.write_bytes(p.read_bytes())
p.write_text(text2, encoding="utf-8", errors="surrogateescape")
print(f"patched fail-closed ({n} site(s)); backup {bak}")
PY
