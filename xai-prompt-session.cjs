"use strict";

/**
 * Sand / Grok Bot custom inference session.
 *
 * Replaces createCursorInferencePromptSession when SAND_INFERENCE_PROVIDER != cursor.
 * Speaks OpenAI Chat Completions (+ SSE tools) so CLIProxy, LiteLLM, xAI, OpenAI,
 * OpenRouter, and openai-oauth all work through the same module.
 *
 * Reads ~/sand-data/xai-inference.env on every session (file wins over process env).
 */

const fs = require("fs");
const http = require("http");
const https = require("https");
const os = require("os");
const path = require("path");
const { URL } = require("url");

const DEBUG_LOG = process.env.SAND_XAI_DEBUG_LOG || "/tmp/sand-xai-debug.log";

const HOST_INTERNAL_MODELS = new Set([
  "sand-default",
  "sand-mock",
  "default",
  "auto",
  "composer",
  "composer-1",
  "composer-1.5",
  "cursor-small",
  "cursor-fast",
  "gpt-4o-mini",
  "gemini-2.5-flash",
  "gemini-2.0-flash",
  "gemini-flash",
]);

function envFilePath() {
  return (
    process.env.SAND_XAI_ENV_FILE ||
    path.join(process.env.SAND_DATA_ROOT || path.join(os.homedir(), "sand-data"), "xai-inference.env")
  );
}

function loadEnvFile() {
  const file = envFilePath();
  let raw;
  try {
    raw = fs.readFileSync(file, "utf8");
  } catch {
    return;
  }
  for (let line of raw.split(/\r?\n/)) {
    line = line.trim();
    if (!line || line.startsWith("#")) continue;
    if (line.startsWith("export ")) line = line.slice(7).trim();
    const eq = line.indexOf("=");
    if (eq < 1) continue;
    const key = line.slice(0, eq).trim();
    let val = line.slice(eq + 1).trim();
    if (
      (val.startsWith('"') && val.endsWith('"')) ||
      (val.startsWith("'") && val.endsWith("'"))
    ) {
      val = val.slice(1, -1);
    }
    if (key) process.env[key] = val;
  }
}

function env(name, fallback) {
  const v = process.env[name];
  if (v == null || v === "") return fallback;
  return v;
}

function truthy(v) {
  if (v == null || v === "") return false;
  const s = String(v).trim().toLowerCase();
  return s === "1" || s === "true" || s === "yes" || s === "on" || s === "enabled";
}

function unwrapRedacted(value, seen) {
  if (value == null) return value;
  const t = typeof value;
  if (t === "string" || t === "number" || t === "boolean") return value;
  if (t !== "object") return value;
  seen = seen || new WeakSet();
  if (seen.has(value)) return undefined;
  seen.add(value);
  if (typeof value.unwrap === "function") {
    try {
      return unwrapRedacted(value.unwrap("unsafe_always_allowed", {}), seen);
    } catch {
      /* fall through */
    }
  }
  if (Array.isArray(value)) return value.map((v) => unwrapRedacted(v, seen));
  if (Buffer.isBuffer(value)) return value.toString("utf8");
  if (typeof value.toJSON === "function") {
    try {
      const j = value.toJSON();
      if (j !== value) return unwrapRedacted(j, seen);
    } catch {
      /* ignore */
    }
  }
  if (typeof value.valueOf === "function") {
    try {
      const v = value.valueOf();
      if (v !== value && (typeof v === "string" || typeof v === "number")) return v;
    } catch {
      /* ignore */
    }
  }
  const protoToString = Object.prototype.toString;
  if (typeof value.toString === "function" && value.toString !== protoToString) {
    try {
      const s = value.toString();
      if (s && s !== "[object Object]" && Object.keys(value).length === 0) return s;
    } catch {
      /* ignore */
    }
  }
  const out = {};
  for (const [k, v] of Object.entries(value)) {
    out[k] = unwrapRedacted(v, seen);
  }
  return out;
}

function asString(value) {
  const v = unwrapRedacted(value);
  if (v == null) return "";
  if (typeof v === "string") return v;
  if (typeof v === "number" || typeof v === "boolean") return String(v);
  try {
    return JSON.stringify(v);
  } catch {
    return String(v);
  }
}

function sanitizeToolId(id) {
  const raw = asString(id) || "tool";
  const cleaned = raw.replace(/[^a-zA-Z0-9_-]/g, "_");
  return cleaned || "tool";
}

