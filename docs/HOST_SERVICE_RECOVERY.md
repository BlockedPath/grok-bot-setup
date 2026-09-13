# Safe Moshi, Tailscale and OpenSSH recovery

These guards protect local service state without treating every missing file as
proof of a reset. Their fixed policy is:

- Tailscale VPN must be `Running`.
- Tailscale SSH must remain off (`RunSSH=false`).
- Normal OpenSSH must remain on effective port 22.
- Existing Moshi/shared hook configuration and `authorized_keys` are
  authoritative and are never overwritten or line-merged from a backup.

The guards do not run `tailscale up`, change routes or DNS, bypass tailnet
approval, re-pair Moshi, or restart the Grok host.

## Routine monitor

```bash
adapters host-recovery monitor
```

This is read-only. Optional components not installed and not enrolled are
skipped. An enrolled unhealthy component exits nonzero instead of repairing
from an ambiguous backup. Existing monitor-only scheduling can continue to use
this mode until a reviewed recovery release is deployed.

## Prepare immediately before an expected computer update

```bash
adapters host-recovery prepare-reset
```

Each enabled component must be healthy before its snapshot can become
`current`. Snapshot creation uses a staging directory, validates required
files, writes per-file SHA-256 checksums, and only then atomically updates the
`current` symlink. A failed, missing or partial snapshot cannot replace the
last valid snapshot.

Preparation also records the snapshot release, a machine-id hash, boot ID and
timestamp. Change or remove any access/configuration state after preparation?
Run preparation again, or delete that component's
`reset-provenance.json`. This prevents an older prepared state from being
mistaken for current intent. Starting a new preparation invalidates an older
marker before validation, so a failed preparation cannot leave stale recovery
authority active.

Default same-disk locations:

```text
~/.local/share/grok-bot-persist/moshi/
~/.local/share/grok-bot-persist/tailscale-ssh/
```

## Recover after the update

The broad reset path reaches the guards before inference/proxy recovery:

```bash
adapters recover
```

The narrow path does not restart the Grok host:

```bash
adapters host-recovery recover
```

Destructive restoration requires provenance from the same machine, a different
boot ID, a matching checksummed release, and an age of at most seven days.
The first recovery attempt claims the marker for that post-reset boot; retries
on a later boot are rejected. Provenance is consumed after a successful health
check.

Recovery restores absent files only. Existing files—even empty
`authorized_keys`, which can represent deliberate revocation—win over the
snapshot. Differing shared hooks and SSH configuration are preserved. Partial
host-key sets, invalid existing pairing state, stale provenance and failed
post-repair checks stop with a nonzero exit.

If needed, recovery starts tailscaled/OpenSSH/Moshi through their normal local
service commands. It never invokes `tailscale up`. If `RunSSH` is true, it only
issues `tailscale set --ssh=false` and then reads preferences again; a failed
or ineffective setting change is an error.

Exit `0` means healthy/no restoration, `10` means a component restored state,
and any other nonzero status means recovery is incomplete. Bootstrap and the
persisted reset wrapper preserve failures instead of masking them. Preparation
also creates a checksummed recovery-runtime snapshot; checkout-less fallback
verifies that snapshot before executing it.

## Same-disk limitation

These snapshots survive host-bundle or checkout replacement on the same disk.
They do not survive deletion, loss or rollback of the whole VM/disk. They are
not an off-machine backup and intentionally do not contain transferable
credentials in Git. A full-machine loss can require Tailscale login, Moshi
pairing and SSH trust setup again.

## Safe rollout and rollback

Before changing an existing monitor:

1. Review the branch and run `npm test`; tests use temporary directories,
   local Git remotes and fake service commands only.
2. Run `adapters host-recovery monitor` manually. Resolve every nonzero result;
   do not prepare from an unhealthy machine.
3. Run `prepare-reset` immediately before the planned update and retain the
   command output.
4. After the update, run narrow recovery first and inspect any nonzero result.
   Use broad `adapters recover` only when inference/proxy recovery is also
   intended, because that existing command can restart the Grok host.

To roll back, restore the prior scripts/commit and leave the existing
`releases/` directories intact. Do not copy an older release over live
configuration. If intent is ambiguous, remove `reset-provenance.json` and
repair or re-pair manually rather than forcing recovery.
