const assert = require("node:assert/strict");
const { normalizeReturnedToolArgs } = require("../xai-prompt-session.cjs");

const bloated = {
  type: "text",
  content: "hello",
  url: "https://example.invalid/file",
  images: [{ url: "https://example.invalid/image" }],
  alt: "image",
  reply_to: "t1u",
  channel: "slack:room",
  to: "dm",
  widget: { prompt: "Continue?", options: [{ label: "Yes" }] },
  bcId: "bc-test",
  secret: { label: "Token", connector: "test", field: "token" },
};

const allowedByType = {
  text: ["type", "content", "images", "reply_to", "channel", "to"],
  attachment: ["type", "url", "alt", "reply_to", "channel"],
  widget: ["type", "widget", "reply_to"],
  "cursor-agent": ["type", "bcId", "reply_to"],
  "secret-request": ["type", "secret", "reply_to"],
};

for (const [type, allowed] of Object.entries(allowedByType)) {
  const input = { ...bloated, type };
  const output = normalizeReturnedToolArgs("SendToUser", input);
  assert.deepEqual(Object.keys(output).sort(), allowed.sort(), type);
  assert.notStrictEqual(output, input, type);
  assert.equal(input.url, bloated.url, `${type} mutated its input`);
}

const shellArgs = { command: "pwd" };
assert.strictEqual(normalizeReturnedToolArgs("Shell", shellArgs), shellArgs);
console.log("xai tool argument normalization: 6/6 PASS");
