import test from 'node:test';
import assert from 'node:assert/strict';
import { createReader, normalizeRound, compareSequences } from '../data.mjs';

const stamp = new Date(Date.now() - 10000).toISOString();
const row = (seq, overrides = {}) => ({ id: 'round-' + seq, source_seq: String(seq), coefficient: '2.40', round_timestamp: stamp, ...overrides });
function fakeServer(initial, { onRequest, failureAt } = {}) {
  let rows = [...initial], requests = [];
  return {
    requests,
    append: value => rows.push(value),
    fetch: async (input, options) => {
      const url = new URL(input); requests.push({ url, options });
      onRequest?.({ url, number: requests.length });
      if (failureAt === requests.length) return { ok: false, status: 503, json: async () => [] };
      let result = rows.filter(r => r.completed !== false && r.estimated !== true && r.round_timestamp !== null && r.source_seq !== null);
      for (const value of url.searchParams.getAll('source_seq')) {
        const [op, num] = value.split('.');
        if (op === 'not') continue;
        const limit = BigInt(num);
        result = result.filter(r => op === 'lte' ? BigInt(r.source_seq) <= limit : op === 'lt' ? BigInt(r.source_seq) < limit : BigInt(r.source_seq) > limit);
      }
      const asc = url.searchParams.get('order') === 'source_seq.asc';
      result.sort((a, b) => compareSequences(a.source_seq, b.source_seq) * (asc ? 1 : -1));
      return { ok: true, json: async () => result.slice(0, Number(url.searchParams.get('limit'))) };
    }
  };
}
const readerFor = (server, extra = {}) => createReader({ url: 'https://example.supabase.co', publishableKey: 'sb_publishable_test', fetchImpl: server.fetch, ...extra });

test('normalization accepts only completed finite observed rounds and exact signed sequences', () => {
  assert.deepEqual(normalizeRound(row('-9007199254740993123')), { id: 'round--9007199254740993123', seq: '-9007199254740993123', x: 2.4, t: Date.parse(stamp) });
  for (const overrides of [{ coefficient: null }, { coefficient: 'NaN' }, { coefficient: .9 }, { source_seq: 9007199254740992 }, { id: '' }, { round_timestamp: 'bad' }, { round_timestamp: new Date(Date.now() + 60000).toISOString() }, { completed: false }, { estimated: true }]) assert.equal(normalizeRound(row(1, overrides)), null);
});

test('archive reads past 10000 rows with fixed keysets and exact negative sequences', async () => {
  const server = fakeServer(Array.from({ length: 12003 }, (_, i) => row(i - 7000)));
  const batches = [];
  const result = await readerFor(server).loadArchive({ onBatch: (rows, stats) => batches.push(stats.count) });
  assert.equal(result.count, 12003); assert.equal(result.sourceCount, 12003); assert.equal(result.complete, true);
  assert.equal(result.snapshotSeq, '5002'); assert.equal(result.cursor, '5002');
  assert.equal(result.rounds.at(-1).seq, '-7000'); assert.equal(batches.at(-1), 12003);
  for (const { url, options } of server.requests) {
    assert.equal(url.searchParams.get('offset'), null);
    assert.equal(url.searchParams.get('completed'), 'eq.true'); assert.equal(url.searchParams.get('estimated'), 'eq.false');
    assert.equal(options.headers.apikey, 'sb_publishable_test'); assert.ok(Number(url.searchParams.get('limit')) <= 1000);
  }
});

test('new inserts during archive paging cannot shift or duplicate the snapshot', async () => {
  let server;
  server = fakeServer([row(1), row(2), row(3), row(4)], { onRequest: ({ number }) => { if (number === 3) server.append(row(5)); } });
  const reader = readerFor(server, { pageSize: 2 });
  const archived = await reader.loadArchive();
  assert.deepEqual(archived.rounds.map(r => r.seq), ['4', '3', '2', '1']); assert.equal(archived.cursor, '4');
  const incremental = await reader.pollAfter({ cursor: archived.cursor });
  assert.deepEqual(incremental.rounds.map(r => r.seq), ['5']); assert.equal(incremental.cursor, '5');
});

