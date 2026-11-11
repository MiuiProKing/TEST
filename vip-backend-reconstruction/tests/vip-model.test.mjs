import test from 'node:test';
import assert from 'node:assert/strict';
import {normalizeRounds} from '../normalize.mjs';
import {calculateVip} from '../vip-model.mjs';

const START = 1800000000000;
function history(n=200, hitEvery=10, start=START) {
  return Array.from({length:n}, (_,i) => ({id:`${start}:${i}`,coefficient:(i+1)%hitEvery===0?40:1.5,timestamp:start+i*10000}));
}

test('normalizer excludes invalid/future/unconfirmed/conflicting data and deduplicates', () => {
  const valid=history(4), now=valid.at(-1).timestamp;
  const out=normalizeRounds([
    ...valid, valid[0], {id:'conflict',coefficient:3,timestamp:START},
    {id:'conflict',coefficient:5,timestamp:START},
    {coefficient:'2.50',timestamp:START+1}, {coefficient:'2.50',timestamp:START+1},
    {id:'future',coefficient:100,timestamp:now+1},
    {id:'bad',coefficient:null,timestamp:START},
    {id:'bad2',coefficient:0,timestamp:START},
    {id:'bad3',coefficient:Infinity,timestamp:START},
    {id:'bad4',coefficient:5,timestamp:'2026-01-01'},
    {id:'bad5',coefficient:5,timestamp:START,completed:false},
    {id:'bad6',coefficient:5,timestamp:START,estimated:true},
  ],{now});
  assert.equal(out.length,5);
  assert.equal(out.filter(r=>r.coefficient===2.5).length,1);
  assert(!out.some(r=>r.id==='conflict'));
  assert.deepEqual(normalizeRounds(valid.reverse(),{now,limit:2}).map(r=>r.timestamp),[START+20000,START+30000]);
});

test('model reports explicitly experimental response-compatible fields and units', () => {
  const rounds=history(),now=rounds.at(-1).timestamp+1;
  const result=calculateVip(rounds,{now,targets:[40]});
  const t=result.thresholds[0];
  assert.equal(result.sampleSize,200);assert.equal(result.currentSegmentSampleSize,200);
  assert.equal(result.avgRoundSeconds,10);assert.equal(result.windowMs,180000);
  assert.equal(result.estimatedRoundsInWindow,18);
  assert.equal(result.reconstruction,true);assert.equal(result.originalServerModel,false);
  assert.equal(result.calibrated,false);assert.equal(t.count,20);assert.equal(t.frequencyPct,10);
  assert(Math.abs(t.probNext3MinPct-100*(1-0.9**18))<1e-10);
  assert(t.probNext3MinPctInterval95[0]<t.probNext3MinPct && t.probNext3MinPctInterval95[1]>t.probNext3MinPct);
  assert.equal(t.estimatedNextAt,rounds.at(-1).timestamp+100000);
  assert.equal(t.etaStatus,'experimental_median_eta');
  assert.equal(t.avgGapMinutes,100000/60000);
});

test('zero observations suppress point probability while preserving uncertainty upper bound', () => {
  const rounds=history(),result=calculateVip(rounds,{now:rounds.at(-1).timestamp,targets:[500]});
  const t=result.thresholds[0];
  assert.equal(t.count,0);assert.equal(t.frequencyPct,0);assert.equal(t.probNext3MinPct,null);
  assert.equal(t.estimateStatus,'no_events');assert.equal(t.estimatedNextAt,null);
  assert(t.probNext3MinPctInterval95[0]>=0 && t.probNext3MinPctInterval95[1]>0 && t.probNext3MinPctInterval95[1]<=100);
});

test('all hits produce finite 100 percent point probability and bounded Wilson interval', () => {
  const rounds=history(200,1),result=calculateVip(rounds,{now:rounds.at(-1).timestamp,targets:[40],windowMs:10000});
  const t=result.thresholds[0];
  assert.equal(t.probNext3MinPct,100);assert.equal(t.frequencyPct,100);
  assert(t.probNext3MinPctInterval95[0]<100 && t.probNext3MinPctInterval95[1]<=100);
});

