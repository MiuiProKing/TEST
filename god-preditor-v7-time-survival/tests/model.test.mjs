import test from 'node:test';
import assert from 'node:assert/strict';
import { analyzeRounds, normalizeRounds, wilsonInterval } from '../model.mjs';

const START = Date.UTC(2026, 10, 10, 8);
const rows = values => values.map((x, i) => ({ id: `r${i}`, seq: String(i + 1), x, t: START + i * 10_000 }));
const analyze = (values, options = {}) => analyzeRounds(rows(values), { now: START + (values.length - 1) * 10_000, ...options });

test('independent horizon baseline preserves original formula and bounds', () => {
  const result = analyze([1, 100, 2, 20], { threshold: 100, horizon: 3 });
  assert.equal(result.baseline.p, 0.25);
  assert.equal(result.baseline.probability, 1 - 0.75 ** 3);
  assert.ok(result.baseline.interval95[0] < result.baseline.probability);
  assert.ok(result.baseline.interval95[1] > result.baseline.probability);
});

test('distance zero includes next-round gaps and never includes a zero-length event', () => {
  const values = Array.from({ length: 31 }, (_, i) => i % 3 < 2 ? 100 : 1);
  const result = analyze(values, { horizon: 1 });
  assert.equal(result.survival.distance, 0);
  assert.equal(result.survival.completedGaps, 20);
  assert.equal(result.survival.atRisk, 20);
  assert.equal(result.survival.events, 10);
  assert.equal(result.survival.probability, 0.5);
  assert.equal(result.survival.medianGap, 1.5);
});

test('conditional survival uses >distance and <=distance+horizon', () => {
  const values = [100];
  for (let i = 0; i < 20; i++) values.push(1, 100, 1, 1, 100);
  values.push(1, 1);
  const result = analyze(values, { horizon: 1 });
  assert.equal(result.survival.distance, 2);
  assert.equal(result.survival.atRisk, 20);
  assert.equal(result.survival.events, 20);
  assert.equal(result.survival.probability, 1);
  assert.equal(result.survival.censoredIntervals, 1);
  assert.deepEqual(result.survival.censoredLengths, [2]);
  assert.equal(result.survival.completedGaps, 40);
});

test('fewer than20 comparable intervals suppresses the estimate', () => {
  const result = analyze([100, 1, 100]);
  assert.equal(result.survival.atRisk, 1);
  assert.equal(result.survival.status, 'insufficient');
  assert.equal(result.survival.probability, null);
  assert.equal(result.survival.interval95, null);
});

test('collection gaps split intervals and reset current survival distance', () => {
  const input = rows([100, 1, 100, 1, 100]);
  input[3].t += 600_000;
  input[4].t += 600_000;
  const result = analyzeRounds(input, { now: input.at(-1).t });
  assert.equal(result.survival.segmentCount, 2);
  assert.equal(result.survival.completedGaps, 1);
  assert.equal(result.survival.medianGap, 2);
  assert.equal(result.survival.distance, 0);
  input[4].x = 1;
  const withoutTailHit = analyzeRounds(input, { now: input.at(-1).t });
  assert.equal(withoutTailHit.survival.distance, null);
  assert.equal(withoutTailHit.survival.atRisk, 0);
});

test('duplicate, contradictory, invalid, and future rounds cannot inflate counts', () => {
  const input = rows([100, 2, 3, 4]);
  input.push({ ...input[0] }, { ...input[1], x: 99 });
  input.push({ id: 'bad', seq: '8', x: Infinity, t: START });
  input.push({ id: 'future', seq: '9', x: 100, t: START + 1_000_000 });
  const result = analyzeRounds(input, { now: START + 30_000 });
  assert.equal(result.count, 3);
  assert.deepEqual(result.rounds.map(round => round.x), [100, 3, 4]);
  assert.deepEqual(result.excluded, { invalid: 1, future: 1, conflicting: 2, duplicate: 1 });
});

