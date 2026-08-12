# Grok Bot setup

Interactive CLI and optional adapters to point Grok Bot at custom model providers
(DeepSeek, Claude, Grok, OpenAI, …).

## Run

```bash
/workspace/setup/adapters
# or
/workspace/setup/adapters.sh
```

Shortcuts from workspace root (wrappers):

```bash
/workspace/adapters
/workspace/scripts/adapters.sh
```

## Layout

| Path | Purpose |
|------|---------|
| `adapters.sh` | Interactive + scriptable CLI |
| `adapters` | Launcher |
| `cliproxy-api/` | Claude Pro/Max OAuth proxy (`:8317`) |
| `grok-model-bridge/` | LiteLLM multi-provider bridge (`:4000`) |
| `docs/` | Custom inference guide |

## What it configures

Writes durable provider config:

```
/home/box/sand-data/xai-inference.env
```

and can restart the Sand host so Grok Bot picks up the new backend.

See `docs/GUIDE_CUSTOM_INFERENCE.md` for full details.
