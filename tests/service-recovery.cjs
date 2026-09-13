'use strict';
// All recovery exercises use disposable homes, state trees and fake commands.
const assert = require('assert').strict;
const fs = require('fs');
const os = require('os');
const path = require('path');
const {spawnSync} = require('child_process');

const root = path.join(__dirname, '..');
const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'grok-service-recovery-'));
const safeEnv = {
  PATH: process.env.PATH || '/usr/local/bin:/usr/bin:/bin',
  LANG: 'C.UTF-8',
  LC_ALL: 'C.UTF-8',
};
const run = (cmd, args, options = {}) => {
  const result = spawnSync(cmd, args, {encoding: 'utf8', ...options});
  if (result.error) throw result.error;
  return result;
};
const ok = (result, status = 0) => {
  assert.equal(result.status, status, `${result.stdout}\n${result.stderr}`);
  return result;
};
const write = (file, content, mode) => {
  fs.mkdirSync(path.dirname(file), {recursive: true});
  fs.writeFileSync(file, content);
  if (mode) fs.chmodSync(file, mode);
};
const executable = (file, content) => write(file, `#!/usr/bin/env bash\n${content}\n`, 0o755);

function baseIdentity(name) {
  const dir = path.join(temp, name);
  const machine = path.join(dir, 'machine-id');
  const boot = path.join(dir, 'boot-id');
  write(machine, 'machine-a\n');
  write(boot, 'boot-a\n');
  return {dir, machine, boot};
}

function publicationTests() {
  const dir = path.join(temp, 'publication');
  const helper = path.join(root, 'scripts/recovery-state.py');
  const source = path.join(dir, 'source');
  const target = path.join(dir, 'target');
  write(source, 'snapshot bytes\n', 0o600);
  const publish = (from, to) => run('python3', [
    helper, 'publish', '--source', from, '--target', to, '--mode', '600',
  ], {env: safeEnv});

  write(target, 'concurrent user bytes\n');
  ok(publish(source, target), 17);
  assert.equal(fs.readFileSync(target, 'utf8'), 'concurrent user bytes\n');

  fs.unlinkSync(target);
  const danglingDestination = path.join(dir, 'dangling-destination');
  fs.symlinkSync(danglingDestination, target);
  ok(publish(source, target), 17);
  assert.equal(fs.lstatSync(target).isSymbolicLink(), true);
  assert.equal(fs.existsSync(danglingDestination), false);

  const blockedParent = path.join(dir, 'blocked-parent');
  write(blockedParent, 'not a directory\n');
  assert.notEqual(publish(source, path.join(blockedParent, 'target')).status, 0);

  fs.unlinkSync(target);
  const sources = [];
  for (let index = 0; index < 8; index++) {
    const candidate = path.join(dir, `source-${index}`);
    write(candidate, `complete-${index}\n`);
    sources.push(candidate);
  }
  ok(run('bash', ['-c', `
for source in "$PUB_DIR"/source-*; do
  python3 "$HELPER" publish --source "$source" --target "$TARGET" &
done
wait || true
`], {env: {...safeEnv, PUB_DIR: dir, HELPER: helper, TARGET: target}}));
  assert.ok(sources.some(candidate =>
    fs.readFileSync(candidate, 'utf8') === fs.readFileSync(target, 'utf8')));

  fs.unlinkSync(target);
  ok(run('python3', ['-c', `
import importlib.util, os, pathlib, types
spec = importlib.util.spec_from_file_location("recovery_state", ${JSON.stringify(helper)})
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
real_link = module.os.link
def checked_link(staged, target, **kwargs):
    assert not os.path.lexists(target), "target became visible before publication"
    assert pathlib.Path(staged).read_bytes() == pathlib.Path(${JSON.stringify(source)}).read_bytes()
    return real_link(staged, target, **kwargs)
module.os.link = checked_link
module.cmd_publish(types.SimpleNamespace(
    source=${JSON.stringify(source)}, target=${JSON.stringify(target)},
    mode="600", owner=None,
))
`], {env: safeEnv}));
  assert.equal(fs.readFileSync(target, 'utf8'), 'snapshot bytes\n');
  console.log('PASS: no-replace publication preserves concurrent files and rejects dangling/blocked targets');
}

