'use strict';

const assert = require('assert').strict;
const fs = require('fs');
const http = require('http');
const path = require('path');
const vm = require('vm');

const file = process.env.ADAPTER_UNDER_TEST || path.join(__dirname, '..', 'xai-prompt-session.cjs');
const scope = {
  require: id => id === 'fs' ? { ...fs, appendFileSync() {} } : require(id),
  module: { exports: {} }, process: { env: {} }, Buffer, URL, setTimeout, clearTimeout,
  console: { log() {}, error() {} },
};
vm.runInNewContext(fs.readFileSync(file, 'utf8') +
  '\nmodule.exports.test = {normalizeSendToUserArgs, runStream};', scope, { filename: file });
const adapter = scope.module.exports;
const own = (value, key) => Object.prototype.hasOwnProperty.call(value, key);
const plain = value => JSON.parse(JSON.stringify(value));
const readArgs = { path: '/tmp/machineid-omission-check.txt' };
const progressArgs = { type: 'text', content: 'I will read the file now.' };
const tools = [
  { name: 'Read', parameters: { type: 'object', properties: { path: {type:'string'}, machineId: {type:'string'} }, required: ['path'] } },
  { name: 'SendToUser', parameters: { type: 'object', properties: { type: {type:'string'}, content: {type:'string'}, end_turn: {type:'boolean'} }, required: ['type','content'] } },
];

function assertEndTurn(args, expected, present = true) {
  assert.equal(own(args, 'end_turn'), present, 'end_turn presence must not change');
  assert.equal(args.end_turn, expected, 'end_turn must not be invented or coerced');
}

async function main() {
  for (const name of ['SendToUser', 'send_message']) {
    // Null and invalid explicit values must not be silently turned into true;
    // leave validation to the host rather than inventing a completion signal.
    for (const extra of [{}, {end_turn:false}, {end_turn:true}, {end_turn:null}, {end_turn:'false'}]) {
      const input = { ...progressArgs, ...extra };
      const original = JSON.stringify(input);
      const output = adapter.test.normalizeSendToUserArgs(name, input);
      assertEndTurn(output, input.end_turn, own(input, 'end_turn'));
      assert.equal(output.content, input.content);
      assert.equal(output.type, 'text');
      assert.equal(JSON.stringify(input), original, 'normalization must not mutate its input');
    }
  }
  assert.deepEqual(plain(adapter.test.normalizeSendToUserArgs('Read', readArgs)), readArgs);
  console.log('PASS: omitted, false, true, null and invalid explicit end_turn preserved; other tools unchanged');

  let scenario;
  const server = http.createServer((req, res) => {
    let raw = '';
    req.on('data', chunk => { raw += chunk; });
    req.on('end', () => {
      const body = JSON.parse(raw);
      assert.ok(body.tools.every(t => t.function.strict === false), 'machineId strict:false fix must remain');
      res.writeHead(200, {'Content-Type':'text/event-stream'});
      const emit = delta => res.write('data: ' + JSON.stringify({choices:[{delta}]}) + '\n\n');
      if (scenario.text) emit({content:scenario.text});
      for (const [index, call] of (scenario.calls || []).entries()) {
        const args = JSON.stringify(call.args);
        emit({tool_calls:[{index,id:'call_'+index,function:{name:call.name,arguments:args.slice(0,7)}}]});
        emit({tool_calls:[{index,function:{arguments:args.slice(7)}}]});
      }
      res.end('data: ' + JSON.stringify({choices:[{delta:{},finish_reason:scenario.calls?.length ? 'tool_calls' : 'stop'}]}) + '\n\ndata: [DONE]\n\n');
    });
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const run = async (next, exposedTools = tools) => {
    scenario = next;
    const result = await adapter.test.runStream({
      model:'test-model',messages:[{role:'user',content:'synthetic end-turn regression'}],tools:exposedTools,
      invocationId:'end-turn-test',auth:{mode:'key',token:'test-only',extraHeaders:{},baseUrl:`http://127.0.0.1:${server.address().port}`},
    });
    return {result,calls:result.parts.filter(p => p.type === 'tool-call')};
  };
  try {
    for (const extra of [{}, {end_turn:false}, {end_turn:true}, {end_turn:null}]) {
      const input = {...progressArgs,...extra};
      const {result,calls} = await run({text:'Optional commentary',calls:[{name:'SendToUser',args:input}]});
      assert.equal(calls.length,1, 'do not duplicate actual SendToUser calls');
      assertEndTurn(calls[0].args,input.end_turn,own(input,'end_turn'));
      const history = plain(adapter.convertMessages(result.response.messages));
      const serialized = history.flatMap(m => m.tool_calls || [])[0];
      assertEndTurn(JSON.parse(serialized.function.arguments),input.end_turn,own(input,'end_turn'));
    }
    console.log('PASS: real-tool SSE parsing and historical serialization preserve end_turn semantics');

    const progressAndRead = await run({calls:[{name:'SendToUser',args:progressArgs},{name:'Read',args:readArgs}]});
    assert.deepEqual(plain(progressAndRead.calls.map(c => c.toolName)),['SendToUser','Read']);
    assertEndTurn(progressAndRead.calls[0].args,undefined,false);
    assert.deepEqual(plain(progressAndRead.calls[1].args),readArgs);

    const readWithCommentary = await run({text:'I will read it now.',calls:[{name:'Read',args:readArgs}]});
    assert.deepEqual(plain(readWithCommentary.calls.map(c => c.toolName)),['Read'], 'never synthesize a final SendToUser alongside pending work');
    assert.deepEqual(plain(readWithCommentary.calls[0].args),readArgs);
    console.log('PASS: progress+Read and commentary+Read cannot acquire a synthetic end-turn call; machineId stays absent');

    const final = await run({text:'The work is complete.'});
    assert.equal(final.calls.length,1);
    assert.equal(final.calls[0].toolName,'SendToUser');
    assertEndTurn(final.calls[0].args,true);
    assert.equal(final.calls[0].args.content,'The work is complete.');
    assert.equal(final.result.response.finishReason,'tool-calls');
    assert.equal((await run({text:'   '})).calls.length,0);
    assert.equal((await run({text:'Plain text without a delivery tool'},[tools[0]])).calls.length,0);
    console.log('PASS: plain-text-only final promotion explicitly ends the turn; empty/unavailable delivery is not promoted');
  } finally {
    await new Promise(resolve => server.close(resolve));
  }
}
main().catch(error => { console.error(error); process.exitCode = 1; });