test('sequence conflicts are rejected and huge integer sequences sort safely', () => {
  const input = [
    { id: 'a', seq: '9007199254740993', x: 1, t: START },
    { id: 'b', seq: '9007199254740992', x: 2, t: START },
    { id: 'c', seq: '7', x: 100, t: START + 10_000 },
    { id: 'd', seq: '7', x: 5, t: START + 20_000 },
  ];
  const result = normalizeRounds(input, START + 30_000);
  assert.deepEqual(result.rounds.map(round => round.id), ['b', 'a']);
  assert.equal(result.excluded.conflicting, 2);
});

test('signed imported sequences retain exact values and sort numerically at timestamp ties', () => {
  const sequences = ['2', '-001', '-9007199254740992', '9007199254740993', '-77143', '-9007199254740993', '0'];
  const input = sequences.map((seq, i) => ({ id: `signed${i}`, seq, x: 2, t: START }));
  const result = normalizeRounds(input, START);
  assert.deepEqual(result.rounds.map(round => round.seq), [
    '-9007199254740993', '-9007199254740992', '-77143', '-1', '0', '2', '9007199254740993',
  ]);
  for (const seq of ['-0', '-000', '0', '000', -0, 0]) {
    const single = normalizeRounds([{ id: 'zero', seq, x: 2, t: START }], START);
    assert.equal(single.rounds[0].seq, '0');
  }
  assert.equal(normalizeRounds([{ id: 'negative', seq: -77143, x: 2, t: START }], START).rounds[0].seq, '-77143');
});

test('stale inputs never present a ready survival forecast', () => {
  const input = rows(Array(25).fill(100));
  const result = analyzeRounds(input, { now: input.at(-1).t + 180_001 });
  assert.equal(result.latest.stale, true);
  assert.equal(result.survival.status, 'stale');
  assert.equal(result.survival.probability, null);
  assert.equal(result.survival.atRisk, 24);
});

test('minute and second tables are descriptive, supported buckets only', () => {
  const input = Array.from({ length: 40 }, (_, i) => ({
    id: String(i), seq: String(i), x: i % 2 ? 100 : 1,
    t: START + i * 60 * 60_000 + 12 * 60_000 + 34_000,
  }));
  const result = analyzeRounds(input, { now: input.at(-1).t });
  assert.equal(result.timeBins.descriptiveOnly, true);
  assert.deepEqual(result.timeBins.minutes.map(bin => [bin.value, bin.total, bin.hits, bin.p]), [[12, 40, 20, 0.5]]);
  assert.deepEqual(result.timeBins.seconds.map(bin => [bin.value, bin.total, bin.hits]), [[34, 40, 20]]);
  assert.ok(result.timeBins.minutes[0].interval95[0] < 0.5);
});

test('chronological70/30 validation trains a fixed one-round baseline only', () => {
  const input = rows([...Array(70).fill(100), ...Array(30).fill(1)]).reverse();
  const result = analyzeRounds(input, { now: START + 99 * 10_000, horizon: 10 });
  assert.equal(result.validation.status, 'ready');
  assert.equal(result.validation.target, 'constant_one_round_baseline');
  assert.equal(result.validation.trainCount, 70);
  assert.equal(result.validation.testCount, 30);
  assert.equal(result.validation.expected, 1);
  assert.equal(result.validation.actual, 0);
  assert.equal(result.validation.brier, 1);
});

test('empty and short history never fabricate statistics or denominator80', () => {
  const empty = analyzeRounds([], { now: START });
  assert.equal(empty.baseline.probability, null);
  assert.equal(empty.latest, null);
  assert.equal(empty.survival.medianGap, null);
  assert.equal(empty.validation.brier, null);
  assert.deepEqual(empty.cluster, { hits: 0, count: 0 });
  assert.deepEqual(analyze([1, 100]).cluster, { hits: 1, count: 2 });
});

test('Wilson intervals are finite at zero and all events; bad options rejected', () => {
  assert.equal(wilsonInterval(0, 0), null);
  assert.ok(wilsonInterval(0, 20).every(Number.isFinite));
  assert.ok(wilsonInterval(20, 20).every(Number.isFinite));
  assert.throws(() => analyzeRounds([], { threshold: NaN }), RangeError);
  assert.throws(() => analyzeRounds([], { horizon: 0 }), RangeError);
});