function moshiTests() {
  const {dir, machine, boot} = baseIdentity('moshi');
  const home = path.join(dir, 'home');
  const persist = path.join(dir, 'persist');
  const binary = path.join(home, '.local/bin/moshi-hook');
  const secrets = path.join(home, '.local/state/moshi/secrets.json');
  const pairings = path.join(home, '.config/moshi/host-pairings.json');
  const hook = path.join(home, '.cursor/hooks.json');
  const optionalHook = path.join(home, '.codex/hooks.json');
  const deny = path.join(dir, 'recovery-denied');
  executable(binary, '[[ "${1:-}" == status ]] && echo "Status: paired"');
  write(secrets, '{"pairing":"synthetic"}\n', 0o600);
  write(pairings, '{"host":"synthetic"}\n', 0o600);
  write(hook, '{"user":"before"}\n');
  write(optionalHook, '{"moshi":"enabled"}\n');
  const env = {
    ...safeEnv,
    MOSHI_HOME: home,
    MOSHI_PERSIST: persist,
    RECOVERY_MACHINE_ID_FILE: machine,
    RECOVERY_BOOT_ID_FILE: boot,
    MOSHI_DAEMON_CHECK_CMD: 'exit 0',
    GROK_RECOVERY_DENY_FILE: deny,
  };
  const script = path.join(root, 'scripts/ensure-moshi.sh');
  const call = (mode, extra = {}) => run('bash', [script, mode],
    {env: {...env, ...extra}});

  ok(call('prepare-reset'));
  write(deny, 'orchestrator\n', 0o600);
  assert.notEqual(call('prepare-reset').status, 0);
  assert.equal(fs.readFileSync(deny, 'utf8'), 'orchestrator\n',
    'standalone component preparation must not clear an orchestrator deny');
  fs.unlinkSync(deny);
  const lockResult = run('bash', ['-c', `
(
  exec 8>"$MOSHI_PERSIST/.recovery.lock"
  flock -x 8
  : > "$LOCK_READY"
  sleep 1
) &
holder=$!
while [[ ! -f "$LOCK_READY" ]]; do sleep 0.01; done
RECOVERY_LOCK_TIMEOUT=0 bash "$MOSHI_SCRIPT" snapshot
rc=$?
wait "$holder"
exit "$rc"
`], {env: {...env, LOCK_READY: path.join(dir, 'lock-ready'), MOSHI_SCRIPT: script}});
  assert.notEqual(lockResult.status, 0, 'component mutation must respect the recovery lock');
  const helperLog = path.join(dir, 'helper-calls');
  const failingStateHelper = path.join(dir, 'failing-state-helper');
  write(failingStateHelper, `import os, sys
with open(os.environ["HELPER_CALLS"], "a", encoding="utf-8") as log:
    log.write(sys.argv[1] + "\\n")
if sys.argv[1] == os.environ.get("FAIL_HELPER_COMMAND"):
    raise SystemExit(23)
os.execv(sys.executable, [sys.executable, ${JSON.stringify(path.join(root, 'scripts/recovery-state.py'))}, *sys.argv[1:]])
`);
  let failed = call('snapshot', {
    RECOVERY_STATE_HELPER: failingStateHelper,
    FAIL_HELPER_COMMAND: 'create',
    HELPER_CALLS: helperLog,
  });
  assert.notEqual(failed.status, 0);
  assert.doesNotMatch(failed.stdout, /validated Moshi snapshot/);
  failed = call('snapshot', {
    RECOVERY_STATE_HELPER: path.join(dir, 'missing-state-helper.py'),
  });
  assert.notEqual(failed.status, 0);
  assert.doesNotMatch(failed.stdout, /validated Moshi snapshot/);
  fs.rmSync(helperLog);
  failed = call('prepare-reset', {
    RECOVERY_STATE_HELPER: failingStateHelper,
    FAIL_HELPER_COMMAND: 'invalidate-provenance',
    HELPER_CALLS: helperLog,
  });
  assert.notEqual(failed.status, 0);
  assert.deepEqual(fs.readFileSync(helperLog, 'utf8').trim().split('\n'),
    ['invalidate-provenance']);
  assert.equal(fs.existsSync(path.join(persist, 'reset-provenance.json')), true,
    'failed invalidation must stop before replacing old authority');
  assert.equal(fs.existsSync(deny), true);
  write(boot, 'boot-denied\n');
  fs.unlinkSync(secrets);
  assert.notEqual(call('recover', {
    GROK_APPROVE_SENSITIVE_RESTORE: '1',
  }).status, 0);
  assert.equal(fs.existsSync(secrets), false,
    'global deny marker must block surviving stale component authority');
  write(secrets, '{"pairing":"synthetic"}\n', 0o600);
  write(boot, 'boot-a\n');
  fs.rmSync(helperLog);
  failed = call('prepare-reset', {
    RECOVERY_STATE_HELPER: failingStateHelper,
    FAIL_HELPER_COMMAND: 'prepare',
    HELPER_CALLS: helperLog,
  });
  assert.notEqual(failed.status, 0);
  assert.equal(fs.existsSync(path.join(persist, 'reset-provenance.json')), false);
  assert.equal(fs.existsSync(deny), true);
  assert.doesNotMatch(failed.stdout, /recorded Moshi reset provenance/);
  assert.deepEqual(fs.readFileSync(helperLog, 'utf8').trim().split('\n'),
    ['invalidate-provenance', 'create', 'prepare']);
  ok(call('prepare-reset'));
  assert.equal(fs.existsSync(deny), false);
  const current = fs.readlinkSync(path.join(persist, 'current'));
  const releaseDir = fs.realpathSync(path.join(persist, 'current'));
  const snapBinary = path.join(releaseDir, 'bin/moshi-hook');
  fs.chmodSync(snapBinary, 0o644);
  assert.notEqual(run('python3', [path.join(root, 'scripts/recovery-state.py'),
    'verify', '--component', 'moshi', '--persist', persist], {env: safeEnv}).status, 0);
  fs.chmodSync(snapBinary, 0o755);
  write(path.join(releaseDir, 'unmanifested'), 'bad\n');
  assert.notEqual(run('python3', [path.join(root, 'scripts/recovery-state.py'),
    'verify', '--component', 'moshi', '--persist', persist], {env: safeEnv}).status, 0);
  fs.unlinkSync(path.join(releaseDir, 'unmanifested'));
  write(secrets, '{broken json\n');
  assert.notEqual(call('snapshot').status, 0);
  assert.equal(fs.readlinkSync(path.join(persist, 'current')), current,
    'failed snapshot must not replace current');
  assert.notEqual(call('prepare-reset').status, 0);
  assert.equal(fs.existsSync(path.join(persist, 'reset-provenance.json')), false,
    'failed preparation must invalidate older reset provenance');
  write(secrets, '{"pairing":"synthetic"}\n', 0o600);
  ok(call('prepare-reset'));

  const provenancePath = path.join(persist, 'reset-provenance.json');
  const provenance = JSON.parse(fs.readFileSync(provenancePath, 'utf8'));
  const verifyProvenance = () => run('python3', [
    path.join(root, 'scripts/recovery-state.py'), 'verify-provenance',
    '--component', 'moshi', '--persist', persist,
    '--machine-id-file', machine, '--boot-id-file', boot,
  ], {env: safeEnv});
  write(boot, 'boot-probe\n');
  write(machine, 'different-machine\n');
  assert.notEqual(verifyProvenance().status, 0);
  write(machine, 'machine-a\n');
  write(provenancePath, `${JSON.stringify({...provenance, created_at: 0})}\n`);
  assert.notEqual(verifyProvenance().status, 0);
  write(provenancePath,
    `${JSON.stringify({...provenance, created_at: Math.floor(Date.now() / 1000) + 3600})}\n`);
  assert.notEqual(verifyProvenance().status, 0);
  write(provenancePath, `${JSON.stringify(provenance)}\n`);

  write(boot, 'boot-b\n');
  fs.unlinkSync(binary);
  fs.unlinkSync(secrets);
  fs.unlinkSync(pairings);
  fs.unlinkSync(optionalHook);
  write(hook, '{"user":"changed-after-snapshot"}\n');
  assert.notEqual(call('recover').status, 0);
  assert.equal(fs.existsSync(secrets), false,
    'sensitive Moshi deletion must require explicit approval before mutation');
  const failingHelper = path.join(dir, 'fail-optional-helper');
  write(failingHelper, `import os, sys
if sys.argv[1] == "publish" and "--target" in sys.argv:
    target = sys.argv[sys.argv.index("--target") + 1]
    if target == ${JSON.stringify(secrets)}:
        with open(${JSON.stringify(binary)}, "w", encoding="utf-8") as output:
            output.write('#!/bin/sh\\n[ "$1" = status ] && echo "Status: paired"\\n')
        os.chmod(${JSON.stringify(binary)}, 0o755)
    if target == ${JSON.stringify(optionalHook)}:
        os.makedirs(os.path.dirname(${JSON.stringify(optionalHook)}), exist_ok=True)
        with open(${JSON.stringify(optionalHook)}, "w", encoding="utf-8") as output:
            output.write('{"user":"concurrent"}\\n')
os.execv(sys.executable, [sys.executable, ${JSON.stringify(path.join(root, 'scripts/recovery-state.py'))}, *sys.argv[1:]])
`);
  assert.notEqual(call('recover', {
    GROK_APPROVE_SENSITIVE_RESTORE: '1',
    RECOVERY_STATE_HELPER: failingHelper,
  }).status, 0);
  assert.equal(fs.readFileSync(binary, 'utf8').includes('Status: paired'), true,
    'failure handling must preserve a concurrently modified published file');
  assert.equal(fs.readFileSync(secrets, 'utf8'), '{"pairing":"synthetic"}\n',
    'earlier publications remain complete and are never unsafely deleted');
  assert.equal(fs.readFileSync(optionalHook, 'utf8'), '{"user":"concurrent"}\n');
  ok(call('recover', {GROK_APPROVE_SENSITIVE_RESTORE: '1'}));
  assert.equal(fs.readFileSync(hook, 'utf8'), '{"user":"changed-after-snapshot"}\n');
  assert.equal(fs.readFileSync(secrets, 'utf8'), '{"pairing":"synthetic"}\n');
  assert.equal(fs.readFileSync(optionalHook, 'utf8'), '{"user":"concurrent"}\n');
  assert.equal(fs.existsSync(path.join(persist, 'reset-provenance.json')), false);
  ok(call('recover'));

  fs.unlinkSync(pairings);
  const ambiguous = call('recover');
  assert.notEqual(ambiguous.status, 0);
  assert.equal(fs.existsSync(pairings), false,
    'missing pairing without reset provenance must not be resurrected');
  console.log('PASS: Moshi snapshots validate first, preserve hooks, consume provenance and reject ambiguity');
}

