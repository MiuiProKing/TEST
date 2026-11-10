const __vite__mapDeps = (
  i,
  m = __vite__mapDeps,
  d = m.f ||
    (m.f = [
      "assets/vortex-scene-BPgrQS3F.js",
      "assets/index-C5ThNCN-.js",
      "assets/PremiumAccess-e9rUD6rd.js",
      "assets/circle-check-B56GEMOe.js",
      "assets/circle-x-Bj11oEwU.js",
      "assets/analysis-data-BaiXRb_2.js",
      "assets/history-DU1SVBVB.js",
    ]),
) => i.map((i) => d[i]);
import {
  c as xe,
  r as p,
  j as e,
  as as he,
  d as pe,
  P as ge,
  e as be,
  at as je,
  au as we,
  k as ve,
  l as ye,
  A as Ne,
  m as Z,
  ap as Me,
} from "./index-C5ThNCN-.js";
import { u as ke, P as Se } from "./PremiumAccess-e9rUD6rd.js";
import { C as Pe } from "./circle-check-B56GEMOe.js";
import { C as Re } from "./circle-x-Bj11oEwU.js";
import { o as ze } from "./analysis-data-BaiXRb_2.js";
import { H as Ce } from "./history-DU1SVBVB.js";
const Ae = [
    ["circle", { cx: "12", cy: "16", r: "1", key: "1au0dj" }],
    [
      "rect",
      { x: "3", y: "10", width: "18", height: "12", rx: "2", key: "6s8ecr" },
    ],
    ["path", { d: "M7 10V7a5 5 0 0 1 10 0v3", key: "1pqi11" }],
  ],
  Ie = xe("lock-keyhole", Ae);
