# Grok Heavy fleet cutover

**Date:** 31 Aug 2026
**Status:** story + dry-run CLI on this PR. No live switch. Merge/deploy later GO.
**Owner:** Opened as `panrix:feat/fleet-heavy` → BlockedPath PR #3 via VPS `gh` (panrix). Do not use the dead `GITHUB_TOKEN` PAT. Terra QAs. Ricky GOs the first flick from a non-chat shell on Grok Bot's computer.

This is how we move every office Grok Bot agent off the Cursor meter onto SuperGrok Heavy when the weekly Grok Bot cap is gone, without repeating the hours-long crash.

---

## 1. What we are switching

Not a per-agent toggle. Not the in-app Plan screen. Not Sign Out.

One shared host on Grok Bot's computer runs every office agent. Completions today go to Cursor (`SAND_INFERENCE_PROVIDER=cursor`). The UI can still show `grok-4.6`. That does not mean Heavy.

Heavy means:

1. Patch `host-main.cjs` so sessions use `createXaiPromptSession`
2. Write `~/sand-data/xai-inference.env` with `SAND_INFERENCE_PROVIDER=xai`
3. Restart `host-main.cjs`

Auth stays `~/.grok/auth.json` (already present). Cursor stays signed in. There is no in-app "change to Grok" switch. Signing out of Cursor deletes the Cursor account. Never do that.

The adapters command that already exists:

```bash
PATH="$HOME/.local/bin:$HOME/.grok/bin:$PATH"
/home/box/grok-bot-setup/adapters.sh use grok-session --model grok-4.6 --effort medium
```

`--effort medium` is the multi-agent setting. Default without the flag is `high`.

This PR does **not** replace that command. It wraps it so a CoS turn cannot SIGTERM the host.

