'use strict';
// All destructive simulations use disposable directories, local Git remotes and
// a stub recovery command. Never invoke the live host or restart any service.
const assert = require('assert').strict;
const fs = require('fs');
const os = require('os');
const path = require('path');
const {spawnSync} = require('child_process');
const root = path.join(__dirname,'..');
const temp = fs.mkdtempSync(path.join(os.tmpdir(),'grok-fix-recovery-'));
function run(cmd,args,options={}) {
  const result=spawnSync(cmd,args,{encoding:'utf8',...options});
  if(result.error)throw result.error;
  return result;
}
function ok(result,status=0) {
  assert.equal(result.status,status,result.stdout+'\n'+result.stderr);
  return result;
}
const env={...process.env,GIT_CONFIG_NOSYSTEM:'1',GIT_CONFIG_GLOBAL:'/dev/null',GIT_AUTHOR_NAME:'Recovery Test',GIT_AUTHOR_EMAIL:'recovery@example.invalid',GIT_COMMITTER_NAME:'Recovery Test',GIT_COMMITTER_EMAIL:'recovery@example.invalid'};
function git(dir,...args){return ok(run('git',['-C',dir,...args],{env}));}
try {
  const backup=path.join(temp,'backup');
  const host=path.join(temp,'host');fs.mkdirSync(host);
  const recoveryEnv={...env,GROK_TOOL_FIX_BACKUP_DIR:backup,SAND_HOST_DIR:host};
  ok(run('bash',[path.join(root,'scripts/preserve-tool-contracts.sh')],{env:recoveryEnv}));
  const current=path.join(backup,'current');
  const release=fs.readlinkSync(current);
  ok(run('bash',[path.join(root,'scripts/preserve-tool-contracts.sh')],{env:recoveryEnv}));
  assert.equal(fs.readlinkSync(current),release,'identical snapshots must be idempotent');
  const expected=fs.readFileSync(path.join(root,'xai-prompt-session.cjs'),'utf8');
  const adapter=path.join(host,'xai-prompt-session.cjs');
  const bundle=path.join(host,'host-main.cjs');
  fs.writeFileSync(bundle,'// createXaiPromptSession\n');
  const restore=()=>run('bash',[path.join(current,'scripts/restore-tool-contracts.sh')],{env:recoveryEnv});
  ok(restore(),10); // Missing adapter after an update.
  assert.equal(fs.readFileSync(adapter,'utf8'),expected);
  ok(restore());
  fs.writeFileSync(adapter,expected.replace('        strict: false,','').replace('Preserve omitted end_turn: progress updates must not end the host turn.','old normalization'));
  ok(restore(),10); // Both regressions reintroduced by an update.
  assert.equal(fs.readFileSync(adapter,'utf8'),expected);
  const unpatchedHost='function createSession() {\n      const requestedModel = "test";\n      const inferenceOptions = {};\n      return createCursorInferencePromptSession(inferenceOptions);\n}\n';
  fs.writeFileSync(bundle,unpatchedHost);
  ok(restore(),10); // Host hook lost but adapter survived.
  assert.ok(fs.readFileSync(bundle,'utf8').includes('require("./xai-prompt-session.cjs")'));
  assert.equal(fs.readFileSync(adapter,'utf8'),expected);
  ok(restore());
  ok(run('node',['--check',bundle]));
  console.log('PASS: isolated update restores missing/regressed adapter and lost hook; snapshot/restore are idempotent');

  const stale=path.join(temp,'stale.cjs');fs.writeFileSync(stale,'module.exports = {};\n');
  const verify=path.join(current,'scripts/verify-tool-patch.sh');
  fs.writeFileSync(bundle,unpatchedHost);
  ok(run('bash',[verify],{env:{...recoveryEnv,XAI_SESSION_SRC:stale}}),3);
  assert.equal(fs.readFileSync(adapter,'utf8'),expected,'hook repair must not install stale source');
  assert.equal(fs.readFileSync(bundle,'utf8'),unpatchedHost);
  fs.writeFileSync(path.join(current,'xai-prompt-session.cjs'),'// corrupt snapshot\n');
  const corrupt=restore();assert.notEqual(corrupt.status,0);assert.match(corrupt.stderr,/checksum mismatch/);
  assert.equal(fs.readFileSync(adapter,'utf8'),expected);
  console.log('PASS: stale source and corrupted snapshots rejected without overwriting installed adapter');

  // Bootstrap fixtures: only a local file://-style Git remote, no real network.
  const seed=path.join(temp,'seed'),remote=path.join(temp,'remote.git'),checkout=path.join(temp,'checkout');
  fs.mkdirSync(seed);git(seed,'init','-b','main');
  fs.writeFileSync(path.join(seed,'adapters.sh'),'#!/bin/sh\nprintf recovery > "$RECOVERY_CALLED"\n');
  fs.writeFileSync(path.join(seed,'adapters'),'#!/bin/sh\nexit 0\n');
  fs.writeFileSync(path.join(seed,'xai-prompt-session.cjs'),'baseline\n');
  fs.mkdirSync(path.join(seed,'scripts'));fs.writeFileSync(path.join(seed,'scripts/stub.sh'),'#!/bin/sh\n');
  git(seed,'add','.');git(seed,'commit','-m','baseline');
  ok(run('git',['clone','--bare',seed,remote],{env}));
  ok(run('git',['clone',remote,checkout],{env}));
  const standaloneDir=path.join(temp,'standalone');fs.mkdirSync(standaloneDir);
  const bootstrap=path.join(standaloneDir,'bootstrap.sh');fs.copyFileSync(path.join(root,'scripts/bootstrap.sh'),bootstrap);
  const called=path.join(temp,'called');
  const bootEnv={...env,GROK_BOT_SETUP_DIR:checkout,GROK_BOT_SETUP_REPO:remote,GROK_BOT_SETUP_REF:'main',RECOVERY_CALLED:called};
  const boot=()=>run('bash',[bootstrap],{env:bootEnv});
  fs.writeFileSync(path.join(checkout,'xai-prompt-session.cjs'),'local fixes\n');
  assert.notEqual(boot().status,0);assert.equal(fs.existsSync(called),false);
  assert.equal(fs.readFileSync(path.join(checkout,'xai-prompt-session.cjs'),'utf8'),'local fixes\n');
  git(checkout,'add','.');git(checkout,'commit','-m','local fixes');
  const localHead=git(checkout,'rev-parse','HEAD').stdout.trim();
  ok(boot());assert.equal(git(checkout,'rev-parse','HEAD').stdout.trim(),localHead);
  assert.equal(fs.readFileSync(called,'utf8'),'recovery');fs.unlinkSync(called);
  fs.writeFileSync(path.join(seed,'upstream.txt'),'new upstream\n');git(seed,'add','.');git(seed,'commit','-m','upstream');git(seed,'push',remote,'main');
  assert.notEqual(boot().status,0);assert.equal(fs.existsSync(called),false);
  assert.equal(git(checkout,'rev-parse','HEAD').stdout.trim(),localHead);
  const fresh=path.join(temp,'fresh');
  git(seed,'branch','tool-fixes');git(seed,'push',remote,'tool-fixes');
  ok(run('bash',[bootstrap],{env:{...bootEnv,GROK_BOT_SETUP_DIR:fresh,GROK_BOT_SETUP_REF:'tool-fixes'}}));
  assert.equal(git(fresh,'branch','--show-current').stdout.trim(),'tool-fixes');
  console.log('PASS: bootstrap preserves dirty/local-ahead fixes, refuses divergent updates, supports explicit recovery branch');
} finally {
  fs.rmSync(temp,{recursive:true,force:true});
}
