'use strict';
// Optional integration against a supplied host bundle. Extract only named pure
// helpers; never require/launch the host or connect to a registered computer.
const assert = require('assert').strict;
const fs = require('fs');
const vm = require('vm');
const z = require('zod');
const convert = require('zod-to-json-schema').zodToJsonSchema;
const hostFile = process.env.SAND_HOST_BUNDLE;
if (!hostFile) throw Error('Set SAND_HOST_BUNDLE to the host-main.cjs to verify');
const source = fs.readFileSync(hostFile, 'utf8');
const names = [
  'preprocessLenientNumber', 'lenientNumber', 'createOffsetSchema', 'createLimitSchema',
  'createIncludeLineNumbersSchema', 'createParametersSchemaLatest',
  'machineIdSchema', 'extendWithMachineId', 'extendMachineIdParameter',
  'extendRequiredMachineIdParameter', 'resolveMachineIdArgument',
  'stripSchemaArtifacts', 'createZodAgentTool', 'jsonSchema',
  'withLocalToolScope', 'createMachineRoutedTool',
];
const extracted = names.map(name => {
  const start = source.indexOf('function ' + name + '(');
  assert.notEqual(start, -1, 'missing host helper: ' + name);
  const end = source.indexOf('\n}\n', start);
  assert.notEqual(end, -1);
  return source.slice(start, end + 2);
}).join('\n');
const scope = {
  external_exports: z, esm_default2: convert, MACHINE_ID_DESCRIPTION: 'Registered machine identifier.',
  schemaSymbol: Symbol.for('vercel.ai.schema'), validatorSymbol: Symbol('validator'),
  sandTurnDirectionEpochKey: Symbol('epoch'), sandLocalToolScopeKey: Symbol('local-scope'),
  ToolCallUnexpectedEnvironmentError: Error,
};
vm.createContext(scope);
vm.runInContext(extracted, scope);
const plain = v => JSON.parse(JSON.stringify(v));
const base = scope.createParametersSchemaLatest({includeNegativeOffset:true});
const machine = scope.extendMachineIdParameter(base, ['registered-test-machine'], 'open');
const parameters = scope.createZodAgentTool('READ', {name:'Read',parameters:machine}).parameters.jsonSchema;
assert.deepEqual(plain(parameters.required), ['path']);
assert.equal(machine.safeParse({path:'/tmp/example'}).success, true);
assert.equal(machine.safeParse({path:'/tmp/example',machineId:null}).success, false);
const requiredMachine = scope.extendRequiredMachineIdParameter(base, ['registered-test-machine'], 'open');
assert.equal(requiredMachine.safeParse({path:'/tmp/example'}).success, false);
console.log('PASS: extracted host Read definition/conversion requires only path; copy-tool machineId remains required');
console.log('Host Read schema: ' + JSON.stringify(parameters));

async function main() {
  const events = [];
  const ctx = { get() { return 123; }, with(key, value) { assert.equal(key, scope.sandLocalToolScopeKey); return {...this, localScope:value}; } };
  const handler = {};
  const meta = {toolCallId:'routing-test'};
  for (const action of ['read-file', 'run-command']) {
    const box = {name:action, parameters:{jsonSchema:parameters},descriptionGenerator:()=>'',execute:async (receivedCtx, receivedHandler, stream, receivedMeta)=>{
      assert.equal(receivedCtx,ctx); assert.equal(receivedHandler,handler); assert.equal(receivedMeta,meta);
      let raw=''; for await (const chunk of stream) raw+=chunk;
      const args=JSON.parse(raw); assert.equal(Object.prototype.hasOwnProperty.call(args,'machineId'),false);
      events.push('box'); return 'box';
    }};
    let approvalAllowed = true;
    const permission = {completeScope(s) { assert.equal(s.action,action); events.push('complete'); }};
    const machineTool = scope.withLocalToolScope({...box,execute:async (receivedCtx, receivedHandler, stream, receivedMeta)=>{
      assert.equal(receivedCtx.localScope.agentId,'test-agent');
      assert.equal(receivedCtx.localScope.directionEpoch,123);
      assert.equal(receivedHandler,handler); assert.equal(receivedMeta,meta);
      events.push('machine');
      let raw=''; for await (const chunk of stream) raw+=chunk;
      const args=machine.parse(JSON.parse(raw));
      const id=scope.resolveMachineIdArgument(['registered-test-machine'],args);
      if (id !== 'registered-test-machine') throw Error('Unknown explicit selector');
      events.push('approval'); // Mock the existing user-computer boundary; never contact it.
      if (!approvalAllowed) throw Error('Approval denied');
      return id;
    }},'test-agent',permission,action);
    const routed=scope.createMachineRoutedTool({boxTool:box,machineTool,descriptionSuffix:''});
    for (const [label,extra] of [['absent',{}],['null',{machineId:null}],['empty',{machineId:''}],['space',{machineId:'   '}],['unknown',{machineId:'unknown'}],['valid',{machineId:'registered-test-machine'}]]) {
      events.length=0;
      const raw=JSON.stringify({path:'/tmp/example',...extra});
      const stream=(async function*(){yield raw.slice(0,9);yield raw.slice(9);})();
      if (label==='absent') {
        assert.equal(await routed.execute(ctx,handler,stream,meta),'box');
        assert.deepEqual(events,['box']);
      } else if (label==='valid') {
        assert.equal(await routed.execute(ctx,handler,stream,meta),'registered-test-machine');
        assert.deepEqual(events,['machine','approval','complete']);
      } else {
        await assert.rejects(routed.execute(ctx,handler,stream,meta));
        assert.deepEqual(events,['machine','complete']);
      }
    }
    approvalAllowed = false;
    events.length = 0;
    await assert.rejects(routed.execute(ctx, handler, (async function* () {
      yield JSON.stringify({path:'/tmp/example',machineId:'registered-test-machine'});
    })(), meta), /Approval denied/);
    assert.deepEqual(events, ['machine','approval','complete'], 'denied explicit targeting must not fall back to box');
  }
  console.log('PASS: extracted dispatcher preserves omission, explicit targeting, permission scope/cleanup; invalid selectors never fall back to box (machine execution mocked)');
}
main().catch(error=>{console.error(error);process.exitCode=1;});
