import test from 'node:test';
import assert from 'node:assert/strict';
import {createSupabaseFeed} from '../supabase-feed.mjs';

const NOW=1800000000000;
const KEY='sb_publishable_test_key';
const config={url:'https://example.supabase.test',publishableKey:KEY};
const row=(seq,{id=String(seq),coefficient=2,t=NOW-1000}={})=>({id,source_seq:String(seq),coefficient,round_timestamp:new Date(t).toISOString()});

function database(initial,{sequenceColumn='source_seq',onCall}={}) {
  const rows=[...initial];
  const calls=[];
  return {rows,calls,fetch:async(url,options)=>{
    const target=new URL(url);calls.push({target,options});
    await onCall?.({target,options,rows,calls});
    options.signal.throwIfAborted();
    assert.equal(options.method,'GET');
    assert.equal(options.headers.apikey,KEY);
    assert.equal(options.headers.Authorization,undefined);
    assert.equal(target.searchParams.has('offset'),false);
    const filters=target.searchParams.getAll(sequenceColumn);
    let selected=rows.filter(r=>r[sequenceColumn]!=null);
    for (const filter of filters) {
      if (filter.startsWith('lte.')) selected=selected.filter(r=>BigInt(r[sequenceColumn])<=BigInt(filter.slice(4)));
      if (filter.startsWith('lt.')) selected=selected.filter(r=>BigInt(r[sequenceColumn])<BigInt(filter.slice(3)));
    }
    selected.sort((a,b)=>BigInt(a[sequenceColumn])>BigInt(b[sequenceColumn])?-1:1);
    selected=selected.slice(0,Number(target.searchParams.get('limit')));
    return new Response(JSON.stringify(selected),{status:200,headers:{'Content-Type':'application/json'}});
  }};
}

test('bounded snapshots inspect at most2000 rows using exact signed keysets',async()=>{
  const rows=Array.from({length:2600},(_,i)=>row(i-2000,{t:NOW-(2600-i)*1000}));
  const db=database(rows),feed=createSupabaseFeed({...config,fetchImpl:db.fetch});
  const result=await feed.load({now:NOW});
  assert.equal(result.sourceCount,2000);
  assert.equal(result.rounds.length,2000);
  assert.equal(result.snapshotSeq,'599');
  assert.equal(result.rounds[0].id,'-1400');
  assert.equal(result.rounds.at(-1).id,'599');
  assert.equal(db.calls.length,3);
  assert.deepEqual(db.calls[2].target.searchParams.getAll('source_seq'),['not.is.null','lte.599','lt.-400']);
  assert.equal(db.calls[1].target.searchParams.get('completed'),'eq.true');
  assert.equal(db.calls[1].target.searchParams.get('estimated'),'eq.false');
});

test('new inserts after the fixed head cannot shift pages or enter the snapshot',async()=>{
  const db=database(Array.from({length:1500},(_,i)=>row(i,{t:NOW-(1500-i)*1000})),{
    onCall({rows,calls}) {if(calls.length===2) rows.push(row(100000,{coefficient:999}));},
  });
  const result=await createSupabaseFeed({...config,fetchImpl:db.fetch}).load({now:NOW});
  assert.equal(result.sourceCount,1500);
  assert.equal(result.snapshotSeq,'1499');
  assert.equal(result.rounds.some(r=>r.coefficient===999),false);
  assert.equal(new Set(result.rounds.map(r=>r.id)).size,1500);
});

test('invalid and future records count toward raw row bounds without becoming observations',async()=>{
  const rows=[row(1),row(2,{coefficient:0}),row(3,{coefficient:'bad'}),row(4,{t:NOW+10000}),
    {...row(5),round_timestamp:'invalid'}, {...row(6),estimated:true}, {...row(7),completed:false}];
  const db=database(rows),feed=createSupabaseFeed({...config,historyLimit:5,fetchImpl:db.fetch});
  const result=await feed.load({now:NOW});
  assert.equal(result.sourceCount,5);
  assert.equal(result.rounds.length,0);
  assert.equal(db.calls.length,2);
});

test('future filtering is applied per caller even for a cached complete snapshot',async()=>{
  const db=database([row(1),row(2,{t:NOW+1000})]);
  const feed=createSupabaseFeed({...config,fetchImpl:db.fetch});
  assert.deepEqual((await feed.load({now:NOW})).rounds.map(r=>r.id),['1']);
  assert.equal((await feed.load({now:NOW+2000})).rounds.length,2);
  assert.equal((await feed.load({now:NOW-2000})).rounds.length,0);
  assert.equal(db.calls.length,2);
});

test('conflicting IDs are removed and identical observations are deduplicated',async()=>{
  const db=database([row(1,{id:'same',t:NOW-1000}),row(2,{id:'same',t:NOW-2000}),
    row(3,{id:'duplicate'}),row(4,{id:'duplicate'}),row(5,{id:'good',coefficient:'3.5'})]);
  const result=await createSupabaseFeed({...config,fetchImpl:db.fetch}).load({now:NOW});
  assert.deepEqual(result.rounds.map(r=>r.id),['duplicate','good']);
  assert.equal(result.rounds.at(-1).coefficient,3.5);
});