test('staleness boundary suspends future estimates, retaining historical facts', () => {
  const rounds=history(),last=rounds.at(-1).timestamp;
  assert.equal(calculateVip(rounds,{now:last+180000}).fresh,true);
  const r=calculateVip(rounds,{now:last+180001,targets:[40]});
  assert.equal(r.fresh,false);assert.equal(r.estimateStatus,'stale');
  assert.equal(r.thresholds[0].probNext3MinPct,null);assert.equal(r.thresholds[0].probNext3MinPctInterval95,null);
  assert.equal(r.thresholds[0].estimatedNextAt,null);assert.equal(r.thresholds[0].count,20);
});

test('collection gaps split intervals, current pace, and minimum sample gating', () => {
  const older=history(),current=history(50,5,older.at(-1).timestamp+600000);
  const r=calculateVip([...older,...current],{now:current.at(-1).timestamp,targets:[40]});
  assert.equal(r.sampleSize,250);assert.equal(r.segmentCount,2);assert.equal(r.currentSegmentSampleSize,50);
  assert.equal(r.avgRoundSeconds,10);assert.equal(r.thresholds[0].count,30);
  assert.equal(r.thresholds[0].estimateStatus,'insufficient_contiguous_history');
  assert.equal(r.thresholds[0].probNext3MinPct,null);assert.equal(r.thresholds[0].estimatedNextAt,null);
  assert(r.thresholds[0].avgGapMinutes<2); // The ten-minute collection break never becomes an event gap.
});

test('historical frequency remains separate from current contiguous rate', () => {
  const older=history(200,1),current=history(200,10,older.at(-1).timestamp+600000);
  const r=calculateVip([...older,...current],{now:current.at(-1).timestamp,targets:[40]});
  const t=r.thresholds[0];
  assert.equal(t.frequencyPct,55);assert.equal(t.currentSegmentFrequencyPct,10);
  assert(Math.abs(t.probNext3MinPct-100*(1-0.9**18))<1e-10);
});

test('overdue median ETA is not moved forward and a drought does not inflate future probability', () => {
  const rounds=history(),last=rounds.at(-1).timestamp;
  const early=calculateVip(rounds,{now:last+1,targets:[40]}).thresholds[0];
  const later=calculateVip(rounds,{now:last+100001,targets:[40]}).thresholds[0];
  assert(early.estimatedNextAt>last);assert.equal(later.estimatedNextAt,null);
  assert.equal(later.etaStatus,'overdue');assert.equal(later.probNext3MinPct,early.probNext3MinPct);
});

test('fewer than five events cannot create a median ETA', () => {
  const rounds=history(200,50),t=calculateVip(rounds,{now:rounds.at(-1).timestamp,targets:[40]}).thresholds[0];
  assert.equal(t.count,4);assert.equal(t.etaStatus,'insufficient_events');assert.equal(t.estimatedNextAt,null);
  assert.equal(t.estimateStatus,'ready');assert(t.probNext3MinPct>0);
});

test('duplicate timestamps break continuity; historical-only events cannot power a current forecast', () => {
  const older=history(),current=history(200,1000,older.at(-1).timestamp+600000);
  const t=calculateVip([...older,...current],{now:current.at(-1).timestamp,targets:[40]}).thresholds[0];
  assert.equal(t.count,20);assert.equal(t.eventsInCurrentSegment,0);
  assert.equal(t.probNext3MinPct,null);assert.equal(t.etaStatus,'no_events');
  const tie={id:'tie',coefficient:2,timestamp:current.at(-1).timestamp};
  const r=calculateVip([...current,tie],{now:tie.timestamp,targets:[40]});
  assert.equal(r.segmentCount,2);assert.equal(r.currentSegmentSampleSize,1);
});

test('empty inputs and invalid options do not invent predictions', () => {
  const empty=calculateVip([],{now:START});
  assert.equal(empty.sampleSize,0);assert.equal(empty.fresh,false);assert.equal(empty.avgRoundSeconds,null);
  assert(empty.thresholds.every(t=>t.estimatedNextAt===null && t.probNext3MinPct===null));
  for(const options of [{targets:[]},{targets:[NaN]},{windowMs:0},{minSampleSize:1},{maxGapMs:0},{now:NaN}]) {
    assert.throws(()=>calculateVip([],{now:START,...options}));
  }
  assert.throws(()=>normalizeRounds('not rounds',{now:START}));
  assert.throws(()=>normalizeRounds([],{now:START,limit:0}));
});
