# Grok Model Bridge

Local OpenAI-compatible proxy (LiteLLM) so Grok Bot or any tool can call models through one endpoint.

**Primary auth:** your existing **Grok CLI session** (`~/.grok/auth.json` from `grok login`). No ChatGPT OAuth required.

## Start

```bash
cd /workspace/grok-model-bridge
./scripts/start.sh
```

Listens on `http://127.0.0.1:4000`.

`start.sh` loads the session token from `~/.grok/auth.json` automatically. If the token is expired, run:

```bash
grok login
```

## Call it

Base URL: `http://127.0.0.1:4000/v1`  
Master key: value of `LITELLM_MASTER_KEY` in `.env` (default `sk-local-bridge-change-me`)

```bash
curl -s http://127.0.0.1:4000/v1/models \
  -H "Authorization: Bearer sk-local-bridge-change-me"

curl -s http://127.0.0.1:4000/v1/chat/completions \
  -H "Authorization: Bearer sk-local-bridge-change-me" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "grok",
    "messages": [{"role": "user", "content": "ping"}]
  }'
```

### Model aliases

| Alias | Backend | Auth |
|-------|---------|------|
| `grok` / `grok-4.5` | `https://cli-chat-proxy.grok.com/v1` → `grok-4.5` | Grok CLI session (`~/.grok/auth.json`) |
| `claude-sonnet` | Anthropic Claude Sonnet 4.5 | `ANTHROPIC_API_KEY` (optional) |
| `gemini-flash` | Gemini 2.5 Flash | `GEMINI_API_KEY` (optional) |

Point any OpenAI SDK at `base_url=http://127.0.0.1:4000/v1` and `api_key=<LITELLM_MASTER_KEY>`.
