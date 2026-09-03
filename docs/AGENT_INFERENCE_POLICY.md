# Agent inference policy (effort matrix + optional per-agent provider)

**Status:** overlay on Heavy. Ricky ruling 1 Sep 2026: this slice is **effort only**. Next module is per-agent **model** (Pump → Codex as the proof).

## This slice (effort)

| Agent | UUID | Provider | Model | Effort |
|---|---|---|---|---|
| CoS | `5cadd652-…` | grok-heavy | grok-4.6 | **high** |
| Development | `7a4ecb2d-…` | grok-heavy | grok-4.6 | **high** |
| Pump | `8ae9a103-…` | grok-heavy | grok-4.6 | **high** |
| Finance + everyone else | — | grok-heavy | grok-4.6 | **medium** |

## Next module (not this deploy)

Flip Pump’s policy row to `provider: codex` / local `127.0.0.1:10531`. Codex code path stays in the hook (fail closed, no Cursor fallback). Do not enable it until slice-0 proves `agentId`.

## What it does

`xai-prompt-session.cjs` reads `/home/box/sand-data/agent-inference-policy.json` (override with `SAND_AGENT_INFERENCE_POLICY`) on each session.

- Missing/unreadable policy → **fail closed** (`provider=policy-missing`). Does **not** default anyone (including Pump) to grok-heavy.
- Pump UUID without an explicit policy row → `policy-row-missing` (never silent default).
- `extractAgentId` allowlist only: `agentId` / `agent.id` (ignores `source_agent_id` / `target_agent_id`).
- Unknown UUID (with policy present) → medium + WARN.
- `provider: codex` (next module) → `http://127.0.0.1:10531/v1` with dummy Bearer `openai-oauth`. **Fail closed** if `~/.codex/auth.json` missing or proxy down — no Grok fallback, no Cursor fallback.
- Hook install (`ensure-xai-inference.sh`) **rethrows** on create failure (no Cursor catch).
- Policy reads into **locals**. Never write `SAND_XAI_*` into `process.env`.

**Before trusting high (or later Pump→Codex) — slice 0 (log-only):** set `SAND_XAI_DUMP_SESSION_KEYS=1` in `xai-inference.env` (or the host env), restart once, ping CoS and Pump, then:

```bash
grep 'sessionOptions keys' /tmp/sand-host-manual.log | tail -20
grep '\[sand-xai\] agent=' /tmp/sand-host-manual.log | tail -20
```

Need a real UUID in `extracted agentId=…`. Live slice-0 (1 Sep) proved `sessionOptions` has **no** `agentId` key. Empty identity **refuses the per-agent overlay** (fleet default medium, never high). The hook now also passes `hostOptions` (`options2`) and dumps those keys. If that is also empty, overlay cannot SHIP until host-main exposes a UUID. Unset the dump flag after.

## Install on the box (desktop terminal)

```bash
cp /home/box/grok-bot-setup/examples/agent-inference-policy.json \
  /home/box/sand-data/agent-inference-policy.json

# Deploy updated module + fail-closed hook (one restart — Node require cache)
cp /home/box/grok-bot-setup/xai-prompt-session.cjs /home/box/sand-host/xai-prompt-session.cjs
# Re-run patch only if hook still has Cursor fallback:
#   bash /home/box/grok-bot-setup/scripts/ensure-xai-inference.sh
# Then ONE host restart from desktop terminal, e.g.:
#   /home/box/grok-bot-setup/adapters.sh restart-host
# (Only after Ricky GO for restart. Not from CoS.)
```

After first deploy, **policy JSON edits do not need restart** (mtime cache).

## Smoke

1. Finance short ping → log `effort=medium provider=grok-heavy`
2. CoS one line → `effort=high`
3. Development one line → `effort=high`
4. Pump one line → `effort=high provider=grok-heavy` (not Codex yet)

```bash
grep '\[sand-xai\] agent=' /tmp/sand-host-manual.log | tail -20
```

## Tests

```bash
bash ./scripts/test-agent-inference-policy.sh
```

Never points at live adapters / `--go`.
