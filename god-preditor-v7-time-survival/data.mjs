/** Read-only Supabase archive reader. Sequence cursors are exact decimal strings. */
const PAGE_MAX = 1000;
const SELECT = 'id,source_seq,coefficient,round_timestamp';

function sequence(value) {
  if (typeof value === 'number' && !Number.isSafeInteger(value)) return null;
  if (!['number', 'string', 'bigint'].includes(typeof value)) return null;
  const text = String(value);
  if (!/^-?\d+$/.test(text)) return null;
  try { return BigInt(text).toString(); } catch { return null; }
}

export function normalizeRound(row, now = Date.now()) {
  if (!row || typeof row !== 'object' || row.completed === false || row.estimated === true) return null;
  const seq = sequence(row.source_seq);
  const id = typeof row.id === 'string' ? row.id : Number.isSafeInteger(row.id) ? String(row.id) : '';
  const x = typeof row.coefficient === 'number' || typeof row.coefficient === 'string'
    ? Number(row.coefficient) : NaN;
  const t = typeof row.round_timestamp === 'string' ? Date.parse(row.round_timestamp) : NaN;
  if (seq === null || !id || !Number.isFinite(x) || x < 1 || !Number.isFinite(t) || t <= 0 || t > now) return null;
  return { id, seq, x, t };
}

export function compareSequences(a, b) {
  const first = sequence(a), second = sequence(b);
  if (first === null || second === null) throw new TypeError('Некорректный номер источника');
  return BigInt(first) < BigInt(second) ? -1 : BigInt(first) > BigInt(second) ? 1 : 0;
}

/**
 * getHead() -> exact maximum source_seq or null.
 * loadArchive({snapshotSeq,onBatch,signal}) reads all rows <= a fixed head.
 * pollAfter({cursor,onBatch,signal}) captures a new head and reads (cursor,head].
 * Both loaders resolve {rounds,cursor,snapshotSeq,sourceCount,count,futureCount,
 * rejectedCount,complete:true}. A rejected/future row is never a fake event.
 * Future rows hold cursor below their sequence until their timestamp arrives.
 * onBatch(rounds,stats) is progress only: persist a complete cache after resolve.
 */
