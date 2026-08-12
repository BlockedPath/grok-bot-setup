# Guide: Point Grok Bot at xAI (or any other provider)

**Complete, re-doable runbook.** Use this if you need to rebuild the custom inference path, switch models/providers, or recover after a host upgrade.

| Related file | Purpose |
|--------------|---------|
| `xai-prompt-session.cjs` | Inference implementation (OpenAI chat completions -> your provider) |
| **`/workspace/setup/adapters.sh`** | **Install/start adapters + switch provider (recommended CLI)** |
| `scripts/ensure-xai-inference.sh` | Re-inject the `host-main.cjs` hook after upgrades |
| `XAI_GROK_BOT_FIXES.md` | Short log of the three bugs we hit |
| `XAI_INFERENCE.md` | Compact env reference |
| `GUIDE_CUSTOM_INFERENCE.html` | Same guide, rendered for the browser |
| `./grok-model-bridge/` (local, via `adapters install litellm`) | Optional LiteLLM multi-provider proxy |
| `/home/box/sand-data/xai-inference.env` | Durable provider config loaded by the host module |

### Quick switch (adapters CLI)

**Interactive menu (recommended):**

```bash
/workspace/setup/adapters
# or:
/workspace/setup/adapters.sh
```

Walks you through status, install/start/stop, and switching providers (DeepSeek, Claude, Grok, …). Each switch asks for model/credentials as needed, then offers to restart the host.

**Scriptable one-liners:**

```bash
/workspace/setup/adapters.sh status
/workspace/setup/adapters.sh install all
/workspace/setup/adapters.sh use deepseek   # prompts model + API key
/workspace/setup/adapters.sh use claude     # prompts model + OAuth or Console key
```

---

## Table of contents

