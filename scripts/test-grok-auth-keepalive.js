#!/usr/bin/env node
"use strict";
/**
 * M3: expired grok auth must not return the dead key.
 * Never hits live auth.x.ai, adapters, or --go.
 */
const fs = require("fs");
const os = require("os");
const path = require("path");
const assert = require("assert");

const ROOT = path.join(__dirname, "..");
const WORKDIR = fs.mkdtempSync(path.join(os.tmpdir(), "grok-auth-m3-"));
const AUTH = path.join(WORKDIR, "auth.json");

delete process.env.XAI_API_KEY;
delete process.env.GROK_CODE_XAI_API_KEY;
delete process.env.GROK_XAI_API_KEY;
delete process.env.GROK_SESSION_TOKEN;
process.env.GROK_AUTH_FILE = AUTH;
process.env.SAND_XAI_ENV_FILE = path.join(WORKDIR, "missing.env");
process.env.SAND_AGENT_INFERENCE_POLICY = path.join(ROOT, "examples/agent-inference-policy.json");

const KEY = "TEST_KEY_DO_NOT_LEAK";
const REFRESH = "TEST_REFRESH_DO_NOT_LEAK";
const COS = "5cadd652-c086-4ef2-8b64-e9c466e848b8";

function isoOffset(seconds) {
  return new Date(Date.now() + seconds * 1000).toISOString().replace(/\.\d{3}Z$/, "Z");
}

function writeAuth(expiresAt) {
  fs.writeFileSync(
    AUTH,
    JSON.stringify({
      "https://auth.x.ai": {
        key: KEY,
        refresh_token: REFRESH,
        expires_at: expiresAt,
        auth_mode: "oidc",
        email: "secret@example.com",
      },
    })
  );
}

const mod = require(path.join(ROOT, "xai-prompt-session.cjs"));

let pass = 0;
let fail = 0;

function check(name, fn) {
  try {
    const r = fn();
    if (r && typeof r.then === "function") {
      return r
        .then(() => {
          console.log("ok ", name);
          pass += 1;
        })
        .catch((e) => {
          console.log("FAIL", name, e && e.message ? e.message : e);
          fail += 1;
        });
    }
    console.log("ok ", name);
    pass += 1;
    return Promise.resolve();
  } catch (e) {
    console.log("FAIL", name, e && e.message ? e.message : e);
    fail += 1;
    return Promise.resolve();
  }
}

(async () => {
  await check("exports grokSessionToken + grokAuthProbe + resolveAuth", () => {
    assert.strictEqual(typeof mod.grokSessionToken, "function");
    assert.strictEqual(typeof mod.grokAuthProbe, "function");
    assert.strictEqual(typeof mod.resolveAuth, "function");
  });

  writeAuth(isoOffset(36000));
  await check("fresh key is returned", () => {
    const probe = mod.grokAuthProbe();
    assert.strictEqual(probe.status, "ok");
    assert.strictEqual(probe.has_key, true);
    assert.strictEqual(mod.grokSessionToken(), KEY);
    const auth = mod.resolveAuth();
    assert.strictEqual(auth.mode, "session");
    assert.strictEqual(auth.token, KEY);
  });

  writeAuth(isoOffset(1800));
  await check("soon still returns key (no auto-refresh in hook)", () => {
    const probe = mod.grokAuthProbe();
    assert.strictEqual(probe.status, "soon");
    assert.strictEqual(mod.grokSessionToken(), KEY);
  });

  writeAuth(isoOffset(-7200));
  await check("expired probe does not include token fields", () => {
    const probe = mod.grokAuthProbe();
    assert.strictEqual(probe.status, "EXPIRED");
    assert.ok(probe.seconds_left < 0);
    const blob = JSON.stringify(probe);
    assert.ok(!blob.includes(KEY), blob);
    assert.ok(!blob.includes(REFRESH), blob);
    assert.ok(!blob.includes("secret@example.com"), blob);
  });

  await check("expired grokSessionToken returns empty (no dead key)", () => {
    assert.strictEqual(mod.grokSessionToken(), "");
  });

  await check("expired resolveAuth throws GROK_AUTH_EXPIRED without token", () => {
    let threw = false;
    try {
      mod.resolveAuth();
    } catch (e) {
      threw = true;
      assert.strictEqual(e.code, "GROK_AUTH_EXPIRED");
      const msg = String(e.message);
      assert.ok(/GROK_AUTH_EXPIRED/.test(msg), msg);
      assert.ok(/expires_at=/.test(msg), msg);
      assert.ok(/seconds_left=/.test(msg), msg);
      assert.ok(!msg.includes(KEY), msg);
      assert.ok(!msg.includes(REFRESH), msg);
    }
    assert.ok(threw);
  });

  await check("expired resolveSessionAuth throws GROK_AUTH_EXPIRED", async () => {
    const inf = mod.resolveAgentInference({ agentId: COS });
    assert.strictEqual(inf.provider, "grok-heavy");
    let threw = false;
    try {
      await mod.resolveSessionAuth(inf);
    } catch (e) {
      threw = true;
      assert.strictEqual(e.code, "GROK_AUTH_EXPIRED");
      assert.ok(!String(e.message).includes(KEY));
    }
    assert.ok(threw);
  });

  console.log(`\n${pass} passed, ${fail} failed`);
  try {
    fs.rmSync(WORKDIR, { recursive: true, force: true });
  } catch {
    /* ignore */
  }
  process.exit(fail === 0 ? 0 : 1);
})();
