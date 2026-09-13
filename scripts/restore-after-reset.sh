#!/usr/bin/env bash
# After a Sand wipe: reinstall the host hook, CLIProxy v7, and Management Center
# from this repo. Secrets (claude login, Meta API keys) are not in git.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECKOUT="${GROK_BOT_SETUP_DIR:-$HOME/grok-bot-setup}"

run_validated_runtime() {
  local base="$1" release
  release="$(python3 - "$base" <<'PY'
import hashlib, json, pathlib, sys
base = pathlib.Path(sys.argv[1]).resolve()
current = base / "current"
if not current.is_symlink():
    raise SystemExit("ERROR: persisted recovery current is not a symlink")
release = current.resolve(strict=True)
release.relative_to((base / "releases").resolve())
manifest = json.loads((release / "manifest.json").read_text(encoding="utf-8"))
if manifest.get("schema") != 1 or manifest.get("component") != "host-recovery-runtime":
    raise SystemExit("ERROR: invalid persisted recovery manifest")
files = manifest.get("files")
if not isinstance(files, dict) or not files:
    raise SystemExit("ERROR: empty persisted recovery manifest")
actual = {
    str(path.relative_to(release))
    for path in release.rglob("*")
    if path.is_file() and path.name != "manifest.json"
}
if actual != set(files):
    raise SystemExit("ERROR: persisted recovery contents do not match manifest")
for logical, metadata in files.items():
    path = release / logical
    logical_path = pathlib.PurePosixPath(logical)
    if logical_path.is_absolute() or ".." in logical_path.parts or path.is_symlink():
        raise SystemExit("ERROR: unsafe persisted recovery path")
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    if digest != metadata.get("sha256"):
        raise SystemExit(f"ERROR: persisted recovery checksum mismatch: {logical}")
    if path.stat().st_mode & 0o777 != metadata.get("mode"):
        raise SystemExit(f"ERROR: persisted recovery mode mismatch: {logical}")
expected = hashlib.sha256(
    json.dumps(manifest, sort_keys=True, separators=(",", ":")).encode()
).hexdigest()
if release.name != expected:
    raise SystemExit("ERROR: persisted recovery release id mismatch")
print(release)
PY
)" || return 1
  [[ -x "$release/scripts/recover-host-services.sh" ]] || return 1
  echo "+ checkout unavailable; running narrow validated host-service recovery" >&2
  exec "$release/scripts/recover-host-services.sh" recover
}

if [[ -x "$ROOT/adapters.sh" ]]; then
  ADAPTERS="$ROOT/adapters.sh"
elif [[ -x "$CHECKOUT/adapters.sh" ]]; then
  ADAPTERS="$CHECKOUT/adapters.sh"
else
  run_validated_runtime "$ROOT/recovery-runtime" ||
    run_validated_runtime "${GROK_RECOVERY_RUNTIME_DIR:-$HOME/.local/share/grok-bot-persist/recovery-runtime}" ||
    {
      # When this wrapper itself is inside releases/<id>/scripts.
      if [[ -f "$ROOT/manifest.json" ]]; then
        run_validated_runtime "$(cd "$ROOT/../.." && pwd)"
      else
        false
      fi
    } || {
      echo "ERROR: no checkout or validated persisted recovery runtime found" >&2
      exit 1
    }
fi

exec "$ADAPTERS" recover "$@"
