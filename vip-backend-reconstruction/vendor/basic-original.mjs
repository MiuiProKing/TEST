// Exact public BASIC forecast, distinct from the VIP server model.
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
const Z = m,
  Fe = f;
const l = 6e4,
  Te = 6e4,
  $ = (t) => (t.length ? t.reduce((s, e) => s + e, 0) / t.length : 0),
  E = (t) => {
    if (!t.length) return 0;
    const s = [...t].sort((o, a) => o - a),
      e = Math.floor(s.length / 2);
    return s.length % 2 ? s[e] : (s[e - 1] + s[e]) / 2;
  },
  te = (t) => {
    if (t.length < 2) return 0;
    const s = $(t);
    return Math.sqrt($(t.map((e) => (e - s) ** 2)));
  },
  X = (t, s) => {
    if (!t.length) return 0;
    let e = t[t.length - 1];
    for (let o = t.length - 2; o >= 0; o--) e = s * t[o] + (1 - s) * e;
    return e;
  },
  O = (t) => {
    if (!t.length) return 0;
    const s = t.map((e) => Math.log(Math.max(e, 1.001)));
    return Math.exp($(s));
  },
  ne = (t) => {
    let s = -1 / 0;
    for (const e of t) e > s && (s = e);
    return s === -1 / 0 ? 0 : s;
  },
  se = (t) => {
    if (t.length < 2) return 0;
    const s = E(t);
    return E(t.map((e) => Math.abs(e - s)));
  },
  d = (t, s, e) => Math.max(s, Math.min(e, t));
