import {
  d as y,
  P as w,
  e as S,
  f as R,
  r,
  j as e,
  S as A,
} from "./index-C5ThNCN-.js";
import { o as E, a as b } from "./analysis-data-BaiXRb_2.js";
import { B as F, R as I } from "./button-4JeZmZFi.js";
import { B as C } from "./triangle-alert-CzDFXfJ_.js";
import { T as P, a as T } from "./trending-up-B5K2KKMW.js";
const B = y({ method: "POST" })
    .middleware([w])
    .handler(
      S("ddbd425daedaba6871a9a8a60c6c943415250e22750ffa1255ea8a5406ee7d49"),
    ),
  k = 45e3,
  M = (t) =>
    t === "low"
      ? "Faible (<2x)"
      : t === "mid"
        ? "Moyen (2-10x)"
        : t === "high"
          ? "Élevé (10-100x)"
          : "Mega (≥100x)",
  L = (t) =>
    t === "low"
      ? "from-slate-500/20 to-slate-700/20 border-slate-500/30"
      : t === "mid"
        ? "from-blue-500/20 to-cyan-500/20 border-blue-500/30"
        : t === "high"
          ? "from-orange-500/20 to-red-500/20 border-orange-500/30"
          : "from-fuchsia-500/30 to-purple-600/30 border-fuchsia-500/40";