function tailscaleFixture(name) {
  const {dir, machine, boot} = baseIdentity(name);
  const home = path.join(dir, 'home');
  const bin = path.join(dir, 'bin');
  const persist = path.join(dir, 'persist');
  const state = path.join(dir, 'tailscaled.state');
  const sshDir = path.join(dir, 'ssh');
  const config = path.join(sshDir, 'sshd_config');
  const auth = path.join(home, '.ssh/authorized_keys');
  const prefs = path.join(dir, 'prefs.json');
  const backend = path.join(dir, 'backend');
  const listening = path.join(dir, 'listening');
  const tailscale = path.join(bin, 'tailscale');
  const tailscaled = path.join(bin, 'tailscaled');
  const sshd = path.join(bin, 'sshd');
  const ss = path.join(bin, 'ss');

  executable(tailscale, `
case "\${1:-}" in
  status) printf '{"BackendState":"%s"}\\n' "$(cat "$MOCK_BACKEND")" ;;
  debug) cat "$MOCK_PREFS" ;;
  set)
    [[ "\${MOCK_SET_FAIL:-0}" == 1 ]] && exit 9
    [[ "\${MOCK_SET_INEFFECTIVE:-0}" == 1 ]] && exit 0
    printf '{"RunSSH":false}\\n' > "$MOCK_PREFS"
    ;;
  *) exit 2 ;;
esac`);
  executable(tailscaled, 'exit 0');
  executable(sshd, '[[ "${1:-}" == -T ]] && echo "port ${MOCK_SSH_PORT:-22}"');
  executable(ss, `
echo 'State Recv-Q Send-Q Local Address:Port Peer Address:Port'
[[ "$(cat "$MOCK_LISTENING")" == 1 ]] && echo "LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:((\\"\${MOCK_LISTENER:-sshd}\\",pid=1,fd=3))"`);
  write(state, 'synthetic tailscale state\n', 0o600);
  write(config, 'Port 22\n# user setting\n');
  write(path.join(sshDir, 'ssh_host_ed25519_key'), 'synthetic private\n', 0o600);
  write(path.join(sshDir, 'ssh_host_ed25519_key.pub'), 'synthetic public\n');
  write(auth, 'ssh-ed25519 synthetic user@example.invalid\n', 0o600);
  write(prefs, '{"RunSSH":false}\n');
  write(backend, 'Running\n');
  write(listening, '1\n');
  const env = {
    ...safeEnv,
    RECOVERY_HOME: home,
    GROK_BOT_TS_SSH_PERSIST: persist,
    RECOVERY_MACHINE_ID_FILE: machine,
    RECOVERY_BOOT_ID_FILE: boot,
    TAILSCALE_BIN: tailscale,
    TAILSCALED_BIN: tailscaled,
    SSHD_BIN: sshd,
    SS_BIN: ss,
    TAILSCALE_STATE_FILE: state,
    OPENSSH_CONFIG_DIR: sshDir,
    SSHD_CONFIG: config,
    AUTHORIZED_KEYS_FILE: auth,
    RECOVERY_NO_SUDO: '1',
    RECOVERY_SYSTEM_OWNER: `${process.getuid()}:${process.getgid()}`,
    MOCK_PREFS: prefs,
    MOCK_BACKEND: backend,
    MOCK_LISTENING: listening,
  };
  return {dir, machine, boot, home, persist, state, sshDir, config, auth, prefs, env};
}

