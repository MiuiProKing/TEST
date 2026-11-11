import {normalizeRounds} from './normalize.mjs';

const FRESH_MS = 180000;
const median = a => {
  if (!a.length) return null;
  const s = [...a].sort((x, y) => x-y), n = s.length >> 1;
  return s.length % 2 ? s[n] : (s[n-1]+s[n])/2;
};
const mean = a => a.length ? a.reduce((s, x) => s+x, 0)/a.length : null;
const chance = (p, n) => p <= 0 ? 0 : p >= 1 ? 1 : -Math.expm1(n*Math.log1p(-p));
function wilson(hits, n) {
  if (!n) return null;
  const z = 1.959963984540054, z2 = z*z, p = hits/n;
  const center = (p+z2/(2*n))/(1+z2/n);
  const half = z*Math.sqrt(p*(1-p)/n+z2/(4*n*n))/(1+z2/n);
  return [Math.max(0, center-half), Math.min(1, center+half)];
}
function eventGaps(segment, threshold) {
  const events = segment.filter(row => row.coefficient >= threshold), gaps = [];
  for (let i=1; i<events.length; i++) gaps.push(events[i].timestamp-events[i-1].timestamp);
  return {events, gaps};
}

/**
 * Independent, inspectable reconstruction of the public VIP response contract.
 * The original private server formula is unavailable. Neither probabilities nor
 * median interval ETAs have demonstrated predictive advantage.
 *
 * Historical count/frequency use every normalized round. Future-window estimates
 * use only the latest continuous segment, with >=minSampleSize fresh rounds.
 * No elapsed-wait CDF is treated as a future probability and no overdue ETA is
 * shifted arbitrarily into the future.
 */
export function calculateVip(input, {
  now = Date.now(), targets = [40, 200, 500], windowMs = 180000,
  minSampleSize = 200, maxGapMs = 300000,
} = {}) {
  if (!Array.isArray(targets) || !targets.length || targets.some(t => !Number.isFinite(t) || t < 1)) throw new TypeError('targets must contain finite thresholds >=1');
  if (!Number.isFinite(windowMs) || windowMs <= 0 || !Number.isFinite(maxGapMs) || maxGapMs <= 0) throw new TypeError('windowMs/maxGapMs must be positive');
  if (!Number.isSafeInteger(minSampleSize) || minSampleSize < 2) throw new TypeError('minSampleSize must be an integer >=2');
  const rounds = normalizeRounds(input, {now});
  const segments = [];
  for (let i=0; i<rounds.length; i++) {
    const gap = i ? rounds[i].timestamp-rounds[i-1].timestamp : 0;
    if (!i || gap <= 0 || gap > maxGapMs) segments.push([]);
    segments.at(-1).push(rounds[i]);
  }
  const current = segments.at(-1) ?? [], latest = rounds.at(-1);
  const dataCutoff = latest?.timestamp ?? null;
  const fresh = dataCutoff !== null && now-dataCutoff <= FRESH_MS;
  const roundGaps = current.slice(1).map((row, i) => row.timestamp-current[i].timestamp);
  const avgRoundMs = mean(roundGaps), avgRoundSeconds = avgRoundMs === null ? null : avgRoundMs/1000;
  const ready = fresh && current.length >= minSampleSize && avgRoundMs > 0;
  const horizonRounds = avgRoundMs > 0 ? windowMs/avgRoundMs : null;
  const commonStatus = !latest ? 'no_data' : !fresh ? 'stale' : !ready ? 'insufficient_contiguous_history' : 'ready';
  const thresholds = [...new Set(targets)].map(threshold => {
    const count = rounds.filter(row => row.coefficient >= threshold).length;
    const historicalGaps = segments.flatMap(segment => eventGaps(segment, threshold).gaps);
    const {events, gaps} = eventGaps(current, threshold);
    const perRound = current.length ? events.length/current.length : null;
    const bounds = ready ? wilson(events.length, current.length) : null;
    const estimateStatus = commonStatus !== 'ready' ? commonStatus : !events.length ? 'no_events' : 'ready';
    const etaMedian = median(gaps);
    const candidate = events.length >= 5 && etaMedian > 0 ? events.at(-1).timestamp+etaMedian : null;
    const etaStatus = commonStatus !== 'ready' ? commonStatus : !events.length ? 'no_events'
      : events.length < 5 ? 'insufficient_events' : candidate === null ? 'insufficient_intervals'
        : candidate <= now ? 'overdue' : 'experimental_median_eta';
    return {
      threshold, count,
      frequencyPct: rounds.length ? 100*count/rounds.length : null,
      avgGapMinutes: historicalGaps.length ? mean(historicalGaps)/60000 : null,
      medianGapMinutes: historicalGaps.length ? median(historicalGaps)/60000 : null,
      estimatedNextAt: etaStatus === 'experimental_median_eta' ? candidate : null,
      probNext3MinPct: estimateStatus === 'ready' ? 100*chance(perRound, horizonRounds) : null,
      probNext3MinPctInterval95: bounds?.map(p => 100*chance(p, horizonRounds)) ?? null,
      estimateStatus, etaStatus, eventsInCurrentSegment: events.length,
      currentSegmentFrequencyPct: perRound === null ? null : perRound*100,
      etaMedianGapMinutes: etaMedian === null ? null : etaMedian/60000,
      etaBasis: 'current_segment_median_hit_gap',
    };
  });
  return {
    sampleSize: rounds.length, fresh, dataCutoff, avgRoundSeconds, windowMs,
    segmentCount: segments.length, currentSegmentSampleSize: current.length,
    estimatedRoundsInWindow: horizonRounds, estimateStatus: commonStatus,
    thresholds, reconstruction: true, originalServerModel: false,
    method: 'independent_rounds', calibrated: false,
    assumptions: [
      'Future-window probability assumes independent rounds with a constant empirical event rate.',
      'Only the latest contiguous segment estimates the current rate and pace.',
      'Wilson bounds describe sampling uncertainty under these assumptions, not forecasting accuracy.',
      'Median hit-to-hit ETA is an experimental time marker, not a demonstrated cycle.',
      'An overdue marker does not increase the chance of the next independent round.',
    ],
  };
}
