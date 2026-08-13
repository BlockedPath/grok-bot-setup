# Grok Bot → Claude: What Was Broken and How It Was Fixed

**Date:** 2026-08-12
**Outcome:** The Grok Bot runs on Claude (`claude-opus-5`) via Claude Pro OAuth instead of the trial-limited Grok/Cursor path.

---

## 1. Runtime topology (what runs where)

```
Grok Bot UI
  → sand-host (host-main.cjs, port 1340)          ← gateway/control plane (required by the product)
      → [patched createSession hook]              ← injected into host-main.cjs
          → xai-prompt-session.cjs                ← custom inference stream (this file was repaired)
              → POST /v1/chat/completions (SSE + tools)
                  → CLIProxyAPI (127.0.0.1:8317, key sand-cliproxy)   ← Go proxy, Claude Pro OAuth
                      → Anthropic (claude-opus-5)
```

Supporting processes:

| Process | Port | Kept alive by |
|---|---|---|
| sand-host (host-main.cjs) | 1340 | sand-supervisor.mjs (in-box supervisor; DO NOT kill the supervisor chain) |
| CLIProxyAPI (go/bin/server) | 8317 | cliproxy-api/scripts/watchdog.sh |
| LiteLLM bridge (optional, multi-provider) | 4000 | manual (`adapters.sh start litellm`) |

Config files:

- `/home/box/sand-data/xai-inference.env` — durable provider config, read by `xai-prompt-session.cjs` on every session (env file, not process env):

```
SAND_INFERENCE_PROVIDER=xai
XAI_API_KEY=sand-cliproxy
SAND_XAI_BASE_URL=http://127.0.0.1:8317/v1
SAND_XAI_MODEL=claude-opus-5
SAND_XAI_THINKING=enabled
SAND_XAI_REASONING_EFFORT=medium
SAND_XAI_IDENTITY=1
```

- `~/.local/share/grok-bot-adapters/cliproxy-api/config.yaml` — cliproxy (port 8317, key `sand-cliproxy`).
- `~/.local/share/grok-bot-adapters/grok-model-bridge/config.yaml` — LiteLLM bridge; `grok`/`grok-4.5` and all claude model names route to `openai/claude-opus-5` (or the matching claude model) via `http://127.0.0.1:8317/v1`, `api_key: sand-cliproxy`.

---

## 2. The stock-vs-patched path (why "out of trial credits")

Stock behavior:

```
Grok Bot UI → sand-host → createCursorSandInference → Cursor Connect RPC → cursor-grok model
```

That model path is what reports **"You've used all of your grok bot trial usage"**. There is no settings UI for the provider — the host must be patched.

Patched behavior (this box): a hook in `createCursorSandInference.createSession(...)` returns `createXaiPromptSession(...)` from `xai-prompt-session.cjs` whenever `SAND_INFERENCE_PROVIDER != "cursor"`.

---

## 3. The hook (how it's injected into host-main.cjs)

The hook must be **re-injected after every host bundle swap/upgrade**. The injection anchor in `host-main.cjs` (minified bundle) is inside `function createCursorSandInference`:

```js
      const requestedModel = resolveSandRequestedModel({
        sessionOptions,
        envModelOverride: process.env.SAND_AGENT_MODEL,
        storedDefaultModel: options2.getDefaultModel?.(),
        storedComputerUseModel: options2.getComputerUseModel?.(),
        storedBrowserUseModel: options2.getBrowserUseModel?.(),
        experimentModelOverride
      });
      const session = createCursorInferencePromptSession({
```

Insert between the `});` and `const session = ...`:

```js
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
```

Verify:

```bash
grep -c createXaiPromptSession /home/box/sand-host/host-main.cjs   # expect 2
node --check /home/box/sand-host/xai-prompt-session.cjs            # expect SYNTAX OK
```

Original bundle backup: `/home/box/sand-host/host-main.cjs.cursor-bak`

---

## 4. Bugs found and fixed in xai-prompt-session.cjs

The file was a half-finished refactor. Each bug below silently broke the turn
or fell back to Cursor (which then showed the trial-usage error).

1. **Generator/promise mismatch (syntax error).**
   `runStream` contained `yield` statements but was declared `async function` (no `*`) →
   `SyntaxError: Unexpected strict mode reserved word` at require time →
   every bot turn fell back to Cursor.
   *Fix:* made it a plain `async function` and moved the early error paths out
   of generator form (see `errorResult()`).

