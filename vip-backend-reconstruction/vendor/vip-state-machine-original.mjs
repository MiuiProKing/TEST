// Exact public normalization and signal state machine. ze aliases the original normalizer.
function m(s, i = 300, e = 1 / 0) {
  const n = new Set();
  return [...s]
    .sort((t, a) => a.timestamp - t.timestamp)
    .filter((t) =>
      !Number.isFinite(t.coefficient) ||
      t.coefficient < 1 ||
      !Number.isFinite(t.timestamp) ||
      t.timestamp <= 0 ||
      t.timestamp > e ||
      (t.id && n.has(t.id))
        ? !1
        : (t.id && n.add(t.id), !0),
    )
    .slice(0, i);
}
function f(s, i = Date.now()) {
  const e = s[0]?.timestamp;
  return e !== void 0 && e <= i + 3e4 && i - e <= 18e4;
}
const ze = m;
function Te(n, o, i, u) {
  const l = i + u,
    a = n
      .filter(
        (s) =>
          Number.isFinite(s.coefficient) &&
          s.coefficient >= 1 &&
          Number.isFinite(s.timestamp) &&
          s.timestamp >= i &&
          s.timestamp <= l,
      )
      .reduce((s, t) => (!s || t.coefficient > s.coefficient ? t : s), null);
  return {
    reached: !!a && a.coefficient >= o,
    best: a?.coefficient ?? null,
    bestAt: a?.timestamp ?? null,
  };
}
const L = 18e4;
function We(n, o, i, u) {
  const l = ze(o, o.length, i).reverse(),
    c = Te(l, n.target, n.start, n.end - n.start);
  if (c.reached && c.best !== null && c.bestAt !== null)
    return {
      target: n.target,
      status: "validated",
      coefficient: c.best,
      at: c.bestAt,
    };
  if (i <= n.end || c.best === null) return null;
  const a = l.filter((d) => d.timestamp <= n.start).at(-1),
    s = l.find((d) => d.timestamp >= n.end);
  if (!a || !s) return null;
  const t = l.filter(
      (d) => d.timestamp >= a.timestamp && d.timestamp <= s.timestamp,
    ),
    r = Math.min(18e4, Math.max(6e4, u * 3e3));
  return !Number.isFinite(r) ||
    t.some(
      (d, f) => f > 0 && d.timestamp - (t[f - 1]?.timestamp ?? d.timestamp) > r,
    )
    ? null
    : { target: n.target, status: "failed", coefficient: c.best, at: n.end };
}
const Oe = 4e4;
function le() {
  return {
    windows: [],
    lockedWindows: [],
    lastStarts: {},
    pending: [],
    rounds: [],
    messages: [],
  };
}
function De(n, o, i, u, l, c) {
  const a = {
    ...n,
    windows: n.windows.filter((t) => i < t.end),
    lockedWindows: [...n.lockedWindows, ...n.windows.filter((t) => i >= t.end)],
    lastStarts: { ...n.lastStarts },
    pending: [...n.pending],
    messages: n.messages.filter((t) => i < t.expiresAt),
  };
  u &&
    [40, 200, 500].every((t) => a.lockedWindows.some((r) => r.target === t)) &&
    (a.lockedWindows = []);
  const s = new Map();
  for (const t of [...n.rounds, ...o])
    t.timestamp >= i - L * 3 &&
      t.timestamp <= i &&
      s.set(t.id ?? `${t.timestamp}:${t.coefficient}`, t);
  if (((a.rounds = [...s.values()]), u))
    for (const t of c) {
      const r = t.estimatedNextAt;
      if (
        r === null ||
        !Number.isFinite(r) ||
        r < i ||
        r <= (a.lastStarts[t.threshold] ?? 0) ||
        a.windows.some((f) => f.target === t.threshold) ||
        a.lockedWindows.some((f) => f.target === t.threshold)
      )
        continue;
      const d = { target: t.threshold, start: r, end: r + L };
      (a.windows.push(d), a.pending.push(d), (a.lastStarts[t.threshold] = r));
    }
  return (
    (a.pending = a.pending.filter((t) => {
      const r = We(t, a.rounds, i, l);
      return (
        r && a.messages.push({ result: r, expiresAt: i + Oe }),
        !r && i <= t.end + L
      );
    })),
    a
  );
}
export {
  Te as bestInWindow,
  We as resolveWindow,
  De as advanceState,
  le as initialState,
};
