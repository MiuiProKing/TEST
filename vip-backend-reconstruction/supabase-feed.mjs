/** Read-only, bounded Supabase snapshots. No private credentials are embedded. */
const PAGE_SIZE = 1000;
const IDENTIFIER = /^[A-Za-z_][A-Za-z0-9_]*$/;
const INTEGER = /^-?\d+$/;

function fail(message, code) {
  const error = new Error(message);
  error.code = code;
  return error;
}

function sequence(value) {
  if (typeof value === 'number' && !Number.isSafeInteger(value)) return null;
  if (!['string', 'number', 'bigint'].includes(typeof value) || !INTEGER.test(String(value))) return null;
  try { return BigInt(value).toString(); } catch { return null; }
}

function publicKey(value) {
  if (typeof value !== 'string' || !value.trim() || /\s/.test(value)) return false;
  if (/^sb_secret_/i.test(value)) return false;
  if (/^sb_publishable_[A-Za-z0-9_-]+$/.test(value)) return true;
  const parts = value.split('.');
  if (parts.length !== 3) return false;
  try {
    const encoded = parts[1].replaceAll('-', '+').replaceAll('_', '/');
    const payload = JSON.parse(atob(encoded.padEnd(Math.ceil(encoded.length / 4) * 4, '=')));
    return payload.role === 'anon';
  } catch { return false; }
}

function requestSignal(parent) {
  if (typeof AbortSignal.timeout === 'function' && typeof AbortSignal.any === 'function') {
    return { signal:AbortSignal.any([parent, AbortSignal.timeout(20000)]), cleanup() {} };
  }
  const controller = new AbortController();
  const abort = () => controller.abort(parent.reason);
  const timer = setTimeout(() => controller.abort(), 20000);
  timer.unref?.();
  parent.addEventListener('abort', abort, {once:true});
  if (parent.aborted) abort();
  return {signal:controller.signal,cleanup() {clearTimeout(timer);parent.removeEventListener('abort',abort);}};
}

function waitForCaller(promise, signal) {
  if (!signal) return promise;
  signal.throwIfAborted();
  return new Promise((resolve, reject) => {
    const abort = () => {cleanup();reject(signal.reason ?? new DOMException('Aborted','AbortError'));};
    const cleanup = () => signal.removeEventListener('abort', abort);
    signal.addEventListener('abort', abort, {once:true});
    promise.then(value => {cleanup();resolve(value);}, error => {cleanup();reject(error);});
  });
}

function observations(snapshot, now) {
  const unique = new Map();
  const conflicts = new Set();
  for (const row of snapshot.rows) {
    if (!row.id || !Number.isFinite(row.coefficient) || row.coefficient < 1 ||
        !Number.isFinite(row.timestamp) || row.timestamp <= 0 || row.timestamp > now || row.rejectedFlags) continue;
    const round = {id:row.id,coefficient:row.coefficient,timestamp:row.timestamp};
    const old = unique.get(round.id);
    if (old && (old.coefficient !== round.coefficient || old.timestamp !== round.timestamp)) conflicts.add(round.id);
    else unique.set(round.id, round);
  }
  return [...unique.values()].filter(row => !conflicts.has(row.id))
    .sort((a,b) => a.timestamp-b.timestamp || a.id.localeCompare(b.id));
}

/**
 * load({now,signal,force}) -> {rounds,sourceCount,snapshotSeq,loadedAt}.
 * Exactly historyLimit source rows are inspected at most; invalid rows still count.
 * A fixed sequence head and descending keysets prevent new inserts shifting pages.
 * Cache and in-flight reads are shared; aborting one caller does not abort others.
 */
