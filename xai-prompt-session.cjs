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

const crypto = require("crypto");
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


function imageMimeForPath(fp) {
  const ext = String(fp || "").toLowerCase().split(".").pop();
  if (ext === "png") return "image/png";
  if (ext === "jpg" || ext === "jpeg") return "image/jpeg";
  if (ext === "webp") return "image/webp";
  if (ext === "gif") return "image/gif";
  return "image/png";
}

function fileUrlToDataUrl(url) {
  // xAI/CLIProxy reject file:// and bare paths: must be http(s) URL or base64 data URL.
  const raw = String(url || "");
  if (!raw || raw.startsWith("data:") || raw.startsWith("http://") || raw.startsWith("https://")) return raw || "";
  let fp = raw.startsWith("file://") ? raw.slice(7) : raw;
  const maxBytes = Number(process.env.SAND_XAI_MAX_IMAGE_BYTES || 8 * 1024 * 1024);
  try {
    const st = fs.statSync(fp);
    if (!st.isFile() || st.size <= 0 || st.size > maxBytes) return "";
    const b64 = fs.readFileSync(fp).toString("base64");
    return `data:${imageMimeForPath(fp)};base64,${b64}`;
  } catch {
    return "";
  }
}

function normalizeImageUrl(url) {
  const raw = String(url || "").trim();
  if (!raw) return "";
  if (raw.startsWith("data:image/") || raw.startsWith("http://") || raw.startsWith("https://")) return raw;
  return fileUrlToDataUrl(raw);
}

function attachmentToImageUrl(msg) {
  // Grok Bot chat stores pics as separate user-attachment entries (file_path),
  // NOT as image blocks inside message.content. Convert them here.
  const m = msg || {};
  const fp = m.file_path ?? m.filePath ?? m.path ?? m.url;
  if (typeof fp === "string" && fp) return normalizeImageUrl(fp);
  const atts = m.attachments ?? m.file_attachments ?? m.files;
  if (Array.isArray(atts)) {
    for (const a of atts) {
      const cand = a && (a.file_path ?? a.filePath ?? a.path ?? a.url);
      if (typeof cand === "string" && cand) {
        const u = normalizeImageUrl(cand);
        if (u) return u;
      }
    }
  }
  return "";
}

function extractImagePathsFromText(text) {
  // The app hands chat images to this agent as a plain-text note
  // ("The user attached a file... materialized on your box at .../attachments/xxx.png")
  // instead of an image block. Pull absolute image file paths out so they
  // can be base64'd into real image_url parts.
  const out = [];
  if (typeof text !== "string" || !text) return out;
  if (text.indexOf("attach") === -1 && text.indexOf("/attachments/") === -1 && text.indexOf("/uploads/") === -1) return out;
  const re = /(\/home\/box\/[A-Za-z0-9_@.\-\/]+\.(?:png|jpe?g|webp|gif))/gi;
  let m;
  while ((m = re.exec(text)) !== null) {
    const fp = m[1];
    if (out.indexOf(fp) === -1) out.push(fp);
    if (out.length >= 5) break;
  }
  return out;
}

function contentToParts(content) {
  // Split converted content into text parts + image parts so merges keep images.
  if (content == null) return { texts: [], images: [] };
  if (typeof content === "string") return { texts: content ? [content] : [], images: [] };
  if (!Array.isArray(content)) return { texts: [], images: [] };
  const texts = [];
  const images = [];
  for (const part of content) {
    if (!part) continue;
    if (typeof part === "string") {
      if (part) texts.push(part);
      continue;
    }
    const t = part.type;
    if (t === "image_url") {
      const u = part.image_url && part.image_url.url ? String(part.image_url.url) : "";
      if (u) images.push(u);
      continue;
    }
    if (typeof part.text === "string" && part.text) {
      texts.push(part.text);
      continue;
    }
  }
  return { texts, images };
}

function buildUserContent(texts, images) {
  const t = (texts || []).filter(Boolean);
  const imgs = (images || []).filter(Boolean);
  if (!imgs.length) return t.join("\n\n");
  return [
    ...t.map((x) => ({ type: "text", text: x })),
    ...imgs.map((u) => ({ type: "image_url", image_url: { url: u } })),
  ];
}