function Y(t, s) {
  const e = new Map();
  for (const a of t) {
    const i = s(a),
      f = e.get(i) ?? { coefs: [], g: 0, mg: 0 };
    (f.coefs.push(a.coefficient),
      a.coefficient >= 10 && f.g++,
      a.coefficient >= 100 && f.mg++,
      e.set(i, f));
  }
  const o = new Map();
  for (const [a, i] of e)
    o.set(a, {
      count: i.coefs.length,
      goldenCount: i.g,
      megaCount: i.mg,
      avg: O(i.coefs),
      max: ne(i.coefs),
    });
  return o;
}
function ae(t, s) {
  const e = t
    .filter((a) => a.coefficient >= s)
    .sort((a, i) => a.timestamp - i.timestamp);
  if (e.length < 2)
    return {
      avgGap: 0,
      medGap: 0,
      stdGap: 0,
      madGap: 0,
      last: e[0]?.timestamp ?? null,
      count: e.length,
    };
  const o = [];
  for (let a = 1; a < e.length; a++)
    o.push(e[a].timestamp - e[a - 1].timestamp);
  return {
    avgGap: $(o),
    medGap: E(o),
    stdGap: te(o),
    madGap: se(o),
    last: e[e.length - 1].timestamp,
    count: e.length,
  };
}
function De(t, s) {
  const e = [...t].sort((x, u) => x.timestamp - u.timestamp),
    o = [],
    a = ae(e, 100);
  if (a.count >= 5 && a.last && a.medGap > 0) {
    const x = a.last + a.medGap,
      u = x - s,
      h = d(a.madGap * 1.4826 || a.medGap * 0.35, 2 * l, 12 * l),
      p = s - a.last;
    if (
      a.madGap > 0 &&
      a.madGap < a.medGap * 0.5 &&
      (Math.abs(u) <= h * 0.7 || p >= a.medGap * 0.9)
    ) {
      const y = d(1 - Math.abs(u) / Math.max(h, 1), 0, 1),
        U = Math.min(10, a.count),
        q = d(55 + U + y * 12, 55, 82);
      o.push({
        expectedAt: u > 0 ? x : s + Math.max(2 * l, h * 0.4),
        windowMs: d(h, 3 * l, 10 * l),
        estimatedCoef: 100,
        confidence: Math.round(q),
        reason: `Cycle 100x≈${(a.medGap / l).toFixed(1)}min — dernier il y a ${(p / l).toFixed(1)}min (${a.count} évts)`,
      });
    }
  }
  const i = e.slice(-80);
  let f = 0,
    m = 0;
  for (const x of i) (x.coefficient >= 20 && f++, x.coefficient >= 50 && m++);
  if (m >= 3 && f >= 6) {
    const x = d(55 + m * 5 + f, 55, 82);
    o.push({
      expectedAt: s + 3 * l,
      windowMs: 6 * l,
      estimatedCoef: 120,
      confidence: Math.round(x),
      reason: `Cluster chaud : ${f}×≥20x + ${m}×≥50x sur 80 tours`,
    });
  }
  const g = e.filter((x) => x.coefficient >= 100);
  if (g.length >= 4 && a.last && e.length >= 80) {
    const x = s - a.last,
      u = e[e.length - 1].timestamp - e[0].timestamp,
      h = u > 0 ? g.length / u : 0;
    if (h > 0) {
      const p = 1 - Math.exp(-h * x);
      if (p >= 0.75) {
        const r = d(1 / h, 9e4, 8 * l),
          y = d(50 + p * 30, 50, 80);
        o.push({
          expectedAt: s + r,
          windowMs: d(r * 0.8, 3 * l, 7 * l),
          estimatedCoef: 100,
          confidence: Math.round(y),
          reason: `Hazard Poisson : P(retard)=${(p * 100).toFixed(0)}% (λ⁻¹≈${(1 / h / l).toFixed(1)}min)`,
        });
      }
    }
  }
  if (!o.length) return null;
  o.sort((x, u) => u.confidence - x.confidence);
  const v = o[0];
  return o.length < 2 && v.confidence < 75
    ? null
    : (o.length >= 2 && (v.confidence = Math.min(92, v.confidence + 5)), v);
}
function Pe(t, s, e = Date.now()) {
  if (((t = Z(t, t.length, e)), !Fe(t, e) || t.length < 20)) return null;
  if (s) {
    const c = Math.max(s.estimatedAt + s.windowMs, s.generatedAt + Te);
    if (e < c) return s;
  }
  const o = [...t].sort((c, b) => b.timestamp - c.timestamp),
    a = o.map((c) => c.coefficient);
  $(a);
  const i = E(a),
    f = O(a),
    m = a.slice(0, 20),
    g = a.slice(0, 50);
  $(m);
  const v = $(g),
    x = X(m, 0.25),
    u = X(g, 0.12),
    h = te(g),
    p = se(g),
    r = ae(o, 10),
    y = r.last ? e - r.last : 1 / 0,
    U = Y(o, (c) => new Date(c.timestamp).getUTCHours()),
    q = Y(o, (c) => new Date(c.timestamp).getUTCMinutes()),
    k = new Date(e),
    w = U.get(k.getUTCHours()),
    oe = (k.getUTCMinutes() + 2) % 60,
    T = q.get(oe),
    J = a.slice(0, 15),
    ie = J.length === 15 && J.every((c) => c < 2),
    N = o.slice(0, 30).filter((c) => c.coefficient >= 20),
    A = De(t, e);
  if (r.medGap > 0 && r.last) {
    const b = r.last + r.medGap - e,
      F = d(r.madGap * 1.4826 || r.medGap * 0.55, 6e4, 4 * l),
      M = r.count >= 8 && r.madGap > 0 && r.madGap < r.medGap * 0.6,
      C = Math.abs(b) <= F * 0.6;
    if (M && C) {
      const Q = N.length,
        pe = Q >= 3 ? 2 : Q >= 1 ? 3 : 4,
        ue = ne(o.slice(0, 80).map((Me) => Me.coefficient)),
        he = d(ue / pe, 2, 20),
        be = d(60 - (Math.abs(b) / F) * 15, 40, 62),
        ve = w && w.avg > f ? 3 : 0,
        ye = d(r.count / 20, 0, 4),
        V = Math.round(d(be + ve + ye, 40, 68));
      return {
        estimatedCoef: +he.toFixed(2),
        confidence: V >= 66 ? "Moyen" : "Faible",
        reliability: V,
        estimatedAt: b > 0 ? e + Math.max(b, 9e4) : e + 2 * l,
        windowMs: d(r.medGap * 0.25, 9e4, 3 * l),
        pattern: "Cycle des cotes d'or détecté",
        basis: `Cycle médian ${(r.medGap / l).toFixed(1)} min — dernier ${(y / l).toFixed(1)} min — MAD ${(r.madGap / l).toFixed(2)}min`,
        generatedAt: e,
        bigOpportunity: A,
      };
    }
  }
  if (ie) {
    const c = d(f * 2.5 + i, 2.5, 15),
      b = Math.round(d(70 + Math.min(15, (e - o[14].timestamp) / 6e4), 65, 92));
    return {
      estimatedCoef: +c.toFixed(2),
      confidence: b >= 82 ? "Élevé" : "Moyen",
      reliability: b,
      estimatedAt: e + 9e4,
      windowMs: 2 * l,
      pattern: "Série basse — rebond statistique",
      basis: `15 tours <2x — moy géo ${f.toFixed(2)}x, médiane ${i.toFixed(2)}x`,
      generatedAt: e,
      bigOpportunity: A,
    };
  }
  if (N.length >= 3) {
    const c = O(N.map((C) => C.coefficient)),
      b = N.length >= 5 ? 3 : N.length >= 4 ? 4 : 5,
      F = d(c / b, 2, 12),
      M = Math.min(78, 60 + N.length * 3);
    return {
      estimatedCoef: +F.toFixed(2),
      confidence: M >= 72 ? "Élevé" : "Moyen",
      reliability: M,
      estimatedAt: e + 2 * l,
      windowMs: 2.5 * l,
      pattern: `${N.length} cotes ≥20x récentes`,
      basis: `Moy. géo grosses cotes ${c.toFixed(2)}x ÷ ${b}`,
      generatedAt: e,
      bigOpportunity: A,
    };
  }
  const D = o.slice(0, 60),
    G = D.filter((c) => c.coefficient >= 5 && c.coefficient < 10),
    P = D.length ? D.filter((c) => c.coefficient < 2).length / D.length : 0;
  if (G.length >= 3) {
    const c = O(G.map((C) => C.coefficient)),
      b = P > 0.55 || h > v * 1.4,
      F = b ? d(c * 0.45, 2, 4.5) : d(c * 0.7, 3, 7),
      M = Math.round(d(64 + G.length * 4 + (b ? -6 : 6), 58, 90));
    return {
      estimatedCoef: +F.toFixed(2),
      confidence: M >= 82 ? "Élevé" : M >= 68 ? "Moyen" : "Faible",
      reliability: M,
      estimatedAt: e + 2 * l,
      windowMs: 2.5 * l,
      pattern: b
        ? `Phase mixte — ${G.length} cotes 5x-9x sur base fragile`
        : `Phase favorable — ${G.length} cotes 5x-9x récentes`,
      basis: `Zone 5x-9x géo ${c.toFixed(2)}x — <2x: ${(P * 100).toFixed(0)}% — σ50 ${h.toFixed(2)}`,
      generatedAt: e,
      bigOpportunity: A,
    };
  }
  const B = w && w.count >= 5 ? w.avg / Math.max(f, 0.1) : 1,
    re = T && T.count >= 5 ? T.avg / Math.max(f, 0.1) : 1,
    ce = x * 0.5 + u * 0.3 + v * 0.2;
  let S = d(ce * B * 0.6 + (T?.max ?? 0) * 0.1 + 1.6, 1.8, 12);
  const K = P > 0.6 || h > v * 1.6;
  K ? (S = Math.min(S, 3.2)) : P > 0.45 && (S = Math.min(S, 5));
  const le = d(t.length / 25, 0, 28),
    de = d(Math.abs(B - 1) * 42, 0, 22),
    me = d(Math.abs(re - 1) * 32, 0, 16),
    fe = p > 0 && p < v * 0.6 ? 5 : 0,
    xe = K ? -8 : 0,
    R = Math.round(d(52 + le + de + me + fe + xe, 50, 92)),
    ge = 2 * l + (((60 - k.getUTCSeconds()) * 1e3) % 45e3);
  return {
    estimatedCoef: +S.toFixed(2),
    confidence: R >= 82 ? "Élevé" : R >= 66 ? "Moyen" : "Faible",
    reliability: R,
    estimatedAt: e + ge,
    windowMs: 2.5 * l,
    pattern:
      B > 1.1
        ? "Plage horaire favorable"
        : B < 0.9
          ? "Plage horaire faible"
          : "Analyse multi-signaux",
    basis: `EMA20 ${x.toFixed(2)}x — H${k.getUTCHours()}h UTC: géo ${w?.avg.toFixed(2) ?? "—"}x (${w?.count ?? 0}) — MAD ${p.toFixed(2)} — σ ${h.toFixed(2)} — ${t.length} tours`,
    generatedAt: e,
    bigOpportunity: A,
  };
}
export { Pe as forecastBasic };
