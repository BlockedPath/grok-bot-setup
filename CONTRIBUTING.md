# Contributing to grok-bot-setup

Thanks for helping improve the Grok Bot adapters CLI. This guide covers how to
report issues, propose changes, and submit pull requests.

## Code of Conduct

By participating, you agree to uphold our [Code of Conduct](CODE_OF_CONDUCT.md).

## Ways to contribute

- **Bug reports** — something broke or behaves unexpectedly
- **Feature requests** — new providers, flags, or UX improvements
- **Docs** — README, guide, help text, examples
- **Code** — fixes and features in `adapters.sh` / packaging

## Before you open an issue

1. Search [existing issues](https://github.com/BlockedPath/grok-bot-setup/issues)
2. Confirm you’re on a recent release:
   ```bash
   npm view grok-bot-setup version
   adapters help
   ```
3. Capture useful context:
   ```bash
   adapters status
   adapters check-logins
   uname -a
   bash --version | head -1
   ```

Use the issue templates when filing bugs or feature requests. **Do not paste
API keys, session tokens, or full auth files.** Redact secrets.

## Development setup

```bash
git clone https://github.com/BlockedPath/grok-bot-setup.git
cd grok-bot-setup
./adapters help
bash -n adapters.sh   # syntax check
npm test              # same checks used in CI (local)
```

CI (`.github/workflows/ci.yml`) runs on every push/PR to `main`: bash syntax,
ShellCheck (errors), help smoke test, and an `npm pack` install of the bin.

Optional local npm link:

```bash
npm link
adapters help
```

### Project layout

| Path | Role |
|------|------|
| `adapters.sh` | Main CLI (install / start / use / menu) |
| `adapters` | Thin launcher |
| `xai-prompt-session.cjs` | Host inference module (copied into `~/sand-host`) |
| `scripts/ensure-xai-inference.sh` | Injects the createSession hook into `host-main.cjs` |
| `scripts/restore-after-reset.sh` | `adapters recover` after a Sand wipe |
| `scripts/bootstrap.sh` | curl-pipe entry: clone/update repo + recover |
| `examples/cliproxy-openai-compat.yaml` | Meta + DeepSeek model templates (no secrets) |
| `xai-inference.env.example` | Template for `~/sand-data/xai-inference.env` |
| `package.json` | npm package + `bin` entries |
| `docs/` | Long-form guide + assets |

Local proxy trees (`cliproxy-api/`, `grok-model-bridge/`) are **created by**
`adapters install` under `~/.local/share/grok-bot-adapters/` (or `ADAPTERS_DATA`).
Do not commit those runtime dirs.

### Environment this tool targets

- Sand / Grok Bot host (`~/sand-host`, `~/sand-data`)
- Linux or macOS, bash 4+, `curl`, `python3`
- Optional: Go (CLIProxy), `uv` (LiteLLM), Node/`npx` (openai-oauth)

## Pull requests

1. Fork and create a branch from `main`:
   ```bash
   git checkout -b fix/short-description
   ```
2. Make focused changes (one concern per PR when possible).
3. Keep commits clear; avoid drive-by reformatting of unrelated sections.
4. Test what you touched:
   ```bash
   bash -n adapters.sh
   ./adapters help
   ./adapters status
   # if you changed install/start:
   # ./adapters install litellm
   # ./adapters start litellm
   ```
5. Open a PR using the pull request template.

### PR checklist

- [ ] `bash -n adapters.sh` passes
- [ ] No secrets (`.env`, tokens, credentials) committed
- [ ] README / help updated if user-facing behavior changed
- [ ] Issue linked (`Fixes #123`) when applicable

## Coding notes

- Prefer portable **bash** (avoid bash 5-only features unless gated).
- Match existing style in `adapters.sh` (helpers, `log` / `warn` / `die`).
- Scaffolded files for cliproxy/LiteLLM live inside `write_*_tree` helpers —
  update those generators rather than adding vendored trees to the repo.
- npm `bin` must keep working via symlink; keep `_script_dir` resolution intact.

## Releases (maintainers)

```bash
npm version patch|minor|major -m "release: v%s"
git push origin main --follow-tags
npm publish --otp=<code>
```

## Questions

Open a [discussion issue](https://github.com/BlockedPath/grok-bot-setup/issues/new/choose)
or start from the feature-request template. Thanks for contributing.
