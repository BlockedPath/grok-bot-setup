'use strict';

const assert = require('assert').strict;
const fs = require('fs');
const http = require('http');
const path = require('path');
const vm = require('vm');

// Test private functions without extending the adapter's production exports.
const file = path.join(__dirname, '..', 'xai-prompt-session.cjs');
const scope = {
  require: (id) => id === 'fs' ? { ...fs, appendFileSync() {} } : require(id),
  module: { exports: {} }, process: { env: {} }, Buffer, URL, setTimeout, clearTimeout,
  console: { log() {}, error() {} },
};
vm.runInNewContext(fs.readFileSync(file, 'utf8') +
  '\nmodule.exports.test = {convertTools, runStream, parseArgs};', scope, { filename: file });
const adapter = scope.module.exports;
const plain = (value) => JSON.parse(JSON.stringify(value));
const schema = {
  type: 'object',
  properties: {
    path: { type: 'string' }, machineId: { type: 'string' },
    options: { type: 'object', properties: { mandatory: { type: 'string' }, optional: { type: 'string' } }, required: ['mandatory'] },
  },
  required: ['path'],
};
const tools = [
  { name: 'Read', parameters: { jsonSchema: schema } },
  { name: 'Shell', inputSchema: { type: 'object', properties: { command: {type:'string'}, machineId: {type:'string'} }, required: ['command'] } },
  { name: 'CopyToBox', schema: { type: 'object', properties: { machineId: {type:'string'} }, required: ['machineId'] } },
];

async function main() {
  const original = JSON.stringify(tools);
  const converted = plain(adapter.test.convertTools(tools));
  for (const tool of converted) assert.equal(tool.function.strict, false, 'explicit non-strict semantics must survive Responses translation');
  assert.deepEqual(converted[0].function.parameters, schema);
  assert.deepEqual(converted[1].function.parameters.required, ['command']);
  assert.deepEqual(converted[2].function.parameters.required, ['machineId']);
  assert.equal(JSON.stringify(tools), original, 'do not mutate the source schemas');
  console.log('PASS: explicit strict:false; required, optional, nested and genuinely required machineId schemas unchanged');

  let returnedArgs;
  const requests = [];
  const server = http.createServer((req, res) => {
    let raw = '';
    req.on('data', chunk => { raw += chunk; });
    req.on('end', () => {
      requests.push(JSON.parse(raw));
      res.writeHead(200, {'Content-Type':'text/event-stream'});
      const args = JSON.stringify(returnedArgs);
      for (const [index, fragment] of [args.slice(0, 5), args.slice(5)].entries()) {
        res.write('data: ' + JSON.stringify({choices:[{delta:{tool_calls:[{index:0, ...(index === 0 ? {id:'call_probe'} : {}), function:{...(index === 0 ? {name:'Read'} : {}), arguments:fragment}}]}}]}) + '\n\n');
      }
      res.end('data: ' + JSON.stringify({choices:[{delta:{},finish_reason:'tool_calls'}]}) + '\n\ndata: [DONE]\n\n');
    });
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  try {
    for (const [label, extra] of [
      ['absent', {}], ['null', {machineId:null}], ['empty', {machineId:''}],
      ['whitespace', {machineId:'   '}], ['valid', {machineId:'registered-test-machine'}],
      ['unknown', {machineId:'unregistered-test-machine'}],
    ]) {
      returnedArgs = {path:'/tmp/machineid-omission-check.txt', ...extra};
      const result = await adapter.test.runStream({
        model:'test-model', messages:[{role:'user',content:'synthetic schema test'}], tools,
        invocationId:'schema-test', auth:{mode:'key',token:'test-only',extraHeaders:{},baseUrl:`http://127.0.0.1:${server.address().port}`},
      });
      const call = result.parts.find(part => part.type === 'tool-call');
      assert.ok(call, 'must parse the SSE tool call');
      assert.deepEqual(plain(call.args), returnedArgs, label + ' arguments must remain unchanged');
      const history = plain(adapter.convertMessages(result.response.messages));
      const historicalCall = history.flatMap(m => m.tool_calls || [])[0];
      assert.deepEqual(JSON.parse(historicalCall.function.arguments), returnedArgs, label + ' historical serialization');
      const request = requests[requests.length - 1];
      assert.deepEqual(request.tools, converted, 'HTTP request must preserve schemas and strict:false');
      assert.equal(Object.prototype.hasOwnProperty.call(call.args, 'machineId'), label !== 'absent');
    }
    console.log('PASS: HTTP/SSE and historical serialization preserve absent/null/empty/whitespace/valid/unknown selectors');
  } finally {
    await new Promise(resolve => server.close(resolve));
  }
}
main().catch(error => { console.error(error); process.exitCode = 1; });
