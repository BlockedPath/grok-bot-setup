#!/usr/bin/env bash
# Wrapper: unit tests for agent-inference-policy. Never live host.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec node "$ROOT/scripts/test-agent-inference-policy.js"