function sanitizeToolId(id) {
  const raw = asString(id) || "tool";
  const cleaned = raw.replace(/[^a-zA-Z0-9_-]/g, "_") || "tool";
  if (cleaned.length <= 64) return cleaned;
  // Host prefixes call-<uuid>-<n>_ onto the upstream Codex fc_/call_ id (~85
  // chars). Prefer the upstream suffix so the assistant tool_call and the
  // tool result still share an id; hashing each side independently broke pairing
  // and left bots spinning on orphan tool calls.
  const m = cleaned.match(/(?:^|_)((?:fc|call)_[A-Za-z0-9_-]{8,})$/);
  if (m && m[1].length <= 64) return m[1];
  const digest = crypto.createHash("sha256").update(cleaned).digest("hex").slice(0, 40);
  return `call_${digest}`;
}

function sanitizeToolName(name) {
  const raw = asString(name) || "tool";
  const cleaned = raw.replace(/[^a-zA-Z0-9_-]/g, "_");
  return cleaned || "tool";
}

function isPlaceholderValue(v) {
  if (v == null) return true;
  if (typeof v === "boolean") return false;
  if (typeof v === "number") return false;
  if (typeof v === "string") {
    const s = v.trim();
    return !s || /^(placeholder|x|n\/?a|none|null|undefined|dummy)$/i.test(s) || s.startsWith("dummy") || /^https?:\/\/example\.com/i.test(s);
  }
  if (Array.isArray(v)) return v.length === 0 || v.every(isPlaceholderValue);
  if (typeof v === "object") {
    const vals = Object.values(v);
    return vals.length === 0 || vals.every(isPlaceholderValue);
  }
  return false;
}

function normalizeSendToUserArgs(name, args, streamText) {
  if (name !== "SendToUser" && name !== "send_message") return args || {};
  if (!args || typeof args !== "object" || Array.isArray(args)) args = {};
  const out = { ...args };
  let body =
    asString(out.content) ||
    asString(out.message) ||
    asString(out.text) ||
    asString(out.body);
  if (!body && streamText && asString(streamText).trim()) {
    body = asString(streamText).trim();
  }
  if (body) {
    if (!asString(out.content)) out.content = body;
    if (!asString(out.message)) out.message = body;
    if (!asString(out.text)) out.text = body;
  }
  if (!asString(out.type)) out.type = "text";
  // Preserve omitted end_turn: progress updates must not end the host turn.
  // Explicit values are left unchanged for the host to validate.

  for (const key of ["url", "images", "alt", "reply_to", "channel", "widget", "bcId", "secret"]) {
    if (isPlaceholderValue(out[key])) delete out[key];
  }
  const kind = asString(out.type) || "text";
  if (kind === "text") {
    delete out.widget;
    delete out.secret;
    delete out.url;
    delete out.alt;
    delete out.bcId;
    if (!Array.isArray(out.images) || out.images.length === 0) {
      delete out.images;
    } else {
      out.images = out.images.filter(img => img && typeof img === "object" && typeof img.url === "string" && !isPlaceholderValue(img.url));
      if (out.images.length === 0) delete out.images;
    }
    if (!asString(out.content)) {
      out.content = body || " ";
      out.message = out.content;
      out.text = out.content;
    }
  } else if (kind === "attachment") {
    delete out.content;
    delete out.bcId;
    delete out.widget;
    delete out.secret;
    delete out.images;
  } else if (kind === "cursor-agent") {
    delete out.url;
    delete out.alt;
    delete out.content;
    delete out.widget;
    delete out.secret;
    delete out.images;
  } else if (kind === "widget") {
    delete out.url;
    delete out.alt;
    delete out.bcId;
    delete out.secret;
    delete out.images;
  } else if (kind === "secret-request") {
    delete out.url;
    delete out.alt;
    delete out.bcId;
    delete out.widget;
    delete out.images;
  }

  if (out.to && out.channel) {
    delete out.to;
  }
  if (out.to && out.to !== "dm") {
    delete out.to;
  }
  if (out.channel && isPlaceholderValue(out.channel)) {
    delete out.channel;
  }

  return out;
}