function tailscaleTests() {
  const fixture = tailscaleFixture('tailscale');
  const script = path.join(root, 'scripts/ensure-tailscale-ssh.sh');
  const call = (mode, extra = {}) => run('bash', [script, mode],
    {env: {...fixture.env, ...extra}});
  write(path.join(fixture.dir, 'backend'), 'Stopped\n');
  assert.notEqual(call('monitor').status, 0);
  write(path.join(fixture.dir, 'backend'), 'Running\n');
  assert.notEqual(call('monitor', {MOCK_SSH_PORT: '2222'}).status, 0);
  assert.notEqual(call('monitor', {MOCK_LISTENER: 'other'}).status, 0);
  ok(call('prepare-reset'));
  const failHelper = path.join(fixture.dir, 'failing-state-helper');
  write(failHelper, `import os, sys
if sys.argv[1] == os.environ.get("FAIL_HELPER_COMMAND"):
    raise SystemExit(29)
os.execv(sys.executable, [sys.executable, ${JSON.stringify(path.join(root, 'scripts/recovery-state.py'))}, *sys.argv[1:]])
`);
  assert.notEqual(call('prepare-reset', {
    RECOVERY_STATE_HELPER: failHelper,
    FAIL_HELPER_COMMAND: 'create',
  }).status, 0);
  assert.equal(fs.existsSync(path.join(fixture.persist, 'reset-provenance.json')), false);
  ok(call('prepare-reset'));
  assert.notEqual(call('prepare-reset', {
    RECOVERY_STATE_HELPER: failHelper,
    FAIL_HELPER_COMMAND: 'prepare',
  }).status, 0);
  assert.equal(fs.existsSync(path.join(fixture.persist, 'reset-provenance.json')), false);
  ok(call('prepare-reset'));

  // A deliberate key removal remains authoritative on routine healthy runs.
  write(fixture.auth, '', 0o600);
  ok(call('recover'));
  assert.equal(fs.readFileSync(fixture.auth, 'utf8'), '');

  // A failed RunSSH correction must be visible and leave provenance reusable.
  write(fixture.boot, 'boot-b\n');
  write(fixture.prefs, '{"RunSSH":true}\n');
  ok(call('recover', {MOCK_SET_FAIL: '1'}), 5);
  assert.equal(fs.existsSync(path.join(fixture.persist, 'reset-provenance.json')), true);
  write(fixture.boot, 'boot-other\n');
  assert.notEqual(call('recover').status, 0,
    'provenance claimed by one recovery boot must fail on later boots');
  write(fixture.boot, 'boot-b\n');
  ok(call('recover', {MOCK_SET_INEFFECTIVE: '1'}), 5);
  ok(call('recover'), 10);
  assert.equal(fs.readFileSync(fixture.auth, 'utf8'), '',
    'Tailscale repair must not resurrect removed keys');

  // Prepare a fresh update, then simulate reset-deleted files and a user config edit.
  write(fixture.auth, 'ssh-ed25519 replacement user@example.invalid\n', 0o600);
  write(fixture.boot, 'boot-c\n');
  ok(call('prepare-reset'));
  write(fixture.config, 'Port 22\n# changed by user after preparation\n');
  fs.unlinkSync(fixture.state);
  fs.unlinkSync(fixture.auth);
  fs.unlinkSync(path.join(fixture.sshDir, 'ssh_host_ed25519_key'));
  fs.unlinkSync(path.join(fixture.sshDir, 'ssh_host_ed25519_key.pub'));
  write(fixture.boot, 'boot-d\n');
  const racingHelper = path.join(fixture.dir, 'racing-state-helper');
  const concurrentPublic = path.join(fixture.sshDir, 'ssh_host_ed25519_key.pub');
  write(racingHelper, `import os, sys
if sys.argv[1] == "publish" and "--target" in sys.argv:
    target = sys.argv[sys.argv.index("--target") + 1]
    if target.endswith("ssh_host_ed25519_key"):
        with open(${JSON.stringify(concurrentPublic)}, "w", encoding="utf-8") as output:
            output.write("concurrent public key\\n")
os.execv(sys.executable, [sys.executable, ${JSON.stringify(path.join(root, 'scripts/recovery-state.py'))}, *sys.argv[1:]])
`);
  assert.notEqual(call('recover', {
    GROK_APPROVE_SENSITIVE_RESTORE: '1',
    RECOVERY_STATE_HELPER: racingHelper,
  }).status, 0);
  assert.equal(fs.existsSync(fixture.state), false);
  assert.equal(fs.existsSync(fixture.auth), false);
  assert.equal(fs.readFileSync(
    path.join(fixture.sshDir, 'ssh_host_ed25519_key'), 'utf8'), 'synthetic private\n');
  assert.equal(fs.readFileSync(concurrentPublic, 'utf8'), 'concurrent public key\n');
  fs.unlinkSync(path.join(fixture.sshDir, 'ssh_host_ed25519_key'));
  fs.unlinkSync(concurrentPublic);
  assert.notEqual(call('recover', {
    GROK_APPROVE_SENSITIVE_RESTORE: '1',
    RECOVERY_SYSTEM_OWNER: 'no-such-user:no-such-group',
  }).status, 0);
  assert.equal(fs.existsSync(fixture.state), false,
    'failed privileged ownership must remove the partial restore');
  ok(call('recover', {GROK_APPROVE_SENSITIVE_RESTORE: '1'}), 10);
  assert.match(fs.readFileSync(fixture.config, 'utf8'), /changed by user/);
  assert.match(fs.readFileSync(fixture.auth, 'utf8'), /replacement/);
  ok(call('recover'));

  // A host key removed during later file publication rolls those files back.
  write(fixture.boot, 'boot-e\n');
  ok(call('prepare-reset'));
  fs.unlinkSync(fixture.state);
  write(fixture.boot, 'boot-f\n');
  const lateRemovalHelper = path.join(fixture.dir, 'late-removal-helper');
  write(lateRemovalHelper, `import os, sys
if sys.argv[1] == "publish" and "--target" in sys.argv:
    target = sys.argv[sys.argv.index("--target") + 1]
    if target == ${JSON.stringify(fixture.state)}:
        os.unlink(${JSON.stringify(path.join(fixture.sshDir, 'ssh_host_ed25519_key.pub'))})
os.execv(sys.executable, [sys.executable, ${JSON.stringify(path.join(root, 'scripts/recovery-state.py'))}, *sys.argv[1:]])
`);
  assert.notEqual(call('recover', {
    GROK_APPROVE_SENSITIVE_RESTORE: '1',
    RECOVERY_STATE_HELPER: lateRemovalHelper,
  }).status, 0);
  assert.equal(fs.readFileSync(fixture.state, 'utf8'), 'synthetic tailscale state\n',
    'late interference may leave only fully published files, never partial bytes');
  write(path.join(fixture.sshDir, 'ssh_host_ed25519_key.pub'), 'synthetic public\n');

  // A replacement host-key set is authoritative even when another file needs recovery.
  write(fixture.boot, 'boot-g\n');
  ok(call('prepare-reset'));
  fs.unlinkSync(path.join(fixture.sshDir, 'ssh_host_ed25519_key'));
  fs.unlinkSync(path.join(fixture.sshDir, 'ssh_host_ed25519_key.pub'));
  fs.mkdirSync(path.join(fixture.sshDir, 'ssh_host_ed25519_key'));
  fs.unlinkSync(fixture.state);
  write(fixture.boot, 'boot-h\n');
  assert.notEqual(call('recover', {GROK_APPROVE_SENSITIVE_RESTORE: '1'}).status, 0);
  assert.equal(fs.existsSync(fixture.state), false);
  assert.equal(fs.statSync(path.join(fixture.sshDir, 'ssh_host_ed25519_key')).isDirectory(), true);
  fs.rmdirSync(path.join(fixture.sshDir, 'ssh_host_ed25519_key'));
  write(path.join(fixture.sshDir, 'ssh_host_rsa_key'), 'replacement private\n', 0o600);
  write(path.join(fixture.sshDir, 'ssh_host_rsa_key.pub'), 'replacement public\n');
  assert.notEqual(call('recover', {GROK_APPROVE_SENSITIVE_RESTORE: '1'}).status, 0);
  assert.equal(fs.existsSync(fixture.state), false,
    'host-key ambiguity must be detected before restoring other SSH/VPN files');
  assert.equal(fs.existsSync(path.join(fixture.sshDir, 'ssh_host_ed25519_key')), false);
  assert.equal(fs.existsSync(path.join(fixture.sshDir, 'ssh_host_rsa_key')), true);

  // A partial host-key set is not silently completed from a historical set.
  write(fixture.state, 'synthetic tailscale state\n', 0o600);
  ok(call('prepare-reset'));
  fs.unlinkSync(path.join(fixture.sshDir, 'ssh_host_rsa_key.pub'));
  write(fixture.boot, 'boot-i\n');
  const partial = call('recover', {GROK_APPROVE_SENSITIVE_RESTORE: '1'});
  assert.notEqual(partial.status, 0);
  assert.equal(fs.existsSync(path.join(fixture.sshDir, 'ssh_host_rsa_key.pub')), false);
  console.log('PASS: SSH keys/config preserve user intent; RunSSH=false is verified; partial state fails');
}

