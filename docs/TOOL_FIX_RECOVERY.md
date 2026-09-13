# Preserve and recover the tool-contract fixes

The tested adapter must keep both contracts:

- Emit `strict: false` so a Responses provider does not make optional machineId required.
- Preserve omitted/false/true end_turn on actual SendToUser calls. Only synthesize a final SendToUser for text-only responses with no pending tool calls.

## Protection layers

1. Regression tests run with `npm test`.
2. Bootstrap no longer uses `git reset --hard`. It refuses dirty, wrong-branch or divergent checkouts; local-ahead commits are retained. Resolve updates explicitly rather than discarding local fixes.
3. The recovery verifier detects both regressions and a missing host hook. It refuses stale source snapshots instead of installing them.
4. A versioned, checksummed recovery copy lives outside the checkout and sand-host. This protects against a host-bundle or checkout replacement, **not deletion of the entire VM**.
5. The off-VM code snapshot is on GitHub: `BlockedPath/grok-bot-setup`, on `main` and the recovery branch `fix/tool-contract-update-recovery`. The recovery branch retains this tested baseline while main can evolve. The published changes contain code/tests and this generic guide, not local logs, machine reports or credentials.

## Create a verified local recovery copy

```bash
bash scripts/preserve-tool-contracts.sh
```

Default destination:

```text
~/.local/share/grok-bot-persist/tool-contracts/releases/<manifest-sha256>/
~/.local/share/grok-bot-persist/tool-contracts/current
```

Copies are versioned; prior releases remain available. Snapshot creation runs the adapter regressions before updating `current`. `GROK_TOOL_FIX_BACKUP_DIR` can choose an alternative destination, including a separately backed-up disk.

## After a host update or checkout reset

```bash
bash ~/.local/share/grok-bot-persist/tool-contracts/current/scripts/restore-tool-contracts.sh
```

This checks the snapshot's file checksums, runs regressions, and restores the adapter/hook if needed. It does **not** install/restart CLIProxy, change SSH/Tailscale/Moshi, write credential/configuration files, or restart the host. It uses the existing inference-hook installer if the hook was lost, including that installer's existing env-based model-default handling; no new model override is introduced here.

Exit codes: `0` means already healthy; `10` means restored files and a host reload may be necessary. Other nonzero codes mean stop and inspect. A file restored on disk does not establish which adapter the running process has loaded. Ask before a disruptive host restart; then verify a fresh chat with a real path-only Read.

The root checkout can also run `bash scripts/restore-tool-contracts.sh`. The independent snapshot remains useful if that checkout disappears.

## After a full VM wipe

Local snapshots cannot survive deletion of the disk. Restore the off-VM code into a new directory:

```bash
git clone --branch fix/tool-contract-update-recovery \
  https://github.com/BlockedPath/grok-bot-setup.git "$HOME/grok-tool-fix-recovery"
cd "$HOME/grok-tool-fix-recovery"
bash scripts/preserve-tool-contracts.sh
bash scripts/restore-tool-contracts.sh
```

Wait for the platform to unpack sand-host first. Existing provider authentication/configuration and unrelated services have their own recovery requirements; they are intentionally not stored in this backup. If the host has changed enough that the hook anchor is unrecognized, restoration stops rather than guessing a patch.

Do not use `adapters recover` or `bootstrap.sh` merely to repair the tool adapter: those broader setup commands can also install/start proxies and restart the host. `restore-tool-contracts.sh` is the narrow repair command.

There is no newly installed privileged boot service or automatic host restart. The existing verifier can be called by a supported update routine, or run the command above after an update. Off-VM storage guarantees recoverability of the code, not unattended recovery of every VM service.

## Recovery tests

`tests/recovery.cjs` uses disposable directories and local Git remotes only. It simulates deleted/regressed adapters, missing hooks, stale source, corrupted snapshots, dirty/local-ahead/divergent Git trees and an explicitly selected recovery branch. It never starts the real host or contacts registered user computers.

For the optional host-helper tests:

```bash
npm ci --ignore-scripts
SAND_HOST_BUNDLE="$HOME/sand-host/host-main.cjs" npm run test:host-machine-id
```