test('completed loads are cached, force bypasses cache, clear invalidates cache',async()=>{
  const db=database([row(1)]),feed=createSupabaseFeed({...config,fetchImpl:db.fetch});
  const first=await feed.load({now:NOW});
  first.rounds[0].coefficient=999;
  assert.equal((await feed.load({now:NOW})).rounds[0].coefficient,2);
  assert.equal(db.calls.length,2);
  await feed.load({now:NOW,force:true});assert.equal(db.calls.length,4);
  feed.clear();await feed.load({now:NOW});assert.equal(db.calls.length,6);
});

test('in-flight reads coalesce and one cancelled caller cannot cancel another',async()=>{
  let release;
  const gate=new Promise(resolve=>{release=resolve;});
  const db=database([row(1)],{onCall:async({calls})=>{if(calls.length===1)await gate;}});
  const feed=createSupabaseFeed({...config,fetchImpl:db.fetch});
  const controller=new AbortController();
  const first=feed.load({now:NOW,signal:controller.signal});
  const rejection=assert.rejects(first,{name:'AbortError'});
  const second=feed.load({now:NOW});
  controller.abort();release();
  await rejection;
  assert.equal((await second).rounds.length,1);
  assert.equal(db.calls.length,2);
});

test('HTTP, network and malformed pages are generic errors and never cached as complete',async()=>{
  let calls=0;
  const feed=createSupabaseFeed({...config,fetchImpl:async()=>{
    calls++;
    if(calls===1)return new Response('private response detail',{status:403});
    throw new Error('secret URL or key should not appear');
  }});
  await assert.rejects(feed.load({now:NOW}),e=>e.message==='Supabase HTTP 403' && e.code==='SUPABASE_HTTP');
  await assert.rejects(feed.load({now:NOW}),e=>e.message==='Supabase request failed' && !e.message.includes('secret'));
  assert.equal(calls,2);
  const malformed=createSupabaseFeed({...config,fetchImpl:async()=>new Response('{}',{status:200})});
  await assert.rejects(malformed.load({now:NOW}),/invalid page/);
});

test('partial paging failure cannot poison a later complete load',async()=>{
  const rows=Array.from({length:1100},(_,i)=>row(i,{t:NOW-(1100-i)*1000}));
  let failed=false;
  const db=database(rows,{onCall({calls}) {if(calls.length===3&&!failed){failed=true;throw Error('temporary');}}});
  const feed=createSupabaseFeed({...config,fetchImpl:db.fetch});
  await assert.rejects(feed.load({now:NOW}),/request failed/);
  const complete=await feed.load({now:NOW});
  assert.equal(complete.rounds.length,1100);
  assert.equal(db.calls.length,6);
});

test('unsafe or non-progressing sequences fail explicitly',async()=>{
  const unsafe=createSupabaseFeed({...config,fetchImpl:async()=>new Response(JSON.stringify([{source_seq:9007199254740992}]))});
  await assert.rejects(unsafe.load({now:NOW}),/invalid sequence/);
  const db=database([row('-9007199254740994'),row('-9007199254740993')]);
  const result=await createSupabaseFeed({...config,fetchImpl:db.fetch}).load({now:NOW});
  assert.equal(result.snapshotSeq,'-9007199254740993');
  assert.equal(result.rounds.length,2);
  let calls=0;
  const unordered=createSupabaseFeed({...config,fetchImpl:async()=>{
    calls++;return new Response(JSON.stringify(calls===1?[{source_seq:'3'}]:[row(2),row(3)]));
  }});
  await assert.rejects(unordered.load({now:NOW}),/sequence order/);
});

test('empty tables and pre-aborted callers do not invent data or make requests',async()=>{
  const db=database([]),feed=createSupabaseFeed({...config,fetchImpl:db.fetch});
  assert.deepEqual((await feed.load({now:NOW})).rounds,[]);
  assert.equal(db.calls.length,1);
  const controller=new AbortController();controller.abort();
  await assert.rejects(feed.load({now:NOW,signal:controller.signal}),{name:'AbortError'});
  assert.equal(db.calls.length,1);
});

test('configuration rejects private keys and permits only safe public API origins/identifiers',()=>{
  assert.throws(()=>createSupabaseFeed(),/SUPABASE_URL/);
  assert.throws(()=>createSupabaseFeed({...config,url:'http://public.example'}),/HTTPS/);
  assert.throws(()=>createSupabaseFeed({...config,url:'https://user:pass@example.test'}),/credentials/);
  assert.throws(()=>createSupabaseFeed({...config,publishableKey:'sb_secret_never_expose'}),/publishable/);
  const jwt=role=>'e30.'+Buffer.from(JSON.stringify({role})).toString('base64url')+'.signature';
  assert.throws(()=>createSupabaseFeed({...config,publishableKey:jwt('service_role')}),/publishable/);
  assert.doesNotThrow(()=>createSupabaseFeed({...config,publishableKey:jwt('anon')}));
  assert.doesNotThrow(()=>createSupabaseFeed({...config,url:'http://localhost:54321'}));
  assert.throws(()=>createSupabaseFeed({...config,table:'rounds?select=*'}),/column name/);
  assert.throws(()=>createSupabaseFeed({...config,historyLimit:10001}),/historyLimit/);
  assert.throws(()=>createSupabaseFeed({...config,cacheMs:-1}),/cacheMs/);
});
