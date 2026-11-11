/** Input cleanup for the independent reconstruction; not a recovered server function. */
export function normalizeRounds(input, {now = Date.now(), limit = 10000} = {}) {
  if (!Number.isFinite(now) || now <= 0) throw new TypeError('now must be a positive timestamp');
  if (!Number.isSafeInteger(limit) || limit < 1) throw new TypeError('limit must be a positive integer');
  if (input == null) return [];
  if (typeof input === 'string' || typeof input[Symbol.iterator] !== 'function') throw new TypeError('rounds must be iterable');
  const seen = new Map(), conflicts = new Set();
  for (const row of input) {
    if (!row || row.completed === false || row.estimated === true) continue;
    const coefficient = typeof row.coefficient === 'number' || typeof row.coefficient === 'string' && row.coefficient.trim()
      ? Number(row.coefficient) : NaN;
    const timestamp = row.timestamp;
    if (!Number.isFinite(coefficient) || coefficient < 1 || !Number.isFinite(timestamp) || timestamp <= 0 || timestamp > now) continue;
    const suppliedId = row.id == null ? '' : typeof row.id === 'string' ? row.id.trim() : Number.isSafeInteger(row.id) ? String(row.id) : null;
    if (suppliedId === null) continue;
    const id = suppliedId || `round:${timestamp}:${coefficient}`;
    const previous = seen.get(id);
    if (previous && (previous.coefficient !== coefficient || previous.timestamp !== timestamp)) conflicts.add(id);
    else if (!previous) seen.set(id, {id, coefficient, timestamp});
  }
  return [...seen.values()].filter(row => !conflicts.has(row.id))
    .sort((a, b) => a.timestamp - b.timestamp || a.id.localeCompare(b.id)).slice(-limit);
}