function wiringTests() {
  const dir = path.join(temp, 'wiring');
  const scripts = path.join(dir, 'scripts');
  const calls = path.join(dir, 'calls');
  const moshiMarker = path.join(dir, 'moshi-authority');
  const tsMarker = path.join(dir, 'ts-authority');
  fs.mkdirSync(scripts, {recursive: true});
  executable(path.join(scripts, 'ensure-moshi.sh'),
    `echo "moshi:$1" >> "$MOCK_CALLS"
key="MOSHI_\${1//-/_}_RC"
rc="\${!key:-\${MOSHI_RC:-0}}"
if [[ "$rc" == 0 ]]; then
  [[ "$1" == invalidate-reset ]] && rm -f "$MOSHI_MARKER"
  [[ "$1" == arm-reset ]] && : > "$MOSHI_MARKER"
fi
exit "$rc"`);
  executable(path.join(scripts, 'ensure-tailscale-ssh.sh'),
    `echo "tailscale:$1" >> "$MOCK_CALLS"
key="TS_\${1//-/_}_RC"
rc="\${!key:-\${TS_RC:-0}}"
if [[ "$rc" == 0 ]]; then
  [[ "$1" == invalidate-reset ]] && rm -f "$TS_MARKER"
  [[ "$1" == arm-reset ]] && : > "$TS_MARKER"
fi
exit "$rc"`);
  const env = {
    ...safeEnv,
    HOME: path.join(dir, 'orchestrator-home'),
    GROK_RECOVERY_SCRIPT_DIR: scripts,
    GROK_RECOVERY_FORCE_COMPONENTS: '1',
    MOCK_CALLS: calls,
    MOSHI_MARKER: moshiMarker,
    TS_MARKER: tsMarker,
  };
  const orchestrator = path.join(root, 'scripts/recover-host-services.sh');
  ok(run('bash', [orchestrator, 'recover'], {env: {...env, MOSHI_RC: '10'}}), 10);
  assert.deepEqual(fs.readFileSync(calls, 'utf8').trim().split('\n'),
    ['moshi:recover', 'tailscale:recover']);
  fs.rmSync(calls);
  ok(run('bash', [orchestrator, 'recover'], {env: {...env, TS_RC: '7'}}), 7);

  const prepBase = {
    ...env,
    GROK_RECOVERY_SOURCE_DIR: path.join(root, 'scripts'),
    GROK_BOT_PERSIST_ROOT: path.join(dir, 'prepare-persist'),
  };
  const globalDeny = path.join(prepBase.GROK_BOT_PERSIST_ROOT, '.recovery-denied');
  const prep = extra => run('bash', [orchestrator, 'prepare-reset'],
    {env: {...prepBase, ...extra}});
  const readCalls = () => fs.readFileSync(calls, 'utf8').trim().split('\n');

  fs.rmSync(calls);
  write(moshiMarker, 'old\n');
  write(tsMarker, 'old\n');
  assert.notEqual(prep({MOSHI_invalidate_reset_RC: '7'}).status, 0);
  assert.deepEqual(readCalls(), ['moshi:invalidate-reset', 'tailscale:invalidate-reset']);
  assert.equal(fs.existsSync(moshiMarker), true);
  assert.equal(fs.existsSync(tsMarker), false,
    'later components must still invalidate after an earlier invalidation failure');
  assert.equal(fs.existsSync(globalDeny), true);

  fs.rmSync(calls);
  fs.rmSync(moshiMarker, {force: true});
  assert.notEqual(prep({TS_snapshot_RC: '8'}).status, 0);
  assert.deepEqual(readCalls(), [
    'moshi:invalidate-reset', 'tailscale:invalidate-reset',
    'moshi:snapshot', 'tailscale:snapshot',
  ]);
  assert.equal(fs.existsSync(moshiMarker), false);
  assert.equal(fs.existsSync(tsMarker), false);
  assert.equal(fs.existsSync(globalDeny), true);

  fs.rmSync(calls);
  assert.notEqual(prep({TS_arm_reset_RC: '9'}).status, 0);
  assert.deepEqual(readCalls(), [
    'moshi:invalidate-reset', 'tailscale:invalidate-reset',
    'moshi:snapshot', 'tailscale:snapshot',
    'moshi:arm-reset', 'tailscale:arm-reset',
    'moshi:invalidate-reset', 'tailscale:invalidate-reset',
  ]);
  assert.equal(fs.existsSync(moshiMarker), false);
  assert.equal(fs.existsSync(tsMarker), false,
    'partial marker publication must be rolled back for every component');
  assert.equal(fs.existsSync(globalDeny), true);

  const badSource = path.join(dir, 'bad-runtime-source');
  fs.mkdirSync(badSource, {recursive: true});
  for (const file of [
    'recover-host-services.sh', 'ensure-moshi.sh', 'ensure-tailscale-ssh.sh',
    'restore-after-reset.sh',
  ]) {
    fs.copyFileSync(path.join(root, 'scripts', file), path.join(badSource, file));
  }
  write(path.join(badSource, 'recovery-state.py'), 'raise SystemExit(19)\n');
  fs.rmSync(calls);
  assert.notEqual(prep({GROK_RECOVERY_SOURCE_DIR: badSource}).status, 0);
  assert.deepEqual(readCalls(), [
    'moshi:invalidate-reset', 'tailscale:invalidate-reset',
    'moshi:snapshot', 'tailscale:snapshot',
  ]);
  assert.equal(fs.existsSync(moshiMarker), false);
  assert.equal(fs.existsSync(tsMarker), false);
  assert.equal(fs.existsSync(globalDeny), true);

  const adaptersCalls = path.join(dir, 'adapter-calls');
  executable(path.join(dir, 'host-recovery.sh'),
    'echo "$1" > "$MOCK_ADAPTER_CALLS"; exit "${HOST_RECOVERY_RC:-0}"');
  const adaptersEnv = {
    ...safeEnv,
    HOME: path.join(dir, 'adapter-home'),
    GROK_HOST_RECOVERY_SCRIPT: path.join(dir, 'host-recovery.sh'),
    GROK_RECOVERY_COMPONENTS_ONLY: '1',
    MOCK_ADAPTER_CALLS: adaptersCalls,
  };
  ok(run('bash', [path.join(root, 'adapters.sh'), 'recover'],
    {env: {...adaptersEnv, HOST_RECOVERY_RC: '9'}}), 9);
  assert.equal(fs.readFileSync(adaptersCalls, 'utf8').trim(), 'recover');
  ok(run('bash', [path.join(root, 'adapters.sh'), 'recover'],
    {env: {...adaptersEnv, HOST_RECOVERY_RC: '10'}}));

  // The real bootstrap -> adapters recover path reaches both components.
  const gitEnv = {
    ...safeEnv,
    GIT_CONFIG_NOSYSTEM: '1',
    GIT_CONFIG_GLOBAL: '/dev/null',
    GIT_AUTHOR_NAME: 'Recovery Test',
    GIT_AUTHOR_EMAIL: 'recovery@example.invalid',
    GIT_COMMITTER_NAME: 'Recovery Test',
    GIT_COMMITTER_EMAIL: 'recovery@example.invalid',
  };
  const git = (cwd, ...args) => ok(run('git', ['-C', cwd, ...args], {env: gitEnv}));
  const seed = path.join(dir, 'seed');
  const remote = path.join(dir, 'remote.git');
  const bootCheckout = path.join(dir, 'boot-checkout');
  fs.mkdirSync(path.join(seed, 'scripts'), {recursive: true});
  for (const file of ['adapters', 'adapters.sh', 'xai-prompt-session.cjs']) {
    fs.copyFileSync(path.join(root, file), path.join(seed, file));
  }
  fs.chmodSync(path.join(seed, 'adapters'), 0o755);
  fs.chmodSync(path.join(seed, 'adapters.sh'), 0o755);
  fs.copyFileSync(orchestrator, path.join(seed, 'scripts/recover-host-services.sh'));
  fs.chmodSync(path.join(seed, 'scripts/recover-host-services.sh'), 0o755);
  fs.copyFileSync(path.join(scripts, 'ensure-moshi.sh'),
    path.join(seed, 'scripts/ensure-moshi.sh'));
  fs.copyFileSync(path.join(scripts, 'ensure-tailscale-ssh.sh'),
    path.join(seed, 'scripts/ensure-tailscale-ssh.sh'));
  fs.chmodSync(path.join(seed, 'scripts/ensure-moshi.sh'), 0o755);
  fs.chmodSync(path.join(seed, 'scripts/ensure-tailscale-ssh.sh'), 0o755);
  git(seed, 'init', '-b', 'main');
  git(seed, 'add', '.');
  git(seed, 'commit', '-m', 'fixture');
  ok(run('git', ['clone', '--bare', seed, remote], {env: gitEnv}));
  const standalone = path.join(dir, 'bootstrap.sh');
  fs.copyFileSync(path.join(root, 'scripts/bootstrap.sh'), standalone);
  const bootEnv = {
    ...gitEnv,
    HOME: path.join(dir, 'bootstrap-home'),
    GROK_BOT_SETUP_DIR: bootCheckout,
    GROK_BOT_SETUP_REPO: remote,
    GROK_BOT_SETUP_REF: 'main',
    GROK_RECOVERY_COMPONENTS_ONLY: '1',
    GROK_RECOVERY_FORCE_COMPONENTS: '1',
    GROK_RECOVERY_SCRIPT_DIR: path.join(bootCheckout, 'scripts'),
    MOCK_CALLS: path.join(dir, 'bootstrap-calls'),
  };
  ok(run('bash', [standalone], {env: bootEnv}));
  assert.deepEqual(fs.readFileSync(bootEnv.MOCK_CALLS, 'utf8').trim().split('\n'),
    ['moshi:recover', 'tailscale:recover']);
  fs.rmSync(bootEnv.MOCK_CALLS);
  ok(run('bash', [standalone], {env: {...bootEnv, TS_RC: '8'}}), 8);

  // A persisted wrapper resolves the checkout and preserves its failure status.
  const persistWrapper = path.join(dir, 'persist/scripts/restore-after-reset.sh');
  fs.mkdirSync(path.dirname(persistWrapper), {recursive: true});
  fs.copyFileSync(path.join(root, 'scripts/restore-after-reset.sh'), persistWrapper);
  fs.chmodSync(persistWrapper, 0o755);
  const checkout = path.join(dir, 'checkout');
  executable(path.join(checkout, 'adapters.sh'), 'exit 6');
  ok(run('bash', [persistWrapper], {
    env: {...safeEnv, HOME: path.join(dir, 'wrapper-home'), GROK_BOT_SETUP_DIR: checkout},
  }), 6);

  // A checkout-less wrapper executes only a checksummed persisted runtime.
  const persistRoot = path.join(dir, 'validated-persist');
  const runtimeEnv = {
    ...env,
    RECOVERY_HOME: path.join(dir, 'runtime-home'),
    GROK_BOT_PERSIST_ROOT: persistRoot,
    GROK_RECOVERY_SOURCE_DIR: path.join(root, 'scripts'),
  };
  ok(run('bash', [orchestrator, 'prepare-reset'], {env: runtimeEnv}));
  const validatedWrapper = path.join(persistRoot, 'scripts/restore-after-reset.sh');
  fs.mkdirSync(path.dirname(validatedWrapper), {recursive: true});
  fs.copyFileSync(path.join(root, 'scripts/restore-after-reset.sh'), validatedWrapper);
  fs.chmodSync(validatedWrapper, 0o755);
  const runtimeCalls = path.join(dir, 'runtime-calls');
  const fallbackEnv = {
    ...runtimeEnv,
    MOCK_CALLS: runtimeCalls,
    GROK_BOT_SETUP_DIR: path.join(dir, 'missing-checkout'),
    TS_RC: '7',
  };
  ok(run('bash', [validatedWrapper], {env: fallbackEnv}), 7);
  const runtimeCurrent = fs.realpathSync(
    path.join(persistRoot, 'recovery-runtime/current'));
  fs.appendFileSync(path.join(runtimeCurrent, 'scripts/recover-host-services.sh'), '\n# corrupt\n');
  fs.rmSync(runtimeCalls);
  assert.notEqual(run('bash', [validatedWrapper], {env: fallbackEnv}).status, 0);
  assert.equal(fs.existsSync(runtimeCalls), false,
    'corrupt persisted runtime must be rejected before component execution');
  console.log('PASS: orchestrator, adapters recover and persisted wrapper propagate component failures');
}

try {
  publicationTests();
  moshiTests();
  tailscaleTests();
  wiringTests();
} finally {
  fs.rmSync(temp, {recursive: true, force: true});
}