1. [Mental model](#1-mental-model)
2. [Prerequisites](#2-prerequisites)
3. [Rebuild from scratch (xAI)](#3-rebuild-from-scratch-xai)
4. [Three bugs you must not reintroduce](#4-three-bugs-you-must-not-reintroduce)
5. [Day-to-day: switch model or provider](#5-day-to-day-switch-model-or-provider)
6. [Using other providers (full recipes)](#6-using-other-providers-full-recipes)
7. [Codex OAuth / ChatGPT subscription models](#7-codex-oauth--chatgpt-subscription-models)
8. [Multi-provider via LiteLLM bridge](#8-multi-provider-via-litellm-bridge)
9. [Message and tool conversion rules](#9-message-and-tool-conversion-rules)
10. [Host restart and recovery](#10-host-restart-and-recovery)
11. [Troubleshooting](#11-troubleshooting)
12. [Checklist](#12-checklist)
13. [File map](#13-file-map)
14. [What "done" looks like](#14-what-done-looks-like)

---

## 1. Mental model

### Stock behavior (Cursor)

```
Grok Bot UI
  -> sand-host (host-main.cjs)
      -> createCursorSandInference()
          -> Cursor Connect RPC  (https://api2.cursor.sh)
              -> model (e.g. cursor-grok-4.5-high-fast)
```

There is **no** settings UI for "provider = xAI".  
`agentDefaultModel` only sets a **model id string**. Transport stays Cursor unless you patch the host.

### Patched behavior (this box)

```
Grok Bot UI
  -> sand-host (host-main.cjs)   [patched createSession]
      -> xai-prompt-session.cjs
          -> POST /v1/chat/completions  (SSE + tools)
              -> xAI  OR  any OpenAI-compatible base URL
```

- Sand still owns tools, permissions, agent loop, UI.
- Only the **model stream** is replaced.

### What still may call Cursor

Even when the brain is on xAI, the host may still contact Cursor for:

- privacy-mode lookup  
- box-store sync  
- marketplace / labeling  
- some web-search helper wiring  

Those are **not** the agent completion path.

---

## 2. Prerequisites

1. **Node for the host** -- on this image: `/exec-daemon/node` (Node 22+).
2. **Writable host dir**
   ```
   /home/box/sand-host/host-main.cjs
   /home/box/sand-host/xai-prompt-session.cjs
   ```
3. **Credentials** for the provider you choose (see [section 6](#6-using-other-providers-full-recipes)).
4. **Ability to restart the host** (supervisor or manual; see [section 9](#9-host-restart-and-recovery)).

---

## 3. Rebuild from scratch (xAI)

### Step A -- Auth

**Option 1 -- Grok CLI session (recommended here)**

```bash
grok login
# headless: grok login --device-auth
# result: ~/.grok/auth.json with OIDC entry + "key"
```

**Option 2 -- API key**

```bash
export XAI_API_KEY="xai-..."
# optional: export SAND_XAI_BASE_URL="https://api.x.ai/v1"
```

**Smoke-test session -> cli-chat-proxy**

```bash
python3 - <<'PY'
import json, urllib.request
from pathlib import Path
auth = json.loads(Path.home().joinpath(".grok/auth.json").read_text())
token = next(
    v["key"] for k, v in auth.items()
    if v.get("key") and ("auth.x.ai" in k or v.get("auth_mode") == "oidc")
)
req = urllib.request.Request(
    "https://cli-chat-proxy.grok.com/v1/models",
    headers={
        "Authorization": f"Bearer {token}",
        "X-XAI-Token-Auth": "xai-grok-cli",
        "User-Agent": "grok-cli/1.0.0",
    },
)
print(urllib.request.urlopen(req, timeout=30).status)
PY
```

Expect `200`.

---

### Step B -- Inference module

Keep this file next to the host entrypoint:

```
/home/box/sand-host/xai-prompt-session.cjs
```

It must export `createXaiPromptSession` and implement Sand's prompt-session contract.

#### Session shape

```js
{
  getExecutor(initialMessages) { /* -> executor */ },
  getModelId() { return "grok-4.5"; }
}
```

#### Executor shape (critical)

```js
{
  appendMessages(messages) { /* array or single msg */; return this; },
  getMessages() { return [...this.messages]; },  // MUST be Array
  getState()    { return [...this.messages]; },  // MUST be Array
  clearMessages() {},
  stream(ctx, invocationId, tools, options) {
    return {
      fullStream,           // async iterable
      response,             // Promise
      usage,                // Promise
      extendedUsage,        // Promise
      providerMetadata,     // Promise
      invocationId,         // Promise
    };
  }
}
```

#### Stream part types (agent understands these)

| `type` | Payload |
|--------|---------|
| `text-delta` | `{ textDelta }` |
| `reasoning` | `{ textDelta }` (from xAI `reasoning_content`) |
| `tool-call-streaming-start` | `{ toolCallId, toolName }` |
| `tool-call-delta` | `{ toolCallId, toolName, argsTextDelta }` |
| `tool-call` | `{ toolCallId, toolName, args }` (object) |
| `finish` | `{ finishReason, usage, response }` |
| `error` | `{ error }` |

#### xAI session HTTP shape

```http
POST https://cli-chat-proxy.grok.com/v1/chat/completions
Authorization: Bearer <session-from-auth.json>
X-XAI-Token-Auth: xai-grok-cli
x-grok-client-version: 1.0.0
x-grok-model-override: grok-4.5
User-Agent: grok-cli/1.0.0
Content-Type: application/json

{
  "model": "grok-4.5",
  "messages": [...],
  "tools": [...],          // optional
  "tool_choice": "auto",
  "stream": true
}
```

API-key mode uses `https://api.x.ai/v1` and plain `Authorization: Bearer <XAI_API_KEY>` (no X-XAI-Token-Auth headers).

---

### Step C -- Patch `host-main.cjs`

In `createCursorSandInference` -> `createSession(...)`, **after** `resolveSandRequestedModel(...)` and **before** `createCursorInferencePromptSession(...)`, insert:

```js
const inferenceProvider = (process.env.SAND_INFERENCE_PROVIDER || "xai").toLowerCase();
if (inferenceProvider !== "cursor") {
  try {
    const { createXaiPromptSession } = require("./xai-prompt-session.cjs");
    return createXaiPromptSession({
      requestedModel,
      onRequestId,
      sessionOptions,
    });
  } catch (xaiErr) {
    console.error("[sand-xai] failed to create xAI session, falling back to Cursor:", xaiErr);
  }
}
```

On this box, re-apply automatically if the anchor still matches:

```bash
/home/box/sand-host/scripts/ensure-xai-inference.sh
```

Verify:

```bash
grep -n createXaiPromptSession /home/box/sand-host/host-main.cjs
```

---

### Step D -- Pin default model (optional)

Edit `/home/box/sand-data/settings.json`:

```json
{
  "agentDefaultModel": {
    "modelId": "grok-4.5",
    "maxMode": true,
    "parameters": [
      { "id": "effort", "value": "high" },
      { "id": "fast", "value": "true" }
    ]
  }
}
```

The module also maps host-internal ids (`sand-default`, `gemini-2.5-flash`, ...) -> `grok-4.5` so summarization sessions do not break.

---

### Step E -- Restart host

See [section 9](#9-host-restart-and-recovery). Minimum:

```bash
export SAND_PACKAGED=1
export SAND_DATA_ROOT=/home/box/sand-data
export SAND_HOST_IN_BOX=1
export SAND_HOST_LOG_FILE=/tmp/sand-host-manual.log
export SAND_INFERENCE_PROVIDER=xai

/exec-daemon/node /home/box/sand-host/host-main.cjs
```

Confirm gateway:

```bash
cat /home/box/sand-data/gateway.json
# { "port": 1340, "pid": ..., "token": "..." }
```

---

### Step F -- Smoke test (no UI)

```bash
/exec-daemon/node -e '
const { createXaiPromptSession } = require("/home/box/sand-host/xai-prompt-session.cjs");
(async () => {
  const s = createXaiPromptSession({ requestedModel: { modelId: "grok-4.5" } });
  const ex = s.getExecutor([{ role: "user", content: "Reply with exactly: XAI_OK" }]);
  const r = ex.stream({}, "t", [
    { name: "ping", description: "ping",
      parameters: { jsonSchema: { type: "object", properties: { msg: { type: "string" } } } } }
  ], {});
  let t = "";
  for await (const p of r.fullStream) {
    if (p.type === "text-delta") t += p.textDelta;
    if (p.type === "error") throw p.error;
  }
  console.log("model", s.getModelId(), "text", JSON.stringify(t));
  console.log("getState isArray", Array.isArray(ex.getState()));
})().catch((e) => { console.error(e); process.exit(1); });
'
```

After a real UI turn, host log should contain:

```text
[sand-xai] session model=grok-4.5 auth=session base=https://cli-chat-proxy.grok.com/v1
```

---

## 4. Three bugs you must not reintroduce

### Bug A -- `plainMessages.map is not a function`

| | |
|--|--|
| **UI** | Agent failed to respond ... `plainMessages.map is not a function` |
| **Cause** | `getState()` returned `{ messages: [...] }` |
| **Rule** | `getState()` / `getMessages()` return **arrays** |

```js
// WRONG
getState() { return { messages: this.messages }; }

// RIGHT (BasePromptBuilder)
getState() { return [...this.messages]; }
getMessages() { return [...this.messages]; }
```

### Bug B -- HTTP 400 `tool parameter root must be an object type`

| | |
|--|--|
| **Log** | `xAI inference HTTP 400: tool parameter root must be an object type` |
| **Cause** | Tools pass AI SDK wrappers `{ jsonSchema: { type: "object", ... }, validate }` |
| **Mistake** | `JSON.stringify` sent the wrapper; root had no `type: "object"` |
| **Rule** | Always send **plain JSON Schema** with root `type: "object"` |

```js
// Unwrap AI SDK schema
const schema = tool.parameters?.jsonSchema ?? tool.parameters;
// Ensure:
{ type: "object", properties: { ... } }
// null/empty -> { type: "object", properties: {} }
// scalar/array root -> wrap under properties.value
```

Implemented in `normalizeToolParameters()` inside `xai-prompt-session.cjs`.

### Bug C -- Wrong model ids

| | |
|--|--|
| **Log** | `session model=sand-default` or `gemini-2.5-flash` |
| **Cause** | Host opens summarizer / default sessions with non-xAI ids |
| **Rule** | Map unknowns -> real provider model (`grok-4.5` or `SAND_XAI_MODEL`) |

---

## 5. Day-to-day: switch model or provider

The current module is OpenAI Chat Completions-shaped. In **API key mode** it uses:

- Bearer token from `XAI_API_KEY` (name is historical; value can be any provider key)
- Base URL from `SAND_XAI_BASE_URL`
- Model from `SAND_XAI_MODEL`

### Switch model only (stay on xAI)

```bash
export SAND_XAI_MODEL="grok-4.5"    # or another id your endpoint accepts
# restart host
```

### Switch provider (OpenAI-compatible)

```bash
export XAI_API_KEY="sk-..."                         # provider API key
export SAND_XAI_BASE_URL="https://api.openai.com/v1"
export SAND_XAI_MODEL="gpt-4o"
export SAND_INFERENCE_PROVIDER=xai                  # keep non-cursor path
# restart host -- see section 9
```

### Switch via LiteLLM bridge (Claude / Gemini / multi)

```bash
# 1) start bridge
/workspace/setup/grok-model-bridge/scripts/start.sh

# 2) point host at bridge
export XAI_API_KEY="sk-local-bridge-change-me"      # = LITELLM_MASTER_KEY in .env
export SAND_XAI_BASE_URL="http://127.0.0.1:4000/v1"
export SAND_XAI_MODEL="claude-sonnet"               # alias from config.yaml
# restart host
```

### Switch to Codex OAuth (ChatGPT subscription models)

```bash
# 1) codex login  (or: npx openai-oauth login)
# 2) start local OpenAI-compatible proxy
npx openai-oauth@latest --detach --host 127.0.0.1 --port 10531

# 3) point host at that proxy
export XAI_API_KEY="openai-oauth"                   # dummy; proxy uses ~/.codex tokens
export SAND_XAI_BASE_URL="http://127.0.0.1:10531/v1"
export SAND_XAI_MODEL="gpt-5.4-mini"                # pick from proxy /v1/models
# restart host
```

Full steps: [section 7](#7-codex-oauth--chatgpt-subscription-models).

### Back to stock Cursor

```bash
export SAND_INFERENCE_PROVIDER=cursor
# restart host
```

Or remove the `createXaiPromptSession` block from `host-main.cjs`.

---

## 6. Using other providers (full recipes)

> **Auth note:** `resolveAuth()` prefers `XAI_API_KEY`. If set, **session auth is skipped** and `SAND_XAI_BASE_URL` defaults to `https://api.x.ai/v1` unless you override it.  
> So for non-xAI providers you **must** set both `XAI_API_KEY` (or rename in code) **and** `SAND_XAI_BASE_URL`.

### 6.1 xAI -- Grok CLI session (current default)

| Setting | Value |
|---------|--------|
| Auth | `~/.grok/auth.json` via `grok login` |
| Base | `https://cli-chat-proxy.grok.com/v1` (automatic when no API key) |
| Model | `grok-4.5` (default) |
| Extra headers | `X-XAI-Token-Auth`, `x-grok-model-override`, ... (built-in) |

```bash
# unset API key so session mode wins
unset XAI_API_KEY GROK_CODE_XAI_API_KEY GROK_XAI_API_KEY
unset SAND_XAI_BASE_URL
export SAND_XAI_MODEL=grok-4.5
export SAND_INFERENCE_PROVIDER=xai
# restart host
```

### 6.2 xAI -- API key

```bash
export XAI_API_KEY="xai-..."
export SAND_XAI_BASE_URL="https://api.x.ai/v1"
export SAND_XAI_MODEL="grok-4.5"
export SAND_INFERENCE_PROVIDER=xai
# restart host
```

### 6.3 OpenAI

```bash
export XAI_API_KEY="$OPENAI_API_KEY"          # or paste sk-...
export SAND_XAI_BASE_URL="https://api.openai.com/v1"
export SAND_XAI_MODEL="gpt-4o"                # or gpt-4.1, o3-mini, ...
export SAND_INFERENCE_PROVIDER=xai
# restart host
```

Smoke:

```bash
curl -s https://api.openai.com/v1/models \
  -H "Authorization: Bearer $OPENAI_API_KEY" | head
```

### 6.4 OpenRouter (many models behind one key)

```bash
export XAI_API_KEY="$OPENROUTER_API_KEY"
export SAND_XAI_BASE_URL="https://openrouter.ai/api/v1"
export SAND_XAI_MODEL="anthropic/claude-sonnet-4"   # or openai/gpt-4o, google/gemini-...
export SAND_INFERENCE_PROVIDER=xai
# restart host
```

Optional headers (if you extend the module): `HTTP-Referer`, `X-Title`.

### 6.5 Together AI

```bash
export XAI_API_KEY="$TOGETHER_API_KEY"
export SAND_XAI_BASE_URL="https://api.together.xyz/v1"
export SAND_XAI_MODEL="meta-llama/Meta-Llama-3.1-70B-Instruct-Turbo"
export SAND_INFERENCE_PROVIDER=xai
# restart host
```

### 6.6 Ollama (local)

```bash
ollama pull llama3.1
export XAI_API_KEY="ollama"                   # Ollama often ignores the key
export SAND_XAI_BASE_URL="http://127.0.0.1:11434/v1"
export SAND_XAI_MODEL="llama3.1"
export SAND_INFERENCE_PROVIDER=xai
# restart host
```

**Caveat:** tool-calling quality varies by model; agent tools may misbehave.

### 6.7 Azure OpenAI

Azure usually needs a deployment URL + `api-version` query. Minimal approach:

```bash
export XAI_API_KEY="$AZURE_OPENAI_API_KEY"
export SAND_XAI_BASE_URL="https://YOUR_RESOURCE.openai.azure.com/openai/deployments/YOUR_DEPLOYMENT"
export SAND_XAI_MODEL="gpt-4o"                # deployment name may be required as model
# You may need to patch the module to append ?api-version=2024-xx-xx
# and use header api-key instead of Authorization -- Azure variants differ.
export SAND_INFERENCE_PROVIDER=xai
```

If stock Bearer auth fails, edit `resolveAuth()` in `xai-prompt-session.cjs` to emit Azure headers.

### 6.8 Anthropic Claude (native API is not Chat Completions)

**Do not** point `SAND_XAI_BASE_URL` at `https://api.anthropic.com/v1` without an adapter.  
Anthropic uses `/v1/messages` + `x-api-key` + `anthropic-version`.

**Option A -- Claude Pro/Max OAuth with tools (recommended for Grok Bot agents):** use CLIProxyAPI. See [Claude OAuth (Pro/Max) and Claude Opus 5](#claude-oauth-promax-and-claude-opus-5).

**Option B -- Console API key:** LiteLLM bridge ([section 8](#8-multi-provider-via-litellm-bridge)):

```bash
# in grok-model-bridge/.env
ANTHROPIC_API_KEY=sk-ant-...
LITELLM_MASTER_KEY=sk-local-bridge-change-me

# config.yaml already has:
# - model_name: claude-sonnet
#   litellm_params:
#     model: anthropic/claude-sonnet-4-5
#     api_key: os.environ/ANTHROPIC_API_KEY

/workspace/setup/grok-model-bridge/scripts/start.sh

export XAI_API_KEY="sk-local-bridge-change-me"
export SAND_XAI_BASE_URL="http://127.0.0.1:4000/v1"
export SAND_XAI_MODEL="claude-sonnet"
export SAND_INFERENCE_PROVIDER=xai
# restart host
```

### 6.9 Google Gemini

Same idea -- use LiteLLM:

```yaml
# config.yaml
- model_name: gemini-flash
  litellm_params:
    model: gemini/gemini-2.5-flash
    api_key: os.environ/GEMINI_API_KEY
```

```bash
export XAI_API_KEY="sk-local-bridge-change-me"
export SAND_XAI_BASE_URL="http://127.0.0.1:4000/v1"
export SAND_XAI_MODEL="gemini-flash"
# restart host
```

### 6.10 Provider cookbook (summary)

| Provider | Base URL | Key | Model example | Via module direct? |
|----------|----------|-----|---------------|--------------------|
| xAI session | `cli-chat-proxy.grok.com/v1` | `auth.json` | `grok-4.5` | Yes (default) |
| xAI API | `api.x.ai/v1` | `XAI_API_KEY` | `grok-4.5` | Yes |
| OpenAI | `api.openai.com/v1` | OpenAI key as `XAI_API_KEY` | `gpt-4o` | Yes |
| OpenRouter | `openrouter.ai/api/v1` | OpenRouter key | `anthropic/claude-...` | Yes |
| Together | `api.together.xyz/v1` | Together key | Llama / Mixtral ids | Yes |
| Ollama | `127.0.0.1:11434/v1` | dummy | local name | Yes (tools vary) |
| Azure | deployment URL | Azure key | deployment name | Partial (headers) |
| Anthropic | -- | -- | -- | **No** -- use LiteLLM |
| Gemini | -- | -- | -- | **No** -- use LiteLLM |
| **Codex OAuth (ChatGPT)** | `127.0.0.1:10531/v1` (local proxy) | ChatGPT login -> `~/.codex` | account-available Codex models | Yes via `openai-oauth` proxy |
| Multi | `127.0.0.1:4000/v1` | `LITELLM_MASTER_KEY` | alias from yaml | Yes (bridge) |

---

## 7. Codex OAuth / ChatGPT subscription models

Use this when you want Grok Bot to call **OpenAI models billed through a ChatGPT / Codex subscription** (OAuth), not a Platform API key.

### How it works

```
Grok Bot
  -> xai-prompt-session.cjs  (OpenAI Chat Completions client)
      -> local openai-oauth proxy  (http://127.0.0.1:10531/v1)
          -> ChatGPT Codex backend  (chatgpt.com/backend-api/codex)
              -> models your ChatGPT account can use
```

Codex CLI stores OAuth tokens in **`~/.codex/auth.json`** (or the OS keyring).  
A small local proxy (`openai-oauth`) turns those tokens into a normal OpenAI-compatible `/v1` API that our host module can call.

> **Legal / ToS note:** ChatGPT OAuth proxies are unofficial and may break or violate OpenAI terms if misused. Prefer your own account, don't share tokens, and treat `~/.codex/auth.json` like a password. For production automation, OpenAI still recommends Platform API keys.

### Step 1 -- Sign in (get Codex OAuth tokens)

**Option A -- Codex CLI (official)**

```bash
# install Codex CLI if needed (npm / official installer)
codex login                 # browser OAuth (default)
# headless / remote box:
codex login --device-auth   # device code flow

codex login status          # confirm signed in
```

Credentials land in:

```
~/.codex/auth.json
```

**Option B -- openai-oauth login (same credential store)**

```bash
npx openai-oauth@latest login
# uses localhost:1455 callback; stores in ~/.codex
```

**Headless box (this sand):** login on a machine with a browser, then copy auth:

```bash
# on laptop after codex login:
ssh user@remote 'mkdir -p ~/.codex'
scp ~/.codex/auth.json user@remote:~/.codex/auth.json
```

Or enable device-code login in ChatGPT security settings, then:

```bash
codex login --device-auth
```

### Step 2 -- Start the OpenAI-compatible OAuth proxy

```bash
# foreground
npx openai-oauth@latest --host 127.0.0.1 --port 10531

# or background
npx openai-oauth@latest --detach --host 127.0.0.1 --port 10531
npx openai-oauth status
npx openai-oauth logs --follow
```

Default listen: **`http://127.0.0.1:10531/v1`**.

Useful flags:

| Flag | Default | Meaning |
|------|---------|---------|
| `--host` | `127.0.0.1` | Bind address (keep loopback unless you trust the network) |
| `--port` | `10531` | Proxy port |
| `--models` | account discovery | Comma-separated model allowlist |
| `--oauth-file` | `~/.codex/auth.json` | Where tokens live |
| `--base-url` | `https://chatgpt.com/backend-api/codex` | Upstream Codex API |

List models your account can use:

```bash
curl -s http://127.0.0.1:10531/v1/models \
  -H "Authorization: Bearer openai-oauth" | head
```

(Proxy uses Codex OAuth; the Bearer value can be a dummy string.)

Supported proxy surfaces (typical):

- `/v1/chat/completions` (what Grok Bot uses)
- `/v1/responses`
- `/v1/models`
- streaming, tool calls, reasoning (subject to Codex limits)

### Step 3 -- Point Grok Bot at the proxy

```bash
export XAI_API_KEY="openai-oauth"                 # any non-empty bearer; not a Platform key
export SAND_XAI_BASE_URL="http://127.0.0.1:10531/v1"
export SAND_XAI_MODEL="gpt-5.4-mini"              # MUST be a model from /v1/models
export SAND_INFERENCE_PROVIDER=xai                # keep non-Cursor path
# restart host (Node caches the module; env is read at process start)
```

Host log after a turn should look like:

```text
[sand-xai] session model=gpt-5.4-mini auth=api_key base=http://127.0.0.1:10531/v1
```

### Step 4 -- Smoke test

```bash
# proxy alone
curl -s http://127.0.0.1:10531/v1/chat/completions \
  -H "Authorization: Bearer openai-oauth" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gpt-5.4-mini",
    "messages": [{"role":"user","content":"Reply with exactly: CODEX_OK"}],
    "stream": false
  }' | head -c 800

# same path the host module uses
/exec-daemon/node -e '
const { createXaiPromptSession } = require("/home/box/sand-host/xai-prompt-session.cjs");
process.env.XAI_API_KEY = "openai-oauth";
process.env.SAND_XAI_BASE_URL = "http://127.0.0.1:10531/v1";
process.env.SAND_XAI_MODEL = "gpt-5.4-mini";
(async () => {
  // re-require after env set if needed -- prefer setting env before process start
  delete require.cache[require.resolve("/home/box/sand-host/xai-prompt-session.cjs")];
  const { createXaiPromptSession: make } = require("/home/box/sand-host/xai-prompt-session.cjs");
  const s = make({ requestedModel: { modelId: "gpt-5.4-mini" } });
  const ex = s.getExecutor([{ role: "user", content: "Reply with exactly: CODEX_OK" }]);
  const r = ex.stream({}, "t", [], {});
  let t = "";
  for await (const p of r.fullStream) {
    if (p.type === "text-delta") t += p.textDelta;
    if (p.type === "error") throw p.error;
  }
  console.log(JSON.stringify(t), s.getModelId());
})().catch((e) => { console.error(e); process.exit(1); });
'
```

### Model ids

- Only models **Codex exposes for your ChatGPT plan** appear on `/v1/models`.
- Names change over time (e.g. `gpt-5.4-mini`, `gpt-5.6-...`). **Always list models** from the proxy; don't hard-code forever.
- Host-internal ids (`sand-default`, etc.) are still remapped by `mapModelId()` -- set `SAND_XAI_MODEL` so the override wins.

### Codex OAuth + LiteLLM (optional)

If you want aliases like `codex-gpt` next to `claude-sonnet` on one port:

```yaml
# /workspace/setup/grok-model-bridge/config.yaml
- model_name: codex-gpt
  litellm_params:
    model: openai/gpt-5.4-mini          # must match proxy model id
    api_base: http://127.0.0.1:10531/v1
    api_key: openai-oauth
```

Then:

1. Keep `openai-oauth` running on `10531`.
2. Start LiteLLM on `4000`.
3. Point the host at LiteLLM:

```bash
export XAI_API_KEY="sk-local-bridge-change-me"
export SAND_XAI_BASE_URL="http://127.0.0.1:4000/v1"
export SAND_XAI_MODEL="codex-gpt"
```

### Ops for Codex OAuth

| Task | Command / note |
|------|----------------|
| Login status | `codex login status` |
| Logout | `codex logout` |
| Proxy status | `npx openai-oauth status` |
| Stop proxy | `npx openai-oauth stop` |
| Token file | `~/.codex/auth.json` (do not commit / share) |
| Token refresh | Codex / openai-oauth refresh during use; re-login if expired |
| This box placeholder | `/workspace/setup/grok-model-bridge/.chatgpt-auth/auth.json` is **not** a full login (only a device-code marker). Use `~/.codex/auth.json`. |

### Troubleshooting (Codex-specific)

| Symptom | Fix |
|---------|-----|
| Proxy won't start / not signed in | `codex login` or `npx openai-oauth login` |
| 401 from `10531` | Stale tokens -> login again; confirm `~/.codex/auth.json` |
| Model not found | `curl .../v1/models` and set `SAND_XAI_MODEL` to a listed id |
| Host still on xAI | Confirm `SAND_XAI_BASE_URL=http://127.0.0.1:10531/v1` and **restart host** |
| Tools fail | Some Codex models/plans differ on tool quality; try another listed model |
| Headless login fails | Use `--device-auth` or copy `auth.json` from a machine with a browser |
| Port 10531 in use | `npx openai-oauth --port 10532` and update `SAND_XAI_BASE_URL` |

### Security

- Keep `openai-oauth` on **127.0.0.1** unless you intentionally expose it (Tailscale only, auth, etc.).
- Never put Codex OAuth tokens into `XAI_API_KEY` for third-party clouds.
- Prefer Platform **API keys** for CI/public runners; OAuth is for personal/subscription use.

---

## 8. Multi-provider via LiteLLM bridge

Use when you want **one stable base URL** and many backends.

### Layout

```
/workspace/setup/grok-model-bridge/
  config.yaml       # aliases -> providers
  .env              # secrets
  scripts/start.sh  # loads auth.json session + starts LiteLLM
  logs/bridge.log
```

### Example `config.yaml` (current)

```yaml
model_list:
  - model_name: grok
    litellm_params:
      model: openai/grok-4.5
      api_base: https://cli-chat-proxy.grok.com/v1
      api_key: os.environ/GROK_SESSION_TOKEN
      extra_headers:
        X-XAI-Token-Auth: xai-grok-cli
        x-grok-client-version: "1.0.0"
        x-grok-model-override: grok-4.5
        User-Agent: grok-cli/1.0.0

  - model_name: claude-sonnet
    litellm_params:
      model: anthropic/claude-sonnet-4-5
      api_key: os.environ/ANTHROPIC_API_KEY

  - model_name: gemini-flash
    litellm_params:
      model: gemini/gemini-2.5-flash
      api_key: os.environ/GEMINI_API_KEY

general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
```

Add OpenAI:

```yaml
  - model_name: gpt-4o
    litellm_params:
      model: openai/gpt-4o
      api_key: os.environ/OPENAI_API_KEY
```

### `.env`

```bash
LITELLM_MASTER_KEY=sk-local-bridge-change-me
ANTHROPIC_API_KEY=sk-ant-...
OPENAI_API_KEY=sk-...
GEMINI_API_KEY=...
# GROK_SESSION_TOKEN is filled by start.sh from ~/.grok/auth.json when possible
```

### Start bridge

```bash
/workspace/setup/grok-model-bridge/scripts/start.sh
# listens on http://127.0.0.1:4000
curl -s http://127.0.0.1:4000/v1/models \
  -H "Authorization: Bearer sk-local-bridge-change-me"
```

### Point Grok Bot at bridge

```bash
export XAI_API_KEY="sk-local-bridge-change-me"
export SAND_XAI_BASE_URL="http://127.0.0.1:4000/v1"
export SAND_XAI_MODEL="claude-sonnet"   # or grok, gemini-flash, gpt-4o, ...
export SAND_INFERENCE_PROVIDER=xai
# restart host
```

**Important:** starting the bridge alone does **not** change Grok Bot. The host inference module must target `:4000`.

---

## 9. Message and tool conversion rules

### Messages (Sand -> OpenAI)

| Sand | OpenAI |
|------|--------|
| `system` / `user` text or parts | `role` + `content` |
| `assistant` + `tool-call` parts | `tool_calls[]` + text `content` |
| `tool` + `tool-result` | `role: "tool"`, `tool_call_id`, string `content` |
| `reasoning` | omit on resend (or map if provider needs it) |
| images | `image_url` parts if vision supported |

### Tools

Sand passes `{ name, description, parameters }` where `parameters` is often:

```js
{ jsonSchema: { type: "object", properties: {...} }, validate: fn }
```

Before HTTP:

1. Take `parameters.jsonSchema` (or `inputSchema`).
2. Ensure root `{ type: "object", properties: {...} }`.
3. Emit OpenAI tools:

```json
{
  "type": "function",
  "function": {
    "name": "Shell",
    "description": "...",
    "parameters": { "type": "object", "properties": { ... } }
  }
}
```

---

## 10. Host restart and recovery

### Why restart matters

Node **caches** `require("./xai-prompt-session.cjs")`.  
Edits to that file do nothing until the **host process** restarts.

Env vars for inference (`SAND_XAI_*`, `XAI_API_KEY`, `SAND_INFERENCE_PROVIDER`) are also read when the **host process starts**, so provider switches need a restart too.

### UI stuck on "Reconnecting" (important)

This is the most common failure after a **manual** host restart.

| Cause | What you see | Fix |
|-------|----------------|-----|
| Host restarted **without full Sand env** | Host log: `Waiting for an inference credential...` forever; UI "Reconnecting" | Restart host **with** `SAND_INFERENCE_RENEWAL_CREDENTIAL` (and other Sand vars) -- see below |
| **Gateway token changed** | Desktop still has old token from previous `gateway.json` | Hard-refresh / reopen Grok Bot window so it reloads `/home/box/sand-data/gateway.json` |
| Host process dead | `/health` fails; no listener on 1340 | Start host again |
| Wrong gateway port / bind | Client cannot reach host | Confirm `gateway.json` port (usually **1340**) and host alive |

**Never start the host with only:**

```bash
export SAND_PACKAGED=1
export SAND_DATA_ROOT=/home/box/sand-data
export SAND_HOST_IN_BOX=1
# ...this is NOT enough
```

That omits box credentials. You will get:

```text
Waiting for an inference credential. Grok Bot's computer renews this automatically...
inference-credential renewer started, but no renewal credential was delivered into the box
```

### Required env when restarting by hand

Copy from a **live Sand process** that already has the full env (supervisor, websockify, session-sync, etc.), **or** ensure at least:

| Variable | Purpose |
|----------|---------|
| `SAND_INFERENCE_RENEWAL_CREDENTIAL` | Lets the host renew Cursor/Sand inference credentials (box-store sync, privacy, desktop attach). **Required for a healthy box.** |
| `SAND_GATEWAY_TOKEN` | Shared gateway auth; missing/mismatch confuses clients |
| `SAND_DATA_ROOT` | Usually `/home/box/sand-data` |
| `SAND_HOST_IN_BOX=1` | Host-in-box mode |
| `SAND_PACKAGED=1` | Packaged host layout |
| `SAND_HOST_PORT` | Usually `1340` |
| `SAND_BOX_AUTH_ID` | Box identity |
| `SAND_INFERENCE_PROVIDER=xai` | Use custom `xai-prompt-session` (not stock Cursor model path) |
| `SAND_XAI_MODEL=grok-4.5` | Default Grok model (Grok OAuth path) |

**Grok OAuth brain path** (session via `~/.grok/auth.json`):

- Do **not** set `XAI_API_KEY` / `SAND_XAI_BASE_URL` (unless you intentionally use API key or a proxy).
- Confirm log after a turn:  
  `[sand-xai] session model=grok-4.5 auth=session base=https://cli-chat-proxy.grok.com/v1`

Find a donor process that still has the renewal credential:

```bash
python3 - <<'PY'
from pathlib import Path
for p in Path("/proc").iterdir():
    if not p.name.isdigit():
        continue
    try:
        env = (p / "environ").read_bytes()
    except Exception:
        continue
    if b"SAND_INFERENCE_RENEWAL_CREDENTIAL=" in env and b"SAND_GATEWAY_TOKEN=" in env:
        print("donor pid", p.name)
        break
PY
```

### Manual restart (correct -- full env + Grok OAuth)

```bash
# 1) Stop current host (exact cmdline match only)
python3 - <<'PY'
import os, signal
from pathlib import Path
for p in Path("/proc").iterdir():
    if not p.name.isdigit():
        continue
    try:
        c = (p / "cmdline").read_bytes()
    except Exception:
        continue
    if c == b"/exec-daemon/node\x00/home/box/sand-host/host-main.cjs\x00":
        os.kill(int(p.name), signal.SIGTERM)
        print("killed", p.name)
PY

sleep 2

# 2) Start with FULL env from a donor Sand process + Grok OAuth overrides
python3 - <<'PY'
import os, subprocess, time, json
from pathlib import Path

donor = None
for p in Path("/proc").iterdir():
    if not p.name.isdigit():
        continue
    try:
        envb = (p / "environ").read_bytes()
    except Exception:
        continue
    if b"SAND_INFERENCE_RENEWAL_CREDENTIAL=" in envb and b"SAND_GATEWAY_TOKEN=" in envb:
        donor = p.name
        break
if not donor:
    raise SystemExit("No donor process with SAND_INFERENCE_RENEWAL_CREDENTIAL -- start via supervisor instead")

env = {}
for e in Path(f"/proc/{donor}/environ").read_bytes().split(b"\0"):
    if not e or b"=" not in e:
        continue
    k, v = e.split(b"=", 1)
    env[k.decode()] = v.decode("utf-8", "replace")

# Grok OAuth (session) -- strip API-key / Codex proxy overrides
for k in ("XAI_API_KEY", "GROK_CODE_XAI_API_KEY", "GROK_XAI_API_KEY", "SAND_XAI_BASE_URL", "OPENAI_API_KEY"):
    env.pop(k, None)

env.update({
    "SAND_PACKAGED": "1",
    "SAND_DATA_ROOT": "/home/box/sand-data",
    "SAND_HOST_IN_BOX": "1",
    "SAND_HOST_LOG_FILE": "/tmp/sand-host-manual.log",
    "SAND_INFERENCE_PROVIDER": "xai",
    "SAND_XAI_MODEL": "grok-4.5",
})

log = open("/tmp/sand-host-manual.log", "a")
log.write("\n--- manual restart with full sand env + grok oauth ---\n")
log.flush()
proc = subprocess.Popen(
    ["/exec-daemon/node", "/home/box/sand-host/host-main.cjs"],
    cwd="/home/box/sand-host",
    env=env,
    stdout=log,
    stderr=log,
    start_new_session=True,
)
print("spawned", proc.pid)
time.sleep(3)
print(Path("/home/box/sand-data/gateway.json").read_text())
PY

# 3) Health check
curl -s http://127.0.0.1:1340/health \
  -H "Authorization: Bearer $(python3 -c 'import json;print(json.load(open("/home/box/sand-data/gateway.json"))["token"])')"
```

Good signs in log:

```text
[sand-host] inference-credential renewer started (backend self-renewal is the sole inference-credential source)
[sand-host] gateway listening on http://0.0.0.0:1340 (auth required)
```

Then in the **UI**: hard-refresh or reopen the bot so it reloads the gateway token.

### Gateway token / `gateway.json`

Path: `/home/box/sand-data/gateway.json`

```json
{
  "port": 1340,
  "pid": 12345,
  "scheme": "http",
  "host": "0.0.0.0",
  "token": "..."
}
```

- Host rewrite of this file is normal on restart.
- Desktop clients cache the previous `token` -- that alone can leave the UI on **Reconnecting**.
- Prefer reusing the same launch path (supervisor) when possible so token churn is lower.

### After a host **bundle upgrade**

Upgrade can replace `host-main.cjs` and drop the patch:

```bash
test -f /home/box/sand-host/xai-prompt-session.cjs
/home/box/sand-host/scripts/ensure-xai-inference.sh
# restart host with FULL env (section above)
grep createXaiPromptSession /home/box/sand-host/host-main.cjs
```

Also re-copy docs if wiped: `/workspace/setup/docs/GUIDE_CUSTOM_INFERENCE.md`.

### Logs

| Path | When |
|------|------|
| `/tmp/sand-host-manual.log` | Manual launches |
| `/tmp/sand-host.log` | Supervisor-managed |
| `/tmp/sand-supervisor.log` | Restarts / crash loops |

```bash
rg '\[sand-xai\]|Waiting for an inference credential|gateway listening|HTTP 400|failed to respond|TypeError' \
  /tmp/sand-host-manual.log | tail
```

---

## 11. Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| UI stuck **Reconnecting** | Host restarted without full env, and/or gateway token changed | Restart with `SAND_INFERENCE_RENEWAL_CREDENTIAL` (section 10); hard-refresh UI |
| Log: `Waiting for an inference credential` | Missing `SAND_INFERENCE_RENEWAL_CREDENTIAL` | Copy full env from a donor Sand process; restart host |
| Log: `no renewal credential was delivered into the box` | Same as above | Do not start host with only `SAND_PACKAGED` / `SAND_DATA_ROOT` |
| Agent fails: `plainMessages.map is not a function` | `getState()` not an array | Fix MessageBuilder; restart host |
| `tool parameter root must be an object type` | AI SDK schema wrapper not unwrapped | Use `normalizeToolParameters`; restart |
| `session model=sand-default` | model id map missing | Map unknowns -> real model |
| HTTP 401 / Unauthenticated to xAI | expired `~/.grok/auth.json` | `grok login` again |
| HTTP 401 with API key | wrong key / base URL | Check `XAI_API_KEY` + `SAND_XAI_BASE_URL` |
| Still using Cursor | patch missing or `SAND_INFERENCE_PROVIDER=cursor` | `ensure-xai-inference.sh`; set provider `xai` |
| Still on Codex / terra after intending Grok | `SAND_XAI_BASE_URL` points at `:10531` or default module was codex-oriented | Unset `SAND_XAI_BASE_URL` / `XAI_API_KEY`; set `SAND_XAI_MODEL=grok-4.5`; restart |
| Code change ignored | require cache | Restart host |
| Bridge works in curl, bot does not | host still on cli-chat-proxy | Set `SAND_XAI_BASE_URL=http://127.0.0.1:4000/v1` + restart |
| Anthropic 404 / wrong API | pointed at Anthropic native URL | Use LiteLLM, not raw `api.anthropic.com` |
| Codex OAuth model missing / 401 on 10531 | not logged in or proxy down | `codex login`; start `npx openai-oauth`; see [section 7](#7-codex-oauth--chatgpt-subscription-models) |
| No gateway.json | host dead | Check supervisor log; start host with full env |
| Tools never called | model ignores tools / Ollama weak tools | Stronger model; verify `tools` in request |
| Double host / flapping | supervisor + manual both launching | Pick one launcher |

### Verify traffic path

After one chat message:

```bash
rg '\[sand-xai\]' /tmp/sand-host-manual.log | tail -5
# expect: session model=... auth=session|api_key base=https://...
```

`base=` should be your intended provider, not `api2.cursor.sh`.

---

## 12. Checklist

```
[ ] Auth works (grok login and/or API key; curl/models 200)
[ ] xai-prompt-session.cjs present beside host-main.cjs
[ ] host-main createSession patched (grep createXaiPromptSession)
[ ] getState/getMessages return arrays
[ ] tool params unwrapped to type:object JSON Schema
[ ] unknown model ids mapped to a real provider model
[ ] SAND_XAI_BASE_URL / XAI_API_KEY / SAND_XAI_MODEL set for target provider
[ ] host restarted after any code or env change
[ ] host restarted with FULL Sand env (includes SAND_INFERENCE_RENEWAL_CREDENTIAL)
[ ] after host restart, UI hard-refreshed if stuck on Reconnecting
[ ] smoke test prints text + getState isArray true
[ ] UI turn logs [sand-xai] with correct base URL (session + cli-chat-proxy for Grok OAuth)
[ ] (optional) LiteLLM up on :4000 if using multi-provider aliases
[ ] (optional Codex OAuth) codex login -> openai-oauth on :10531 -> SAND_XAI_BASE_URL points there
```

---

## 13. File map (this box)

```
/home/box/sand-host/
  host-main.cjs                    # patched createSession
  xai-prompt-session.cjs           # custom inference
  scripts/ensure-xai-inference.sh
  GUIDE_CUSTOM_INFERENCE.md        # this file
  GUIDE_CUSTOM_INFERENCE.html      # browser-friendly copy
  XAI_INFERENCE.md
  XAI_GROK_BOT_FIXES.md

/home/box/sand-data/
  settings.json                    # agentDefaultModel, permissions
  gateway.json                     # live host port / pid / token
  agents/<id>/                     # per-bot stores

/home/box/.grok/
  auth.json                        # Grok CLI session (xAI)

/home/box/.codex/
  auth.json                        # Codex / ChatGPT OAuth tokens (if using section 7)

/workspace/setup/grok-model-bridge/
  config.yaml
  .env
  scripts/start.sh
  logs/bridge.log
  .chatgpt-auth/                   # incomplete placeholder only -- not a full Codex login
```

---

## 14. What "done" looks like

1. Message sent in Grok Bot.
2. Host log:
   ```text
   [sand-xai] session model=grok-4.5 auth=session base=https://cli-chat-proxy.grok.com/v1
   ```
   (or your OpenAI / bridge base URL).
3. Bot replies and can run tools (SendMessage, Shell, ...).
4. No:
   - `plainMessages.map is not a function`
   - `tool parameter root must be an object type`
5. Model stream does **not** go to `api2.cursor.sh`.

---

## 15. Extending the module cleanly (optional future work)

If you outgrow the `XAI_*` env names, refactor once:

```text
SAND_INFERENCE_PROVIDER=openai-compat|cursor
SAND_LLM_BASE_URL=
SAND_LLM_API_KEY=
SAND_LLM_MODEL=
SAND_LLM_EXTRA_HEADERS_JSON={"X-Title":"GrokBot"}
```

Keep unchanged:

1. Executor contract (`getState` arrays, stream parts).  
2. Tool schema normalization.  
3. Model-id coercion for host-internal names.  

Only auth, base URL, headers, and model mapping should differ per provider.

---



---

## Claude OAuth (Pro/Max) and Claude Opus 5

### Two different Claude credentials

| Credential | Where from | Works with Grok Bot agents (tools)? | Works with Claude Code CLI? |
|------------|------------|-------------------------------------|-----------------------------|
| **Claude.ai OAuth** (`sk-ant-oat01-...`) | `claude login` -> `~/.claude/.credentials.json` | **Yes** via **CLIProxyAPI** (below) | **Yes** |
| **Anthropic Console API key** (`sk-ant-api...`) | console.anthropic.com | **Yes** via LiteLLM | Yes (API billing) |

Raw Pro OAuth against `api.anthropic.com` from a third-party client is blocked (429 / third-party).  
**CLIProxyAPI** speaks the Claude Code client fingerprint (OAuth + tool-name rewrite + beta headers) and exposes a normal OpenAI `/v1/chat/completions` API with **function calling**. That is what Grok Bot needs for agents.

Do **not** use `claude-max-api-proxy` for agents: it wraps `claude -p` and **drops tools**, so agents sit idle after the first text turn.

### Want Opus 5 inside **Grok Bot** (Pro OAuth + tools) -- working path

Install once (already done on this box):

```bash
go install github.com/router-for-me/CLIProxyAPI/v6/cmd/server@latest
# binary: ~/go/bin/server
```

Config: `/workspace/setup/cliproxy-api/config.yaml` (port `8317`, api-key `sand-cliproxy`, auth-dir `~/.cli-proxy-api`).

Start / refresh auth from Claude Code login:

```bash
/workspace/setup/cliproxy-api/scripts/start.sh
# syncs ~/.claude/.credentials.json -> ~/.cli-proxy-api/claude-pro-local.json
# starts CLIProxyAPI on http://127.0.0.1:8317
```

Point Sand host (keep full donor env, especially `SAND_INFERENCE_RENEWAL_CREDENTIAL` + `SAND_GATEWAY_TOKEN`):

```bash
export SAND_INFERENCE_PROVIDER=xai
export XAI_API_KEY=sand-cliproxy
export SAND_XAI_BASE_URL=http://127.0.0.1:8317/v1
export SAND_XAI_MODEL=claude-opus-5
# restart host-main.cjs with the rest of the Sand env cloned from the previous process
```

Verified on this box:

- `POST /v1/chat/completions` with `model=claude-opus-5` returns text.
- Same endpoint with OpenAI `tools` returns `finish_reason=tool_calls` and real `tool_calls`.
- Streaming SSE tool_calls are accepted by `xai-prompt-session.cjs` (`tool-call-streaming-start` / `tool-call` / `finish`).

If agents go idle again after a host upgrade: re-run `ensure-xai-inference.sh` (or re-patch `createSession`), re-start CLIProxyAPI, and re-apply the env above with a **full** env restart.

### Want Opus 5 on **Claude Code** only

```bash
claude --model claude-opus-5
# or one-shot:
claude -p "your prompt" --model claude-opus-5 --output-format text
```

### Console API key alternative (pay-per-token)

Use LiteLLM (`/workspace/setup/grok-model-bridge`) with a real `ANTHROPIC_API_KEY` and `SAND_XAI_BASE_URL=http://127.0.0.1:4000/v1`. Not required if CLIProxyAPI OAuth is healthy.

*End of guide.*