export function createReader({ url, publishableKey, table = 'luckyjet_rounds', fetchImpl = globalThis.fetch, pageSize = PAGE_MAX } = {}) {
  const origin = new globalThis.URL(url);
  if (!['https:', 'http:'].includes(origin.protocol) || origin.username || origin.password) throw new TypeError('Некорректный адрес Supabase');
  if (typeof publishableKey !== 'string' || !publishableKey.trim()) throw new TypeError('Не задан публичный ключ Supabase');
  if (!/^[a-zA-Z_][a-zA-Z0-9_]*$/.test(table)) throw new TypeError('Некорректная таблица');
  if (typeof fetchImpl !== 'function') throw new TypeError('Fetch недоступен');
  if (!Number.isInteger(pageSize) || pageSize < 1 || pageSize > PAGE_MAX) throw new TypeError('Размер страницы должен быть от 1 до 1000');
  const endpoint = new globalThis.URL('/rest/v1/' + table, origin);

  async function request(filters, signal) {
    signal?.throwIfAborted();
    const target = new globalThis.URL(endpoint);
    target.searchParams.set('select', SELECT);
    target.searchParams.set('completed', 'eq.true');
    target.searchParams.set('estimated', 'eq.false');
    target.searchParams.set('round_timestamp', 'not.is.null');
    target.searchParams.set('source_seq', 'not.is.null');
    for (const [key, value] of filters) target.searchParams.append(key, String(value));
    const response = await fetchImpl(target, {
      headers: { apikey: publishableKey, Accept: 'application/json' },
      cache: 'no-store', signal
    });
    if (!response.ok) throw new Error('Supabase HTTP ' + response.status + ' — данные не загружены полностью');
    const rows = await response.json();
    if (!Array.isArray(rows)) throw new Error('Supabase вернул некорректную страницу');
    signal?.throwIfAborted();
    return rows;
  }

  async function getHead({ signal } = {}) {
    const rows = await request([['order', 'source_seq.desc'], ['limit', 1]], signal);
    if (!rows.length) return null;
    const head = sequence(rows[0].source_seq);
    if (head === null) throw new Error('Supabase вернул некорректный номер источника');
    return head;
  }

  async function read({ snapshotSeq, cursor = null, direction, onBatch, signal }) {
    const snapshot = snapshotSeq === null ? null : sequence(snapshotSeq);
    const initial = cursor === null ? null : sequence(cursor);
    if (snapshotSeq !== null && snapshot === null || cursor !== null && initial === null) throw new TypeError('Некорректный курсор истории');
    const collected = new Map();
    let sourceCount = 0, rejectedCount = 0, futureCount = 0, firstFuture = null, boundary = initial;
    const progress = () => {
      let safeCursor = snapshot ?? initial;
      if (firstFuture !== null && safeCursor !== null && BigInt(safeCursor) >= BigInt(firstFuture)) safeCursor = (BigInt(firstFuture) - 1n).toString();
      if (initial !== null && safeCursor !== null && BigInt(safeCursor) < BigInt(initial)) safeCursor = initial;
      return { cursor: safeCursor, snapshotSeq: snapshot, sourceCount, count: collected.size, futureCount, rejectedCount };
    };
    if (snapshot === null || initial !== null && BigInt(snapshot) <= BigInt(initial)) return { rounds: [], ...progress(), complete: true };
    while (true) {
      const filters = [['order', 'source_seq.' + direction], ['limit', pageSize], ['source_seq', 'lte.' + snapshot]];
      if (direction === 'asc' && boundary !== null) filters.push(['source_seq', 'gt.' + boundary]);
      if (direction === 'desc' && boundary !== null) filters.push(['source_seq', 'lt.' + boundary]);
      const rows = await request(filters, signal);
      if (rows.length > pageSize) throw new Error('Supabase вернул слишком большую страницу');
      if (!rows.length) break;
      const batch = [];
      let previous = boundary;
      const now = Date.now();
      for (const row of rows) {
        const seq = sequence(row?.source_seq);
        if (seq === null || BigInt(seq) > BigInt(snapshot)) throw new Error('Нарушена граница снимка истории');
        if (previous !== null && (direction === 'asc' ? BigInt(seq) <= BigInt(previous) : BigInt(seq) >= BigInt(previous))) throw new Error('Нарушен порядок source_seq: неполный архив не сохранён');
        previous = seq;
        sourceCount++;
        const timestamp = typeof row.round_timestamp === 'string' ? Date.parse(row.round_timestamp) : NaN;
        if (Number.isFinite(timestamp) && timestamp > now) {
          futureCount++;
          if (firstFuture === null || BigInt(seq) < BigInt(firstFuture)) firstFuture = seq;
          continue;
        }
        const normalized = normalizeRound(row, now);
        if (!normalized) { rejectedCount++; continue; }
        const old = collected.get(normalized.id);
        if (old) {
          if (old.seq !== normalized.seq || old.x !== normalized.x || old.t !== normalized.t) throw new Error('Конфликт записей истории: одинаковый id');
          continue;
        }
        collected.set(normalized.id, normalized);
        batch.push(normalized);
      }
      boundary = previous;
      await onBatch?.(batch, progress());
      if (rows.length < pageSize) break;
    }
    return { rounds: [...collected.values()], ...progress(), complete: true };
  }

  async function loadArchive({ snapshotSeq, onBatch, signal } = {}) {
    const snapshot = snapshotSeq === undefined ? await getHead({ signal }) : snapshotSeq;
    return read({ snapshotSeq: snapshot, direction: 'desc', onBatch, signal });
  }

  async function pollAfter({ cursor = null, onBatch, signal } = {}) {
    const snapshot = await getHead({ signal });
    return read({ snapshotSeq: snapshot, cursor, direction: 'asc', onBatch, signal });
  }

  return { getHead, loadArchive, pollAfter };
}
