# Grok Bot setup

Interactive CLI and optional adapters to point **Grok Bot** at custom model providers (DeepSeek, Claude, Grok, OpenAI, OpenRouter, ChatGPT/Codex OAuth, or any OpenAI-compatible URL).

It writes durable provider config, can install/start local proxies, and restarts the Sand host so Grok Bot picks up the new backend.

## Prerequisites

- A Sand / Grok Bot host environment (`~/sand-host`, `~/sand-data`)
- `bash`, `curl`, `python3`
- For optional adapters (downloaded by `./adapters install`):
  - **CLIProxyAPI** (Claude OAuth): Go toolchain
  - **LiteLLM bridge**: [`uv`](https://docs.astral.sh/uv/)
  - **openai-oauth** (ChatGPT/Codex): Node/`npx`

## Install

### 1. Clone

```bash
git clone https://github.com/BlockedPath/grok-bot-setup.git
cd grok-bot-setup
```

On this box the tree often lives at `/workspace/setup`. Either path works; examples below use a local checkout named `grok-bot-setup`.

### 2. Install adapters (and optional login CLIs)

`./adapters install` downloads binaries and scaffolds local runtime dirs (`cliproxy-api/`, `grok-model-bridge/`) next to the CLI. Those dirs are **not** in the repo.

```bash
# Download + scaffold: CLIProxyAPI, LiteLLM, openai-oauth cache
./adapters install all

# Optional: install login CLIs (claude / grok / codex) if missing
./adapters install login-agents
```

Targets:

| Command | What it installs |
|---------|------------------|
| `./adapters install all` | CLIProxy binary + config, LiteLLM + config, openai-oauth |
| `./adapters install cliproxy` | Claude OAuth proxy binary and local tree (`:8317`) |
| `./adapters install litellm` | LiteLLM proxy and local tree (`:4000`) |
| `./adapters install openai-oauth` | Warm `npx openai-oauth` cache |
| `./adapters install claude` / `grok` / `codex` | Provider login CLIs |
| `./adapters install login-agents` | Any missing login CLIs |

### 3. Log in where needed

```bash
claude login          # Claude Pro/Max OAuth (for CLIProxy)
grok login            # Grok CLI session (~/.grok/auth.json)
codex login           # ChatGPT/Codex OAuth (~/.codex/auth.json)
```

Check status anytime:

```bash
./adapters status
./adapters check-logins
```

### 4. Start proxies (only if you need them)

```bash
./adapters start all
# or individually:
./adapters start cliproxy      # :8317 Claude OAuth
./adapters start litellm       # :4000 LiteLLM
./adapters start openai-oauth  # :10531 Codex/ChatGPT
```

Stop with `./adapters stop [all|cliproxy|litellm|openai-oauth]`.

## Use

### Interactive (recommended)

```bash
./adapters
# same as:
./adapters.sh
./adapters menu
```

Menu:

1. Status  
2. Switch provider (DeepSeek / Claude / Grok / OpenAI / …)  
3. Install adapters  
4. Start adapters  
5. Stop adapters  
6. Restart host  
7. Check / install login agents  
8. Help  
0. Quit  

Each provider switch prompts for model/credentials as needed, writes config, then offers a host restart.

### Scriptable one-liners

```bash
./adapters status
./adapters use deepseek                 # prompts model + API key
./adapters use claude                   # prompts model + OAuth or Console key
./adapters use grok-session             # uses ~/.grok/auth.json
./adapters use openai --key sk-... --model gpt-4o
./adapters use openrouter --key sk-or-... --model openai/gpt-4o
./adapters use xai-api --key xai-... --model grok-4.5
./adapters use litellm --model grok
./adapters use openai-oauth --model gpt-5.4-mini
./adapters use direct --base-url https://example.com/v1 --model my-model --key KEY
./adapters use cursor                   # back to stock Cursor inference
./adapters restart-host
```

Common flags for `use`:

- `--model ID` — skip the model prompt  
- `--key KEY` — skip the API-key prompt (or use env vars like `OPENAI_API_KEY`)  
- `--auth oauth|api_key` — Claude auth mode  

### Provider profiles

| Profile | Backend | Auth |
|---------|---------|------|
| `deepseek` | `api.deepseek.com` | DeepSeek API key |
| `claude` / `cliproxy` | CLIProxy `:8317` or LiteLLM + Anthropic | `claude login` OAuth **or** Console API key |
| `grok-session` / `grok` | Grok cli-chat-proxy | `grok login` session |
| `xai-api` / `xai` | `api.x.ai` | xAI platform API key |
| `openai` | OpenAI Platform | `OPENAI_API_KEY` |
| `openrouter` | OpenRouter | `OPENROUTER_API_KEY` |
| `litellm` / `bridge` | LiteLLM `:4000` | master key in local `grok-model-bridge/.env` |
| `openai-oauth` / `codex` | openai-oauth `:10531` | `codex login` |
| `direct` | Any OpenAI-compatible URL | your key + base URL |
| `cursor` / `stock` | Stock Cursor path | (disables custom provider) |

## What it configures

Writes durable provider config:

```
~/sand-data/xai-inference.env
```

and can update `~/sand-data/settings.json` and restart the Sand host so Grok Bot uses the new backend.

Local install artifacts (gitignored):

```
./cliproxy-api/          # created by: adapters install cliproxy
./grok-model-bridge/     # created by: adapters install litellm
```

## Layout

| Path | Purpose |
|------|---------|
| `adapters` / `adapters.sh` | Interactive + scriptable CLI (installs proxies on demand) |
| `docs/` | Full custom-inference guide |

## Docs

- Full runbook: [`docs/GUIDE_CUSTOM_INFERENCE.md`](docs/GUIDE_CUSTOM_INFERENCE.md)  
- HTML guide: [`docs/GUIDE_CUSTOM_INFERENCE.html`](docs/GUIDE_CUSTOM_INFERENCE.html)  
- CLI help: `./adapters help`
