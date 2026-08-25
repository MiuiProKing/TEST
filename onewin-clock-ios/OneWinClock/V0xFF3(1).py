#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
V0xFF3 — GROSSE CÔTE / ASSURANCE analyzer for Lucky Jet-style crash histories.

What it does:
- Polls a public/history JSON endpoint you configure yourself.
- Tracks unique completed rounds.
- Learns observed intervals between 30x+, 100x+, and 140x+ events.
- Builds observation windows from historical interval medians/spread.
- Sends Telegram status messages and validates outcomes inside windows.

Important:
Crash-game outcomes are not reliably predictable from prior multipliers alone.
This script is an analytics/backtesting/alerting tool, not a guarantee of future results.

Environment variables:
  V0XFF3_BOT_TOKEN        Telegram bot token
  V0XFF3_CHAT_ID          Telegram chat/group id
  V0XFF3_HISTORY_URL      Public JSON history endpoint
  V0XFF3_CUSTOMER_ID      Optional request header
  V0XFF3_SESSION_ID       Optional request header
  V0XFF3_POLL_SEC         Poll interval, default 4
  V0XFF3_TZ               Timezone, default Europe/Kyiv
"""

import os
import sys
import time
import json
import math
import signal
import sqlite3
import statistics
import threading
from dataclasses import dataclass
from datetime import datetime, timedelta
from typing import Any, Dict, Iterable, List, Optional, Tuple

import requests

try:
    from zoneinfo import ZoneInfo
except ImportError:
    ZoneInfo = None


APP_NAME = "V0xFF3"
DB_FILE = os.getenv("V0XFF3_DB", "v0xff3.sqlite3")

BOT_TOKEN = os.getenv("V0XFF3_BOT_TOKEN", "").strip()
CHAT_ID = os.getenv("V0XFF3_CHAT_ID", "").strip()
HISTORY_URL = os.getenv(
    "V0XFF3_HISTORY_URL",
    "https://crash-gateway-grm-cr.100hp.app/history",
).strip()

CUSTOMER_ID = os.getenv(
    "V0XFF3_CUSTOMER_ID",
    "077dee8d-c923-4c02-9bee-757573662e69",
).strip()
SESSION_ID = os.getenv(
    "V0XFF3_SESSION_ID",
    "00000000-0000-4000-8000-000000000000",
).strip()

POLL_SEC = max(2, int(os.getenv("V0XFF3_POLL_SEC", "4")))
TZ_NAME = os.getenv("V0XFF3_TZ", "Europe/Kyiv")
TZ = ZoneInfo(TZ_NAME) if ZoneInfo else None

ASSURANCE_X = 30.0
HIGH_X = 100.0
TARGET_X = 140.0

MIN_EVENTS_FOR_WINDOW = 4
DEFAULT_WINDOW_MINUTES = 3
RESERVE_GAP_MINUTES = 8
MAX_WINDOW_MINUTES = 4
MIN_WINDOW_MINUTES = 2

running = True
engine_enabled = True
last_update_id = 0


@dataclass
class Round:
    round_id: str
    coefficient: float
    ts: datetime


@dataclass
class SignalWindow:
    created_at: datetime
    primary_start: datetime
    primary_end: datetime
    reserve_start: datetime
    reserve_end: datetime
    confidence: int
    based_on: str
    resolved: bool = False
    result: str = ""


def now() -> datetime:
    return datetime.now(TZ) if TZ else datetime.now().astimezone()


def fmt_dt(dt: datetime) -> str:
    return dt.astimezone(TZ).strftime("%H:%M:%S") if TZ else dt.strftime("%H:%M:%S")


def fmt_hm(dt: datetime) -> str:
    return dt.astimezone(TZ).strftime("%H:%M") if TZ else dt.strftime("%H:%M")


def tg_api(method: str) -> str:
    return f"https://api.telegram.org/bot{BOT_TOKEN}/{method}"


def send_message(text: str, reply_markup: Optional[dict] = None) -> None:
    if not BOT_TOKEN or not CHAT_ID:
        print(text, flush=True)
        return
    payload = {
        "chat_id": CHAT_ID,
        "text": text,
        "parse_mode": "HTML",
        "disable_web_page_preview": True,
    }
    if reply_markup:
        payload["reply_markup"] = json.dumps(reply_markup, ensure_ascii=False)
    try:
        r = requests.post(tg_api("sendMessage"), data=payload, timeout=15)
        r.raise_for_status()
    except Exception as e:
        print(f"[telegram] {e}", file=sys.stderr, flush=True)


def keyboard() -> dict:
    return {
        "inline_keyboard": [
            [
                {"text": "🔥 V0xFF3 ВКЛ", "callback_data": "on"},
                {"text": "⛔ V0xFF3 ВЫКЛ", "callback_data": "off"},
            ],
            [
                {"text": "📊 Статистика", "callback_data": "stats"},
                {"text": "🔌 Проверка", "callback_data": "check"},
            ],
        ]
    }


def init_db() -> sqlite3.Connection:
    conn = sqlite3.connect(DB_FILE, check_same_thread=False)
    conn.execute("""
        CREATE TABLE IF NOT EXISTS rounds (
            round_id TEXT PRIMARY KEY,
            coefficient REAL NOT NULL,
            ts TEXT NOT NULL
        )
    """)
    conn.execute("""
        CREATE TABLE IF NOT EXISTS signals (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            created_at TEXT NOT NULL,
            primary_start TEXT NOT NULL,
            primary_end TEXT NOT NULL,
            reserve_start TEXT NOT NULL,
            reserve_end TEXT NOT NULL,
            confidence INTEGER NOT NULL,
            based_on TEXT NOT NULL,
            result TEXT DEFAULT ''
        )
    """)
    conn.commit()
    return conn


DB = init_db()


def parse_ts(value: Any) -> datetime:
    if isinstance(value, (int, float)):
        # Heuristic: milliseconds vs seconds.
        if value > 10_000_000_000:
            value = value / 1000.0
        return datetime.fromtimestamp(float(value), tz=TZ)

    if isinstance(value, str):
        s = value.strip()
        if s.isdigit():
            return parse_ts(int(s))
        try:
            s = s.replace("Z", "+00:00")
            dt = datetime.fromisoformat(s)
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=TZ)
            return dt.astimezone(TZ)
        except Exception:
            pass

    return now()


def first_present(d: Dict[str, Any], keys: Iterable[str]) -> Any:
    for k in keys:
        if k in d and d[k] is not None:
            return d[k]
    return None


def normalize_round(item: Dict[str, Any]) -> Optional[Round]:
    rid = first_present(item, ["id", "round_id", "roundId", "_id", "gameId"])
    coeff = first_present(
        item,
        ["topCoefficient", "top_coefficient", "coefficient", "multiplier", "value"]
    )
    if coeff is None:
        finals = first_present(item, ["finalValues", "final_values"])
        if isinstance(finals, list) and finals:
            coeff = max(finals)

    ts = first_present(
        item,
        ["createdAt", "created_at", "timestamp", "time", "start_time", "endedAt", "ended_at"]
    )

    if rid is None or coeff is None:
        return None

    try:
        c = float(coeff)
    except Exception:
        return None

    return Round(str(rid), c, parse_ts(ts))


def extract_items(data: Any) -> List[Dict[str, Any]]:
    if isinstance(data, list):
        return [x for x in data if isinstance(x, dict)]

    if isinstance(data, dict):
        for key in ["history", "rounds", "data", "items", "results"]:
            v = data.get(key)
            if isinstance(v, list):
                return [x for x in v if isinstance(x, dict)]
            if isinstance(v, dict):
                for key2 in ["history", "rounds", "items", "results"]:
                    vv = v.get(key2)
                    if isinstance(vv, list):
                        return [x for x in vv if isinstance(x, dict)]

    return []


def fetch_history() -> List[Round]:
    if not HISTORY_URL:
        raise RuntimeError("V0XFF3_HISTORY_URL не задан")

    headers = {
        "Accept": "application/json",
        "User-Agent": "V0xFF3/1.0",
    }
    if CUSTOMER_ID:
        headers["customer-id"] = CUSTOMER_ID
    if SESSION_ID:
        headers["session-id"] = SESSION_ID

    r = requests.get(HISTORY_URL, headers=headers, timeout=15)
    r.raise_for_status()
    data = r.json()

    out: List[Round] = []
    for item in extract_items(data):
        rr = normalize_round(item)
        if rr:
            out.append(rr)

    out.sort(key=lambda x: x.ts)
    return out


def save_round(rr: Round) -> bool:
    try:
        DB.execute(
            "INSERT INTO rounds(round_id, coefficient, ts) VALUES(?,?,?)",
            (rr.round_id, rr.coefficient, rr.ts.isoformat()),
        )
        DB.commit()
        return True
    except sqlite3.IntegrityError:
        return False


def load_rounds(limit: int = 5000) -> List[Round]:
    rows = DB.execute(
        "SELECT round_id, coefficient, ts FROM rounds ORDER BY ts DESC LIMIT ?",
        (limit,),
    ).fetchall()
    out = [
        Round(rid, float(c), datetime.fromisoformat(ts).astimezone(TZ))
        for rid, c, ts in reversed(rows)
    ]
    return out


def event_rounds(threshold: float, rounds: List[Round]) -> List[Round]:
    return [r for r in rounds if r.coefficient >= threshold]


def intervals_minutes(events: List[Round]) -> List[float]:
    return [
        max(0.0, (b.ts - a.ts).total_seconds() / 60.0)
        for a, b in zip(events, events[1:])
        if b.ts > a.ts
    ]


def robust_interval_stats(values: List[float]) -> Optional[Tuple[float, float]]:
    vals = [v for v in values if 0.25 <= v <= 24 * 60]
    if len(vals) < MIN_EVENTS_FOR_WINDOW - 1:
        return None

    med = statistics.median(vals)
    if len(vals) >= 4:
        q = statistics.quantiles(vals, n=4, method="inclusive")
        spread = max(1.0, (q[2] - q[0]) / 2.0)
    else:
        spread = max(1.0, statistics.pstdev(vals))

    return med, spread


def last_event_age(threshold: float, rounds: List[Round]) -> Optional[timedelta]:
    evs = event_rounds(threshold, rounds)
    if not evs:
        return None
    return now() - evs[-1].ts


def rounds_since(threshold: float, rounds: List[Round]) -> Optional[int]:
    for idx in range(len(rounds) - 1, -1, -1):
        if rounds[idx].coefficient >= threshold:
            return len(rounds) - 1 - idx
    return None


def confidence_score(intervals: List[float]) -> int:
    # Descriptive regularity score, NOT a calibrated win probability.
    if len(intervals) < 3:
        return 35

    med = statistics.median(intervals)
    if med <= 0:
        return 35

    mad = statistics.median([abs(x - med) for x in intervals]) if intervals else med
    regularity = max(0.0, min(1.0, 1.0 - mad / max(med, 1e-6)))
    sample = min(1.0, len(intervals) / 20.0)
    score = 35 + int(35 * regularity + 20 * sample)
    return max(35, min(90, score))


def build_window(rounds: List[Round]) -> Optional[SignalWindow]:
    tiers = [
        (TARGET_X, "140X"),
        (HIGH_X, "100X"),
        (ASSURANCE_X, "30X"),
    ]

    chosen = None
    for threshold, label in tiers:
        evs = event_rounds(threshold, rounds)
        ints = intervals_minutes(evs)
        stats = robust_interval_stats(ints)
        if stats and evs:
            chosen = (threshold, label, evs, ints, stats)
            break

    if not chosen:
        return None

    threshold, label, evs, ints, (med, spread) = chosen
    last = evs[-1].ts

    center = last + timedelta(minutes=med)
    width = int(round(max(MIN_WINDOW_MINUTES, min(MAX_WINDOW_MINUTES, spread))))
    half = timedelta(minutes=width / 2)

    p_start = center - half
    p_end = center + half

    # Never issue a window that has already fully passed.
    if p_end <= now():
        cycles = max(1, math.ceil((now() - center).total_seconds() / max(60.0, med * 60.0)))
        center = center + timedelta(minutes=med * cycles)
        p_start = center - half
        p_end = center + half

    r_start = p_start + timedelta(minutes=RESERVE_GAP_MINUTES)
    r_end = p_end + timedelta(minutes=RESERVE_GAP_MINUTES)

    return SignalWindow(
        created_at=now(),
        primary_start=p_start,
        primary_end=p_end,
        reserve_start=r_start,
        reserve_end=r_end,
        confidence=confidence_score(ints[-20:]),
        based_on=f"{label}: median={med:.1f}m, samples={len(ints)}",
    )


def signal_text(sw: SignalWindow, rounds: List[Round]) -> str:
    a30 = last_event_age(30, rounds)
    a100 = last_event_age(100, rounds)
    a140 = last_event_age(140, rounds)

    def age_str(td: Optional[timedelta]) -> str:
        if td is None:
            return "нет данных"
        s = max(0, int(td.total_seconds()))
        return f"{s//60} мин {s%60} сек"

    r140 = rounds_since(140, rounds)
    return (
        f"🔥 <b>{APP_NAME} — GROSSE CÔTE</b>\n\n"
        f"🎯 ЦЕЛЬ: <b>{TARGET_X:.0f}X</b>\n"
        f"🛡 ASSURANCE: <b>{ASSURANCE_X:.0f}X</b>\n\n"
        f"⏰ ОСНОВНОЕ ОКНО\n"
        f"<b>{fmt_hm(sw.primary_start)}–{fmt_hm(sw.primary_end)}</b>\n\n"
        f"⏰ РЕЗЕРВНОЕ ОКНО\n"
        f"<b>{fmt_hm(sw.reserve_start)}–{fmt_hm(sw.reserve_end)}</b>\n\n"
        f"📊 Индекс регулярности: <b>{sw.confidence}%</b>\n"
        f"🧠 Основа: {sw.based_on}\n\n"
        f"Последний 30X+: {age_str(a30)}\n"
        f"Последний 100X+: {age_str(a100)}\n"
        f"Последний 140X+: {age_str(a140)}\n"
        f"Раундов после 140X+: {r140 if r140 is not None else 'нет данных'}\n\n"
        f"⚠️ Это статистическое окно по прошлым интервалам, не гарантия исхода."
    )


def status_text(rounds: List[Round]) -> str:
    def cnt(t: float) -> int:
        return len(event_rounds(t, rounds))

    last = rounds[-1] if rounds else None
    return (
        f"📊 <b>{APP_NAME} СТАТИСТИКА</b>\n\n"
        f"Раундов в базе: <b>{len(rounds)}</b>\n"
        f"30X+: <b>{cnt(30)}</b>\n"
        f"100X+: <b>{cnt(100)}</b>\n"
        f"140X+: <b>{cnt(140)}</b>\n"
        f"Последний коэффициент: <b>{last.coefficient:.2f}X</b>"
        if last else
        f"📊 <b>{APP_NAME}</b>\n\nДанных пока нет."
    )


def evaluate_window(sw: SignalWindow, rounds: List[Round]) -> Optional[str]:
    if sw.resolved:
        return sw.result

    relevant = [
        r for r in rounds
        if sw.primary_start <= r.ts <= sw.reserve_end
    ]

    if any(r.coefficient >= TARGET_X for r in relevant):
        return "🔥 CÔTE 140X VALIDÉE"

    # Only finalize assurance after reserve window has ended.
    if now() > sw.reserve_end:
        if any(r.coefficient >= ASSURANCE_X for r in relevant):
            best = max(r.coefficient for r in relevant)
            return f"🛡 ASSURANCE 30X VALIDÉE — максимум {best:.2f}X"
        best = max((r.coefficient for r in relevant), default=0.0)
        return f"❌ СИГНАЛ НЕ ЗАШЁЛ — максимум {best:.2f}X"

    return None


def save_signal(sw: SignalWindow) -> int:
    cur = DB.execute(
        """
        INSERT INTO signals(
            created_at, primary_start, primary_end,
            reserve_start, reserve_end, confidence, based_on
        ) VALUES(?,?,?,?,?,?,?)
        """,
        (
            sw.created_at.isoformat(),
            sw.primary_start.isoformat(),
            sw.primary_end.isoformat(),
            sw.reserve_start.isoformat(),
            sw.reserve_end.isoformat(),
            sw.confidence,
            sw.based_on,
        ),
    )
    DB.commit()
    return int(cur.lastrowid)


def resolve_signal(signal_id: int, result: str) -> None:
    DB.execute("UPDATE signals SET result=? WHERE id=?", (result, signal_id))
    DB.commit()


def recent_open_signal() -> Optional[Tuple[int, SignalWindow]]:
    row = DB.execute(
        """
        SELECT id, created_at, primary_start, primary_end,
               reserve_start, reserve_end, confidence, based_on, result
        FROM signals
        WHERE result=''
        ORDER BY id DESC LIMIT 1
        """
    ).fetchone()
    if not row:
        return None

    sid, created, ps, pe, rs, re, conf, based, result = row
    sw = SignalWindow(
        created_at=datetime.fromisoformat(created).astimezone(TZ),
        primary_start=datetime.fromisoformat(ps).astimezone(TZ),
        primary_end=datetime.fromisoformat(pe).astimezone(TZ),
        reserve_start=datetime.fromisoformat(rs).astimezone(TZ),
        reserve_end=datetime.fromisoformat(re).astimezone(TZ),
        confidence=int(conf),
        based_on=based,
        resolved=bool(result),
        result=result or "",
    )
    return int(sid), sw


def should_create_signal(sw: SignalWindow) -> bool:
    existing = recent_open_signal()
    if existing:
        return False

    # Do not spam far-away observations.
    lead = (sw.primary_start - now()).total_seconds() / 60
    return 0 <= lead <= 20


def poll_loop() -> None:
    global engine_enabled

    while running:
        try:
            fetched = fetch_history()
            new_count = 0
            for rr in fetched:
                if save_round(rr):
                    new_count += 1

            rounds = load_rounds()

            open_sig = recent_open_signal()
            if open_sig:
                sid, sw = open_sig
                result = evaluate_window(sw, rounds)
                if result:
                    resolve_signal(sid, result)
                    send_message(f"{result}\n\n🧠 {APP_NAME} начинает новый анализ.", keyboard())

            if engine_enabled and not recent_open_signal():
                sw = build_window(rounds)
                if sw and should_create_signal(sw):
                    save_signal(sw)
                    send_message(signal_text(sw, rounds), keyboard())

            if new_count:
                last = rounds[-1]
                print(
                    f"[{fmt_dt(now())}] +{new_count} rounds | "
                    f"last={last.coefficient:.2f}X id={last.round_id}",
                    flush=True,
                )

        except Exception as e:
            print(f"[poll] {type(e).__name__}: {e}", file=sys.stderr, flush=True)

        time.sleep(POLL_SEC)


def answer_callback(callback_id: str, text: str = "") -> None:
    if not BOT_TOKEN:
        return
    try:
        requests.post(
            tg_api("answerCallbackQuery"),
            data={"callback_query_id": callback_id, "text": text[:180]},
            timeout=10,
        )
    except Exception:
        pass


def command_loop() -> None:
    global last_update_id, engine_enabled

    if not BOT_TOKEN:
        return

    while running:
        try:
            params = {"timeout": 25, "offset": last_update_id + 1}
            r = requests.get(tg_api("getUpdates"), params=params, timeout=35)
            r.raise_for_status()
            data = r.json()

            for upd in data.get("result", []):
                last_update_id = max(last_update_id, upd["update_id"])

                msg = upd.get("message") or {}
                text = (msg.get("text") or "").strip().lower()
                chat_id = str((msg.get("chat") or {}).get("id", ""))

                # Restrict command handling to configured chat.
                if chat_id and CHAT_ID and chat_id != CHAT_ID:
                    continue

                if text in ("/start", "/menu"):
                    send_message(
                        f"🔥 <b>{APP_NAME}</b>\n\n"
                        f"Отдельный анализатор GROSSE CÔTE / ASSURANCE.\n"
                        f"Цель: {TARGET_X:.0f}X\n"
                        f"Страховка: {ASSURANCE_X:.0f}X",
                        keyboard(),
                    )

                elif text == "/stats":
                    send_message(status_text(load_rounds()), keyboard())

                cb = upd.get("callback_query")
                if cb:
                    cdata = cb.get("data", "")
                    callback_id = cb.get("id", "")
                    cb_chat = str((((cb.get("message") or {}).get("chat") or {}).get("id", "")))

                    if cb_chat and CHAT_ID and cb_chat != CHAT_ID:
                        answer_callback(callback_id, "Недоступно")
                        continue

                    if cdata == "on":
                        engine_enabled = True
                        answer_callback(callback_id, "V0xFF3 включён")
                        send_message("✅ V0xFF3 включён", keyboard())

                    elif cdata == "off":
                        engine_enabled = False
                        answer_callback(callback_id, "V0xFF3 выключен")
                        send_message("⛔ V0xFF3 выключен", keyboard())

                    elif cdata == "stats":
                        answer_callback(callback_id, "Статистика обновлена")
                        send_message(status_text(load_rounds()), keyboard())

                    elif cdata == "check":
                        ok = bool(HISTORY_URL)
                        answer_callback(callback_id, "Проверяю")
                        try:
                            rows = fetch_history() if ok else []
                            send_message(
                                f"🔌 <b>ПРОВЕРКА {APP_NAME}</b>\n\n"
                                f"History URL: {'✅' if HISTORY_URL else '❌'}\n"
                                f"Telegram: {'✅' if BOT_TOKEN and CHAT_ID else '⚠️ консоль'}\n"
                                f"Получено раундов: <b>{len(rows)}</b>",
                                keyboard(),
                            )
                        except Exception as e:
                            send_message(
                                f"❌ Ошибка подключения:\n<code>{type(e).__name__}: {e}</code>",
                                keyboard(),
                            )

        except Exception as e:
            print(f"[commands] {type(e).__name__}: {e}", file=sys.stderr, flush=True)
            time.sleep(3)


def stop_handler(signum, frame):
    global running
    running = False


def main() -> None:
    signal.signal(signal.SIGINT, stop_handler)
    signal.signal(signal.SIGTERM, stop_handler)

    print(f"{APP_NAME} starting...")
    print(f"DB: {DB_FILE}")
    print(f"TZ: {TZ_NAME}")
    print(f"History: {HISTORY_URL or 'NOT SET'}")

    if not HISTORY_URL:
        print(
            "\nERROR: set V0XFF3_HISTORY_URL to a public history JSON endpoint.",
            file=sys.stderr,
        )
        sys.exit(2)

    send_message(
        f"🚀 <b>{APP_NAME} ЗАПУЩЕН</b>\n\n"
        f"🎯 CÔTE: {TARGET_X:.0f}X\n"
        f"🛡 ASSURANCE: {ASSURANCE_X:.0f}X\n"
        f"🧠 Анализ интервалов включён.",
        keyboard(),
    )

    t = threading.Thread(target=command_loop, daemon=True)
    t.start()

    poll_loop()


if __name__ == "__main__":
    main()