function sanitizeToolName(name) {
  const raw = asString(name) || "tool";
  const cleaned = raw.replace(/[^a-zA-Z0-9_-]/g, "_");
  return cleaned || "tool";
}

function isPlainObject(v) {
  return v != null && typeof v === "object" && !Array.isArray(v);
}

function normalizeToolParameters(raw) {
  let schema = raw;
  if (schema && typeof schema === "object") {
    if (schema.jsonSchema) schema = schema.jsonSchema;
    else if (schema.inputSchema) schema = schema.inputSchema;
    else if (schema.schema) schema = schema.schema;
  }
  schema = unwrapRedacted(schema);
  if (!isPlainObject(schema) || Array.isArray(schema)) {
    return { type: "object", properties: {} };
  }
  const type = schema.type;
  if (type == null || type === "object") {
    return {
      ...schema,
      type: "object",
      properties: isPlainObject(schema.properties) ? schema.properties : {},
    };
  }
  return {
    type: "object",
    properties: { value: schema },
  };
}

function requestedModelId(requestedModel) {
  if (requestedModel == null) return "";
  if (typeof requestedModel === "string") return requestedModel;
  const id = requestedModel.modelId ?? requestedModel.model ?? requestedModel.id;
  return asString(id);
}

function mapModelId(requestedModel) {
  const configured = env("SAND_XAI_MODEL", "grok-4.5");
  const raw = requestedModelId(requestedModel);
  if (!raw) return configured;
  const lower = raw.toLowerCase();
  if (HOST_INTERNAL_MODELS.has(lower)) return configured;
  if (lower.startsWith("sand-") || lower.startsWith("cursor-")) return configured;
  if (lower.includes("high-fast") || lower.includes("summar")) return configured;
  return raw;
}

function grokSessionToken() {
  const authPath = env("GROK_AUTH_FILE", path.join(os.homedir(), ".grok", "auth.json"));
  let data;
  try {
    data = JSON.parse(fs.readFileSync(authPath, "utf8"));
  } catch {
    return "";
  }
  if (!data || typeof data !== "object") return "";
  let entry = null;
  for (const [k, v] of Object.entries(data)) {
    if (v && typeof v === "object" && v.key && (k.includes("auth.x.ai") || v.auth_mode === "oidc")) {
      entry = v;
      break;
    }
  }
  if (!entry) {
    for (const v of Object.values(data)) {
      if (v && typeof v === "object" && v.key) {
        entry = v;
        break;
      }
    }
  }
  return entry && entry.key ? String(entry.key) : "";
}

function resolveAuth() {
  const apiKey =
    env("XAI_API_KEY") || env("GROK_CODE_XAI_API_KEY") || env("GROK_XAI_API_KEY") || "";
  if (apiKey) {
    return {
      mode: "key",
      token: apiKey,
      baseUrl: env("SAND_XAI_BASE_URL", "https://api.x.ai/v1").replace(/\/+$/, ""),
      extraHeaders: {},
    };
  }
  const session = grokSessionToken();
  return {
    mode: session ? "session" : "none",
    token: session,
    baseUrl: env("SAND_XAI_BASE_URL", "https://cli-chat-proxy.grok.com/v1").replace(/\/+$/, ""),
    extraHeaders: session
      ? {
          "X-XAI-Token-Auth": "xai-grok-cli",
          "x-grok-client-version": "1.0.0",
          "User-Agent": "grok-cli/1.0.0",
        }
      : {},
  };
}

function normalizeUsage(usage) {
  const u = usage && typeof usage === "object" ? usage : {};
  const promptTokens = Number(u.promptTokens ?? u.prompt_tokens ?? u.inputTokens ?? u.input_tokens ?? 0) || 0;
  const completionTokens =
    Number(u.completionTokens ?? u.completion_tokens ?? u.outputTokens ?? u.output_tokens ?? 0) || 0;
  const totalTokens = Number(u.totalTokens ?? u.total_tokens ?? 0) || promptTokens + completionTokens;
  return { promptTokens, completionTokens, totalTokens };
}

function normalizeExtendedUsage(usage) {
  const u = usage && typeof usage === "object" ? usage : {};
  return {
    inputTokens: Number(u.inputTokens ?? u.prompt_tokens ?? u.promptTokens ?? 0) || 0,
    outputTokens: Number(u.outputTokens ?? u.completion_tokens ?? u.completionTokens ?? 0) || 0,
    cacheReadTokens: Number(u.cacheReadTokens ?? u.cache_read_tokens ?? 0) || 0,
    cacheWriteTokens: Number(u.cacheWriteTokens ?? u.cache_write_tokens ?? 0) || 0,
    maxTokens: Number(u.maxTokens ?? u.max_tokens ?? 0) || 0,
  };
}