function H({ rounds: t, game: i }) {
  const j = R(B),
    [a, m] = r.useState(null),
    [u, h] = r.useState(!1),
    [x, c] = r.useState(null),
    f = r.useRef(!1),
    n = r.useMemo(
      () =>
        E(t, 200).map((s) => ({
          coefficient: s.coefficient,
          timestamp: s.timestamp,
        })),
      [t],
    ),
    l = r.useRef({ game: i, payload: n }),
    o = r.useRef(!1);
  r.useEffect(() => {
    l.current = { game: i, payload: n };
  }, [i, n]);
  const [N, v] = r.useState(!1),
    p = async () => {
      const s = l.current,
        g = b(s.payload);
      if ((v(g), !g)) {
        (m(null), c("Tours trop anciens — analyse suspendue."));
        return;
      }
      if (!(f.current || s.payload.length < 20)) {
        ((f.current = !0), h(!0), c(null));
        try {
          const d = await j({ data: { game: s.game, rounds: s.payload } });
          o.current &&
            l.current.game === s.game &&
            b(l.current.payload) &&
            m(d);
        } catch (d) {
          o.current &&
            l.current.game === s.game &&
            c(d instanceof Error ? d.message : "Erreur IA");
        } finally {
          ((f.current = !1), o.current && h(!1));
        }
      }
    };
  return (
    r.useEffect(() => {
      if (((o.current = !0), m(null), c(null), n.length < 20)) return;
      p();
      const s = setInterval(p, k);
      return () => {
        ((o.current = !1), clearInterval(s));
      };
    }, [i, n.length >= 20]),
    n.length < 20
      ? e.jsxs("div", {
          className: "glass rounded-3xl p-5 sm:p-6 flex items-center gap-3",
          children: [
            e.jsx(C, {
              className: "w-5 h-5 text-[var(--neon-purple)] animate-pulse",
            }),
            e.jsxs("p", {
              className: "text-sm text-muted-foreground font-mono",
              children: ["IA en attente — ", n.length, "/20 tours collectés…"],
            }),
          ],
        })
      : e.jsxs("div", {
          className: `relative glass rounded-3xl p-5 sm:p-6 bg-gradient-to-br ${a ? L(a.category) : "from-purple-500/10 to-fuchsia-500/10 border-purple-500/20"} border`,
          children: [
            e.jsxs("div", {
              className:
                "flex items-center justify-between mb-4 flex-wrap gap-2",
              children: [
                e.jsxs("div", {
                  className: "flex items-center gap-2.5",
                  children: [
                    e.jsxs("div", {
                      className: "relative",
                      children: [
                        e.jsx(A, { className: "w-5 h-5 text-fuchsia-400" }),
                        e.jsx("div", {
                          className:
                            "absolute inset-0 blur-md bg-fuchsia-400/40 animate-pulse",
                        }),
                      ],
                    }),
                    e.jsx("h3", {
                      className:
                        "font-display font-bold text-base sm:text-lg tracking-tight",
                      children: "Prédiction IA — prochain multiplicateur",
                    }),
                  ],
                }),
                e.jsxs(F, {
                  variant: "outline",
                  size: "sm",
                  onClick: p,
                  disabled: u,
                  className:
                    "flex items-center gap-1.5 px-3 py-1.5 rounded-lg glass text-xs font-mono hover:bg-white/5 transition disabled:opacity-50",
                  children: [
                    e.jsx(I, {
                      className: `w-3 h-3 ${u ? "animate-spin" : ""}`,
                    }),
                    u ? "Analyse…" : "Réanalyser",
                  ],
                }),
              ],
            }),
            x &&
              e.jsxs("p", {
                className: "text-xs font-mono text-red-400 mb-3",
                children: ["⚠ ", x],
              }),
            a && N
              ? e.jsxs(e.Fragment, {
                  children: [
                    e.jsxs("div", {
                      className: "grid grid-cols-2 sm:grid-cols-4 gap-3",
                      children: [
                        e.jsxs("div", {
                          className: "glass rounded-2xl p-3 sm:p-4",
                          children: [
                            e.jsxs("div", {
                              className:
                                "flex items-center gap-1.5 text-[10px] font-mono text-muted-foreground uppercase mb-1",
                              children: [
                                e.jsx(P, { className: "w-3 h-3" }),
                                " Estimé",
                              ],
                            }),
                            e.jsxs("div", {
                              className:
                                "font-display font-black text-2xl sm:text-3xl bg-gradient-to-br from-fuchsia-400 to-purple-500 bg-clip-text text-transparent",
                              children: [a.estimatedCoef.toFixed(2), "×"],
                            }),
                          ],
                        }),
                        e.jsxs("div", {
                          className: "glass rounded-2xl p-3 sm:p-4",
                          children: [
                            e.jsxs("div", {
                              className:
                                "flex items-center gap-1.5 text-[10px] font-mono text-muted-foreground uppercase mb-1",
                              children: [
                                e.jsx(T, { className: "w-3 h-3" }),
                                " Catégorie",
                              ],
                            }),
                            e.jsx("div", {
                              className:
                                "font-display font-bold text-sm sm:text-base",
                              children: M(a.category),
                            }),
                          ],
                        }),
                        e.jsxs("div", {
                          className: "glass rounded-2xl p-3 sm:p-4",
                          children: [
                            e.jsx("div", {
                              className:
                                "text-[10px] font-mono text-muted-foreground uppercase mb-1",
                              children: "Score d'analyse",
                            }),
                            e.jsxs("div", {
                              className: "flex items-center gap-2",
                              children: [
                                e.jsx("div", {
                                  className:
                                    "flex-1 h-2 rounded-full bg-white/5 overflow-hidden",
                                  children: e.jsx("div", {
                                    className:
                                      "h-full bg-gradient-to-r from-fuchsia-500 to-purple-500 transition-all",
                                    style: { width: `${a.confidence}%` },
                                  }),
                                }),
                                e.jsxs("span", {
                                  className: "font-mono text-sm font-bold",
                                  children: [a.confidence, "%"],
                                }),
                              ],
                            }),
                          ],
                        }),
                        e.jsxs("div", {
                          className: "glass rounded-2xl p-3 sm:p-4",
                          children: [
                            e.jsx("div", {
                              className:
                                "text-[10px] font-mono text-muted-foreground uppercase mb-1",
                              children: "Base d'analyse",
                            }),
                            e.jsxs("div", {
                              className: "font-mono text-sm",
                              children: [a.analyzed, " tours"],
                            }),
                          ],
                        }),
                      ],
                    }),
                    e.jsx("p", {
                      className:
                        "mt-4 text-xs sm:text-sm text-muted-foreground italic border-l-2 border-fuchsia-500/40 pl-3",
                      children: a.rationale,
                    }),
                    e.jsxs("p", {
                      className:
                        "mt-2 text-[10px] font-mono text-muted-foreground/60",
                      children: [
                        "Données à ",
                        new Date(a.dataCutoff).toLocaleTimeString("fr-FR"),
                        " · score non assimilable à un taux de réussite.",
                      ],
                    }),
                  ],
                })
              : e.jsx("p", {
                  className: "text-sm text-muted-foreground font-mono",
                  children: x
                    ? "Analyse indisponible."
                    : "Analyse IA en cours…",
                }),
          ],
        })
  );
}
export { H as A };