test('incremental pagination is ascending and bounded by one captured head', async () => {
  let server;
  server = fakeServer([row(1), row(2), row(3), row(4), row(5)], { onRequest: ({ number }) => { if (number === 3) server.append(row(6)); } });
  const reader = readerFor(server, { pageSize: 2 });
  const result = await reader.pollAfter({ cursor: '1' });
  assert.deepEqual(result.rounds.map(r => r.seq), ['2', '3', '4', '5']); assert.equal(result.cursor, '5');
  assert.deepEqual((await reader.pollAfter({ cursor: result.cursor })).rounds.map(r => r.seq), ['6']);
});

test('future rows hold a safe cursor and become available on a later poll', async () => {
  const future = row(2, { round_timestamp: new Date(Date.now() + 60000).toISOString() });
  const server = fakeServer([row(1), future, row(3)]);
  const reader = readerFor(server, { pageSize: 2 });
  const result = await reader.loadArchive();
  assert.equal(result.futureCount, 1); assert.equal(result.cursor, '1'); assert.deepEqual(result.rounds.map(r => r.seq), ['3', '1']);
  future.round_timestamp = stamp;
  const updated = await reader.pollAfter({ cursor: result.cursor });
  assert.deepEqual(updated.rounds.map(r => r.seq), ['2', '3']); assert.equal(updated.cursor, '3');
});

test('invalid nonfuture values advance the source cursor without becoming observations', async () => {
  const server = fakeServer([row(1), row(2, { coefficient: 'broken' }), row(3)]);
  const result = await readerFor(server).loadArchive();
  assert.equal(result.rejectedCount, 1); assert.equal(result.count, 2); assert.equal(result.sourceCount, 3); assert.equal(result.cursor, '3');
});

test('partial HTTP failures reject rather than returning a complete-looking archive', async () => {
  const server = fakeServer([row(1), row(2), row(3)], { failureAt: 3 });
  const batches = [];
  await assert.rejects(readerFor(server, { pageSize: 2 }).loadArchive({ onBatch: rows => batches.push(rows.length) }), /HTTP 503/);
  assert.deepEqual(batches, [2]);
});

test('conflicting IDs and non-progressing pages fail explicitly', async () => {
  const server = fakeServer([row(1, { id: 'same' }), row(2, { id: 'same' })]);
  await assert.rejects(readerFor(server).loadArchive(), /Конфликт записей/);
  const stuck = { fetch: async () => ({ ok: true, json: async () => [row(2), row(1)] }) };
  await assert.rejects(readerFor(stuck, { pageSize: 2 }).loadArchive({ snapshotSeq: '2' }), /Нарушен порядок/);
});

test('empty database and unchanged heads do not invent rounds or move the cursor backwards', async () => {
  assert.equal(await readerFor(fakeServer([])).getHead(), null);
  const empty = await readerFor(fakeServer([])).pollAfter({ cursor: '3' });
  assert.equal(empty.cursor, '3'); assert.equal(empty.complete, true); assert.deepEqual(empty.rounds, []);
  const unchanged = await readerFor(fakeServer([row(3)])).pollAfter({ cursor: '3' });
  assert.equal(unchanged.cursor, '3'); assert.equal(unchanged.sourceCount, 0);
});

test('aborted loads stop before requests and malformed responses are rejected', async () => {
  const controller = new AbortController(); controller.abort();
  const server = fakeServer([row(1)]);
  await assert.rejects(readerFor(server).loadArchive({ signal: controller.signal }), { name: 'AbortError' }); assert.equal(server.requests.length, 0);
  const malformed = { fetch: async () => ({ ok: true, json: async () => ({ error: 'not an array' }) }) };
  await assert.rejects(readerFor(malformed).getHead(), /некорректную страницу/);
});