function parseArgs(raw) {
  if (raw == null || raw === "") return {};
  if (typeof raw === "object") return unwrapRedacted(raw) || {};
  const s = asString(raw).trim();
  if (!s) return {};
  try {
    return JSON.parse(s);
  } catch {
    return { _raw: s };
  }
}

function convertContentPart(part) {
  const p = unwrapRedacted(part);
  if (p == null) return null;
  if (typeof p === "string") return { kind: "text", text: p };
  if (typeof p !== "object") return { kind: "text", text: asString(p) };
  const type = asString(p.type || p.kind || "");
  if (type === "text" || type === "input_text" || type === "output_text") {
    return { kind: "text", text: asString(p.text ?? p.content ?? "") };
  }
  if (type === "reasoning" || type === "thinking") {
    return { kind: "reasoning", text: asString(p.text ?? p.textDelta ?? p.thinking ?? "") };
  }
  if (type === "tool-call" || type === "tool_use" || type === "function_call") {
    return {
      kind: "tool-call",
      id: sanitizeToolId(p.toolCallId ?? p.tool_call_id ?? p.id),
      name: sanitizeToolName(p.toolName ?? p.tool_name ?? p.name ?? p.function?.name),
      args: parseArgs(p.args ?? p.arguments ?? p.input ?? p.function?.arguments),
    };
  }
  if (type === "tool-result" || type === "tool_result") {
    const result = p.result ?? p.content ?? p.output ?? p.value;
    return {
      kind: "tool-result",
      id: sanitizeToolId(p.toolCallId ?? p.tool_call_id ?? p.id),
      name: sanitizeToolName(p.toolName ?? p.tool_name ?? p.name),
      content: typeof result === "string" ? result : asString(result),
      isError: Boolean(p.isError ?? p.is_error),
    };
  }
  if (type === "image" || type === "image_url" || type === "input_image") {
    const url = p.image_url?.url ?? p.url ?? p.image;
    if (url) return { kind: "image", url: asString(url) };
  }
  if (p.text) return { kind: "text", text: asString(p.text) };
  return null;
}

function convertMessage(rawMsg) {
  const msg = unwrapRedacted(rawMsg) || {};
  const role = asString(msg.role || "user");
  const out = [];

  if (role === "tool") {
    const id = sanitizeToolId(msg.tool_call_id ?? msg.toolCallId ?? msg.id);
    out.push({
      role: "tool",
      tool_call_id: id,
      content: asString(msg.content ?? msg.result ?? ""),
    });
    return out;
  }

  const texts = [];
  const toolCalls = [];
  const toolResults = [];
  const images = [];
  const promoteReasoning = truthy(env("SAND_XAI_PROMOTE_REASONING", "0"));

  const pushContent = (content) => {
    if (content == null) return;
    if (typeof content === "string") {
      if (content) texts.push(content);
      return;
    }
    if (Array.isArray(content)) {
      for (const part of content) {
        const c = convertContentPart(part);
        if (!c) continue;
        if (c.kind === "text" && c.text) texts.push(c.text);
        else if (c.kind === "reasoning" && c.text && promoteReasoning) texts.push(c.text);
        else if (c.kind === "tool-call") toolCalls.push(c);
        else if (c.kind === "tool-result") toolResults.push(c);
        else if (c.kind === "image") images.push(c);
      }
      return;
    }
    const s = asString(content);
    if (s) texts.push(s);
  };

  pushContent(msg.content);
  if (Array.isArray(msg.toolCalls) || Array.isArray(msg.tool_calls)) {
    for (const tc of msg.toolCalls || msg.tool_calls) {
      const c = convertContentPart({ type: "tool-call", ...unwrapRedacted(tc) });
      if (c && c.kind === "tool-call") toolCalls.push(c);
    }
  }

  for (const tr of toolResults) {
    out.push({
      role: "tool",
      tool_call_id: tr.id,
      content: tr.isError ? `ERROR: ${tr.content}` : tr.content,
    });
  }

  if (role === "assistant" || role === "user" || role === "system") {
    const openai = { role };
    if (images.length && (role === "user" || role === "system")) {
      openai.content = [
        ...texts.map((t) => ({ type: "text", text: t })),
        ...images.map((img) => ({ type: "image_url", image_url: { url: img.url } })),
      ];
    } else {
      openai.content = texts.join("\n") || (toolCalls.length ? "" : "");
      if (!openai.content) openai.content = toolCalls.length ? null : "";
    }
    if (role === "assistant" && toolCalls.length) {
      openai.tool_calls = toolCalls.map((tc) => ({
        id: tc.id,
        type: "function",
        function: {
          name: tc.name,
          arguments: JSON.stringify(tc.args ?? {}),
        },
      }));
    }
    if (openai.content || openai.tool_calls) out.push(openai);
  }

  return out;
}

