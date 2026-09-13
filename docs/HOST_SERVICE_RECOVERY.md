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

Preparation is transactional across enabled components: all previous markers
are invalidated first, all snapshots and the persisted runtime are validated,
and only then are new markers armed. If any marker write fails, every marker is
invalidated again. A global deny marker is written before preparation and
removed only after the complete transaction succeeds. If an old component
marker cannot be deleted, that deny marker blocks it from being used later.
Preparation failure means no reset is authorized.

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
boot ID, a matching checksummed release, and an age of at most 24 hours.
The first recovery attempt claims the marker for that post-reset boot; retries
on a later boot are rejected. Provenance is consumed after a successful health
check.

Those facts prove that preparation happened; they cannot prove why a file is
now absent. A deletion after preparation may be a deliberate revocation.
Restoring deleted pairing data, hook/configuration files, Tailscale state, SSH
host keys, or `authorized_keys` therefore also requires explicit operator
approval:

```bash
GROK_APPROVE_SENSITIVE_RESTORE=1 adapters host-recovery recover
```

Without that approval recovery stops before the first file mutation. Review
the prepared snapshot and live absence before approving. Do not set this
variable permanently or in a routine monitor.

Approved recovery restores absent files only. Existing files—even empty
`authorized_keys`, which can represent deliberate revocation—win over the
snapshot. Differing shared hooks and SSH configuration are preserved. Partial
host-key sets, invalid existing pairing state, stale provenance and failed
post-repair checks stop with a nonzero exit. File publication is lock-protected
and uses create-if-absent semantics; a concurrent file or dangling symlink is
never followed or overwritten. The completed file is atomically published at
its final name, so readers cannot observe an empty or partially copied target.

Linux does not provide an atomic transaction across all of these independent
paths. If an unrelated process changes a target after preflight, recovery
stops; any files already published remain complete and checksummed. Recovery
does not delete them by pathname during rollback, because a concurrent user
replacement could otherwise be deleted. Re-run the monitor, inspect the
reported paths, and retry only after resolving that interference.

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

## Safe staged rollout and rollback

Keep existing jobs in `monitor` mode. Installing a pinned release and actually
authorizing recovery are separate actions:

1. Pin the reviewed commit SHA, review its diff, and run `npm test`; tests use temporary directories,
   local Git remotes and fake service commands only.
2. Stage that exact commit/package in a versioned location. Verify its checksum
   and `adapters host-recovery monitor`; do not replace the active guard yet.
3. Switch the monitor-only guard to the pinned staged release. This does not
   prepare, recover, restart, or authorize restoration.
4. Resolve every nonzero monitor result;
   do not prepare from an unhealthy machine.
5. Run `prepare-reset` immediately before a planned update and retain the
   command output.
6. After the update, run narrow recovery without approval first and inspect the
   missing-file plan. Set one-shot approval only after confirming the deletion
   is from the reset rather than user intent.
7. Inspect any nonzero result.
   Use broad `adapters recover` only when inference/proxy recovery is also
   intended, because that existing command can restart the Grok host.

To roll back, restore the prior scripts/commit and leave the existing
`releases/` directories intact. Do not copy an older release over live
configuration. If intent is ambiguous, remove `reset-provenance.json` and
repair or re-pair manually rather than forcing recovery.