Back to Cursor (documented, never from CoS, not as part of this PR's tests):

```bash
/home/box/grok-bot-setup/adapters.sh use cursor
```

Both restart the host unless `--no-restart`. `--no-restart` only writes files. A later restart is still required.

---

## 2. Blast radius

Restart kills `host-main.cjs` for **every** Grok Bot agent on this computer: CoS, Development, Diagnostics, Back Market, Pump, Alex, Inbox, Growth, Workshop, Xero, Process, Restructuring, Finance, plus unused New Agent / New Bot rows.

Gateway token can change. Desktop shows **Reconnecting**. Hard-refresh Grok Bot if it sticks.

Shop Hermes, Telegram, Slack bots, and VPS tmux seats are not this host. They keep running.

---

## 3. Why last time crashed

**What we did:** flipped Heavy from **inside the CoS chat**.

**What happened:** chats dead for hours. Ricky duplicated CoS and ran a second Chief of Staff until the original came back.

**Measured sizes (31 Aug), not a guess:**

| Store | Size |
|---|---|
| CoS jsonl | **56.5 MiB**, 34,716 lines |
| CoS conversation-blobs.db | **213 MiB** |
| CoS agent folder | **248 MiB** |
| Development jsonl | **47.4 MiB** |
| Nothing is 400 MB | 400 MB was high. jsonl is now past 40. |

**Mechanism:**

1. CoS is mid-turn on the same process the switch SIGTERMs.
2. Host restarts and reloads the swollen CoS transcript plus 213 MiB of blobs.
3. Heavy path then tries to POST converted history to `cli-chat-proxy.grok.com` (300s timeout), then trims to 400k chars. Trim is too late.
4. Gateway token changes. Every agent shows Reconnecting.
5. Overnight Cursor host wipes also drop the Heavy hook. The recover routine that auto-`adapters recover`s is **paused on purpose**. Leave it paused during any Cursor-meter week.

**Rule that stands:** never switch Heavy from inside the CoS chat. Duplicate-chat is crash recovery, not a procedure.

---

## 4. The flick switch in this PR

Wrapper, not a new inference stack.

```
bin/fleet-heavy
bin/fleet-status
```

VPS tmux cannot SIGTERM this host unless we add a later bridge. First version: Ricky (or a non-chat shell on Grok Bot's computer) runs the command.

### 4.1 Must refuse on cutover path (exit 2)

Applies to `fleet-heavy` cutover (with or without `--go`), **not** to `fleet-heavy status` / `fleet-status` (those are ungated preflight printers).

- Missing `--i-am-outside-chat`
- Parent walk finds `host-main.cjs` / `sand-host` (test-only `FLEET_FORCE_INSIDE=1` requires `FLEET_ALLOW_TEST_OVERRIDES=1`)
- `agent-data` or transcripts dir missing/unreadable/non-traversable (cannot prove idle/recover paused)
- `Grok-session recover` is enabled, or its JSON is unreadable/invalid
- Host-hook watchdog is running
- `~/.grok/auth.json` is missing. Do not `grok login` from the wrapper.
- Any office jsonl is hot in the last N seconds (mid-turn)
- Any office jsonl mtime is **at or after** cutover start (preflight race)

Test harness overrides (`FLEET_ADAPTERS`, `FLEET_FORCE_*`, path/auth stubs, etc.) are ignored unless `FLEET_ALLOW_TEST_OVERRIDES=1`.

### 4.2 Default is dry-run

Prints `adapters status`, a jsonl size table (warn if > 40 MiB), gate results, and the adapters command that **would** run. Does not call `adapters use`. Does not restart. Note: `adapters status` may chmod the CLIProxy binary executable as a side effect of that existing command — dry-run is not a pure no-op filesystem-wise, but it does not switch inference or restart the host.

### 4.3 Live needs both flags

```bash
/home/box/grok-bot-setup/bin/fleet-heavy --i-am-outside-chat --go
```

That is the only path that calls:

`adapters.sh use grok-session --model grok-4.6 --effort medium`

### 4.4 Tests

`scripts/test-fleet-heavy.sh` uses a stub `adapters` binary. It may pass `--go` against the stub. It must never point `FLEET_ADAPTERS` at the live `adapters.sh` on this host.

### 4.5 Pause meaning

There is no official "pause all Grok Bot agents" CLI. Pause = every office agent idle (no streaming), recover off, watchdog off. Do not start a CoS turn "to pause people". Idle is enough.

---

## 5. After 8 Sep 2026

Cursor Ultra ends 8 September 2026. Then link Heavy on the Grok Bot Plan screen so Ultra returns at $0. Linking does not stack extra Ultra. That is billing. It is not this host patch. Do both: plan link **and** grok-session host, or you can have a paid Heavy plan while completions still hit Cursor.

---

## 6. Critique of this plan

**What is solid**

- Uses the adapters path that already worked on 23 Aug.
- Moves the kill out of CoS.
- Names the real size (56.5 MiB jsonl, not 400 MB).
- Keeps Cursor login and Grok oauth.
- `--effort medium` for a 15-agent host.
- Tests never restart the live host.

**What is still weak**

- Restart still reloads the 56.5 MiB CoS jsonl. External flick avoids *self-kill*, not *fat-chat reload*. First smoke is a **small** agent (Finance), not CoS. CoS last.
- No real pause API. "Idle" is a jsonl mtime heuristic. A turn can still start between the final gate and SIGTERM. The wrapper also refuses if any jsonl mutates after cutover start (covers slow preflight vs short hot window). Residual race after the last check remains.
- VPS tmux cannot yet press the button on this host. First ship is local CLI plus a printed command. Remote SSH/bridge is a later GO.
- Overnight Cursor host wipes will drop the hook again. After we are on Heavy, the paused recover job / watchdog need a **separate** GO.
- Fat transcripts are the underlying disease. This switch does not compact CoS. Do not auto-trim jsonl in the wrapper.

**What we will not do**

- Flip from CoS.
- `adapters use cursor` as an undo from CoS.
- Delete or Sign Out Cursor.
- Delete CoS to "make the file smaller".
- Install a second CoS as the happy path.
- Gas Town / Kilroy / HQ as the switcher.
- Live flick / remote bridge / re-arm recover-watchdog without Ricky GO.

---

## 7. Build order

1. This PR (story + `bin/fleet-heavy` + smashable tests).
2. Terra QA: dry-run only on the live host. No `use grok-session` until Ricky GO.
3. After Terra SHIP, discuss whether tmux:grok should own later work (remote trigger). Not before.
4. Ricky GO from a non-CoS shell: `fleet-heavy --i-am-outside-chat --go`
5. Smoke Finance (tiny chat), then Development, CoS last.
6. Later GO: remote trigger from VPS tmux, and whether to re-arm recover/watchdog.

---

## 8. First command (after Terra, after GO, not now)

```bash
# on Grok Bot's computer, not in CoS, not on the VPS
/home/box/grok-bot-setup/bin/fleet-heavy --i-am-outside-chat
# read the preflight
/home/box/grok-bot-setup/bin/fleet-heavy --i-am-outside-chat --go
```