function convertMessages(rawList) {
  const list = Array.isArray(rawList) ? rawList : rawList == null ? [] : [rawList];
  const out = [];
  for (const msg of list) {
    try {
      out.push(...convertMessage(msg));
    } catch (err) {
      console.error("[sand-xai] convertMessage failed:", err);
    }
  }
  if (out.length && out[out.length - 1].role === "assistant") {
    out.push({ role: "user", content: "(continue)" });
  }
  if (!out.length) {
    out.push({ role: "user", content: "(empty)" });
  }
  return out;
}

function convertTools(tools) {
  if (!Array.isArray(tools) || tools.length === 0) return undefined;
  return tools.map((tool) => {
    const t = unwrapRedacted(tool) || {};
    return {
      type: "function",
      function: {
        name: sanitizeToolName(t.name),
        description: asString(t.description || t.name || ""),
        parameters: normalizeToolParameters(t.parameters ?? t.inputSchema ?? t.schema),
      },
    };
  });
}

function debugDump(raw, converted) {
  try {
    const summarize = (m) => {
      const content = m && m.content;
      return {
        role: m && m.role,
        contentType: Array.isArray(content) ? "array" : typeof content,
        parts: Array.isArray(content) ? content.map((p) => (p && p.type) || typeof p) : undefined,
        contentLen: typeof content === "string" ? content.length : undefined,
        toolCalls: (m && (m.tool_calls || m.toolCalls) || []).length || undefined,
        tool_call_id: m && (m.tool_call_id || m.toolCallId) || undefined,
      };
    };
    const line =
      JSON.stringify({
        ts: new Date().toISOString(),
        raw: (Array.isArray(raw) ? raw : []).map(summarize),
        converted: (converted || []).map(summarize),
      }) + "\n";
    fs.appendFileSync(DEBUG_LOG, line);
  } catch {
    /* ignore */
  }
}

function maxTokens() {
  const raw = env("SAND_XAI_MAX_TOKENS", "8192");
  const n = Number(raw);
  if (!Number.isFinite(n) || n <= 0) return undefined;
  return Math.floor(n);
}

function thinkingEnabled() {
  const v = env("SAND_XAI_THINKING", "disabled");
  return truthy(v);
}

function reasoningEffort() {
  const v = env("SAND_XAI_REASONING_EFFORT", "");
  if (!v) return undefined;
  const s = String(v).toLowerCase();
  if (s === "off" || s === "none" || s === "disabled") return undefined;
  return s;
}

function httpPostStream(urlString, { headers, body, onData }) {
  const u = new URL(urlString);
  const lib = u.protocol === "https:" ? https : http;
  const payload = Buffer.from(body, "utf8");
  const reqHeaders = {
    "Content-Type": "application/json",
    Accept: "text/event-stream",
    "Content-Length": String(payload.length),
    ...headers,
  };
  return new Promise((resolve, reject) => {
    const req = lib.request(
      {
        protocol: u.protocol,
        hostname: u.hostname,
        port: u.port || (u.protocol === "https:" ? 443 : 80),
        path: `${u.pathname}${u.search}`,
        method: "POST",
        headers: reqHeaders,
      },
      (res) => {
        const chunks = [];
        let buffer = "";
        const ok = res.statusCode && res.statusCode >= 200 && res.statusCode < 300;
        res.setEncoding("utf8");
        res.on("data", (chunk) => {
          if (!ok) {
            chunks.push(chunk);
            return;
          }
          buffer += chunk;
          let idx;
          while ((idx = buffer.indexOf("\n")) >= 0) {
            let line = buffer.slice(0, idx);
            buffer = buffer.slice(idx + 1);
            if (line.endsWith("\r")) line = line.slice(0, -1);
            if (!line.startsWith("data:")) continue;
            const data = line.slice(5).trim();
            if (!data || data === "[DONE]") continue;
            try {
              onData(JSON.parse(data));
            } catch {
              /* ignore malformed SSE */
            }
          }
        });
        res.on("end", () => {
          if (!ok) {
            const text = chunks.join("");
            const err = new Error(`HTTP ${res.statusCode}: ${text.slice(0, 800)}`);
            err.status = res.statusCode;
            err.body = text;
            reject(err);
            return;
          }
          resolve();
        });
      }
    );
    req.setTimeout(300000, () => {
      req.destroy(new Error("xAI request timed out"));
    });
    req.on("error", reject);
    req.end(payload);
  });
}

