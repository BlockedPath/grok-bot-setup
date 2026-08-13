#!/usr/bin/env bash
# After a Sand wipe: reinstall the host hook, CLIProxy v7, and Management Center
# from this repo. Secrets (claude login, Meta API keys) are not in git.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec "$ROOT/adapters.sh" recover "$@"
