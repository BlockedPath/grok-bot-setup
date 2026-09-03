# Grok OAuth keepalive (probe / refresh attempt / fail-closed expired key)

**Status:** implementation on the policy bench (`feat/agent-inference-policy` / BlockedPath #4). **Not live.** No `--go`. Recover stays paused. Watchdog stays dead.

Cites: BlockedPath #3 (fleet-heavy), BlockedPath #4 (policy/models), panrix/grok-bot-setup#1 (docs packet).

Overnight 31 Aug / 1 Sep: host `/health` 200, `~/.grok/auth.json` access `key` expired. Hook sent the dead key until a human ran `grok login --device-auth`.

## Two-door rule (hook vs token)

| Door | Symptom | Tool | Who |
|---|---|---|---|
| Hook missing / Cursor wipe | `createXaiPromptSession` gone from host-main | `adapters.sh recover` / `fleet-heavy --go` | Ricky, desktop terminal. **Paused.** |
| Token dead / health 200 | M1 `status=EXPIRED` | M1 probe, optional M2, else human device-auth | CoS pings; human clicks the browser |

Do not weld them. Do not start `host-hook-watchdog.sh` from the oauth path (it `restart-host` / SIGTERM'd the office). Do not enable grok-session recover from this routine. Policy overlay (who gets which model/effort) is a third knob and only works if oauth is alive **and** `agentId` is present.

## Modules

- **M1** `bin/grok-auth-status` — probe. Prints `exists`, `has_key`, `expires_at`, `seconds_left`, `status=ok|soon|EXPIRED`. Never prints `key`, `refresh_token`, or email. `soon` = under 2 hours (`SOON_SECONDS=7200`). Exit 0 ok, 1 soon, 2 expired/missing. Calls `scripts/token-expired.py --probe`.
- **M2** `scripts/refresh-grok-if-expired.sh` — if ok: print `skip` and exit 0. If soon or expired: run `grok models` (non-interactive), re-probe. If still expired: print `refresh-failed` and exit 3. Never `grok login`. Never delete `auth.json`. Unproven that `grok models` rotates `expires_at` — stub both outcomes in tests.
- **M3** `xai-prompt-session.cjs` — if `expires_at` is in the past, do **not** send the dead key. `grokSessionToken()` returns empty; `resolveAuth()` throws `GROK_AUTH_EXPIRED` (`expires_at=… seconds_left=…`, no token). Same file as the #4 policy overlay.
- **M4** this file — CoS recipe below.
- **M5** `bin/grok-auth-cutover-status` — hook present? M1 result? watchdog pid alive? recover armed? Exit 2 if oauth expired. Never `--go`. Never SIGTERM.

## CoS recipe (ping-only)

1. Run M1 (`bin/grok-auth-status`).
2. Quiet if `status=ok`.
3. If `soon` or `EXPIRED`, ping Ricky with the expiry timestamp and the one desktop command:

```
/home/box/.grok/bin/grok login --device-auth
```

Do not call `adapters.sh recover`, `restart-host`, or start the host-hook watchdog from this routine.

Weekly Cursor → Heavy (desktop terminal, not chat):

```
adapters.sh recover          # hook only — still needs Ricky GO if it restarts host
bin/grok-auth-status         # probe
# if EXPIRED: grok login --device-auth  (human)
# if ok: done
```

## Tests

```
bash ./scripts/test-grok-auth-keepalive.sh
bash ./scripts/test-agent-inference-policy.sh
```

Stub fixtures only. No live `auth.x.ai`. No `--go`. No host restart.

## Still open (inherited from #4 — do not skip)

Empty `agentId` still resolves default Heavy medium. Before trusting CoS/Dev/Pump **high** (and before the later Pump→Codex module), log-only slice 0: `SAND_XAI_DUMP_SESSION_KEYS=1` dumps `sessionOptions` **keys only** (no bodies). If the live host does not pass `agentId`, those seats stay medium.