function buildResponseMessages(text, toolCalls) {
  if (toolCalls.length) {
    const content = [];
    if (text) content.push({ type: "text", text });
    for (const tc of toolCalls) {
      content.push({
        type: "tool-call",
        toolCallId: tc.id,
        toolName: tc.name,
        args: tc.args,
      });
    }
    return [{ role: "assistant", content }];
  }
  return [{ role: "assistant", content: text || "" }];
}

function errorResult(modelId, invocationId, err) {
  const message = err && err.message ? err.message : String(err);
  const usage = normalizeUsage({});
  const response = {
    modelId,
    messages: [{ role: "assistant", content: "" }],
    finishReason: "error",
  };
  const parts = [
    { type: "error", error: err instanceof Error ? err : new Error(message) },
    { type: "finish", finishReason: "error", usage, response },
  ];
  return {
    parts,
    response,
    usage,
    extendedUsage: normalizeExtendedUsage({}),
    providerMetadata: {},
    invocationId,
  };
}

async function runStream({ model, messages, tools, invocationId, auth }) {
  const converted = convertMessages(messages);
  debugDump(messages, converted);
  const openaiTools = convertTools(tools);

  const headers = {
    Authorization: `Bearer ${auth.token || "missing"}`,
    ...auth.extraHeaders,
  };
  if (auth.mode === "session") {
    headers["x-grok-model-override"] = model;
  }

  const body = {
    model,
    messages: converted,
    stream: true,
    stream_options: { include_usage: true },
  };
  if (openaiTools && openaiTools.length) {
    body.tools = openaiTools;
    body.tool_choice = "auto";
  }
  const mt = maxTokens();
  if (mt != null) body.max_tokens = mt;
  const effort = thinkingEnabled() ? reasoningEffort() : undefined;
  if (effort) body.reasoning_effort = effort;

  const url = `${auth.baseUrl}/chat/completions`;
  const toolAcc = new Map();
  let text = "";
  let reasoning = "";
  let finishReason = "stop";
  let usageRaw = {};
  const parts = [];

  const push = (part) => {
    parts.push(part);
  };

  try {
    await httpPostStream(url, {
      headers,
      body: JSON.stringify(body),
      onData: (evt) => {
        if (evt && evt.usage) usageRaw = evt.usage;
        const choice = evt && evt.choices && evt.choices[0];
        if (!choice) return;
        if (choice.finish_reason) finishReason = choice.finish_reason;
        const delta = choice.delta || choice.message || {};
        const contentDelta = delta.content;
        if (typeof contentDelta === "string" && contentDelta) {
          text += contentDelta;
          push({ type: "text-delta", textDelta: contentDelta });
        } else if (Array.isArray(contentDelta)) {
          for (const block of contentDelta) {
            const t = asString(block.text ?? block.content ?? "");
            if (t) {
              text += t;
              push({ type: "text-delta", textDelta: t });
            }
          }
        }
        const think =
          delta.reasoning_content ||
          delta.reasoning ||
          (delta.thinking && (delta.thinking.text || delta.thinking));
        if (typeof think === "string" && think) {
          reasoning += think;
          push({ type: "reasoning", textDelta: think });
        }
        const tcs = delta.tool_calls;
        if (Array.isArray(tcs)) {
          for (const tc of tcs) {
            const idx = tc.index != null ? tc.index : toolAcc.size;
            let acc = toolAcc.get(idx);
            if (!acc) {
              acc = { id: "", name: "", args: "" };
              toolAcc.set(idx, acc);
            }
            if (tc.id) acc.id = sanitizeToolId(tc.id);
            const fn = tc.function || {};
            if (fn.name) {
              acc.name = sanitizeToolName(fn.name);
              if (!acc.started) {
                acc.started = true;
                push({
                  type: "tool-call-streaming-start",
                  toolCallId: acc.id || `call_${idx}`,
                  toolName: acc.name,
                });
              }
            }
            if (fn.arguments) {
              acc.args += fn.arguments;
              push({
                type: "tool-call-delta",
                toolCallId: acc.id || `call_${idx}`,
                toolName: acc.name || "tool",
                argsTextDelta: fn.arguments,
              });
            }
          }
        }
      },
    });
  } catch (err) {
    console.error("[sand-xai] HTTP error:", err && err.message ? err.message : err);
    return errorResult(model, invocationId, err);
  }

  const toolCalls = [];
  for (const acc of toolAcc.values()) {
    const id = acc.id || sanitizeToolId(`call_${toolCalls.length}`);
    const name = acc.name || "tool";
    const args = parseArgs(acc.args);
    toolCalls.push({ id, name, args });
    push({ type: "tool-call", toolCallId: id, toolName: name, args });
  }

  const usage = normalizeUsage(usageRaw);
  const response = {
    modelId: model,
    messages: buildResponseMessages(text, toolCalls),
    finishReason: finishReason === "tool_calls" ? "tool-calls" : finishReason || "stop",
  };
  push({ type: "finish", finishReason: response.finishReason, usage, response });

  return {
    parts,
    response,
    usage,
    extendedUsage: normalizeExtendedUsage(usageRaw),
    providerMetadata: reasoning ? { reasoning } : {},
    invocationId,
  };
}

