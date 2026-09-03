#!/usr/bin/env node
"use strict";
/**
 * Unit tests for agent-inference-policy overlay.
 * Never hits live host, adapters use, or --go.
 */
const fs = require("fs");
const os = require("os");
const path = require("path");
const assert = require("assert");

const ROOT = path.join(__dirname, "..");
const WORKDIR = fs.mkdtempSync(path.join(os.tmpdir(), "agent-policy-test-"));
const POLICY = path.join(WORKDIR, "agent-inference-policy.json");
fs.copyFileSync(path.join(ROOT, "examples/agent-inference-policy.json"), POLICY);

process.env.SAND_AGENT_INFERENCE_POLICY = POLICY;
process.env.SAND_XAI_ENV_FILE = path.join(WORKDIR, "missing.env");
process.env.SAND_XAI_MODEL = "grok-4.6";
process.env.SAND_XAI_REASONING_EFFORT = "medium";
process.env.CODEX_AUTH_FILE = path.join(WORKDIR, "no-codex-auth.json");

const mod = require(path.join(ROOT, "xai-prompt-session.cjs"));

const COS = "5cadd652-c086-4ef2-8b64-e9c466e848b8";
const DEV = "7a4ecb2d-9742-493e-bffb-87deb7a722b1";
const FIN = "01da7977-b202-4a08-a775-834768e6150e";
const PUMP = "8ae9a103-cfa2-406d-9bf3-eea00ca5b3a9";
const UNKNOWN = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee";

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
  await check("extract agentId from sessionOptions.agentId", () => {
    assert.strictEqual(mod.extractAgentId({ agentId: COS }), COS.toLowerCase());
  });

  await check("extract agentId from nested agent.id", () => {
    assert.strictEqual(mod.extractAgentId({ agent: { id: FIN } }), FIN.toLowerCase());
  });

  await check("CoS → high grok-heavy", () => {
    const r = mod.resolveAgentInference({ agentId: COS });
    assert.strictEqual(r.effort, "high");
    assert.strictEqual(r.provider, "grok-heavy");
    assert.strictEqual(r.model, "grok-4.6");
    assert.strictEqual(r.known, true);
  });

  await check("Development → high", () => {
    const r = mod.resolveAgentInference({ agentId: DEV });
    assert.strictEqual(r.effort, "high");
  });

  await check("Finance → medium (rest of office)", () => {
    const r = mod.resolveAgentInference({ agentId: FIN });
    assert.strictEqual(r.effort, "medium");
    assert.strictEqual(r.provider, "grok-heavy");
  });

  await check("unknown UUID → medium", () => {
    const r = mod.resolveAgentInference({ agentId: UNKNOWN });
    assert.strictEqual(r.effort, "medium");
    assert.strictEqual(r.provider, "grok-heavy");
    assert.strictEqual(r.known, false);
  });

  await check("Pump → high grok-heavy (Codex is next module)", () => {
    const r = mod.resolveAgentInference({ agentId: PUMP });
    assert.strictEqual(r.provider, "grok-heavy");
    assert.strictEqual(r.effort, "high");
    assert.strictEqual(r.model, "grok-4.6");
  });

  await check("ignore source_agent_id / target_agent_id (allowlist only)", () => {
    const id = mod.extractAgentId({
      source_agent_id: COS,
      target_agent_id: PUMP,
      agentId: FIN,
    });
    assert.strictEqual(id, FIN.toLowerCase());
    const id2 = mod.extractAgentId({
      source_agent_id: COS,
      target_agent_id: PUMP,
    });
    assert.strictEqual(id2, "");
  });

  await check("empty agentId → fleet default medium, not high (overlay refused)", () => {
    const r = mod.resolveAgentInference({});
    assert.strictEqual(r.provider, "grok-heavy");
    assert.strictEqual(r.effort, "medium");
    assert.strictEqual(r.agentId, "");
    assert.strictEqual(r.known, false);
  });

  await check("hostOptions.agentId UUID is used", () => {
    const r = mod.resolveAgentInference(
      {},
      { hostOptions: { agentId: COS } }
    );
    assert.strictEqual(r.agentId, COS.toLowerCase());
    assert.strictEqual(r.effort, "high");
    assert.strictEqual(r.known, true);
  });

  await check("hostOptions.getAgentId() UUID is used", () => {
    const r = mod.resolveAgentInference(
      {},
      { hostOptions: { getAgentId: () => DEV } }
    );
    assert.strictEqual(r.agentId, DEV.toLowerCase());
    assert.strictEqual(r.effort, "high");
  });

  await check("ignore source_agent_id even on hostOptions", () => {
    const r = mod.resolveAgentInference(
      { source_agent_id: COS },
      { hostOptions: { source_agent_id: PUMP } }
    );
    assert.strictEqual(r.agentId, "");
    assert.strictEqual(r.effort, "medium");
  });

  await check("policy missing + Pump UUID must not be grok-heavy", () => {
    process.env.SAND_AGENT_INFERENCE_POLICY = path.join(WORKDIR, "does-not-exist.json");
    // bust cache via new path
    const r = mod.resolveAgentInference({ agentId: PUMP });
    assert.notStrictEqual(r.provider, "grok-heavy");
    assert.strictEqual(r.provider, "policy-missing");
    process.env.SAND_AGENT_INFERENCE_POLICY = POLICY;
    // reload real policy
    mod.resolveAgentInference({ agentId: FIN });
  });

  await check("Pump UUID without policy row must not be grok-heavy", () => {
    const stripped = JSON.parse(fs.readFileSync(POLICY, "utf8"));
    delete stripped.agents[PUMP];
    delete stripped.agents[PUMP.toLowerCase()];
    const strippedPath = path.join(WORKDIR, "no-pump-row.json");
    fs.writeFileSync(strippedPath, JSON.stringify(stripped));
    process.env.SAND_AGENT_INFERENCE_POLICY = strippedPath;
    const r = mod.resolveAgentInference({ agentId: PUMP });
    assert.notStrictEqual(r.provider, "grok-heavy");
    assert.strictEqual(r.provider, "policy-row-missing");
    process.env.SAND_AGENT_INFERENCE_POLICY = POLICY;
    mod.resolveAgentInference({ agentId: FIN });
  });

  await check("createXaiPromptSession Finance effort=medium", () => {
    process.env.SAND_AGENT_INFERENCE_POLICY = POLICY;
    const s = mod.createXaiPromptSession({
      requestedModel: { modelId: "sand-default" },
      sessionOptions: { agentId: FIN },
    });
    assert.strictEqual(s.inference.effort, "medium");
    assert.strictEqual(s.getModelId(), "grok-4.6");
  });

  await check("createXaiPromptSession Pump effort=high", () => {
    const s = mod.createXaiPromptSession({
      requestedModel: { modelId: "sand-default" },
      sessionOptions: { agentId: PUMP },
    });
    assert.strictEqual(s.inference.effort, "high");
    assert.strictEqual(s.inference.provider, "grok-heavy");
  });

  await check("policy does not mutate SAND_XAI_REASONING_EFFORT", () => {
    process.env.SAND_XAI_REASONING_EFFORT = "medium";
    delete process.env.SAND_XAI_BASE_URL;
    mod.resolveAgentInference({ agentId: COS });
    mod.resolveAgentInference({ agentId: PUMP });
    assert.strictEqual(process.env.SAND_XAI_REASONING_EFFORT, "medium");
    assert.ok(!process.env.SAND_XAI_BASE_URL);
  });

  await check("Codex provider path still fail-closed (next module)", async () => {
    let threw = false;
    try {
      await mod.resolveSessionAuth({
        provider: "codex",
        model: "gpt-5.4-mini",
        agentId: PUMP,
      });
    } catch (e) {
      threw = true;
      assert.ok(
        e.code === "CODEX_AUTH_MISSING" || /Codex/i.test(String(e.message)),
        String(e.message)
      );
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