function re(n, o, i) {
  const u = Math.min(o * 0.34, 240),
    l = Math.max(76, u * 0.56) / 38,
    c = [
      { at: 0, x: -0.37, y: 0.36, z: 300 },
      { at: 1.3, x: -0.08, y: 0.27, z: 270 },
      { at: 3.1, x: 0.22, y: 0.12, z: 270 },
      { at: 4.2, x: 0.02, y: 0.12, z: -55 },
      { at: 5.5, x: -0.25, y: -0.24, z: 280 },
      { at: 6.7, x: 0.08, y: -0.34, z: 280 },
      { at: 8.1, x: -0.65, y: -0.46, z: 280 },
      { at: 19, x: -0.65, y: 0.42, z: 300 },
      { at: 20, x: -0.37, y: 0.36, z: 300 },
    ],
    a = n % 20,
    s = Math.max(
      0,
      c.findIndex((m, w) => w < c.length - 1 && a < (c[w + 1]?.at ?? 20)),
    ),
    t = c[s] ?? c[0],
    r = c[s + 1] ?? t,
    d = c[Math.max(0, s - 1)] ?? t,
    f = c[Math.min(c.length - 1, s + 2)] ?? r,
    g = (a - t.at) / (r.at - t.at),
    b = (m) => {
      if (s === 6) return t[m] + (r[m] - t[m]) * g;
      const w = (r[m] - d[m]) * 0.35,
        h = (f[m] - t[m]) * 0.35;
      return (
        (2 * g ** 3 - 3 * g ** 2 + 1) * t[m] +
        (g ** 3 - 2 * g ** 2 + g) * w +
        (-2 * g ** 3 + 3 * g ** 2) * r[m] +
        (g ** 3 - g ** 2) * h
      );
    };
  return { x: b("x") * o, y: b("y") * i, z: b("z"), size: l };
}
function _e({ pulse: n = 0 }) {
  const o = p.useRef(null),
    i = p.useRef(null),
    u = p.useRef(n);
  return (
    (u.current = n),
    p.useEffect(() => {
      const l = o.current,
        c = i.current,
        a = l?.getContext("2d"),
        s = c?.getContext("2d");
      if (!l || !c || !a || !s) return;
      const t = getComputedStyle(l),
        r = (k) => t.getPropertyValue(`--robot-${k}`).trim(),
        d = (k, S = 1) => `rgba(${r(k)},${S})`,
        f = ["violet", "blue", "pink", "violet"].map((k) =>
          r(k).split(",").map(Number),
        ),
        g = window.matchMedia("(prefers-reduced-motion: reduce)");
      let b = 0,
        m = 0,
        w = 0,
        h = 0,
        y = 0,
        D = 0,
        V,
        q,
        $ = 0;
      const I = Math.min(2, window.devicePixelRatio || 1),
        te = () => {
          const k = l.getBoundingClientRect();
          ((b = k.width), (m = k.height));
          for (const S of [l, c]) ((S.width = b * I), (S.height = m * I));
          (a.setTransform(I, 0, 0, I, 0, 0), s.setTransform(I, 0, 0, I, 0, 0));
        };
      te();
      const se = new ResizeObserver(te);
      se.observe(l);
      const ce = Array.from({ length: 1100 }, () => ({
          theta: Math.random() * Math.PI * 2,
          phi: Math.random() * Math.PI * 2,
          speed: 0.2 + Math.random() * 0.8,
          alpha: 0.25 + Math.random() * 0.5,
        })),
        X = (k) => {
          const S = h ? Math.min((k - h) / 1e3, 0.05) : 0;
          ((h = k),
            g.matches || (y += S),
            a.clearRect(0, 0, b, m),
            s.clearRect(0, 0, b, m));
          const G = b / 2,
            H = m * 0.38,
            E = Math.min(b * 0.34, 240),
            Y = E * 0.52,
            de = 1 + u.current * 0.25;
          a.globalCompositeOperation = "lighter";
          for (const x of ce) {
            g.matches ||
              ((x.theta += S * 1.2 * x.speed * de),
              (x.phi += S * 0.24 * x.speed));
            const N = (((x.phi + y * 0.12) / (Math.PI * 2)) % 1) * f.length,
              M = Math.floor(N),
              P = N - M,
              C = f[M] ?? f[0] ?? [0, 0, 0],
              T = f[(M + 1) % f.length] ?? C,
              K = C.map((v, R) => Math.round(v + ((T[R] ?? v) - v) * P));
            ((a.strokeStyle = `rgba(${K.join(",")},${x.alpha})`),
              (a.lineWidth = 0.9),
              a.beginPath());
            for (let v = 0; v <= 5; v++) {
              const R = x.theta + v * 0.07,
                _ = (E + Y * Math.cos(R)) * Math.cos(x.phi),
                W = Y * Math.sin(R),
                F = (E + Y * Math.cos(R)) * Math.sin(x.phi),
                O = W * Math.cos(0.45) - F * Math.sin(0.45),
                A = 700 / (700 + (W * Math.sin(0.45) + F * Math.cos(0.45)));
              v
                ? a.lineTo(G + _ * A, H + O * A)
                : a.moveTo(G + _ * A, H + O * A);
            }
            a.stroke();
          }
          ((a.globalCompositeOperation = "source-over"),
            (a.strokeStyle = d("violet", 0.16)),
            a.beginPath());
          for (let x = 0; x <= 30; x++) {
            const N = (x / 30) * Math.PI * 2 + y * 0.04,
              M = G + Math.cos(N) * E * 1.5,
              P = H + Math.sin(N) * E;
            x ? a.lineTo(M, P) : a.moveTo(M, P);
          }
          a.stroke();
          const z = re(y, b, m),
            ae = re(y + 0.01, b, m),
            j = (z.size * 38) / 50,
            J = G + z.x,
            B = m / 2 - z.y,
            U = Math.atan2(-(ae.y - z.y), ae.x - z.x);
          if (V === void 0 || q === void 0) $ = U;
          else {
            const x = Math.atan2(Math.sin(U - $), Math.cos(U - $));
            (($ += x * (1 - Math.exp(-12 * S))),
              (D += Math.hypot(J - V, B - q)));
          }
          ((V = J), (q = B));
          const ie = D / (14 * z.size);
          (s.save(),
            s.translate(J, B + Math.sin(ie * Math.PI * 4) * j * 0.45),
            s.rotate($ + Math.PI / 2),
            (s.globalAlpha = z.z < 0 ? 0.45 : 1),
            (s.lineCap = "round"),
            (s.lineJoin = "round"));
          for (let x = 0; x < 8; x++) {
            const N = x < 4 ? -1 : 1,
              M = x % 4,
              P = (ie + ((M + (N > 0 ? 1 : 0)) % 2) * 0.5) % 1,
              C = P >= 0.62,
              T = C ? (P - 0.62) / 0.38 : P / 0.62,
              K = (C ? 1 - T * 2 : -1 + T * 2) * 6 * j,
              v = C ? Math.sin(T * Math.PI) : 0,
              R = N * 4.8 * j,
              _ = (M - 1.5) * 3 * j,
              W = N * (25 - v * 3) * j,
              F = (M - 1.5) * 12 * j + K,
              O = N * (14 + v * 2) * j,
              Q = _ + (M - 1.5) * 6 * j - v * 4 * j,
              A = N * (21 - v) * j,
              oe = F - 2.5 * j - v * 3 * j;
            ((s.fillStyle = d("shadow", C ? 0.15 : 0.5)),
              s.beginPath(),
              s.ellipse(W, F + v * 5 * j, 2.5 * j, 1.4 * j, 0, 0, Math.PI * 2),
              s.fill());
            const ue = () => {
              (s.beginPath(),
                s.moveTo(R, _),
                s.lineTo(O, Q),
                s.lineTo(A, oe),
                s.lineTo(W, F),
                s.stroke());
            };
            ((s.strokeStyle = d("highlight")), (s.lineWidth = 1), ue());
            for (const [me, fe] of [
              [R, _],
              [O, Q],
              [A, oe],
            ])
              ((s.strokeStyle = d("highlight")),
                s.beginPath(),
                s.arc(me, fe, 0.5 * j, 0, Math.PI * 2),
                s.stroke());
          }
          ((s.strokeStyle = d("highlight", 0.9)), (s.lineWidth = 0.8));
          for (const [x, N, M] of [
            [6, 5, 7],
            [-4, 3, 3],
          ])
            (s.beginPath(),
              s.ellipse(0, x * j, N * j, M * j, 0, 0, Math.PI * 2),
              s.stroke());
          (s.restore(), g.matches || (w = requestAnimationFrame(X)));
        },
        ne = () => {
          (cancelAnimationFrame(w), (h = 0), (w = requestAnimationFrame(X)));
        };
      return (
        g.addEventListener("change", ne),
        (w = requestAnimationFrame(X)),
        () => {
          (cancelAnimationFrame(w),
            se.disconnect(),
            g.removeEventListener("change", ne));
        }
      );
    }, []),
    e.jsxs(e.Fragment, {
      children: [
        e.jsx("canvas", {
          ref: o,
          className: "absolute inset-0 w-full h-full pointer-events-none",
          "aria-hidden": "true",
        }),
        e.jsx("canvas", {
          ref: i,
          className: "absolute inset-0 z-30 w-full h-full pointer-events-none",
          "aria-hidden": "true",
        }),
      ],
    })
  );
}
function Fe({ pulse: n = 0 }) {
  const o = p.useRef(null),
    i = p.useRef(n),
    [u, l] = p.useState(!1);
  return (
    (i.current = n),
    p.useEffect(() => {
      const c = o.current;
      if (!c) return;
      let a = !1,
        s;
      return (
        he(
          async () => {
            const { mountVortex: t } =
              await import("./vortex-scene-BPgrQS3F.js");
            return { mountVortex: t };
          },
          __vite__mapDeps([0, 1, 2, 3, 4, 5, 6]),
        )
          .then(({ mountVortex: t }) => {
            a || (s = t(c, () => i.current));
          })
          .catch(() => {
            a || l(!0);
          }),
        () => {
          ((a = !0), s?.());
        }
      );
    }, []),
    u
      ? e.jsx(_e, { pulse: n })
      : e.jsx("canvas", {
          ref: o,
          className: "absolute inset-0 z-30 w-full h-full pointer-events-none",
          "aria-hidden": "true",
        })
  );
}
const $e = pe({ method: "GET" })
  .middleware([ge])
  .handler(
    be("29562702b4fe653955ae9aa27f6e70343c1cbcbe33b76ba3f05a73550d2b849c"),
  );
