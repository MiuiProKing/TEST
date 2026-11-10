// Descriptive V7 statistics. No wagers, writes, or guaranteed future outcomes.
const FRESH_MS = 180_000;
const MIN_AT_RISK = 20;
const MIN_TIME_BUCKET = 30;

function median(values) {
  if (!values.length) return null;
  const sorted = [...values].sort((a, b) => a - b);
  const middle = sorted.length >> 1;
  return sorted.length % 2 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2;
}

export function wilsonInterval(hits, count) {
  if (!count) return null;
  const z = 1.959963984540054;
  const p = hits / count;
  const denominator = 1 + z * z / count;
  const center = (p + z * z / (2 * count)) / denominator;
  const half = z * Math.sqrt(p * (1 - p) / count + z * z / (4 * count * count)) / denominator;
  return [Math.max(0, center - half), Math.min(1, center + half)];
}

function seqValue(value) {
  if (typeof value === 'number' && !Number.isSafeInteger(value)) return null;
  if (value == null || !/^-?\d+$/.test(String(value))) return null;
  const text = String(value);
  const negative = text.startsWith('-');
  const magnitude = (negative ? text.slice(1) : text).replace(/^0+(?=\d)/, '');
  return negative && magnitude !== '0' ? `-${magnitude}` : magnitude;
}

function compareSeq(a, b) {
  if (a === b) return 0;
  if (a == null) return -1;
  if (b == null) return 1;
  const negativeA = a.startsWith('-');
  const negativeB = b.startsWith('-');
  if (negativeA !== negativeB) return negativeA ? -1 : 1;
  const magnitudeA = negativeA ? a.slice(1) : a;
  const magnitudeB = negativeB ? b.slice(1) : b;
  const comparison = magnitudeA.length - magnitudeB.length || (magnitudeA < magnitudeB ? -1 : 1);
  return negativeA ? -comparison : comparison;
}

/** Reject every version of conflicting IDs/sequence numbers, rather than choosing one. */
export function normalizeRounds(input, now = Date.now()) {
  const rows = [];
  const signatures = new Map();
  const conflicts = new Set();
  const excluded = { invalid: 0, future: 0, conflicting: 0, duplicate: 0 };
  for (const row of input ?? []) {
    const x = Number(row?.x);
    const t = Number(row?.t);
    const seq = seqValue(row?.seq);
    const suppliedId = row?.id == null ? '' : String(row.id).trim();
    const id = suppliedId || (seq == null ? '' : `source:${seq}`);
    if (!row || !id || !Number.isFinite(x) || x < 1 || !Number.isFinite(t) || t <= 0 || row.completed === false || row.estimated === true) {
      excluded.invalid++;
      continue;
    }
    if (t > now) {
      excluded.future++;
      continue;
    }
    const keys = [`id:${id}`, ...(seq == null ? [] : [`seq:${seq}`])];
    const signature = JSON.stringify([id, seq, x, t]);
    for (const key of keys) {
      const previous = signatures.get(key);
      if (previous != null && previous !== signature) conflicts.add(key);
      else signatures.set(key, signature);
    }
    rows.push({ round: { id, seq, x, t }, keys });
  }
  const seen = new Set();
  const rounds = [];
  for (const { round, keys } of rows) {
    if (keys.some(key => conflicts.has(key))) excluded.conflicting++;
    else if (seen.has(round.id)) excluded.duplicate++;
    else {
      seen.add(round.id);
      rounds.push(round);
    }
  }
  rounds.sort((a, b) => a.t - b.t || compareSeq(a.seq, b.seq) || a.id.localeCompare(b.id));
  return { rounds, excluded };
}

function chanceInRounds(p, horizon) {
  return p >= 1 ? 1 : p <= 0 ? 0 : -Math.expm1(horizon * Math.log1p(-p));
}

function describeBuckets(buckets) {
  return buckets.map((bucket, value) => ({
    value, ...bucket, p: bucket.total ? bucket.hits / bucket.total : null,
    interval95: wilsonInterval(bucket.hits, bucket.total),
  })).filter(bucket => bucket.total >= MIN_TIME_BUCKET)
    .sort((a, b) => b.p - a.p || b.total - a.total || a.value - b.value)
    .slice(0, 8);
}

/**
 * All probabilities are fractions (0..1); intervals are approximate Wilson 95% bounds.
 * baseline assumes independent rounds. survival describes completed observed gaps;
 * censored gaps are counted separately, never invented as event completions.
 * Time buckets and the one-round baseline holdout do not validate survival forecasts.
 */