function createExecutor(session) {
  const state = { messages: [] };
  return {
    appendMessages(messages) {
      const list = Array.isArray(messages) ? messages : messages == null ? [] : [messages];
      state.messages.push(...list);
      return this;
    },
    getMessages() {
      return [...state.messages];
    },
    getState() {
      return [...state.messages];
    },
    clearMessages() {
      state.messages = [];
    },
    stream(ctx, invocationId, tools) {
      if (typeof session.onRequestId === "function") {
        try {
          session.onRequestId(invocationId);
        } catch {
          /* ignore */
        }
      }
      const processing = (async () => {
        loadEnvFile();
        const auth = resolveAuth();
        const model = mapModelId(session.requestedModel);
        if (auth.mode === "none") {
          return errorResult(
            model,
            invocationId,
            new Error("no XAI_API_KEY and no ~/.grok/auth.json session — run adapters use … or grok login")
          );
        }
        return runStream({
          model,
          messages: state.messages,
          tools,
          invocationId,
          auth,
        });
      })();

      const fullStream = (async function* () {
        const result = await processing;
        for (const part of result.parts) yield part;
      })();

      return {
        fullStream,
        response: processing.then((r) => r.response),
        usage: processing.then((r) => r.usage),
        extendedUsage: processing.then((r) => r.extendedUsage),
        providerMetadata: processing.then((r) => r.providerMetadata),
        invocationId: processing.then((r) => r.invocationId ?? invocationId),
      };
    },
  };
}

function createXaiPromptSession(options) {
  loadEnvFile();
  const opts = options || {};
  const requestedModel = opts.requestedModel;
  const model = mapModelId(requestedModel);
  const auth = resolveAuth();
  const thinking = env("SAND_XAI_THINKING", "disabled");
  const effort = env("SAND_XAI_REASONING_EFFORT", "");
  console.error(
    `[sand-xai] session model=${model} auth=${auth.mode} base=${auth.baseUrl} thinking=${thinking}` +
      (effort ? ` effort=${effort}` : "")
  );
  const session = {
    requestedModel,
    onRequestId: opts.onRequestId,
    sessionOptions: opts.sessionOptions,
    getModelId() {
      return mapModelId(this.requestedModel);
    },
    getExecutor(initialMessages) {
      const ex = createExecutor(session);
      if (initialMessages) ex.appendMessages(initialMessages);
      return ex;
    },
  };
  return session;
}

module.exports = { createXaiPromptSession, convertMessages, normalizeToolParameters, mapModelId };

if (require.main === module) {
  loadEnvFile();
  const model = env("SAND_XAI_MODEL", "claude-opus-5");
  const session = createXaiPromptSession({ requestedModel: { modelId: model } });
  const ex = session.getExecutor([{ role: "user", content: "Reply with exactly: XAI_OK" }]);
  const r = ex.stream({}, "smoke", [], {});
  (async () => {
    let text = "";
    for await (const part of r.fullStream) {
      if (part.type === "text-delta") text += part.textDelta;
      if (part.type === "error") throw part.error;
    }
    console.log(`model ${session.getModelId()} text ${JSON.stringify(text)}`);
    console.log("getState isArray", Array.isArray(ex.getState()));
    if (!text.includes("XAI_OK") && !text.trim()) {
      process.exitCode = 1;
    }
  })().catch((err) => {
    console.error(err);
    process.exit(1);
  });
}