function Ee({ results: n }) {
  return e.jsx("div", {
    role: "status",
    "aria-live": "polite",
    "aria-atomic": "true",
    className:
      "pointer-events-none flex w-full max-w-md flex-col items-center gap-3 px-4 text-center",
    children: n.map((o) => {
      const i = o.status === "validated",
        u = i ? Pe : Re;
      return e.jsxs(
        "div",
        {
          className: "w-full bg-background/85 px-4 py-3 backdrop-blur-sm",
          children: [
            e.jsxs("p", {
              className: `flex items-center justify-center gap-2 text-sm font-bold ${i ? "text-neon-green" : "text-destructive"}`,
              children: [
                e.jsx(u, { className: "h-5 w-5 shrink-0" }),
                " ",
                o.target,
                "x — ",
                i ? "VALIDÉ" : "ÉCHEC",
              ],
            }),
            e.jsxs("p", {
              className: "mt-1 font-mono text-lg font-bold text-foreground",
              children: [
                i ? "Coefficient sorti" : "Meilleur coefficient",
                " : ",
                o.coefficient.toFixed(2),
                "x",
              ],
            }),
          ],
        },
        `${o.target}:${o.at}`,
      );
    }),
  });
}
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
function Ge(n, o) {
  const i = p.useRef(le()),
    u = p.useRef(30),
    [l, c] = p.useState(le),
    [a, s] = p.useState(0);
  return (
    p.useEffect(() => {
      s(Date.now());
      const t = setInterval(() => s(Date.now()), 1e3);
      return () => clearInterval(t);
    }, []),
    p.useEffect(() => {
      const t = Date.now(),
        r =
          !!n?.fresh &&
          n.sampleSize >= 200 &&
          n.dataCutoff !== null &&
          t - n.dataCutoff <= L &&
          !!n.avgRoundSeconds;
      (n?.avgRoundSeconds && (u.current = n.avgRoundSeconds),
        (i.current = De(i.current, o, t, r, u.current, n?.thresholds ?? [])),
        c(i.current));
    }, [n, o, a]),
    {
      results: l.messages.map((t) => t.result),
      windows: l.windows,
      lockedWindows: l.lockedWindows,
    }
  );
}
function ee(n) {
  return new Date(n).toLocaleTimeString("fr-FR", {
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  });
}
function Le({ r: n, isNew: o }) {
  const i = n.coefficient >= 10;
  return e.jsxs(Z.div, {
    initial: o ? { scale: 0.6, opacity: 0, y: -12 } : !1,
    animate: { scale: 1, opacity: 1, y: 0 },
    transition: { type: "spring", stiffness: 320, damping: 22 },
    className: `flex flex-col items-center rounded-xl border px-3 py-1.5 min-w-[64px] backdrop-blur-sm ${i ? "border-fuchsia-400/60 bg-fuchsia-400/10 shadow-[0_0_18px_rgba(217,70,239,0.35)]" : "border-purple-400/30 bg-purple-400/[0.07]"}`,
    children: [
      e.jsxs("span", {
        className: `font-mono font-black text-sm ${i ? "text-fuchsia-300" : "text-purple-200"}`,
        children: [n.coefficient.toFixed(2), "x"],
      }),
      e.jsx("span", {
        className: "text-[9px] font-mono text-white/40",
        children: ee(n.timestamp),
      }),
    ],
  });
}
function Ve({ game: n, onStats: o, windows: i, lockedWindows: u }) {
  const [l, c] = p.useState(null),
    [a, s] = p.useState(() => Date.now());
  return (
    p.useEffect(() => {
      let t = !1;
      const r = async () => {
        try {
          const f = await $e({ data: { game: n } });
          t || (c(f), o(f));
        } catch {
          t || (c(null), o(null));
        }
      };
      r();
      const d = setInterval(r, 3e4);
      return () => {
        ((t = !0), clearInterval(d));
      };
    }, [n, o]),
    p.useEffect(() => {
      const t = setInterval(() => s(Date.now()), 1e3);
      return () => clearInterval(t);
    }, []),
    !l || l.sampleSize < 200
      ? e.jsx("p", {
          className: "text-center text-[11px] text-white/40 px-4",
          children:
            "Analyse des tendances en cours… (échantillon insuffisant pour le moment)",
        })
      : e.jsx("div", {
          className: "mx-auto w-full max-w-2xl px-4",
          children: e.jsxs("div", {
            className:
              "rounded-2xl border border-purple-400/20 bg-purple-950/20 backdrop-blur-sm p-3 sm:p-4",
            children: [
              e.jsxs("p", {
                className:
                  "text-[10px] font-black uppercase tracking-[0.15em] text-purple-200/60 mb-2.5",
                children: [
                  "Grosses cotes · ",
                  l.sampleSize.toLocaleString("fr-FR"),
                  " tours analysés",
                ],
              }),
              e.jsx("div", {
                className: "grid grid-cols-3 gap-2",
                children: l.thresholds.map((t) => {
                  const r =
                      l.fresh &&
                      l.dataCutoff !== null &&
                      a - l.dataCutoff <= 18e4,
                    d = u.find((y) => y.target === t.threshold),
                    f = !d && r && (t.probNext3MinPct ?? 0) >= 50,
                    b =
                      (i.find((y) => y.target === t.threshold) ?? d)?.start ??
                      t.estimatedNextAt,
                    m = !d && r && b !== null ? b - a : null,
                    w = m !== null ? Math.max(0, Math.round(m / 1e3)) : null,
                    h =
                      w !== null
                        ? `${String(Math.floor(w / 3600)).padStart(2, "0")}:${String(Math.floor((w % 3600) / 60)).padStart(2, "0")}:${String(w % 60).padStart(2, "0")}`
                        : null;
                  return e.jsxs(
                    "div",
                    {
                      className: `rounded-xl border px-2.5 py-2 text-center ${f ? "border-fuchsia-400/60 bg-fuchsia-400/10 shadow-[0_0_16px_rgba(217,70,239,0.25)]" : "border-white/[0.08] bg-black/30"}`,
                      children: [
                        e.jsxs("p", {
                          className: `font-mono font-black text-base ${f ? "text-fuchsia-300" : "text-white/85"}`,
                          children: [t.threshold, "x+"],
                        }),
                        d &&
                          e.jsxs("p", {
                            className:
                              "mt-1 flex items-center justify-center gap-1 text-[10px] text-muted-foreground",
                            children: [
                              e.jsx(Ie, { className: "size-3" }),
                              " Verrouillé",
                            ],
                          }),
                        t.count === 0
                          ? e.jsx("p", {
                              className: "text-[9px] text-white/40 mt-1",
                              children: "Jamais vu sur l'échantillon",
                            })
                          : e.jsxs(e.Fragment, {
                              children: [
                                r &&
                                  b !== null &&
                                  e.jsx("p", {
                                    className: `text-[10px] font-mono font-bold mt-1 ${f ? "text-fuchsia-300 animate-pulse" : "text-purple-200"}`,
                                    children: `Repère médian ${ee(b)}`,
                                  }),
                                h !== null &&
                                  !f &&
                                  e.jsxs("p", {
                                    className:
                                      "text-[9px] font-mono text-white/50 mt-0.5",
                                    children: ["dans ", h],
                                  }),
                              ],
                            }),
                        e.jsxs("p", {
                          className: "text-[8px] text-white/35 mt-1",
                          children: [
                            r &&
                              t.probNext3MinPct !== null &&
                              `Modèle : ${t.probNext3MinPct.toFixed(0)}% en 3 min · `,
                            t.frequencyPct.toFixed(2),
                            "% des tours",
                            t.avgGapMinutes !== null &&
                              ` · 1×/${t.avgGapMinutes} min`,
                          ],
                        }),
                        !r &&
                          e.jsx("p", {
                            className: "text-[10px] text-muted-foreground mt-1",
                            children:
                              "Collecte ancienne — estimation suspendue",
                          }),
                      ],
                    },
                    t.threshold,
                  );
                }),
              }),
            ],
          }),
        })
  );
}
function qe({ label: n, game: o, rounds: i, status: u, newestId: l }) {
  const [c, a] = p.useState(!1),
    [s, t] = p.useState(0),
    [r, d] = p.useState(null),
    { results: f, windows: g, lockedWindows: b } = Ge(r, i);
  p.useEffect(() => {
    if (!l) return;
    t(1);
    const h = setTimeout(() => t(0), 2500);
    return () => clearTimeout(h);
  }, [l]);
  const m = i.slice(0, 5),
    w =
      u === "live"
        ? "Analyse en cours — détermination de la fenêtre"
        : u === "connecting"
          ? "Connexion au flux en direct…"
          : "Flux interrompu — nouvelle tentative…";
  return e.jsxs("div", {
    className:
      "relative min-h-screen text-white flex flex-col overflow-hidden bg-[#0a0618]",
    children: [
      e.jsxs("div", {
        className: "pointer-events-none absolute inset-0",
        "aria-hidden": "true",
        children: [
          e.jsx("div", {
            className:
              "absolute -top-32 left-1/2 -translate-x-1/2 h-96 w-[42rem] rounded-full bg-purple-600/20 blur-3xl",
          }),
          e.jsx("div", {
            className:
              "absolute bottom-0 -left-24 h-72 w-72 rounded-full bg-fuchsia-600/10 blur-3xl",
          }),
          e.jsx("div", {
            className:
              "absolute bottom-10 -right-24 h-72 w-72 rounded-full bg-blue-600/10 blur-3xl",
          }),
        ],
      }),
      e.jsx("div", {
        className: "pointer-events-none absolute inset-0 contents",
        children: e.jsx(Fe, { pulse: s }),
      }),
      e.jsxs("header", {
        className:
          "relative flex items-center justify-between px-4 sm:px-6 pt-5",
        children: [
          e.jsxs("div", {
            children: [
              e.jsxs("h1", {
                className:
                  "font-display italic font-black text-lg sm:text-2xl tracking-tight",
                children: [
                  "GOD",
                  " ",
                  e.jsx("span", {
                    className:
                      "bg-gradient-to-r from-purple-400 to-fuchsia-500 bg-clip-text text-transparent",
                    children: "PREDITOR",
                  }),
                ],
              }),
              e.jsxs("p", {
                className:
                  "text-[11px] sm:text-xs font-mono tracking-[0.25em] text-purple-200/50",
                children: ["· ", n],
              }),
            ],
          }),
          e.jsxs("div", {
            className: "flex items-center gap-2",
            children: [
              e.jsxs(ve, {
                to: "/jeux",
                className:
                  "inline-flex items-center gap-1.5 rounded-full border border-white/15 bg-white/[0.04] px-3 py-1.5 text-xs text-white/70 hover:bg-white/10 transition-colors",
                children: [e.jsx(ye, { className: "w-3.5 h-3.5" }), " Jeux"],
              }),
              e.jsxs("button", {
                type: "button",
                onClick: () => a(!0),
                className:
                  "inline-flex items-center gap-1.5 rounded-full border border-white/15 bg-white/[0.04] px-3 py-1.5 text-xs text-white/70 hover:bg-white/10 transition-colors",
                children: [
                  e.jsx(Ce, { className: "w-3.5 h-3.5" }),
                  " Historique",
                ],
              }),
            ],
          }),
        ],
      }),
      e.jsx("div", {
        className:
          "relative flex justify-center gap-2 sm:gap-3 px-4 mt-5 flex-wrap",
        children:
          m.length === 0
            ? Array.from({ length: 5 }).map((h, y) =>
                e.jsxs(
                  "div",
                  {
                    className:
                      "rounded-xl border border-white/10 bg-white/[0.03] px-3 py-1.5 min-w-[64px] animate-pulse",
                    children: [
                      e.jsx("div", {
                        className: "h-4 w-10 bg-white/10 rounded mx-auto",
                      }),
                      e.jsx("div", {
                        className: "h-2 w-12 bg-white/5 rounded mx-auto mt-1",
                      }),
                    ],
                  },
                  y,
                ),
              )
            : m.map((h) => e.jsx(Le, { r: h, isNew: h.id === l }, h.id)),
      }),
      e.jsx("div", {
        className:
          "relative z-[35] flex flex-1 min-h-[300px] sm:min-h-[380px] items-center justify-center",
        children: e.jsx(Ee, { results: f }),
      }),
      e.jsx("div", {
        className: "relative",
        children: e.jsx(Ve, {
          game: o,
          onStats: d,
          windows: g,
          lockedWindows: b,
        }),
      }),
      e.jsxs("div", {
        className: "relative flex items-center justify-center gap-2 pb-8 pt-2",
        children: [
          e.jsxs("span", {
            className: "relative flex h-2 w-2",
            children: [
              e.jsx("span", {
                className:
                  "animate-ping absolute inline-flex h-full w-full rounded-full bg-purple-400 opacity-75",
              }),
              e.jsx("span", {
                className:
                  "relative inline-flex rounded-full h-2 w-2 bg-purple-400",
              }),
            ],
          }),
          e.jsx("span", { className: "text-xs text-white/60", children: w }),
        ],
      }),
      e.jsx(Ne, {
        children:
          c &&
          e.jsxs(e.Fragment, {
            children: [
              e.jsx(Z.div, {
                initial: { opacity: 0 },
                animate: { opacity: 1 },
                exit: { opacity: 0 },
                className: "fixed inset-0 bg-black/60 z-40",
                onClick: () => a(!1),
              }),
              e.jsxs(Z.aside, {
                initial: { x: "100%" },
                animate: { x: 0 },
                exit: { x: "100%" },
                transition: { type: "spring", stiffness: 300, damping: 30 },
                className:
                  "fixed right-0 top-0 bottom-0 w-full max-w-sm bg-zinc-950 border-l border-white/10 z-50 flex flex-col",
                children: [
                  e.jsxs("div", {
                    className:
                      "flex items-center justify-between px-4 py-3 border-b border-white/10",
                    children: [
                      e.jsx("h2", {
                        className: "font-display font-bold text-sm",
                        children: "Historique des tours",
                      }),
                      e.jsx("button", {
                        type: "button",
                        onClick: () => a(!1),
                        className:
                          "p-1.5 rounded-full hover:bg-white/10 transition-colors",
                        "aria-label": "Fermer",
                        children: e.jsx(Me, { className: "w-4 h-4" }),
                      }),
                    ],
                  }),
                  e.jsxs("div", {
                    className: "flex-1 overflow-y-auto p-3 space-y-1.5",
                    children: [
                      i.length === 0 &&
                        e.jsx("p", {
                          className: "text-xs text-white/40 text-center py-8",
                          children: "Aucun tour chargé pour le moment.",
                        }),
                      i.map((h) => {
                        const y = h.coefficient >= 10,
                          D = h.coefficient >= 2 && !y;
                        return e.jsxs(
                          "div",
                          {
                            className:
                              "flex items-center justify-between rounded-lg border border-white/[0.06] bg-white/[0.03] px-3 py-2",
                            children: [
                              e.jsxs("span", {
                                className: `font-mono font-bold text-sm ${y ? "text-amber-300" : D ? "text-fuchsia-300" : "text-sky-300"}`,
                                children: [h.coefficient.toFixed(2), "x"],
                              }),
                              e.jsx("span", {
                                className:
                                  "text-[10px] font-mono text-white/40",
                                children: ee(h.timestamp),
                              }),
                            ],
                          },
                          h.id,
                        );
                      }),
                    ],
                  }),
                ],
              }),
            ],
          }),
      }),
    ],
  });
}
function Xe() {
  const { game: n } = je.useParams(),
    o = we[n],
    i = ke();
  return o
    ? i !== "ok"
      ? e.jsx(Se, { loading: i === "loading" })
      : e.jsx(He, { label: o.label, game: n, useRounds: o.useRounds }, n)
    : null;
}
function He({ label: n, game: o, useRounds: i }) {
  const { rounds: u, status: l, newestId: c } = i();
  return e.jsx(qe, { label: n, game: o, rounds: u, status: l, newestId: c });
}
const Ze = Object.freeze(
  Object.defineProperty(
    { __proto__: null, component: Xe },
    Symbol.toStringTag,
    { value: "Module" },
  ),
);
export { Ze as p, re as s };