export function analyzeRounds(input, {
  threshold = 100, horizon = 3, now = Date.now(), maxGapMs = 300_000,
} = {}) {
  if (!Number.isFinite(threshold) || threshold < 1) throw new RangeError('threshold must be finite and >= 1');
  if (!Number.isSafeInteger(horizon) || horizon < 1) throw new RangeError('horizon must be a positive integer');
  if (!Number.isFinite(now) || now <= 0 || !Number.isFinite(maxGapMs) || maxGapMs <= 0) throw new RangeError('Invalid observation time or collection gap');
  const { rounds, excluded } = normalizeRounds(input, now);
  const count = rounds.length;
  const latestRound = rounds.at(-1) ?? null;
  const latest = latestRound ? { ...latestRound, ageMs: now - latestRound.t, stale: now - latestRound.t > FRESH_MS } : null;
  const hits = rounds.map(round => Number(round.x >= threshold));
  const eventCount = hits.reduce((sum, hit) => sum + hit, 0);
  const p = count ? eventCount / count : null;
  const perRoundBounds = wilsonInterval(eventCount, count);
  const segments = [];
  for (let i = 0; i < count; i++) {
    const delta = i ? rounds[i].t - rounds[i - 1].t : 0;
    if (!i || delta <= 0 || delta > maxGapMs) segments.push([]);
    segments.at(-1).push(hits[i]);
  }
  const gaps = [];
  const censoredLengths = [];
  let leftCensoredIntervals = 0;
  let distance = null;
  for (let index = 0; index < segments.length; index++) {
    const segment = segments[index];
    let lastHit = -1;
    for (let i = 0; i < segment.length; i++) {
      if (!segment[i]) continue;
      if (lastHit >= 0) gaps.push(i - lastHit);
      else if (i > 0) leftCensoredIntervals++;
      lastHit = i;
    }
    if (lastHit < 0) leftCensoredIntervals++;
    const tail = lastHit < 0 ? null : segment.length - 1 - lastHit;
    if (tail > 0) censoredLengths.push(tail);
    if (index === segments.length - 1) distance = tail;
  }
  let atRisk = 0;
  let events = 0;
  if (distance != null) {
    for (const gap of gaps) {
      if (gap > distance) atRisk++;
      if (gap > distance && gap <= distance + horizon) events++;
    }
  }
  const enoughIntervals = distance != null && atRisk >= MIN_AT_RISK;
  const survivalStatus = latest?.stale ? 'stale' : enoughIntervals ? 'ready' : 'insufficient';
  const minutes = Array.from({ length: 60 }, () => ({ total: 0, hits: 0 }));
  const seconds = Array.from({ length: 60 }, () => ({ total: 0, hits: 0 }));
  // Contemporary Europe/Kyiv offsets are whole hours: minute/second equal UTC.
  // No Intl formatter is allocated inside the archive-sized loop.
  for (let i = 0; i < count; i++) {
    const time = new Date(rounds[i].t);
    for (const bucket of [minutes[time.getUTCMinutes()], seconds[time.getUTCSeconds()]]) {
      bucket.total++;
      bucket.hits += hits[i];
    }
  }
  const cut = Math.floor(count * 0.7);
  const trainCount = cut;
  const testCount = count - cut;
  const expected = trainCount ? hits.slice(0, cut).reduce((sum, hit) => sum + hit, 0) / trainCount : null;
  const actual = testCount ? hits.slice(cut).reduce((sum, hit) => sum + hit, 0) / testCount : null;
  const validationReady = trainCount >= 20 && testCount >= 20;
  const cluster = rounds.slice(-80);
  return {
    threshold, horizon, rounds, count, excluded, latest,
    baseline: {
      hits: eventCount, count, p,
      probability: p == null ? null : chanceInRounds(p, horizon),
      interval95: perRoundBounds?.map(bound => chanceInRounds(bound, horizon)) ?? null,
      assumption: 'independent_rounds',
    },
    survival: {
      status: survivalStatus,
      probability: survivalStatus === 'ready' ? events / atRisk : null,
      interval95: survivalStatus === 'ready' ? wilsonInterval(events, atRisk) : null,
      atRisk, events, distance, completedGaps: gaps.length,
      medianGap: median(gaps), segmentCount: segments.length,
      currentSegmentCount: segments.at(-1)?.length ?? 0,
      censoredIntervals: censoredLengths.length,
      censoredLengths, leftCensoredIntervals,
      minimumAtRisk: MIN_AT_RISK, intervalMethod: 'wilson_approximate',
      estimator: 'conditional_completed_gaps',
    },
    cluster: { hits: cluster.filter(round => round.x >= threshold).length, count: cluster.length },
    timeBins: {
      minutes: describeBuckets(minutes), seconds: describeBuckets(seconds),
      minimumCount: MIN_TIME_BUCKET, descriptiveOnly: true,
    },
    validation: {
      status: validationReady ? 'ready' : 'insufficient',
      trainCount, testCount, expected, actual,
      brier: validationReady ? hits.slice(cut).reduce((sum, hit) => sum + (expected - hit) ** 2, 0) / testCount : null,
      target: 'constant_one_round_baseline',
    },
  };
}
