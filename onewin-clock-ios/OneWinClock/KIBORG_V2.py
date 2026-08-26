#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
LUCKYJET KILLER FUSION V5 RU

Реконструкция по публично наблюдавшимся форматам BABEL / AllPredictor /
GROSSE CÔTE + собственная статистическая логика на LIVE истории.

ВАЖНО:
- Это НЕ приватный/утёкший оригинальный исходник ALLPREDICTOR KILLER.
- Код не гарантирует будущие коэффициенты.
- Каждый сигнал проверяется на фактических следующих раундах и сохраняется в SQLite.

Режимы:
1) PETIT          — малые цели ~2x–4x, confidence + timing.
2) GROSSE CÔTE   — большая цель 10x–100x + ASSURANCE + окно + 5–7 раундов.
3) KILLER FUSION — объединяет gap, интервалы 10x/20x/50x, pattern, timing,
                   stability и эмпирическую статистику SQLite.
4) COMBINE       — сигнал только при согласии >=2 совместимых движков.
"""

import os
import re
import json
import time
import math
import html
import sqlite3
import threading
from datetime import datetime, timedelta
from statistics import mean, median, pstdev
from zoneinfo import ZoneInfo

import requests
import telebot
from telebot import types

# ============================================================
# ПОДКЛЮЧЕНИЯ — сохранены из рабочей ветки пользователя
# Лучше переопределить секреты через ENV на сервере.
# ============================================================
TOKEN = os.getenv("TELEGRAM_TOKEN", "")
GROUP_CHAT_ID = int(os.getenv("GROUP_CHAT_ID", "-1003959529321"))
ADMIN_ID = int(os.getenv("ADMIN_ID", "8016237913"))

LUCKYJET_URL = os.getenv("LUCKYJET_API_URL", "https://crash-gateway-grm-cr.100hp.app/history")
CUSTOMER_ID = os.getenv("LUCKYJET_CUSTOMER_ID", "077dee8d-c923-4c02-9bee-757573662e69")
SESSION_ID = os.getenv("LUCKYJET_SESSION_ID", "00000000-0000-0000-0000-000000000000")

LUCKYJET_HEADERS = {
    "session-id": SESSION_ID,
    "customer-id": CUSTOMER_ID,
    "Accept": "application/json",
    "User-Agent": "LuckyJet-Killer-Fusion-V5/1.0",
}

TZ = ZoneInfo("Europe/Kyiv")
REQUEST_TIMEOUT = int(os.getenv("REQUEST_TIMEOUT", "12"))
POLL_SECONDS = int(os.getenv("POLL_SECONDS", "5"))
AUTO_SIGNALS = os.getenv("AUTO_SIGNALS", "1") == "1"
CONFIDENCE_MIN = int(os.getenv("CONFIDENCE_MIN", "70"))
SIGNAL_COOLDOWN_SECONDS = int(os.getenv("SIGNAL_COOLDOWN_SECONDS", "60"))
MAX_ATTEMPTS = int(os.getenv("MAX_ATTEMPTS", "3"))
PAUSE_AFTER_2_LOSSES_SECONDS = int(os.getenv("PAUSE_AFTER_2_LOSSES_SECONDS", "300"))
DB_PATH = os.getenv("KILLER_DB", "luckyjet_killer_fusion_v5.sqlite3")
STATE_FILE = os.getenv("KILLER_STATE", "luckyjet_killer_fusion_v5_state.json")

bot = telebot.TeleBot(TOKEN, parse_mode="HTML", threaded=True)
state_lock = threading.RLock()
db_lock = threading.RLock()

ENGINES = {
    "petit": "PETIT",
    "grosse": "GROSSE CÔTE",
    "killer": "KILLER FUSION",
    "combine": "COMBINE",
}

# Публично наблюдавшиеся ориентиры. Они используются только как calibration priors,
# а не как доказанный приватный backend.
PUBLIC_PETIT_MIN = 2.0
PUBLIC_PETIT_MAX = 4.0
PUBLIC_GROSSE_MIN = 10.0
PUBLIC_GROSSE_MAX = 100.0
PUBLIC_HORIZON_ROUNDS = (5, 7)

# Временные признаки/окна, которые встречались в публичных форматах.
FAVOURABLE_HOUR_RANGES = [(1, 2), (11, 13), (16, 19), (21, 23)]
FAVOURABLE_MINUTE_RANGES = [(59, 2), (4, 10), (13, 20), (27, 33), (45, 47), (50, 52), (55, 59)]


# ============================================================
# ОБЩИЕ УТИЛИТЫ
# ============================================================
def now_kyiv():
    return datetime.now(TZ)


def clamp(v, lo, hi):
    return max(lo, min(hi, v))


def safe_float(v):
    try:
        x = float(v)
        return x if math.isfinite(x) else None
    except (TypeError, ValueError):
        return None


def parse_time(raw):
    if raw is None:
        return None
    if isinstance(raw, (int, float)):
        ts = float(raw)
        if ts > 10_000_000_000:
            ts /= 1000.0
        try:
            return datetime.fromtimestamp(ts, TZ)
        except Exception:
            return None
    s = str(raw).strip()
    if not s:
        return None
    s = s.replace("Z", "+00:00")
    try:
        dt = datetime.fromisoformat(s)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=TZ)
        return dt.astimezone(TZ)
    except Exception:
        return None


def default_state():
    return {
        "enabled": {"petit": True, "grosse": False, "killer": False, "combine": False},
        "last_round_id": None,
        "last_signal_at": {k: 0.0 for k in ENGINES},
        "loss_streak": {k: 0 for k in ENGINES},
        "paused_until": {k: 0.0 for k in ENGINES},
    }


def load_state():
    base = default_state()
    try:
        with open(STATE_FILE, "r", encoding="utf-8") as f:
            saved = json.load(f)
        if isinstance(saved, dict):
            for section in ("enabled", "last_signal_at", "loss_streak", "paused_until"):
                if isinstance(saved.get(section), dict):
                    base[section].update(saved[section])
            base["last_round_id"] = saved.get("last_round_id")
    except Exception:
        pass
    return base


state = load_state()


def save_state():
    tmp = STATE_FILE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(state, f, ensure_ascii=False, indent=2)
    os.replace(tmp, STATE_FILE)


# ============================================================
# SQLITE — ФАКТИЧЕСКИЕ РАУНДЫ, СИГНАЛЫ И ОБУЧЕНИЕ
# ============================================================
def db_connect():
    con = sqlite3.connect(DB_PATH, timeout=30)
    con.row_factory = sqlite3.Row
    con.execute("PRAGMA journal_mode=WAL")
    con.execute("PRAGMA synchronous=NORMAL")
    return con


def init_db():
    with db_lock, db_connect() as con:
        con.executescript(
            """
            CREATE TABLE IF NOT EXISTS rounds (
                id TEXT PRIMARY KEY,
                coef REAL NOT NULL,
                api_time TEXT,
                received_at TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS signals (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                engine TEXT NOT NULL,
                signal_type TEXT,
                band TEXT,
                created_round_id TEXT,
                created_at TEXT NOT NULL,
                target REAL NOT NULL,
                target_low REAL,
                target_high REAL,
                insurance REAL,
                confidence_raw INTEGER NOT NULL,
                confidence_final INTEGER NOT NULL,
                timing TEXT,
                window_start TEXT,
                window_end TEXT,
                horizon_min INTEGER,
                horizon_max INTEGER,
                feature_json TEXT,
                status TEXT NOT NULL DEFAULT 'PENDING',
                attempts INTEGER NOT NULL DEFAULT 0,
                best_coef REAL NOT NULL DEFAULT 0,
                insurance_hit INTEGER NOT NULL DEFAULT 0,
                completed_at TEXT
            );

            CREATE TABLE IF NOT EXISTS signal_attempts (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                signal_id INTEGER NOT NULL,
                attempt_no INTEGER NOT NULL,
                round_id TEXT NOT NULL,
                coef REAL NOT NULL,
                created_at TEXT NOT NULL,
                UNIQUE(signal_id, round_id)
            );

            CREATE INDEX IF NOT EXISTS idx_signals_engine_status
                ON signals(engine, status);
            CREATE INDEX IF NOT EXISTS idx_attempts_signal
                ON signal_attempts(signal_id);
            """
        )


def save_round(row):
    with db_lock, db_connect() as con:
        con.execute(
            "INSERT OR IGNORE INTO rounds(id, coef, api_time, received_at) VALUES(?,?,?,?)",
            (row["id"], row["coef"], row.get("api_time"), now_kyiv().isoformat()),
        )


def empirical_engine_stats(engine, limit=250):
    """Возвращает эмпирический WR и число завершённых сигналов."""
    with db_lock, db_connect() as con:
        rows = con.execute(
            """SELECT status FROM signals
               WHERE engine=? AND status IN ('WIN','LOSS')
               ORDER BY id DESC LIMIT ?""",
            (engine, limit),
        ).fetchall()
    n = len(rows)
    if not n:
        return None, 0
    wins = sum(r["status"] == "WIN" for r in rows)
    return wins / n, n


def calibrated_confidence(engine, raw_conf):
    """
    Не переобучаем формулу на маленькой выборке.
    До 8 завершённых сигналов оставляем raw confidence.
    Затем плавно подмешиваем фактический WR.
    """
    wr, n = empirical_engine_stats(engine)
    if wr is None or n < 8:
        return int(clamp(round(raw_conf), 1, 99)), n, wr
    weight = clamp(n / 80.0, 0.10, 0.45)
    empirical_pct = wr * 100.0
    final = raw_conf * (1 - weight) + empirical_pct * weight
    return int(clamp(round(final), 1, 99)), n, wr


def insert_signal(result, created_round_id):
    with db_lock, db_connect() as con:
        cur = con.execute(
            """
            INSERT INTO signals(
                engine, signal_type, band, created_round_id, created_at,
                target, target_low, target_high, insurance,
                confidence_raw, confidence_final, timing,
                window_start, window_end, horizon_min, horizon_max, feature_json
            ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """,
            (
                result["engine"], result.get("type"), result.get("band"), created_round_id,
                now_kyiv().isoformat(), result["target"], result.get("target_low"), result.get("target_high"),
                result.get("insurance"), result.get("confidence_raw", result["confidence"]), result["confidence"],
                result.get("timing"), result.get("window_start"), result.get("window_end"),
                result.get("horizon_min"), result.get("horizon_max"),
                json.dumps(result.get("features", {}), ensure_ascii=False),
            ),
        )
        return cur.lastrowid


def pending_signals():
    with db_lock, db_connect() as con:
        return con.execute(
            "SELECT * FROM signals WHERE status='PENDING' ORDER BY id"
        ).fetchall()


def record_attempt(signal_id, attempt_no, row):
    with db_lock, db_connect() as con:
        con.execute(
            """INSERT OR IGNORE INTO signal_attempts(signal_id, attempt_no, round_id, coef, created_at)
               VALUES(?,?,?,?,?)""",
            (signal_id, attempt_no, row["id"], row["coef"], now_kyiv().isoformat()),
        )


def finish_signal(signal_id, status, attempts, best_coef, insurance_hit):
    with db_lock, db_connect() as con:
        con.execute(
            """UPDATE signals SET status=?, attempts=?, best_coef=?, insurance_hit=?, completed_at=?
               WHERE id=?""",
            (status, attempts, best_coef, int(bool(insurance_hit)), now_kyiv().isoformat(), signal_id),
        )


def update_signal_progress(signal_id, attempts, best_coef, insurance_hit):
    with db_lock, db_connect() as con:
        con.execute(
            "UPDATE signals SET attempts=?, best_coef=?, insurance_hit=? WHERE id=?",
            (attempts, best_coef, int(bool(insurance_hit)), signal_id),
        )


def db_stats_text():
    lines = ["📊 <b>СТАТИСТИКА V5</b>", ""]
    with db_lock, db_connect() as con:
        for key, name in ENGINES.items():
            r = con.execute(
                """SELECT
                     COUNT(*) total,
                     SUM(CASE WHEN status='WIN' THEN 1 ELSE 0 END) wins,
                     SUM(CASE WHEN status='LOSS' THEN 1 ELSE 0 END) losses,
                     SUM(CASE WHEN insurance_hit=1 THEN 1 ELSE 0 END) insurance_hits
                   FROM signals WHERE engine=?""",
                (key,),
            ).fetchone()
            total = int(r["total"] or 0)
            wins = int(r["wins"] or 0)
            losses = int(r["losses"] or 0)
            checked = wins + losses
            wr = 100.0 * wins / checked if checked else 0.0
            lines.append(
                f"<b>{name}</b>: {total} сигналов • ✅ {wins} • ❌ {losses} • "
                f"🛡 {int(r['insurance_hits'] or 0)} • WR {wr:.1f}%"
            )
        rounds = con.execute("SELECT COUNT(*) n FROM rounds").fetchone()["n"]
    lines += ["", f"💾 Раундов в SQLite: <b>{rounds}</b>"]
    return "\n".join(lines)


# ============================================================
# LUCKYJET HISTORY
# ============================================================
def normalize(item):
    if not isinstance(item, dict):
        return None
    raw = item.get("finalValues")
    if isinstance(raw, list) and raw:
        raw = raw[-1]
    if raw is None:
        raw = item.get("topCoefficient")
    if raw is None:
        raw = item.get("coefficient") or item.get("coef") or item.get("value")
    coef = safe_float(raw)
    if coef is None or coef <= 0:
        return None
    raw_time = item.get("createdAt") or item.get("time") or item.get("timestamp")
    rid = str(
        item.get("id") or item.get("roundId") or item.get("round_id") or item.get("hash")
        or f"{coef}:{raw_time or ''}"
    )
    dt = parse_time(raw_time)
    return {
        "id": rid,
        "coef": round(coef, 2),
        "raw_time": raw_time,
        "api_time": dt.isoformat() if dt else None,
    }


def fetch_history(limit=500):
    r = requests.get(LUCKYJET_URL, headers=LUCKYJET_HEADERS, timeout=REQUEST_TIMEOUT)
    r.raise_for_status()
    data = r.json()
    if isinstance(data, dict):
        # Поддержка частых API-обёрток без жёсткой привязки.
        for key in ("data", "history", "items", "results"):
            if isinstance(data.get(key), list):
                data = data[key]
                break
    if not isinstance(data, list):
        raise RuntimeError(f"Unexpected API format: {type(data).__name__}")

    rows, seen = [], set()
    for item in data:
        row = normalize(item)
        if not row or row["id"] in seen:
            continue
        seen.add(row["id"])
        rows.append(row)
        if len(rows) >= limit:
            break
    if not rows:
        raise RuntimeError("LuckyJet history is empty")
    return rows


# ============================================================
# ПРИЗНАКИ И ОБУЧЕНИЕ ИНТЕРВАЛОВ
# rows[0] считается самым свежим раундом, как в рабочей V4.
# ============================================================
def rate(vals, threshold):
    return sum(x >= threshold for x in vals) / max(len(vals), 1)


def gap_since(vals, threshold):
    return next((i for i, x in enumerate(vals) if x >= threshold), len(vals))


def low_streak(vals, threshold):
    n = 0
    for x in vals:
        if x < threshold:
            n += 1
        else:
            break
    return n


def zone(v):
    if v < 1.5:
        return "L"
    if v < 3.0:
        return "M"
    if v < 10.0:
        return "H"
    return "X"


def pattern_probability(vals, history_window=120, key_len=4, success_threshold=3.0):
    """Вероятность успеха после похожей последовательности зон."""
    chronological = list(reversed(vals[:history_window]))
    if len(chronological) < key_len + 8:
        return 0.40, 0
    z = [zone(v) for v in chronological]
    key = tuple(z[-key_len:])
    matches = success = 0
    for i in range(0, len(z) - key_len):
        if tuple(z[i:i + key_len]) == key:
            matches += 1
            if chronological[i + key_len] >= success_threshold:
                success += 1
    return (success / matches if matches else 0.40), matches


def threshold_intervals(vals, threshold, max_len=300):
    """
    Возвращает интервалы в РАУНДАХ между событиями >= threshold.
    История API разворачивается в хронологический порядок.
    """
    chronological = list(reversed(vals[:max_len]))
    idx = [i for i, x in enumerate(chronological) if x >= threshold]
    if len(idx) < 2:
        return []
    return [idx[i] - idx[i - 1] for i in range(1, len(idx))]


def interval_profile(vals, threshold):
    ints = threshold_intervals(vals, threshold)
    if not ints:
        return {"median": None, "mean": None, "count": 0, "last_gap": gap_since(vals, threshold), "phase": 0.0}
    med = median(ints)
    avg = mean(ints)
    last_gap = gap_since(vals, threshold)
    # phase ~1 когда текущий gap приблизился/перешёл историческую медиану.
    phase = clamp(last_gap / max(med, 1), 0, 1.5) / 1.5
    return {"median": med, "mean": avg, "count": len(ints), "last_gap": last_gap, "phase": phase}


def recent_round_seconds():
    """Медианный интервал между реально увиденными ботом live-раундами."""
    with db_lock, db_connect() as con:
        rows = con.execute(
            "SELECT received_at FROM rounds ORDER BY rowid DESC LIMIT 40"
        ).fetchall()
    if len(rows) < 6:
        return None
    times = []
    for r in reversed(rows):
        try:
            times.append(datetime.fromisoformat(r["received_at"]))
        except Exception:
            pass
    diffs = []
    for a, b in zip(times, times[1:]):
        d = (b - a).total_seconds()
        if 2 <= d <= 180:
            diffs.append(d)
    return median(diffs) if len(diffs) >= 4 else None


def _in_hour(h, a, b):
    return a <= h <= b if a <= b else (h >= a or h <= b)


def _in_minute(m, a, b):
    return a <= m <= b if a <= b else (m >= a or m <= b)


def time_score(dt=None):
    dt = dt or now_kyiv()
    h = any(_in_hour(dt.hour, a, b) for a, b in FAVOURABLE_HOUR_RANGES)
    m = any(_in_minute(dt.minute, a, b) for a, b in FAVOURABLE_MINUTE_RANGES)
    if h and m:
        return 1.0
    if m:
        return 0.72
    if h:
        return 0.55
    return 0.25


def market_stability(vals):
    sample = [min(x, 50.0) for x in vals[:50]]
    if len(sample) < 8:
        return "UNKNOWN", 0.50
    avg = mean(sample)
    vol = pstdev(sample) / max(avg, 1.0)
    tail10 = rate(sample, 10.0)
    # Стабильность здесь означает пригодность модели, а не "безопасность ставки".
    score = clamp(1.0 - vol / 1.8, 0, 1) * 0.65 + clamp(1.0 - abs(tail10 - 0.10) / 0.25, 0, 1) * 0.35
    if vol > 1.65:
        return "UNSTABLE", score
    if vol > 1.15:
        return "CAUTION", score
    return "STABLE", score


def build_window(horizon_min=5, horizon_max=7):
    """
    TIME WINDOW: если накоплена реальная live-скорость раундов — окно считается
    через неё. Если данных мало, используется публично наблюдавшийся короткий
    формат 1–3 минуты, но причина явно указывается.
    """
    sec = recent_round_seconds()
    now = now_kyiv()
    if sec:
        start = now + timedelta(seconds=sec * horizon_min)
        end = now + timedelta(seconds=sec * horizon_max)
        source = f"live cadence ~{sec:.1f}s/round"
    else:
        start = now + timedelta(minutes=1)
        end = now + timedelta(minutes=3)
        source = "fallback public-style 1–3 min"
    return start, end, source


def feature_pack(rows):
    vals = [r["coef"] for r in rows[:300]]
    s20, s50, s100 = vals[:20], vals[:50], vals[:100]
    clipped = [min(v, 50.0) for v in s50]
    avg50 = mean(clipped) if clipped else 1.0
    vol = pstdev(clipped) / max(avg50, 1.0) if len(clipped) > 1 else 0.0
    p_small, n_small = pattern_probability(vals, success_threshold=2.0)
    p_big, n_big = pattern_probability(vals, success_threshold=10.0)
    i10 = interval_profile(vals, 10.0)
    i20 = interval_profile(vals, 20.0)
    i50 = interval_profile(vals, 50.0)
    stability_name, stability_score = market_stability(vals)
    return {
        "vals": vals,
        "last": vals[:15],
        "p2": rate(s50, 2.0),
        "p3": rate(s50, 3.0),
        "p5": rate(s50, 5.0),
        "p10": rate(s100, 10.0),
        "p20": rate(s100, 20.0),
        "p50": rate(vals[:200], 50.0),
        "gap2": gap_since(vals, 2.0),
        "gap5": gap_since(vals, 5.0),
        "gap10": gap_since(vals, 10.0),
        "gap20": gap_since(vals, 20.0),
        "gap50": gap_since(vals, 50.0),
        "low2": low_streak(vals, 2.0),
        "low5": low_streak(vals, 5.0),
        "vol": vol,
        "pattern_small": p_small,
        "pattern_small_n": n_small,
        "pattern_big": p_big,
        "pattern_big_n": n_big,
        "i10": i10,
        "i20": i20,
        "i50": i50,
        "time_score": time_score(),
        "stability": stability_name,
        "stability_score": stability_score,
    }


# ============================================================
# ДВИЖОК 1 — PETIT
# ============================================================
def petit_engine(rows):
    f = feature_pack(rows)
    pattern_support = clamp(f["pattern_small_n"] / 7.0, 0, 1)
    recovery = clamp(f["low2"] / 5.0, 0, 1)
    normality = 1.0 - clamp(f["vol"] / 1.6, 0, 1)
    p2_strength = clamp(f["p2"] / 0.55, 0, 1)

    score = clamp(
        0.28 * p2_strength
        + 0.22 * f["pattern_small"]
        + 0.14 * pattern_support
        + 0.15 * recovery
        + 0.12 * normality
        + 0.09 * f["time_score"],
        0, 1,
    )

    target = clamp(2.0 + 2.0 * (score ** 1.35), PUBLIC_PETIT_MIN, PUBLIC_PETIT_MAX)
    raw_conf = 48 + score * 43
    if f["stability"] == "UNSTABLE":
        raw_conf -= 9
    elif f["stability"] == "CAUTION":
        raw_conf -= 4

    conf, learned_n, learned_wr = calibrated_confidence("petit", raw_conf)
    timing = "NOW" if conf >= CONFIDENCE_MIN and f["stability"] != "UNSTABLE" else "WAIT"

    return {
        "engine": "petit",
        "type": "PETIT 2x–4x",
        "band": "small",
        "target": round(target, 2),
        "target_low": 2.0,
        "target_high": round(target, 2),
        "insurance": None,
        "confidence_raw": int(round(clamp(raw_conf, 1, 99))),
        "confidence": conf,
        "timing": timing,
        "reason": (
            f"p2={f['p2']:.2f}; low2={f['low2']}; pattern={f['pattern_small']:.2f}/{f['pattern_small_n']}; "
            f"stability={f['stability']}; time={f['time_score']:.2f}; learned_n={learned_n}"
        ),
        "features": compact_features(f, learned_wr),
    }


# ============================================================
# ДВИЖОК 2 — GROSSE CÔTE
# ============================================================
def grosse_engine(rows):
    f = feature_pack(rows)

    phase10 = f["i10"]["phase"]
    phase20 = f["i20"]["phase"]
    phase50 = f["i50"]["phase"]
    gap_pressure = clamp(f["gap10"] / 18.0, 0, 1) * 0.44 + clamp(f["gap20"] / 35.0, 0, 1) * 0.34 + clamp(f["gap50"] / 90.0, 0, 1) * 0.22
    interval_pressure = phase10 * 0.52 + phase20 * 0.31 + phase50 * 0.17
    burst = clamp(f["p5"] / 0.24, 0, 1) * 0.42 + clamp(f["p10"] / 0.11, 0, 1) * 0.38 + clamp(f["p20"] / 0.055, 0, 1) * 0.20
    pattern_support = clamp(f["pattern_big_n"] / 6.0, 0, 1)

    power = clamp(
        0.24 * gap_pressure
        + 0.25 * interval_pressure
        + 0.16 * burst
        + 0.14 * f["pattern_big"]
        + 0.07 * pattern_support
        + 0.07 * f["time_score"]
        + 0.07 * f["stability_score"],
        0, 1,
    )

    # Большая цель задаётся диапазоном и центральной целью.
    target_low = clamp(10 + 45 * (power ** 1.35), 10, 55)
    target_high = clamp(target_low + 10 + 45 * power, target_low + 5, 100)
    target = clamp((target_low * 0.60 + target_high * 0.40), 10, 100)

    # ASSURANCE: blend двух публично наблюдавшихся форматов:
    # 1) около половины нижней границы; 2) более консервативная отдельная цель.
    half_mode = target_low * 0.50
    babel_like = 3.0 + 12.0 * clamp(
        0.40 * f["pattern_big"] + 0.35 * clamp(f["p5"] / 0.25, 0, 1) + 0.25 * clamp(f["low5"] / 7.0, 0, 1),
        0, 1,
    )
    insurance = clamp(0.55 * half_mode + 0.45 * babel_like, 3.0, 30.0)
    insurance = min(insurance, target_low * 0.75)

    raw_conf = 45 + power * 48 + pattern_support * 4
    if f["gap10"] < 5:
        raw_conf -= 8
    if f["stability"] == "UNSTABLE":
        raw_conf -= 12
    elif f["stability"] == "CAUTION":
        raw_conf -= 5

    conf, learned_n, learned_wr = calibrated_confidence("grosse", raw_conf)
    start, end, window_source = build_window(*PUBLIC_HORIZON_ROUNDS)
    timing = "READY" if conf >= CONFIDENCE_MIN and f["stability"] != "UNSTABLE" else "WAIT"

    return {
        "engine": "grosse",
        "type": "GROSSE CÔTE 10x–100x",
        "band": "big",
        "target": round(target, 2),
        "target_low": round(target_low, 2),
        "target_high": round(target_high, 2),
        "insurance": round(insurance, 2),
        "confidence_raw": int(round(clamp(raw_conf, 1, 99))),
        "confidence": conf,
        "timing": timing,
        "window_start": start.isoformat(),
        "window_end": end.isoformat(),
        "window_source": window_source,
        "horizon_min": 5,
        "horizon_max": 7,
        "reason": (
            f"gap10/20/50={f['gap10']}/{f['gap20']}/{f['gap50']}; "
            f"phase10/20/50={phase10:.2f}/{phase20:.2f}/{phase50:.2f}; "
            f"pattern10={f['pattern_big']:.2f}/{f['pattern_big_n']}; stability={f['stability']}; learned_n={learned_n}"
        ),
        "features": compact_features(f, learned_wr),
    }


# ============================================================
# ДВИЖОК 3 — KILLER FUSION
# ============================================================
def killer_engine(rows):
    f = feature_pack(rows)
    g = grosse_engine(rows)

    # Независимые голоса. Именно это отличает Fusion от одной формулы.
    votes = []
    votes.append(("gap10", clamp(f["gap10"] / max(f["i10"].get("median") or 14, 1), 0, 1.25) / 1.25))
    votes.append(("gap20", clamp(f["gap20"] / max(f["i20"].get("median") or 28, 1), 0, 1.25) / 1.25))
    votes.append(("interval10", f["i10"]["phase"]))
    votes.append(("interval20", f["i20"]["phase"]))
    votes.append(("pattern_big", f["pattern_big"]))
    votes.append(("time", f["time_score"]))
    votes.append(("stability", f["stability_score"]))
    votes.append(("burst", clamp((f["p5"] * 1.4 + f["p10"] * 3.0 + f["p20"] * 5.0), 0, 1)))

    strong_votes = [name for name, score in votes if score >= 0.62]
    vote_mean = mean(score for _, score in votes)

    # Fusion получает высокий confidence только при множественном подтверждении.
    raw_conf = 42 + vote_mean * 36 + len(strong_votes) * 4.0
    if len(strong_votes) < 4:
        raw_conf = min(raw_conf, 69)
    if f["stability"] == "UNSTABLE":
        raw_conf -= 14
    elif f["stability"] == "CAUTION":
        raw_conf -= 5

    conf, learned_n, learned_wr = calibrated_confidence("killer", raw_conf)

    # Fusion слегка сжимает большую цель при слабом согласии и расширяет при сильном.
    strength = clamp((len(strong_votes) - 3) / 5.0, 0, 1)
    target_low = clamp(g["target_low"] * (0.90 + 0.10 * strength), 10, 70)
    target_high = clamp(g["target_high"] * (0.92 + 0.08 * strength), target_low + 5, 100)
    target = target_low * 0.62 + target_high * 0.38
    insurance = clamp(g["insurance"] * (0.95 + 0.05 * strength), 3, 30)

    start, end, window_source = build_window(5, 7)
    timing = "READY" if conf >= CONFIDENCE_MIN and len(strong_votes) >= 4 and f["stability"] != "UNSTABLE" else "WAIT"

    return {
        "engine": "killer",
        "type": "KILLER FUSION BIG",
        "band": "big",
        "target": round(target, 2),
        "target_low": round(target_low, 2),
        "target_high": round(target_high, 2),
        "insurance": round(min(insurance, target_low * 0.75), 2),
        "confidence_raw": int(round(clamp(raw_conf, 1, 99))),
        "confidence": conf,
        "timing": timing,
        "window_start": start.isoformat(),
        "window_end": end.isoformat(),
        "window_source": window_source,
        "horizon_min": 5,
        "horizon_max": 7,
        "reason": (
            f"votes={len(strong_votes)}/8 [{', '.join(strong_votes) or '-'}]; mean={vote_mean:.2f}; "
            f"stability={f['stability']}; gap10={f['gap10']}; i10_med={f['i10'].get('median')}; learned_n={learned_n}"
        ),
        "features": {**compact_features(f, learned_wr), "strong_votes": strong_votes, "vote_mean": round(vote_mean, 4)},
    }


# ============================================================
# ДВИЖОК 4 — COMBINE
# ============================================================
def combine_engine(rows):
    p = petit_engine(rows)
    g = grosse_engine(rows)
    k = killer_engine(rows)

    # BIG consensus: GROSSE + KILLER. SMALL consensus пока требует PETIT +
    # будущий независимый small-engine, поэтому COMBINE не подделывает второй голос.
    big_votes = [x for x in (g, k) if x["confidence"] >= CONFIDENCE_MIN and x.get("timing") == "READY"]
    if len(big_votes) >= 2:
        target_low = max(x["target_low"] for x in big_votes)
        target_high = min(x["target_high"] for x in big_votes)
        if target_high <= target_low:
            target_low = min(x["target_low"] for x in big_votes)
            target_high = min(x["target_high"] for x in big_votes)
        target = mean(x["target"] for x in big_votes)
        insurance = mean(x["insurance"] for x in big_votes if x.get("insurance"))
        raw_conf = mean(x["confidence"] for x in big_votes) + 3
        conf, learned_n, learned_wr = calibrated_confidence("combine", raw_conf)
        start = max(datetime.fromisoformat(x["window_start"]) for x in big_votes)
        end = min(datetime.fromisoformat(x["window_end"]) for x in big_votes)
        if end <= start:
            start, end, _ = build_window(5, 7)
        return {
            "engine": "combine",
            "type": "COMBINE BIG CONSENSUS",
            "band": "big",
            "target": round(target, 2),
            "target_low": round(target_low, 2),
            "target_high": round(target_high, 2),
            "insurance": round(insurance, 2),
            "confidence_raw": int(round(clamp(raw_conf, 1, 99))),
            "confidence": conf,
            "timing": "READY" if conf >= CONFIDENCE_MIN else "WAIT",
            "window_start": start.isoformat(),
            "window_end": end.isoformat(),
            "horizon_min": 5,
            "horizon_max": 7,
            "reason": f"совпали GROSSE + KILLER; learned_n={learned_n}",
            "features": {"grosse_conf": g["confidence"], "killer_conf": k["confidence"], "learned_wr": learned_wr},
        }

    return {
        "engine": "combine",
        "type": "COMBINE",
        "band": None,
        "target": None,
        "insurance": None,
        "confidence_raw": 0,
        "confidence": 0,
        "timing": "WAIT",
        "reason": f"нет двух BIG-голосов: GROSSE={g['confidence']}%/{g['timing']}, KILLER={k['confidence']}%/{k['timing']}; PETIT={p['confidence']}%",
        "features": {},
    }


def compact_features(f, learned_wr=None):
    return {
        "p2": round(f["p2"], 4),
        "p5": round(f["p5"], 4),
        "p10": round(f["p10"], 4),
        "p20": round(f["p20"], 4),
        "gap10": f["gap10"],
        "gap20": f["gap20"],
        "gap50": f["gap50"],
        "i10_median": f["i10"].get("median"),
        "i20_median": f["i20"].get("median"),
        "i50_median": f["i50"].get("median"),
        "pattern_small": round(f["pattern_small"], 4),
        "pattern_big": round(f["pattern_big"], 4),
        "vol": round(f["vol"], 4),
        "stability": f["stability"],
        "stability_score": round(f["stability_score"], 4),
        "time_score": round(f["time_score"], 4),
        "learned_wr": round(learned_wr, 4) if learned_wr is not None else None,
    }


def run_engine(key, rows):
    return {
        "petit": petit_engine,
        "grosse": grosse_engine,
        "killer": killer_engine,
        "combine": combine_engine,
    }[key](rows)


# ============================================================
# AUTO / ПАУЗЫ / ПРОВЕРКА СИГНАЛА
# ============================================================
def enabled_engines():
    with state_lock:
        return [k for k in ENGINES if state["enabled"].get(k)]


def toggle_engine(key):
    with state_lock:
        state["enabled"][key] = not state["enabled"].get(key, False)
        save_state()
        return state["enabled"][key]


def disable_all():
    with state_lock:
        for k in ENGINES:
            state["enabled"][k] = False
        save_state()


def engine_paused(key):
    return time.time() < state["paused_until"].get(key, 0.0)


def can_auto_signal(key, result):
    if not result.get("target"):
        return False
    if result.get("confidence", 0) < CONFIDENCE_MIN:
        return False
    if result.get("timing") not in ("NOW", "READY"):
        return False
    if engine_paused(key):
        return False
    if time.time() - state["last_signal_at"].get(key, 0.0) < SIGNAL_COOLDOWN_SECONDS:
        return False
    return True


def on_engine_win(engine):
    state["loss_streak"][engine] = 0


def on_engine_loss(engine):
    state["loss_streak"][engine] = state["loss_streak"].get(engine, 0) + 1
    if state["loss_streak"][engine] >= 2:
        state["paused_until"][engine] = time.time() + PAUSE_AFTER_2_LOSSES_SECONDS
        state["loss_streak"][engine] = 0


def process_pending(new_row):
    for sig in pending_signals():
        if new_row["id"] == sig["created_round_id"]:
            continue
        # Уже проверяли этот раунд?
        with db_lock, db_connect() as con:
            exists = con.execute(
                "SELECT 1 FROM signal_attempts WHERE signal_id=? AND round_id=?",
                (sig["id"], new_row["id"]),
            ).fetchone()
        if exists:
            continue

        attempt = int(sig["attempts"] or 0) + 1
        actual = new_row["coef"]
        best = max(float(sig["best_coef"] or 0), actual)
        insurance_hit = bool(sig["insurance_hit"])
        record_attempt(sig["id"], attempt, new_row)

        name = ENGINES.get(sig["engine"], sig["engine"])
        target = float(sig["target"])
        insurance = safe_float(sig["insurance"])

        if actual >= target:
            finish_signal(sig["id"], "WIN", attempt, best, insurance_hit)
            on_engine_win(sig["engine"])
            send(
                GROUP_CHAT_ID,
                f"✅ <b>{name} — ЦЕЛЬ ЗАШЛА</b>\n"
                f"🎯 {target:.2f}x • Выпало <b>{actual:.2f}x</b> • раунд {attempt}/{MAX_ATTEMPTS}",
            )
        else:
            if insurance and actual >= insurance and not insurance_hit:
                insurance_hit = True
                send(
                    GROUP_CHAT_ID,
                    f"🛡 <b>{name} — ASSURANCE ЗАШЛА</b>\n"
                    f"🛡 {insurance:.2f}x • Выпало <b>{actual:.2f}x</b> • раунд {attempt}/{MAX_ATTEMPTS}\n"
                    f"Основная цель {target:.2f}x продолжает проверяться.",
                )

            if attempt >= MAX_ATTEMPTS:
                finish_signal(sig["id"], "LOSS", attempt, best, insurance_hit)
                on_engine_loss(sig["engine"])
                pause_note = ""
                if engine_paused(sig["engine"]):
                    pause_note = f"\n⏸ После 2 неудач: пауза {PAUSE_AFTER_2_LOSSES_SECONDS // 60} мин."
                send(
                    GROUP_CHAT_ID,
                    f"❌ <b>{name} — ЦЕЛЬ НЕ ЗАШЛА</b>\n"
                    f"🎯 {target:.2f}x • лучший фактический <b>{best:.2f}x</b> • {MAX_ATTEMPTS} раунда"
                    + (f"\n🛡 Assurance была: {'✅' if insurance_hit else '❌'}" if insurance else "")
                    + pause_note,
                )
            else:
                update_signal_progress(sig["id"], attempt, best, insurance_hit)


# ============================================================
# TELEGRAM UI
# ============================================================
def mode_keyboard():
    kb = types.ReplyKeyboardMarkup(resize_keyboard=True, row_width=2)
    for key, name in ENGINES.items():
        on = state["enabled"].get(key, False)
        kb.add(types.KeyboardButton(f"{'✅' if on else '▶️'} {name}"))
    kb.row(types.KeyboardButton("🎯 ПОЛУЧИТЬ СИГНАЛ"), types.KeyboardButton("🧪 ПРОВЕРИТЬ ПОДКЛЮЧЕНИЕ"))
    kb.row(types.KeyboardButton("🔄 ПОКАЗАТЬ СТАТУС"), types.KeyboardButton("⛔ ВЫКЛЮЧИТЬ ВСЕ"))
    kb.row(types.KeyboardButton("📊 СТАТИСТИКА"), types.KeyboardButton("🧠 ДИАГНОСТИКА"))
    return kb


def inline_keyboard():
    kb = types.InlineKeyboardMarkup(row_width=2)
    for key, name in ENGINES.items():
        on = state["enabled"].get(key, False)
        kb.add(types.InlineKeyboardButton(f"{'✅' if on else '⛔'} {name}", callback_data=f"eng:{key}"))
    kb.add(types.InlineKeyboardButton("⛔ Выключить всё", callback_data="eng:off"))
    return kb


def fmt_window(result):
    if not result.get("window_start") or not result.get("window_end"):
        return None
    try:
        a = datetime.fromisoformat(result["window_start"]).astimezone(TZ)
        b = datetime.fromisoformat(result["window_end"]).astimezone(TZ)
        return f"{a:%H:%M:%S}–{b:%H:%M:%S}"
    except Exception:
        return None


def signal_text(result, manual=False):
    name = ENGINES[result["engine"]]
    if not result.get("target"):
        return f"⏸ <b>{name}: ПРОПУСК</b>\n{html.escape(str(result.get('reason', 'нет условий')))}"

    lines = [
        f"🚀 <b>{name} — {'РУЧНОЙ ' if manual else ''}СИГНАЛ</b>",
        "",
        f"🧩 Режим: <b>{html.escape(str(result.get('type', '-')))}</b>",
    ]
    if result.get("target_low") and result.get("target_high") and result["band"] == "big":
        lines.append(f"🎯 Диапазон: <b>{result['target_low']:.2f}x–{result['target_high']:.2f}x</b>")
        lines.append(f"🎯 Центральная цель: <b>{result['target']:.2f}x</b>")
    else:
        lines.append(f"🎯 Цель: <b>{result['target']:.2f}x</b>")

    if result.get("insurance"):
        lines.append(f"🛡 ASSURANCE: <b>{result['insurance']:.2f}x</b>")

    if result.get("horizon_min") is not None:
        lines.append(f"🎮 Горизонт: <b>{result['horizon_min']}–{result['horizon_max']} раундов</b>")

    window = fmt_window(result)
    if window:
        lines.append(f"🕐 TIME WINDOW: <b>{window}</b>")

    lines += [
        f"⏱ Timing: <b>{html.escape(str(result.get('timing', '-')))}</b>",
        f"🧠 Confidence: <b>{result['confidence']}%</b> <i>(raw {result.get('confidence_raw', result['confidence'])}%)</i>",
        f"🔎 {html.escape(str(result.get('reason', '')))}",
        f"⏰ {now_kyiv():%H:%M:%S} Киев",
        f"🧪 Факт-проверка: следующие {MAX_ATTEMPTS} завершённых раунда.",
    ]
    return "\n".join(lines)


def status_text():
    lines = ["🤖 <b>LUCKYJET KILLER FUSION V5</b>", ""]
    for key, name in ENGINES.items():
        paused = engine_paused(key)
        status = "⏸ ПАУЗА" if paused else ("✅ ВКЛ" if state["enabled"].get(key) else "⛔ ВЫКЛ")
        lines.append(f"{status} — <b>{name}</b>")
    lines += [
        "",
        f"AUTO threshold: <b>{CONFIDENCE_MIN}%</b>",
        f"Anti-spam: <b>{SIGNAL_COOLDOWN_SECONDS} сек</b>",
        f"Validation: <b>{MAX_ATTEMPTS} раунда</b>",
        f"2 LOSE → pause: <b>{PAUSE_AFTER_2_LOSSES_SECONDS // 60} мин</b>",
        f"SQLite: <code>{html.escape(DB_PATH)}</code>",
    ]
    return "\n".join(lines)


def connection_check_text():
    lines = ["🧪 <b>ПРОВЕРКА ПОДКЛЮЧЕНИЯ</b>", ""]
    try:
        me = bot.get_me()
        lines.append(f"✅ Telegram: @{html.escape(me.username or 'bot')}")
    except Exception as exc:
        lines.append(f"❌ Telegram: {html.escape(type(exc).__name__ + ': ' + str(exc))}")
    try:
        rows = fetch_history(5)
        lines.append(f"✅ LuckyJet LIVE: {len(rows)} раундов")
        lines.append("Последние: " + " • ".join(f"{r['coef']:.2f}x" for r in rows[:5]))
    except Exception as exc:
        lines.append(f"❌ LuckyJet LIVE: {html.escape(type(exc).__name__ + ': ' + str(exc))}")
    try:
        with db_lock, db_connect() as con:
            con.execute("SELECT 1").fetchone()
        lines.append("✅ SQLite: OK")
    except Exception as exc:
        lines.append(f"❌ SQLite: {html.escape(str(exc))}")
    return "\n".join(lines)


def diagnostics_text():
    try:
        rows = fetch_history()
        f = feature_pack(rows)
    except Exception as exc:
        return f"❌ Диагностика: {html.escape(str(exc))}"
    sec = recent_round_seconds()
    lines = [
        "🧠 <b>ДИАГНОСТИКА РЫНКА</b>", "",
        f"Последние: {' • '.join(f'{x:.2f}x' for x in f['last'][:10])}",
        f"gap 10/20/50x: <b>{f['gap10']}/{f['gap20']}/{f['gap50']}</b>",
        f"median interval 10/20/50x: <b>{f['i10'].get('median')}/{f['i20'].get('median')}/{f['i50'].get('median')}</b>",
        f"pattern small/big: <b>{f['pattern_small']:.2f}/{f['pattern_big']:.2f}</b>",
        f"stability: <b>{f['stability']}</b> ({f['stability_score']:.2f})",
        f"time score: <b>{f['time_score']:.2f}</b>",
        f"live cadence: <b>{f'{sec:.1f}s' if sec else 'ещё не обучен'}</b>",
    ]
    return "\n".join(lines)


def send(chat_id, text, **kwargs):
    return bot.send_message(chat_id, text, disable_web_page_preview=True, **kwargs)


@bot.message_handler(commands=["start"])
def cmd_start(message):
    send(
        message.chat.id,
        "🚀 <b>LUCKYJET KILLER FUSION V5 RU</b>\n\n"
        "4 независимых режима. KILLER FUSION требует несколько совпавших признаков; "
        "COMBINE требует согласия GROSSE + KILLER.\n"
        "Все результаты сохраняются в SQLite и используются только для калибровки confidence.",
        reply_markup=mode_keyboard(),
    )


@bot.message_handler(commands=["switch", "bots"])
def cmd_switch(message):
    send(message.chat.id, status_text(), reply_markup=inline_keyboard())


@bot.message_handler(commands=["check"])
def cmd_check(message):
    send(message.chat.id, connection_check_text(), reply_markup=mode_keyboard())


@bot.message_handler(commands=["stats"])
def cmd_stats(message):
    send(message.chat.id, db_stats_text(), reply_markup=mode_keyboard())


@bot.message_handler(commands=["diag"])
def cmd_diag(message):
    send(message.chat.id, diagnostics_text(), reply_markup=mode_keyboard())


@bot.message_handler(commands=["signal"])
def cmd_signal(message):
    keys = enabled_engines()
    if not keys:
        return send(message.chat.id, "⛔ Все режимы выключены.", reply_markup=mode_keyboard())
    try:
        rows = fetch_history()
        for key in keys:
            result = run_engine(key, rows)
            send(message.chat.id, signal_text(result, manual=True))
    except Exception as exc:
        send(message.chat.id, f"❌ Ошибка: <code>{html.escape(type(exc).__name__ + ': ' + str(exc))}</code>")


@bot.callback_query_handler(func=lambda c: c.data and c.data.startswith("eng:"))
def callback_engine(call):
    action = call.data.split(":", 1)[1]
    if action == "off":
        disable_all()
        bot.answer_callback_query(call.id, "Все режимы выключены")
    elif action in ENGINES:
        on = toggle_engine(action)
        bot.answer_callback_query(call.id, f"{ENGINES[action]}: {'ВКЛ' if on else 'ВЫКЛ'}")
    try:
        bot.edit_message_text(
            status_text(), call.message.chat.id, call.message.message_id,
            reply_markup=inline_keyboard(), parse_mode="HTML",
        )
    except Exception:
        pass


@bot.message_handler(func=lambda m: bool(m.text) and (
    any(m.text.endswith(name) for name in ENGINES.values()) or
    m.text in {
        "🎯 ПОЛУЧИТЬ СИГНАЛ", "🧪 ПРОВЕРИТЬ ПОДКЛЮЧЕНИЕ", "🔄 ПОКАЗАТЬ СТАТУС",
        "⛔ ВЫКЛЮЧИТЬ ВСЕ", "📊 СТАТИСТИКА", "🧠 ДИАГНОСТИКА",
    }
))
def handle_buttons(message):
    text = message.text.strip()
    if text == "🎯 ПОЛУЧИТЬ СИГНАЛ":
        return cmd_signal(message)
    if text == "🧪 ПРОВЕРИТЬ ПОДКЛЮЧЕНИЕ":
        return cmd_check(message)
    if text == "🔄 ПОКАЗАТЬ СТАТУС":
        return send(message.chat.id, status_text(), reply_markup=mode_keyboard())
    if text == "📊 СТАТИСТИКА":
        return cmd_stats(message)
    if text == "🧠 ДИАГНОСТИКА":
        return cmd_diag(message)
    if text == "⛔ ВЫКЛЮЧИТЬ ВСЕ":
        disable_all()
        return send(message.chat.id, "⛔ Все режимы выключены.", reply_markup=mode_keyboard())
    for key, name in ENGINES.items():
        if text.endswith(name):
            on = toggle_engine(key)
            return send(
                message.chat.id,
                f"{'✅' if on else '⛔'} <b>{name}</b>: {'ВКЛЮЧЕН' if on else 'ВЫКЛЮЧЕН'}",
                reply_markup=mode_keyboard(),
            )


# ============================================================
# LIVE LOOP
# ============================================================
def live_loop():
    while True:
        try:
            rows = fetch_history()
            newest = rows[0]
            with state_lock:
                if newest["id"] != state.get("last_round_id"):
                    state["last_round_id"] = newest["id"]
                    save_round(newest)
                    process_pending(newest)

                    if AUTO_SIGNALS:
                        for key in enabled_engines():
                            result = run_engine(key, rows)
                            if can_auto_signal(key, result):
                                send(GROUP_CHAT_ID, signal_text(result))
                                insert_signal(result, newest["id"])
                                state["last_signal_at"][key] = time.time()

                    save_state()
        except Exception as exc:
            print(f"[{now_kyiv():%Y-%m-%d %H:%M:%S}] LIVE ERROR: {exc}")
        time.sleep(POLL_SECONDS)


def main():
    init_db()
    try:
        bot.remove_webhook()
    except Exception:
        pass
    try:
        send(
            GROUP_CHAT_ID,
            "✅ <b>LUCKYJET KILLER FUSION V5 RU запущен</b>\n"
            "PETIT / GROSSE CÔTE / KILLER FUSION / COMBINE\n"
            "SQLite обучение и факт-проверка активны.",
            reply_markup=mode_keyboard(),
        )
    except Exception as exc:
        print("Telegram startup error:", exc)

    threading.Thread(target=live_loop, daemon=True, name="luckyjet-killer-fusion-v5-live").start()
    bot.infinity_polling(skip_pending=True, timeout=30, long_polling_timeout=30)


if __name__ == "__main__":
    main()
