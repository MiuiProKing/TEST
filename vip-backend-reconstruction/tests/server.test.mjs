import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import {createApp} from '../server.mjs';

const NOW=Date.UTC(2026,10,10,19,40,0);
const rounds=Array.from({length:400},(_,i)=>({id:String(i),coefficient:i%31===0?550:i%13===0?45:1.5,timestamp:NOW-(399-i)*15000}));
async function withServer(fn,options={}) {
  const feed=options.feed ?? {load:async()=>({rounds,sourceCount:rounds.length,loadedAt:NOW})};
  const server=http.createServer(createApp({feed,token:'test-only-token',clock:()=>NOW,allowedOrigins:['https://example.test'],...options}));
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  const base=`http://127.0.0.1:${server.address().port}`;
  try {await fn(base);} finally {await new Promise(resolve=>server.close(resolve));}
}
const authorized={Authorization:'Bearer test-only-token'};
async function post(base,path,body,headers={}) {
  return fetch(base+path,{method:'POST',headers:{...authorized,'Content-Type':'application/json',...headers},body:JSON.stringify(body)});
}

test('health identifies reconstruction; API requires configured token and allowed origin',async()=>{
  await withServer(async base=>{
    assert.equal((await (await fetch(base+'/health')).json()).reconstruction,true);
    assert.equal((await fetch(base+'/api/vip')).status,401);
    assert.equal((await fetch(base+'/api/vip',{headers:{...authorized,Origin:'https://other.test'}})).status,403);
    const good=await fetch(base+'/api/vip?game=luckyjet',{headers:{...authorized,Origin:'https://example.test'}});
    assert.equal(good.status,200);assert.equal(good.headers.get('access-control-allow-origin'),'https://example.test');
    const data=await good.json();assert.equal(data.sampleSize,400);assert.equal(data.originalServerModel,false);
    assert.deepEqual(data.thresholds.map(x=>x.threshold),[40,200,500]);
    assert.equal((await fetch(base+'/api/vip?game=rocketqueen',{headers:authorized})).status,400);
  });
});

test('analysis reuses public BASIC rules and never claims an AI model or win probability',async()=>{
  await withServer(async base=>{
    const r=await post(base,'/api/analysis',{game:'luckyjet',rounds:rounds.slice(-200)});
    assert.equal(r.status,200);
    const data=await r.json();assert.equal(data.ready,true);assert.equal(data.aiModelUsed,false);
    assert.equal(data.confidenceType,'heuristic_rule_score');assert.ok(Number.isFinite(data.estimatedCoef));
    assert.ok(data.estimatedAt>NOW);assert.ok(data.windowMs>0);
    const stale=rounds.slice(-200).map(r=>({...r,timestamp:r.timestamp-200000}));
    assert.equal((await post(base,'/api/analysis',{rounds:stale})).status,422);
    assert.equal((await post(base,'/api/analysis',{rounds:rounds.slice(0,19)})).status,422);
    assert.equal((await post(base,'/api/analysis',{rounds})).status,400);
  });
});

test('WIN only counts coefficients inside the announced window; collection gaps remain unknown',async()=>{
  await withServer(async base=>{
    const start=NOW-180000,end=NOW-90000;
    const gapRows=[{id:'before',coefficient:500,timestamp:start-1000},{id:'inside',coefficient:1.1,timestamp:start+1000},{id:'after',coefficient:1.2,timestamp:NOW}];
    const early=await (await post(base,'/api/validate-window',{target:100,start,end,rounds:gapRows,avgRoundSeconds:10})).json();
    assert.notEqual(early.status,'validated');assert.equal(early.status,'unknown');
    const hitRows=[...gapRows,{id:'hit',coefficient:150,timestamp:start+30000}];
    const hit=await (await post(base,'/api/validate-window',{target:100,start,end,rounds:hitRows})).json();
    assert.equal(hit.status,'validated');assert.equal(hit.result.coefficient,150);
  });
});

test('invalid JSON, too-large input and source failures have bounded non-secret errors',async()=>{
  await withServer(async base=>{
    const bad=await fetch(base+'/api/analysis',{method:'POST',headers:authorized,body:'{'});
    assert.equal(bad.status,400);
    const large=await post(base,'/api/analysis',{padding:'x'.repeat(300000)});assert.equal(large.status,413);
    assert.equal((await post(base,'/api/validate-window',{target:0,start:0,end:1,rounds:[]})).status,400);
  });
  await withServer(async base=>{
    const r=await fetch(base+'/api/vip',{headers:authorized});assert.equal(r.status,502);
    assert.doesNotMatch(await r.text(),/sensitive-value/);
  },{feed:{load:async()=>{throw new Error('sensitive-value');}}});
});
