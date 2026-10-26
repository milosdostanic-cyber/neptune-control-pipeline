import {readFileSync} from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';
const script = readFileSync('Resources/StatsBridge.js', 'utf8').replace('__NEPTUNE_MONTH__','2026-10').replace('__NEPTUNE_START__','2026-09-27').replace('__NEPTUNE_END__','2026-10-26');
const api='https://api.neptune.spaceinch.tech';
const row=(id,source,tokens,score)=>({sessionId:id,source,totalTokensInput:tokens,totalTokensOutput:2,totalTokensCacheRead:3,totalTokensCacheWrite:4,sessionScore:score});
async function run({email='a@spaceinch.com',fail=false,partial=false}={}) {
  const messages=[],calls=[];
  class XHR {
    open(method,url){this.method=method;this.url=url;} setRequestHeader(){} send(){}
    addEventListener(_,listener){this.listener=listener;}
    finish(body){this.status=200;this.responseText=JSON.stringify(body);this.listener();}
  }
  const fetch=async url=>{
    calls.push(url);
    const next=new URL(url).searchParams.has('cursor');
    const data=next?[row('2','cursor',20,null)]:[row('1','claude-code',10,80)];
    const body={data,pageInfo:{nextCursor:next?null:'next'},meta:{total:partial?3:2}};
    return {ok:!(fail&&next),status:fail&&next?500:200,json:async()=>body};
  };
  const context={URL,URLSearchParams,Headers,XMLHttpRequest:XHR,location:{origin:'https://app.neptune.spaceinch.tech'},window:{fetch,webkit:{messageHandlers:{neptuneStats:{postMessage:m=>messages.push(m)}}}}};
  vm.runInNewContext(script,context);
  const me=new XHR();me.open('GET',api+'/me');me.setRequestHeader('Authorization','Bearer harmless-local-sentinel');me.send();me.finish({email,employeeId:'employee'});
  const sessions=new XHR();sessions.open('GET',api+'/employees/employee/coding-sessions?date_from=2026-10-26&date_to=2026-10-26');sessions.setRequestHeader('Authorization','Bearer harmless-local-sentinel');sessions.send();sessions.finish({data:[]});
  await new Promise(resolve=>setTimeout(resolve,20));
  return {messages,calls};
}
const good=await run();
assert.equal(good.calls.length,2);
assert.equal(new URL(good.calls[0]).searchParams.get('date_from'),'2026-09-27');
const stats=good.messages.find(m=>m.kind==='stats');assert.ok(stats);
assert.equal(stats.periodStart,'2026-09-27');
assert.equal(stats.periodEnd,'2026-10-26');
assert.equal(stats.apps.find(x=>x.source==='claude-code').tokens,19);
assert.equal(stats.apps.find(x=>x.source==='cursor').tokens,29);
assert.equal(stats.apps.find(x=>x.source==='claude-code').score,80);
assert.equal(stats.apps.find(x=>x.source==='cursor').score,null);
assert.ok(!JSON.stringify(good.messages).includes('harmless-local-sentinel'));
assert.ok(!JSON.stringify(good.messages).includes('employee'));
const privateAccount=await run({email:'private@example.com'});
assert.equal(privateAccount.calls.length,0);
assert.ok(privateAccount.messages.some(m=>m.kind==='wrongAccount'));
for (const options of [{fail:true},{partial:true}]) {
 const result=await run(options);
 assert.ok(!result.messages.some(m=>m.kind==='stats'));
 assert.ok(result.messages.some(m=>m.kind==='unavailable'));
}
console.log('Stats bridge: pagination, token sums, scores, account boundary, privacy and incomplete-response checks passed.');
