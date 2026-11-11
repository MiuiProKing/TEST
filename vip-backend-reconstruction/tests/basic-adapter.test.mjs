import test from 'node:test';
import assert from 'node:assert/strict';
import {createBasicAnalyzer} from '../basic-analysis.mjs';
import {createClient} from '../client-adapter.mjs';

const NOW=Date.UTC(2026,10,11,4,0,0);
const history=Array.from({length:100},(_,i)=>({id:String(i),coefficient:1.1+i%7,timestamp:NOW-(99-i)*15000}));

test('repeated BASIC requests retain their window until expiry, then calculate another',()=>{
  const engine=createBasicAnalyzer();
  const first=engine.analyze(history,{now:NOW});
  assert.equal(first.ready,true);
  const next=[...history,{id:'next',coefficient:2.1,timestamp:NOW+15000}];
  const held=engine.analyze(next,{now:NOW+15000});
  assert.equal(held.estimatedAt,first.estimatedAt);assert.equal(held.generatedAt,first.generatedAt);
  const after=first.estimatedAt+first.windowMs+1;
  const shifted=history.map(r=>({...r,timestamp:r.timestamp+after-NOW}));
  const expired=engine.analyze(shifted,{now:after});
  assert.equal(expired.ready,true);assert.equal(expired.generatedAt,after);
});

test('stale BASIC input clears an active forecast and separate sources do not share it',()=>{
  const engine=createBasicAnalyzer(),first=engine.analyze(history,{now:NOW});
  const other=engine.analyze(history,{now:NOW+1000,source:'provided_history'});
  assert.notEqual(first.generatedAt,other.generatedAt);
  assert.equal(engine.analyze(history,{now:NOW+180001}).ready,false);
  const fresh=history.map(r=>({...r,timestamp:r.timestamp+190000}));
  assert.equal(engine.analyze(fresh,{now:NOW+190000}).generatedAt,NOW+190000);
});

test('client adapter preserves a deployment prefix and sends only our JSON contract',async()=>{
  const requests=[];
  const client=createClient({baseUrl:'https://example.test/tools/backend',token:'local-test',fetchImpl:async(url,init)=>{
    requests.push({url:String(url),init});return new Response(JSON.stringify({ok:true}),{status:200});
  }});
  await client.getVip('luckyjet');
  await client.analyze({rounds:[]});
  assert.equal(requests[0].url,'https://example.test/tools/backend/api/vip?game=luckyjet');
  assert.equal(requests[1].url,'https://example.test/tools/backend/api/analysis');
  assert.equal(requests[1].init.headers.Authorization,'Bearer local-test');
  assert.deepEqual(JSON.parse(requests[1].init.body),{game:'luckyjet',rounds:[]});
});