2. **Dead references to removed helpers.**
   `session_model_of(executor_of(this))` / `messages_of(this)` were referenced
   but never defined.
   *Fix:* `runStream(ctx, tools, model, messages)` — model and messages are
   threaded through from `session.getModelId()` and the executor's message list.

3. **`stream()` returned wrong contract.**
   The host expects `executor.stream(...)` to return synchronously:
   `{ fullStream: <async iterable>, response: <Promise>, usage: <Promise>, extendedUsage, providerMetadata, invocationId }`.
   `stream()` instead called `.then()` on `runStream`'s return.
   *Fix:* `const processing = runStream(...)`, then
   `fullStream` = delegating async generator (`const result = await processing; yield* result.fullStream`),
   `response`/`usage`/`extendedUsage`/`providerMetadata`/`invocationId` = promises derived from `processing`.

4. **teeStream ate its own stream.**
   The `response` and `usage` promises pushed waiters into the SAME queue the
   fullStream consumer used, and each waiter consumed one part — so text-delta
   parts were swallowed and never reached the UI.
   *Fix:* separate `doneWaiters` list; `response`/`usage` only wait for
   completion and read the aggregate (they never consume parts).

5. **Usage shape mismatch.**
   The host's `sanitizeUsage` expects `{ promptTokens, completionTokens, totalTokens }`
   (Cursor shape), upstream sends OpenAI `{ prompt_tokens, ... }`.
   *Fix:* `normalizeUsage()` converts on the finish part and everywhere a usage
   object is exposed.

6. **`response.modelId` missing.**
   The host's `sanitizeStreamResult` does `response.modelId.trim()` (unguarded).
   *Fix:* the finish `responsePayload` (and error fallbacks) always include
   `modelId`.

7. **`response.messages` missing — the "cannot read properties of undefined (reading 'some')" error.**
   The host builds the turn's new assistant messages from `response.messages`
   (`response.messages.some(...)` in `streamModelAndCollectToolCalls`) and uses
   them to match tool results to tool calls.
   *Fix:* the finish part and the resolved `response` now include
   `messages: [{ role: "assistant", content: text }]` and/or
   `[{ role: "assistant", content: [{ type: "tool-call", toolCallId, toolName, args }, ...] }]`
   using the SAME toolCallIds as the streamed tool-call parts.

8. **Tool id validation (`^[a-zA-Z0-9_-]+$`).**
   Anthropic (via the cliproxy) rejects tool ids containing other characters.
   *Fix:* `sanitizeToolId()` maps invalid chars to `_` deterministically, so the
   assistant `tool_calls[].id` and the matching tool message `tool_call_id`
   stay equal after mapping.

9. **Wrong message format parsing.**
   The host speaks Cursor's content-block format, not OpenAI's:
   `content` is an array of parts
   `{ type: "text", text }`, `{ type: "tool-call", toolCallId, toolName, args }`,
   `{ type: "tool-result", toolCallId, toolName, result, isError }`.
   The converter originally read OpenAI-style `msg.content`/`msg.toolCalls`.
   *Fix:* `convertMessage()` parses content blocks (accepts both Cursor
   `tool-call`/`tool-result` and Anthropic `tool_use`/`tool_result` naming),
   flattens multi-result tool messages, and keeps a legacy string fallback.

10. **Redacted message parts.**
    With privacy mode enabled the host wraps every string field in
    `RedactedString` objects and parts in `RedactedToolCallPart` /
    `RedactedToolResultPart` / `RedactedTextPart`. Plain `typeof x === "string"`
    checks silently dropped all text, args and results.
    *Fix:* `unwrapRedacted()` calls `.unwrap("unsafe_always_allowed", {})`
    (the same purpose the host itself uses right before sending messages to a
    model) with `toString()` / JSON fallbacks.

11. **Assistant-last conversation.**
    Claude rejects conversations ending with an assistant message
    ("This model does not support assistant message prefill").
    *Fix:* after conversion, if the last message is `assistant`, append
    `{ role: "user", content: "(continue)" }`.

12. **Debug aid.**
    `debugDump()` writes the raw + converted message structure (no full
    contents) to `/tmp/sand-xai-debug.log` on every stream.

---

## 5. Restarting the host after changes

Node caches `require("./xai-prompt-session.cjs")` — **any edit needs a host
restart**. The supervisor relaunches the host automatically (with growing
backoff), so:

```bash
kill -TERM $(pgrep -f 'host-main.cjs')   # supervisor relaunches in ~5s..2min (backoff)
# wait, then:
curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer <SAND_GATEWAY_TOKEN>" http://127.0.0.1:1340/health
```

**Never kill the supervisor chain** (`supervise-sand-supervisor` /
`sand-supervisor.mjs`) — the box treats its death as a fatal lifecycle event
and the pod gets reaped.

After any host restart, the bot UI must be **hard-refreshed/reopened**
(it caches the gateway token; otherwise it sits on "Reconnecting").

---

## 6. Verification

Standalone smoke test (no host needed — exercises the full request path):

```bash
cd /home/box/sand-host && SAND_DATA_ROOT=/home/box/sand-data SAND_XAI_MODEL=claude-opus-5 node xai-prompt-session.cjs
# expect: [sand-xai] session model=claude-opus-5 auth=key base=http://127.0.0.1:8317/v1 ...
#         model claude-opus-5 text "XAI_OK"
```

Live turns:

```bash
grep sand-xai /tmp/sand-host.log | tail -20      # session lines, HTTP errors
tail -4 /tmp/sand-xai-debug.log                  # raw + converted message structure
tail -20 /tmp/cliproxy.log                       # upstream errors
```

Healthy signs:
- `[sand-xai] session model=claude-opus-5 auth=key base=http://127.0.0.1:8317/v1 thinking=disabled`
- No `[sand-xai] failed to create xAI session` lines
- No `[sand-xai] HTTP 400` lines
- cliproxy `sync-claude-auth: in sync` (Claude OAuth token valid)

---

## 7. Re-apply after a host upgrade/restore

Host bundle swaps (backend poke `upgrade`, or `adapters.sh restart-host`)
replace `host-main.cjs` and **drop the hook and can clobber
`xai-prompt-session.cjs`**. After any of those:

1. `node --check /home/box/sand-host/xai-prompt-session.cjs`
2. Re-inject the hook (section 3) if `grep -c createXaiPromptSession host-main.cjs` < 2
3. Restart the host (section 5)
4. Hard-refresh the bot UI

---

## 8. Other repairs made along the way

- **LiteLLM bridge (grok-model-bridge)** had a broken uv tool env
  (`missing Python executable`). Fixed with:
  `uv tool install --reinstall --force 'litellm[proxy]==1.97.0rc1' --with 'fastapi==0.140.0'`
- **LiteLLM `proxy_server` import error** on the newest release → pinned to
  the receipt's `1.97.0rc1` (the version adapters.sh was built against).
- **Grok account is out of trial credits** (upstream 403 spending-limit):
  `grok`/`grok-4.5` model names in the LiteLLM bridge now route to
  `claude-opus-5` via the cliproxy, so Grok-Bot-adjacent tooling keeps working
  with the same model names.
- **Placeholder API keys:** `ANTHROPIC_API_KEY` and `GEMINI_API_KEY` in
  `grok-model-bridge/.env` are placeholders. Claude models were rerouted
  through the cliproxy OAuth path (working); Gemini needs a real key.
- **Old "cursor backend" note:** earlier the sand-host was replaced by a stub
  (`host-main.cjs` overwritten, backup at `host-main.cjs.cursor-bak`) to run
  "CLI only". The real host is back and required by the Grok Bot product —
  the patched-inference design above is what actually makes the bot use Claude.

## 9. File map

| Path | Role |
|---|---|
| `/home/box/sand-host/host-main.cjs` | sand-host bundle (hook injected at `createCursorSandInference`) |
| `/home/box/sand-host/host-main.cjs.cursor-bak` | pristine bundle backup |
| `/home/box/sand-host/xai-prompt-session.cjs` | custom inference session (repaired) |
| `/home/box/sand-data/xai-inference.env` | durable provider config (Claude via cliproxy) |
| `~/.local/share/grok-bot-adapters/cliproxy-api/` | CLIProxyAPI (8317, Claude OAuth) |
| `~/.local/share/grok-bot-adapters/grok-model-bridge/` | LiteLLM bridge (4000) |
| `/tmp/sand-xai-debug.log` | per-turn message-structure dump |
| `/tmp/sand-host.log` | host log (`[sand-xai]` lines) |
| `/tmp/cliproxy.log` | cliproxy log |