export function createSupabaseFeed({
  url, publishableKey, table='luckyjet_rounds', timeColumn='round_timestamp',
  sequenceColumn='source_seq', coefficientColumn='coefficient',
  completedColumn='completed', estimatedColumn='estimated', historyLimit=2000,
  cacheMs=15000, fetchImpl=globalThis.fetch,
}={}) {
  let origin;
  try { origin=new URL(url); } catch { throw new TypeError('SUPABASE_URL must be a valid project origin'); }
  const local=['localhost','127.0.0.1','[::1]'].includes(origin.hostname);
  if ((origin.protocol!=='https:' && !(origin.protocol==='http:' && local)) ||
      origin.username || origin.password || origin.search || origin.hash || origin.pathname!=='/') {
    throw new TypeError('SUPABASE_URL must be HTTPS (or local HTTP), without credentials or path');
  }
  if (!publicKey(publishableKey)) throw new TypeError('A Supabase publishable or legacy anon key is required');
  for (const value of [table,timeColumn,sequenceColumn,coefficientColumn,completedColumn,estimatedColumn]) {
    if (typeof value!=='string' || !IDENTIFIER.test(value)) throw new TypeError('Invalid Supabase table or column name');
  }
  if (!Number.isInteger(historyLimit) || historyLimit<1 || historyLimit>10000) throw new RangeError('historyLimit must be 1–10000');
  if (!Number.isFinite(cacheMs) || cacheMs<0 || cacheMs>3600000) throw new RangeError('cacheMs must be 0–3600000');
  if (typeof fetchImpl!=='function') throw new TypeError('fetchImpl must be a function');
  const endpoint=new URL('/rest/v1/'+table,origin);
  let cached=null, inFlight=null, epoch=0;

  async function request(filters, deadline, headOnly=false) {
    const target=new URL(endpoint);
    target.searchParams.set('select',headOnly ? sequenceColumn : ['id',sequenceColumn,coefficientColumn,timeColumn].join(','));
    target.searchParams.set(completedColumn,'eq.true');
    target.searchParams.set(estimatedColumn,'eq.false');
    target.searchParams.append(timeColumn,'not.is.null');
    target.searchParams.append(sequenceColumn,'not.is.null');
    for (const [key,value] of filters) target.searchParams.append(key,String(value));
    const timeout=requestSignal(deadline);
    try {
      let response;
      try {
        response=await fetchImpl(target,{headers:{apikey:publishableKey,Accept:'application/json'},
          method:'GET',credentials:'omit',cache:'no-store',signal:timeout.signal});
      } catch {
        throw fail(timeout.signal.aborted ? 'Supabase request timed out' : 'Supabase request failed',
          timeout.signal.aborted ? 'SUPABASE_TIMEOUT' : 'SUPABASE_NETWORK');
      }
      if (!response.ok) throw fail(`Supabase HTTP ${response.status}`,'SUPABASE_HTTP');
      let rows;
      try { rows=await response.json(); } catch { throw fail('Supabase returned invalid JSON','SUPABASE_DATA'); }
      if (!Array.isArray(rows)) throw fail('Supabase returned an invalid page','SUPABASE_DATA');
      return rows;
    } finally { timeout.cleanup(); }
  }

  async function fetchSnapshot() {
    const deadline=typeof AbortSignal.timeout==='function' ? AbortSignal.timeout(60000) : new AbortController().signal;
    const head=await request([['order',sequenceColumn+'.desc'],['limit',1]],deadline,true);
    if (!head.length) return {rows:[],sourceCount:0,snapshotSeq:null,loadedAt:Date.now()};
    const snapshotSeq=sequence(head[0]?.[sequenceColumn]);
    if (snapshotSeq===null) throw fail('Supabase returned an invalid sequence','SUPABASE_DATA');
    const rows=[];
    let sourceCount=0,boundary=null;
    while (sourceCount<historyLimit) {
      const limit=Math.min(PAGE_SIZE,historyLimit-sourceCount);
      const filters=[['order',sequenceColumn+'.desc'],['limit',limit],[sequenceColumn,'lte.'+snapshotSeq]];
      if (boundary!==null) filters.push([sequenceColumn,'lt.'+boundary]);
      const page=await request(filters,deadline);
      if (page.length>limit) throw fail('Supabase returned an oversized page','SUPABASE_DATA');
      if (!page.length) break;
      let previous=boundary;
      for (const row of page) {
        const seq=sequence(row?.[sequenceColumn]);
        if (seq===null || BigInt(seq)>BigInt(snapshotSeq) || previous!==null && BigInt(seq)>=BigInt(previous)) {
          throw fail('Supabase sequence order is invalid','SUPABASE_DATA');
        }
        previous=seq;sourceCount++;
        const id=typeof row.id==='string' ? row.id : Number.isSafeInteger(row.id) ? String(row.id) : '';
        const coefficient=typeof row[coefficientColumn]==='number' || typeof row[coefficientColumn]==='string'
          ? Number(row[coefficientColumn]) : NaN;
        const timestamp=typeof row[timeColumn]==='string' ? Date.parse(row[timeColumn]) : NaN;
        rows.push({id,coefficient,timestamp,
          rejectedFlags:row[completedColumn]===false || row[estimatedColumn]===true});
      }
      boundary=previous;
      if (page.length<limit) break;
    }
    return {rows,sourceCount,snapshotSeq,loadedAt:Date.now()};
  }

  return {
    async load({now=Date.now(),signal,force=false}={}) {
      if (!Number.isFinite(now) || now<=0) throw new TypeError('now must be a positive UTC millisecond timestamp');
      signal?.throwIfAborted();
      let snapshot;
      if (!force && cached && Date.now()-cached.loadedAt<cacheMs) snapshot=cached;
      else {
        if (!inFlight) {
          const currentEpoch=epoch;
          const work=fetchSnapshot();
          inFlight=work;
          work.then(value => {if (epoch===currentEpoch) cached=value;},()=>{})
            .finally(()=>{if(inFlight===work)inFlight=null;});
        }
        snapshot=await waitForCaller(inFlight,signal);
      }
      signal?.throwIfAborted();
      return {rounds:observations(snapshot,now),sourceCount:snapshot.sourceCount,
        snapshotSeq:snapshot.snapshotSeq,loadedAt:snapshot.loadedAt};
    },
    clear() { epoch++;cached=null;inFlight=null; },
  };
}