function toolsIncludeSendToUser(tools) {
  if (!Array.isArray(tools)) return false;
  return tools.some((tool) => {
    const t = unwrapRedacted(tool) || {};
    return sanitizeToolName(t.name) === "SendToUser";
  });
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

function configuredModelId() {
  return env("SAND_XAI_MODEL", env("SAND_AGENT_MODEL", "grok-4.6"));
}

function mapModelId(requestedModel) {
  const configured = configuredModelId();
  const raw = requestedModelId(requestedModel);
  if (!raw) return configured;
  const lower = raw.toLowerCase();
  if (HOST_INTERNAL_MODELS.has(lower)) return configured;
  if (lower.startsWith("sand-") || lower.startsWith("cursor-")) return configured;
  if (lower.includes("high-fast") || lower.includes("summar")) return configured;
  // Grok Bot UI / host default still advertise grok-4.5; honor the adapters model.
  if (lower === "grok-4.5" || lower.startsWith("cursor-grok-4.5") || lower === "vega" || lower.startsWith("vega-")) {
    return configured;
  }
  return raw;
}

function identityDisplayName(modelId) {
  const id = String(modelId || configuredModelId());
  const m = id.match(/grok-(\d+(?:\.\d+)?)/i);
  if (m) return `Grok ${m[1]}`;
  return id;
}

function rewriteIdentityText(text, modelId) {
  if (typeof text !== "string" || !text) return text;
  const name = identityDisplayName(modelId);
  const id = configuredModelId();
  return text
    .replace(/You are Grok 4\.5/g, `You are ${name}`)
    .replace(/I am Grok 4\.5/g, `I am ${name}`)
    .replace(/I'm Grok 4\.5/g, `I'm ${name}`)
    .replace(/Grok 4\.5/g, name)
    .replace(/grok-4\.5/g, id);
}

function applyIdentity(messages, modelId) {
  if (!truthy(env("SAND_XAI_IDENTITY", "1"))) return messages;
  const name = identityDisplayName(modelId);
  const id = modelId || configuredModelId();
  const line =
    `You are ${name} (model id ${id}). If asked what model you are, answer ${name}. ` +
    `Do not say you are Grok 4.5.`;
  const out = (Array.isArray(messages) ? messages : []).map((m) => {
    if (!m || m.role !== "system") return m;
    if (typeof m.content === "string") {
      return { ...m, content: rewriteIdentityText(m.content, id) };
    }
    return m;
  });
  const sys = out.find((m) => m && m.role === "system" && typeof m.content === "string");
  if (sys) {
    if (!sys.content.startsWith(`You are ${name}`)) {
      sys.content = `${line}\n\n${sys.content}`;
    }
  } else {
    out.unshift({ role: "system", content: line });
  }
  return out;
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
    const norm = normalizeImageUrl(asString(url));
    if (norm) return { kind: "image", url: norm };
  }
  if (type === "attachment" || type === "file" || type === "user-attachment") {
    const u = attachmentToImageUrl(p);
    if (u) return { kind: "image", url: u };
    const t = asString(p.text ?? p.file_name ?? p.fileName ?? "");
    if (t) return { kind: "text", text: t };
  }
  if (typeof p.file_path === "string" || typeof p.filePath === "string") {
    const u = attachmentToImageUrl(p);
    if (u) return { kind: "image", url: u };
  }
  if (p.text) return { kind: "text", text: asString(p.text) };
  return null;
}

function convertMessage(rawMsg) {
  const msg = unwrapRedacted(rawMsg) || {};
  let role = asString(msg.role || "user");
  const out = [];
  // Chat stores pics as kind/user-attachment entries outside message.content.
  if (msg.kind === "user-attachment" || role === "user-attachment" || role === "attachment") {
    const u = attachmentToImageUrl(msg);
    if (u) {
      out.push({ role: "user", content: [{ type: "image_url", image_url: { url: u } }] });
      return out;
    }
    const fallback = asString(msg.file_name ?? msg.fileName ?? "");
    out.push({ role: "user", content: fallback ? `[attached image: ${fallback}]` : "(empty)" });
    return out;
  }

  if (role === "tool") {
    // The id may live on the message OR inside its content parts. Reading only
    // the top level made every array-shaped tool result collapse to the literal
    // id "tool", so results matched no call and strict providers (Codex/Claude)
    // rejected the request while Grok silently tolerated it.
    let rawId = msg.tool_call_id ?? msg.toolCallId ?? msg.id;
    const partsList = Array.isArray(msg.content) ? msg.content : [];
    if (rawId == null || rawId === "") {
      for (const part of partsList) {
        const p = unwrapRedacted(part) || {};
        const cand = p.toolCallId ?? p.tool_call_id ?? p.id;
        if (cand != null && cand !== "") { rawId = cand; break; }
      }
    }
    // Content: prefer real result payloads from the parts when present.
    let body = msg.content ?? msg.result ?? "";
    if (partsList.length) {
      const chunks = [];
      for (const part of partsList) {
        const p = unwrapRedacted(part) || {};
        const val = p.result ?? p.content ?? p.output ?? p.value ?? p.text;
        if (val != null && val !== "") {
          chunks.push(typeof val === "string" ? val : asString(val));
        }
      }
      if (chunks.length) body = chunks.join("\n");
    }
    if (rawId == null || rawId === "") {
      console.error("[sand-xai] tool result has no id; dropping to avoid a phantom pair");
      return out;
    }
    out.push({
      role: "tool",
      tool_call_id: sanitizeToolId(rawId),
      content: asString(body),
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
      if (content) {
        texts.push(content);
        for (const fp of extractImagePathsFromText(content)) {
          const u = normalizeImageUrl(fp);
          if (u && !images.some((x) => x.url === u)) images.push({ kind: "image", url: u });
        }
      }
      return;
    }
    if (Array.isArray(content)) {
      for (const part of content) {
        const c = convertContentPart(part);
        if (!c) continue;
        if (c.kind === "text" && c.text) {
          texts.push(c.text);
          for (const fp of extractImagePathsFromText(c.text)) {
            const u = normalizeImageUrl(fp);
            if (u && !images.some((x) => x.url === u)) images.push({ kind: "image", url: u });
          }
        }
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
  // file_path / attachments carried alongside the message (not inside content).
  if (!msg.content || typeof msg.content === "string") {
    const u = attachmentToImageUrl(msg);
    if (u && !images.includes(u)) images.push(u);
  }
  if (Array.isArray(msg.toolCalls) || Array.isArray(msg.tool_calls)) {
    for (const tc of msg.toolCalls || msg.tool_calls) {
      // NOTE: spread FIRST. An OpenAI-style tool call carries type:"function",
      // which used to override the "tool-call" tag and make convertContentPart
      // return null — silently dropping every assistant tool call.
      const c = convertContentPart({ ...unwrapRedacted(tc), type: "tool-call" });
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
        ...images.map((img) => ({ type: "image_url", image_url: { url: normalizeImageUrl(img.url) } })).filter((x) => x.image_url.url),
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

function intEnv(name, fallback) {
  const n = Number(env(name, String(fallback)));
  return Number.isFinite(n) && n > 0 ? Math.floor(n) : fallback;
}

function messageChars(msg) {
  if (!msg) return 0;
  let n = 0;
  if (typeof msg.content === "string") n += msg.content.length;
  else if (Array.isArray(msg.content)) {
    for (const p of msg.content) {
      if (!p) continue;
      if (typeof p === "string") n += p.length;
      else if (typeof p.text === "string") n += p.text.length;
      else if (p.type === "image_url") n += 1500;
      else n += JSON.stringify(p).length;
    }
  }
  if (Array.isArray(msg.tool_calls)) n += JSON.stringify(msg.tool_calls).length;
  return n;
}

function clipText(s, max) {
  if (typeof s !== "string" || s.length <= max) return s;
  const keep = Math.max(64, Math.floor((max - 48) / 2));
  return `${s.slice(0, keep)}\n…[truncated ${s.length - max} chars]…\n${s.slice(-keep)}`;
}

function clipMessageContent(msg, max) {
  if (!msg || Array.isArray(msg.content)) return msg;
  if (typeof msg.content !== "string" || msg.content.length <= max) return msg;
  return { ...msg, content: clipText(msg.content, max) };
}

function hasToolCalls(msg) {
  return Boolean(msg && msg.role === "assistant" && Array.isArray(msg.tool_calls) && msg.tool_calls.length);
}

function mergeConsecutiveRoles(msgs) {
  const out = [];
  for (const raw of msgs) {
    const m = { ...raw };
    if (Array.isArray(m.tool_calls)) m.tool_calls = m.tool_calls.map((t) => ({ ...t }));
    const last = out[out.length - 1];
    if (m.role === "user" && last && last.role === "user") {
      const a = contentToParts(last.content);
      const b = contentToParts(m.content);
      last.content = buildUserContent([...a.texts, ...b.texts], [...a.images, ...b.images]);
      continue;
    }
    if (m.role === "assistant" && last && last.role === "assistant") {
      const a = contentToParts(last.content);
      const b = contentToParts(m.content);
      const texts = [...a.texts, ...b.texts];
      if (texts.length) last.content = texts.join("\n");
      if (m.tool_calls && m.tool_calls.length) {
        last.tool_calls = [...(last.tool_calls || []), ...m.tool_calls];
      }
      continue;
    }
    out.push(m);
  }
  return out;
}

// Gemini: a function-call turn must follow a user or function-response turn.
// Never start (after system) with assistant/tool, and never leave orphan tool rows.
// Strict providers (Codex/OpenAI Responses, Claude) 400 the whole request when a
// tool_call has no matching tool result, or a tool result has no matching call.
// Interrupted turns ("superseded by a new user message") leave exactly that.
// Grok tolerates it; these do not. Reconcile by ID before sending.
function pairToolCallsAndResults(msgs) {
  const list = Array.isArray(msgs) ? msgs.map((m) => ({ ...m })) : [];

  // Pass 1: collect tool result ids present in the transcript.
  const resultIds = new Set();
  for (const m of list) {
    if (m && m.role === "tool") {
      const id = m.tool_call_id || m.toolCallId;
      if (id) resultIds.add(String(id));
    }
  }

  // Pass 2: drop assistant tool_calls that never got a result.
  const keptCallIds = new Set();
  const out = [];
  for (const m of list) {
    if (m && m.role === "assistant" && Array.isArray(m.tool_calls) && m.tool_calls.length) {
      const kept = m.tool_calls.filter((tc) => {
        const id = tc && (tc.id || tc.tool_call_id);
        return id && resultIds.has(String(id));
      });
      if (kept.length !== m.tool_calls.length) {
        const orphans = m.tool_calls.length - kept.length;
        console.error(`[sand-xai] dropped ${orphans} orphan tool_call(s) with no result`);
      }
      for (const tc of kept) keptCallIds.add(String(tc.id || tc.tool_call_id));
      if (kept.length) {
        m.tool_calls = kept;
      } else {
        delete m.tool_calls;
        const hasText =
          (typeof m.content === "string" && m.content.trim()) ||
          (Array.isArray(m.content) && m.content.length);
        if (!hasText) continue; // nothing left worth sending
      }
    }
    out.push(m);
  }

  // Pass 3: drop tool results whose call was dropped or never existed.
  const final = [];
  for (const m of out) {
    if (m && m.role === "tool") {
      const id = m.tool_call_id || m.toolCallId;
      if (!id || !keptCallIds.has(String(id))) {
        console.error("[sand-xai] dropped orphan tool result", id || "(no id)");
        continue;
      }
    }
    final.push(m);
  }
  return final;
}

function normalizeToolTurns(msgs) {
  let list = mergeConsecutiveRoles(msgs);
  const out = [];
  for (const m of list) {
    if (m.role === "system") {
      out.push(m);
      continue;
    }
    if (m.role === "tool") {
      const last = out[out.length - 1];
      if (last && (hasToolCalls(last) || last.role === "tool")) out.push(m);
      continue;
    }
    if (hasToolCalls(m)) {
      const last = out[out.length - 1];
      if (!last || (last.role !== "user" && last.role !== "tool")) continue;
    }
    out.push(m);
  }
  // After system, conversation must start with user.
  let i = 0;
  while (i < out.length && out[i].role === "system") i++;
  while (i < out.length && out[i].role !== "user") {
    if (out[i].role === "assistant") {
      let j = i + 1;
      while (j < out.length && out[j].role === "tool") j++;
      out.splice(i, j - i);
      continue;
    }
    out.splice(i, 1);
  }
  if (i >= out.length) {
    out.push({ role: "user", content: "(continue)" });
  }
  return out;
}

function dropOldestTurn(msgs) {
  let i = 0;
  while (i < msgs.length && msgs[i].role === "system") i++;
  if (i >= msgs.length - 1) return false;
  // Drop the oldest user turn AND the agent loop that followed it, so a
  // function-call never becomes the first turn after system.
  if (msgs[i].role === "user") {
    let j = i + 1;
    while (j < msgs.length - 1 && msgs[j].role !== "user") j++;
    if (j >= msgs.length) return false;
    msgs.splice(i, j - i);
    return true;
  }
  if (msgs[i].role === "assistant") {
    let j = i + 1;
    while (j < msgs.length - 1 && msgs[j].role === "tool") j++;
    msgs.splice(i, j - i);
    return true;
  }
  msgs.splice(i, 1);
  return true;
}

// Gemini / Antigravity reject requests over ~1,048,576 input tokens. Long Grok Bot
// threads plus one huge tool result (file dump) blow that. Keep system + recent turns.
function trimConvertedMessages(messages, model) {
  const list = Array.isArray(messages) ? messages.map((m) => ({ ...m })) : [];
  const gemini = /gemini/i.test(String(model || ""));
  const maxTool = intEnv("SAND_XAI_MAX_TOOL_CHARS", 12000);
  const maxSys = intEnv("SAND_XAI_MAX_SYSTEM_CHARS", 60000);
  const maxOther = intEnv("SAND_XAI_MAX_MESSAGE_CHARS", 24000);
  const defaultTotal = gemini ? 280000 : 400000;
  const maxTotal = intEnv("SAND_XAI_MAX_INPUT_CHARS", defaultTotal);

  const before = list.reduce((n, m) => n + messageChars(m), 0);
  const beforeCount = list.length;

  for (let i = 0; i < list.length; i++) {
    const role = list[i].role;
    const cap = role === "system" ? maxSys : role === "tool" ? maxTool : maxOther;
    list[i] = clipMessageContent(list[i], cap);
  }

  let total = list.reduce((n, m) => n + messageChars(m), 0);
  let dropped = 0;
  while (total > maxTotal && list.length > 3 && dropOldestTurn(list)) {
    dropped += 1;
    total = list.reduce((n, m) => n + messageChars(m), 0);
  }

  if (total > maxTotal) {
    for (let i = 0; i < list.length && total > maxTotal; i++) {
      if (list[i].role !== "tool") continue;
      const prev = messageChars(list[i]);
      list[i] = { ...list[i], content: "[truncated: prior tool output omitted to fit context]" };
      total += messageChars(list[i]) - prev;
    }
  }

  const paired = pairToolCallsAndResults(list);
  const normalized = normalizeToolTurns(paired);
  const after = normalized.reduce((n, m) => n + messageChars(m), 0);
  if (after !== before || dropped || normalized.length !== beforeCount) {
    console.error(
      `[sand-xai] trimmed input chars ${before}→${after} msgs ${beforeCount}→${normalized.length} droppedTurns=${dropped} model=${model}`
    );
  }
  return normalized;
}

function convertTools(tools) {
  if (!Array.isArray(tools) || tools.length === 0) return undefined;
  return tools.map((tool) => {
    const t = unwrapRedacted(tool) || {};
    return {
      type: "function",
      function: {
        name: sanitizeToolName(t.name),
        description: clipText(asString(t.description || t.name || ""), 800),
        parameters: normalizeToolParameters(t.parameters ?? t.inputSchema ?? t.schema),
        // Host schemas allow omission. Responses-backed proxies otherwise inherit
        // strict defaults that make optional fields (e.g. machineId) mandatory.
        strict: false,
      },
    };
  });
}

function debugImageProbe(stage, messages) {
  try {
    const rows = [];
    const list = Array.isArray(messages) ? messages : [];
    for (let i = 0; i < list.length; i++) {
      const m = list[i] || {};
      const c = m.content;
      let hasImg = false, note = '';
      if (Array.isArray(c)) {
        for (const part of c) {
          if (!part || typeof part !== 'object') continue;
          const t = part.type || part.kind || '';
          if (t === 'image' || t === 'image_url' || t === 'input_image') { hasImg = true; break; }
          if (typeof part.text === 'string' && (part.text.indexOf('/attachments/') !== -1 || part.text.indexOf('/uploads/') !== -1)) {
            const mm = part.text.match(/\/home\/box\/[A-Za-z0-9_@.\-\/]+\.(?:png|jpe?g|webp|gif)/gi) || [];
            note = 'text-paths:' + mm.length;
          }
        }
      } else if (typeof c === 'string' && (c.indexOf('/attachments/') !== -1 || c.indexOf('/uploads/') !== -1)) {
        const mm = c.match(/\/home\/box\/[A-Za-z0-9_@.\-\/]+\.(?:png|jpe?g|webp|gif)/gi) || [];
        note = 'str-paths:' + mm.length;
      }
      if (hasImg || note) rows.push(`${stage}[${i}] role=${m.role} img=${hasImg} ${note}`);
    }
    if (rows.length) fs.appendFileSync(DEBUG_LOG + '.images', new Date().toISOString() + ' ' + rows.join(' | ') + '\n');
  } catch { /* ignore */ }
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
  debugImageProbe('raw-in', messages);
  const stepConvert = convertMessages(messages);
  debugImageProbe('after-convert', stepConvert);
  const stepTrim = trimConvertedMessages(stepConvert, model);
  debugImageProbe('after-trim', stepTrim);
  const converted = applyIdentity(stepTrim, model);
  debugImageProbe('after-identity', converted);
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
        const tcs = delta.tool_calls || (choice.message && choice.message.tool_calls);
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
            if (fn.name) acc.name = sanitizeToolName(fn.name);
            if (typeof fn.arguments === "string" && fn.arguments) acc.args += fn.arguments;
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
    const args = normalizeSendToUserArgs(name, parseArgs(acc.args), text);
    toolCalls.push({ id, name, args });
    // One-shot tool-call only. Codex streams argument JSON one token at a time;
    // replaying those fragments then emitting a re-stringified `tool-call` makes
    // the host ToolCallStream.complete() splice the two JSON encodings into
    // invalid args (Claude sends one complete call, so it never hits this).
    push({ type: "tool-call", toolCallId: id, toolName: name, args });
  }

  // Grok Bot only delivers SendToUser. Promote a plain-text-only reply as a
  // final message, but never synthesize end_turn alongside pending tool work.
  if (
    toolsIncludeSendToUser(tools) &&
    toolCalls.length === 0 &&
    asString(text).trim()
  ) {
    const id = sanitizeToolId("call_sendtouser_promote");
    const args = normalizeSendToUserArgs("SendToUser", { message: asString(text).trim(), end_turn: true });
    toolCalls.unshift({ id, name: "SendToUser", args });
    push({ type: "tool-call", toolCallId: id, toolName: "SendToUser", args });
    finishReason = "tool_calls";
  }

  const usage = normalizeUsage(usageRaw);
  const response = {
    modelId: model,
    messages: buildResponseMessages(text, toolCalls),
    finishReason: finishReason === "tool_calls" ? "tool-calls" : finishReason || "stop",
  };
  const send = toolCalls.find((t) => t.name === "SendToUser");
  console.error(
    `[sand-xai] stream finish=${response.finishReason} tools=${toolCalls.map((t) => t.name).join(",") || "-"} text=${text.length}` +
      (send
        ? ` sendKeys=${Object.keys(send.args || {}).join(",")} type=${asString(send.args && send.args.type)} contentLen=${asString(send.args && (send.args.content || send.args.message || send.args.text)).length} end_turn=${send.args && send.args.end_turn}`
        : "")
  );
  if (send) {
    try {
      fs.appendFileSync(
        "/tmp/sand-xai-send.log",
        JSON.stringify({ ts: new Date().toISOString(), args: send.args }) + "\n"
      );
    } catch {
      /* ignore */
    }
  }
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

module.exports = {
  createXaiPromptSession,
  convertMessages,
  normalizeToolParameters,
  mapModelId,
  trimConvertedMessages,
};

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
