# ============================================================
# LuckyJet BABEL ALL-IN-ONE V30
# Consolidated build: BABEL / PETIT / GRAND / PRO4 /
# CALCUL GROSSE COTE / ALLPREDICTOR / KILLER / JOKERPCS /
# COMBINE50 / MONTANTE + LIVE validation.
#
# Public deterministic predictor reference retained separately:
# luckyjet_FULL_CODE_HISTORY_TELEGRAM_V22.js
# ============================================================

#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""LuckyJet MultiEngine v10 — русская версия + JOKERPCS/BABEL public artifacts.

Движки:
- BABEL: реконструированная эвристика.
- ALLPREDICTOR: история -> цель -> уверенность -> момент входа -> проверка до 3 раундов.
- ALLPREDICTOR KILLER: отключён до появления подтверждённой логики.

Секреты читаются из переменных окружения и не записаны в коде.
"""
from __future__ import annotations

import json
import math
import os
import random
import re
import statistics
import time
import urllib.parse
import urllib.request
from dataclasses import dataclass, asdict
from pathlib import Path
from typing import Dict, List, Optional, Tuple

BOT_TOKEN = os.getenv("TELEGRAM_BOT_TOKEN", "").strip()
CHAT_ID = os.getenv("TELEGRAM_CHAT_ID", "-1003959529321").strip()
SESSION_ID = os.getenv("LJ_SESSION_ID", "00000000-0000-4000-8000-000000000000").strip()
CUSTOMER_ID = os.getenv("LJ_CUSTOMER_ID", "077dee8d-c923-4c02-9bee-757573662e69").strip()
HISTORY_URL = os.getenv(
    "LJ_HISTORY_URL",
    "https://crash-gateway-grm-cr.100hp.app/history"
).strip()

# Дополнительные LIVE-источники можно перечислить через запятую.
# Пример: LJ_HISTORY_FALLBACKS=https://site1/history,https://site2/history
HISTORY_FALLBACKS = [
    x.strip()
    for x in os.getenv("LJ_HISTORY_FALLBACKS", "").split(",")
    if x.strip()
]

# Необязательный резервный API Parse.bot.
# Если PARSE_API_KEY не задан, этот источник просто пропускается.
PARSE_API_KEY = os.getenv("PARSE_API_KEY", "").strip()
PARSE_HISTORY_URL = os.getenv(
    "PARSE_HISTORY_URL",
    "https://api.parse.bot/scraper/dfcd37a4-42ee-4914-824f-2651f659871d/get_rounds_history"
).strip()

# Официально документированный API AllPredictor.
# Создай ключ в Dashboard AllPredictor и задай его как ALLPREDICTOR_API_KEY.
ALLPREDICTOR_API_KEY = os.getenv("ALLPREDICTOR_API_KEY", "ap_c3739662fa0889c81929d0d0900e3793841f4c385cc6c152").strip()
ALLPREDICTOR_COEFFICIENTS_URL = os.getenv(
    "ALLPREDICTOR_COEFFICIENTS_URL",
    "https://allpredictor.com/api/v1/luckyjet/coefficients?limit=20"
).strip()
ALLPREDICTOR_PREDICT_URL = os.getenv(
    "ALLPREDICTOR_PREDICT_URL",
    "https://allpredictor.com/api/v1/luckyjet/predict"
).strip()

POLL_SECONDS = max(1.5, float(os.getenv("POLL_SECONDS", "2.5")))
STATE_PATH = Path(os.getenv("BOT_STATE_FILE", "multiengine_state.json"))

MIN_CONFIDENCE = int(os.getenv("MIN_CONFIDENCE", "70"))
ANTI_SPAM_SECONDS = int(os.getenv("ANTI_SPAM_SECONDS", "60"))

BIG_TIME_WINDOWS = [(59,2),(4,7),(7,10),(14,17),(17,20),(27,30),(30,33),(45,47),(50,52),(57,59)]
BIG_FAVORABLE_HOURS = [(11,13),(16,19),(21,23),(1,2)]

ENGINE_LABELS = {
    "babel": "BABEL",
    "petit": "BABEL PETIT",
    "grand": "BABEL GRAND",
    "twotime": "BABEL 2X TIME",
    "threextime": "BABEL 3X TIME",
    "erick": "ERICK JET SIGNAL",
    "calculbig": "CALCUL DE GROSSE CÔTE",
    "pro4": "BABEL PRO 4",
    "pro4range": "BABEL PRO 4 RANGE",
    "allpredictor": "ALLPREDICTOR",
    "bigtime": "HEURE DE GROSSE COTE 10X–100X",
    "killer": "ALLPREDICTOR KILLER",
    "jokerpcs": "JOKERPCS GROSSE CÔTE",
    "combine50": "LUCKYJET COMBINÉ 50",
    "montantev1": "MONTANTE BOT BABEL V1",
}

DEFAULT_STATE = {
    "engines": {"babel": False, "petit": False, "grand": False, "twotime": False, "threextime": False, "erick": False, "calculbig": False, "pro4": False, "pro4range": False, "allpredictor": True, "bigtime": False, "killer": False, "jokerpcs": False, "combine50": False, "montantev1": False},
    "last_round_id": None,
    "pending": [],
    "stats": {
        "babel": {"win": 0, "lose": 0},
        "petit": {"win": 0, "lose": 0},
        "grand": {"win": 0, "lose": 0},
        "twotime": {"win": 0, "lose": 0},
        "threextime": {"win": 0, "lose": 0},
        "erick": {"win": 0, "lose": 0},
        "calculbig": {"win": 0, "lose": 0},
        "pro4": {"win": 0, "lose": 0},
        "pro4range": {"win": 0, "lose": 0},
        "allpredictor": {"win": 0, "lose": 0},
        "bigtime": {"win": 0, "lose": 0},
        "killer": {"win": 0, "lose": 0},
        "jokerpcs": {"win": 0, "lose": 0},
        "combine50": {"win": 0, "lose": 0},
        "montantev1": {"win": 0, "lose": 0},
    },
    "telegram_offset": 0,
    "last_sent_at": {},
    "last_signal_round": {"babel": None, "petit": None, "grand": None, "twotime": None, "threextime": None, "erick": None, "calculbig": None, "pro4": None, "pro4range": None, "allpredictor": None, "bigtime": None, "killer": None, "jokerpcs": None, "combine50": None, "montantev1": None},
}


def clamp(x: float, lo: float, hi: float) -> float:
    return max(lo, min(hi, x))


def mean(values: List[float]) -> float:
    return statistics.fmean(values) if values else 0.0


def stdev(values: List[float]) -> float:
    return statistics.pstdev(values) if len(values) >= 2 else 0.0


def load_state() -> dict:
    if not STATE_PATH.exists():
        return json.loads(json.dumps(DEFAULT_STATE))
    try:
        data = json.loads(STATE_PATH.read_text("utf-8"))
    except Exception:
        return json.loads(json.dumps(DEFAULT_STATE))

    out = json.loads(json.dumps(DEFAULT_STATE))
    for key in out:
        if key in data:
            out[key] = data[key]

    for eng in ENGINE_LABELS:
        out["engines"].setdefault(eng, DEFAULT_STATE["engines"][eng])
        out["stats"].setdefault(eng, {"win": 0, "lose": 0})
        out["last_signal_round"].setdefault(eng, None)
        out["last_sent_at"].setdefault(eng, 0)

    return out


def save_state(state: dict) -> None:
    tmp = STATE_PATH.with_suffix(STATE_PATH.suffix + ".tmp")
    tmp.write_text(json.dumps(state, ensure_ascii=False, indent=2), "utf-8")
    tmp.replace(STATE_PATH)


@dataclass
class Round:
    id: str
    coefficient: float


@dataclass
class Forecast:
    engine: str
    target: float
    confidence: int
    wait_rounds: int
    validation_rounds: int
    created_after_round_id: str
    reason: str


def normalize_round(row: dict) -> Optional[Round]:
    if not isinstance(row, dict):
        return None

    value = row.get("topCoefficient") if row.get("topCoefficient") is not None else row.get("top_coefficient")
    try:
        coef = float(value)
    except (TypeError, ValueError):
        coef = 0.0

    if coef <= 0:
        vals = row.get("finalValues") if row.get("finalValues") is not None else row.get("final_values")
        if isinstance(vals, list):
            for item in reversed(vals):
                try:
                    n = float(item)
                except (TypeError, ValueError):
                    continue
                if n > 0:
                    coef = n
                    break

    if coef <= 0:
        for key in ("coefficient", "coef", "crash", "value", "multiplier"):
            try:
                n = float(row.get(key, 0))
            except (TypeError, ValueError):
                continue
            if n > 0:
                coef = n
                break

    if coef <= 0 or not math.isfinite(coef):
        return None

    if coef == 1:
        coef = 1.01

    rid = str(
        row.get("id")
        or row.get("roundId")
        or row.get("round_id")
        or row.get("round_id")
        or row.get("hash")
        or ""
    )

    if not rid:
        rid = f"{coef:.2f}:{row.get('createdAt') or row.get('time') or ''}"

    return Round(rid, round(coef, 2))


def _extract_rows(payload) -> list:
    """Достаёт массив раундов из разных форматов API."""
    if isinstance(payload, list):
        return payload

    if not isinstance(payload, dict):
        return []

    # Частые варианты: {"rounds":[...]}, {"data":{"rounds":[...]}},
    # {"data":[...]}, {"history":[...]}, {"result":[...]}.
    for key in ("rounds", "history", "result", "items", "coefficients", "values"):
        value = payload.get(key)
        if isinstance(value, list):
            return value

    data = payload.get("data")
    if isinstance(data, list):
        return data
    if isinstance(data, dict):
        for key in ("rounds", "history", "result", "items", "coefficients", "values"):
            value = data.get(key)
            if isinstance(value, list):
                return value

    return []


def _decode_history(payload, limit: int) -> List[Round]:
    raw_rows = _extract_rows(payload)
    out: List[Round] = []
    seen = set()

    for idx, raw in enumerate(raw_rows):
        if isinstance(raw, (int, float, str)):
            try:
                coef = float(raw)
            except (TypeError, ValueError):
                continue
            raw = {
                "id": f"api:{idx}:{coef}",
                "coefficient": coef,
            }

        r = normalize_round(raw)
        if r and r.id not in seen:
            seen.add(r.id)
            out.append(r)
            if len(out) >= limit:
                break

    return out


def _request_json(url: str, headers: dict, timeout: int = 12):
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=timeout) as response:
        return json.loads(response.read().decode("utf-8"))


def fetch_history(limit: int = 500) -> List[Round]:
    """Получает LIVE-историю с автоматическим резервированием."""
    errors = []

    # 1. Основной источник + дополнительные URL.
    urls = []
    if HISTORY_URL:
        urls.append(HISTORY_URL)
    for u in HISTORY_FALLBACKS:
        if u not in urls:
            urls.append(u)

    # Заголовки специально близки к обычному браузеру:
    # некоторые шлюзы отвечают 403 на "голый" Python-запрос.
    base_headers = {
        "accept": "application/json, text/plain, */*",
        "accept-language": "ru-RU,ru;q=0.9,en;q=0.8",
        "cache-control": "no-cache",
        "pragma": "no-cache",
        "user-agent": (
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) "
            "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 "
            "Mobile/15E148 Safari/604.1"
        ),
        "origin": "https://1win.com",
        "referer": "https://1win.com/",
    }

    if CUSTOMER_ID:
        base_headers["customer-id"] = CUSTOMER_ID
        base_headers["x-customer-id"] = CUSTOMER_ID
    if SESSION_ID:
        base_headers["session-id"] = SESSION_ID
        base_headers["x-session-id"] = SESSION_ID
    if ALLPREDICTOR_API_KEY:
        # Некоторые прокси/API принимают дополнительный ключ.
        # Для самого game history главным остаются session/customer.
        base_headers["X-API-Key"] = ALLPREDICTOR_API_KEY

    for url in urls:
        try:
            payload = _request_json(url, dict(base_headers))
            rows = _decode_history(payload, limit)
            if rows:
                return rows
            errors.append(f"{url}: пустая история")
        except Exception as exc:
            errors.append(f"{url}: {exc}")

    # 2. Официально документированный AllPredictor API.
    # Используется, если задан ALLPREDICTOR_API_KEY.
    if ALLPREDICTOR_API_KEY and ALLPREDICTOR_COEFFICIENTS_URL:
        try:
            payload = _request_json(
                ALLPREDICTOR_COEFFICIENTS_URL,
                {
                    "accept": "application/json",
                    "X-API-Key": ALLPREDICTOR_API_KEY,
                    "user-agent": "LuckyJet-MultiEngine-RU/3.0",
                },
            )
            rows = _decode_history(payload, limit)
            if rows:
                return rows
            errors.append("AllPredictor API: пустая история")
        except Exception as exc:
            errors.append(f"AllPredictor API: {exc}")

    # 3. Резервный управляемый LuckyJet API Parse.
    # Он используется только если пользователь задал PARSE_API_KEY.
    if PARSE_API_KEY and PARSE_HISTORY_URL:
        try:
            payload = _request_json(
                PARSE_HISTORY_URL,
                {
                    "accept": "application/json",
                    "X-API-Key": PARSE_API_KEY,
                    "user-agent": "LuckyJet-MultiEngine-RU/2.0",
                },
            )
            rows = _decode_history(payload, limit)
            if rows:
                return rows
            errors.append("Parse API: пустая история")
        except Exception as exc:
            errors.append(f"Parse API: {exc}")

    # Понятная сводка, а не один непонятный 403.
    if not errors:
        raise RuntimeError("LIVE-источники не настроены")

    short = " | ".join(errors[-4:])
    raise RuntimeError(
        "Все LIVE-источники недоступны. "
        + short
        + (
            " | Задай ALLPREDICTOR_API_KEY или PARSE_API_KEY для резервного API."
            if not ALLPREDICTOR_API_KEY and not PARSE_API_KEY
            else ""
        )
    )



def last_coefficient_text(rows: List[Round]) -> str:
    if not rows:
        return "⚠️ Последний коэффициент пока не получен."
    r = rows[0]
    return (
        "🚀 <b>ПОСЛЕДНИЙ КОЭФФИЦИЕНТ LUCKY JET</b>\n\n"
        f"🎯 <b>{r.coefficient:.2f}X</b>\n"
        f"🆔 <code>{r.id}</code>"
    )

def zone(x: float) -> str:
    if x < 1.50:
        return "B"
    if x < 3.00:
        return "M"
    return "H"


def pattern_probabilities(values_chrono: List[float]) -> Dict[str, float]:
    zones = [zone(x) for x in values_chrono]

    if len(zones) < 10:
        return {"B": 1 / 3, "M": 1 / 3, "H": 1 / 3}

    key = tuple(zones[-4:])
    counts = {"B": 0, "M": 0, "H": 0}
    matches = 0

    for i in range(0, len(zones) - 4):
        if tuple(zones[i:i + 4]) == key:
            counts[zones[i + 4]] += 1
            matches += 1

    if matches < 2:
        return {"B": 1 / 3, "M": 1 / 3, "H": 1 / 3}

    return {k: counts[k] / matches for k in counts}


def ten_x_intervals(values_chrono: List[float]) -> Tuple[List[int], int]:
    idx = [i for i, x in enumerate(values_chrono) if x >= 10.0]
    intervals = [idx[i] - idx[i - 1] for i in range(1, len(idx))]
    gap = len(values_chrono) - 1 - idx[-1] if idx else len(values_chrono)
    return intervals, gap


def allpredictor_forecast(rows: List[Round]) -> Optional[Forecast]:
    # Реконструированная архитектура, не заявляется как оригинальная формула.
    chrono = [r.coefficient for r in reversed(rows[:120])]

    if len(chrono) < 12:
        return None

    recent = chrono[-50:]
    clipped = [min(x, 25.0) for x in recent]
    avg = mean(clipped) or 1.0
    volatility = stdev(clipped) / max(avg, 1.0)
    pat = pattern_probabilities(chrono)

    intervals, gap10 = ten_x_intervals(chrono)
    typical_gap = mean(intervals[-12:]) if intervals else 18.0

    low_ratio = sum(x < 1.5 for x in recent[-16:]) / min(16, len(recent))
    mid_ratio = sum(1.5 <= x < 3 for x in recent[-16:]) / min(16, len(recent))
    high_ratio = sum(x >= 3 for x in recent[-16:]) / min(16, len(recent))

    pressure10 = clamp(gap10 / max(typical_gap, 5.0), 0.0, 1.8) / 1.8
    calm = 1.0 - clamp(volatility / 1.25, 0.0, 1.0)

    high_score = (
        0.44 * pat["H"]
        + 0.28 * pressure10
        + 0.16 * high_ratio
        + 0.12 * (1 - calm)
    )

    mid_score = (
        0.46 * pat["M"]
        + 0.24 * mid_ratio
        + 0.18 * calm
        + 0.12 * (1 - abs(pressure10 - 0.55))
    )

    low_score = (
        0.48 * pat["B"]
        + 0.30 * low_ratio
        + 0.22 * calm
    )

    scores = {"B": low_score, "M": mid_score, "H": high_score}
    best = max(scores, key=scores.get)
    ordered = sorted(scores.values(), reverse=True)
    margin = ordered[0] - ordered[1]

    confidence = int(
        round(clamp(42 + scores[best] * 42 + margin * 70, 35, 88))
    )

    if confidence < 52:
        return None

    if best == "H":
        target = 5.0 if pressure10 > 0.72 and confidence >= 74 else 3.0
    elif best == "M":
        target = 2.0
    else:
        target = 1.5

    wait = 0 if confidence >= 72 else (1 if confidence >= 60 else 2)

    reason = (
        f"pattern={pat[best]:.2f}; "
        f"vol={volatility:.2f}; "
        f"gap10={gap10}/{typical_gap:.1f}; "
        f"zone={best}"
    )

    return Forecast(
        "allpredictor",
        target,
        confidence,
        wait,
        3,
        rows[0].id,
        reason,
    )


def babel_forecast(rows: List[Round]) -> Optional[Forecast]:
    values = [r.coefficient for r in rows[:40]]

    if len(values) < 10:
        return None

    recent = values[:12]
    low = sum(x < 1.5 for x in recent)
    medium = sum(1.5 <= x < 3 for x in recent)
    gap10 = next((i for i, x in enumerate(values) if x >= 10), len(values))

    clipped = [min(x, 20.0) for x in recent]
    vol = stdev(clipped) / max(mean(clipped), 1.0)

    score = (
        48
        + low * 2.0
        + min(gap10, 18) * 0.8
        - max(0.0, vol - 0.9) * 10
    )

    confidence = int(round(clamp(score, 40, 82)))

    if confidence < 57:
        return None

    if gap10 >= 12 and low >= 5:
        target = 3.0
    elif low >= 5 or medium >= 5:
        target = 2.0
    else:
        target = 1.5

    wait = 1 if confidence < 68 else 0

    return Forecast(
        "babel",
        target,
        confidence,
        wait,
        3,
        rows[0].id,
        f"low12={low}; mid12={medium}; gap10={gap10}; vol={vol:.2f}",
    )



def _minute_in_window(minute: int, start: int, end: int) -> bool:
    if start <= end:
        return start <= minute <= end
    return minute >= start or minute <= end


def _hour_in_window(hour: int, start: int, end: int) -> bool:
    if start <= end:
        return start <= hour <= end
    return hour >= start or hour <= end


def babel_time_grid_score() -> float:
    now = time.localtime()
    minute, hour = now.tm_min, now.tm_hour
    minute_hit = any(_minute_in_window(minute, a, b) for a, b in BIG_TIME_WINDOWS)
    hour_hit = any(_hour_in_window(hour, a, b) for a, b in BIG_FAVORABLE_HOURS)
    if minute_hit and hour_hit:
        return 1.0
    if minute_hit:
        return 0.75
    if hour_hit:
        return 0.45
    return 0.0


def anti_spam_ok(state: dict, engine: str) -> bool:
    last = float(state.get("last_sent_at", {}).get(engine, 0) or 0)
    return time.time() - last >= ANTI_SPAM_SECONDS


def mark_sent(state: dict, engine: str) -> None:
    state.setdefault("last_sent_at", {})[engine] = int(time.time())


def estimate_grand_insurance(rows: List[Round]) -> float:
    vals = sorted(r.coefficient for r in rows[:80] if 1.5 <= r.coefficient < 10.0)
    if not vals:
        return 3.0
    idx = max(0, min(len(vals)-1, int(round((len(vals)-1)*0.72))))
    return round(max(2.5, min(6.0, vals[idx])), 2)


def petit_forecast(rows: List[Round]) -> Optional[Forecast]:
    vals=[r.coefficient for r in rows[:60]]
    if len(vals)<16:
        return None
    recent=vals[:16]
    low=sum(x<1.5 for x in recent)/len(recent)
    mid=sum(1.5<=x<3 for x in recent)/len(recent)
    clipped=[min(x,12.0) for x in recent]
    vol=stdev(clipped)/max(mean(clipped),1.0)
    score=0.48*mid+0.32*low+0.20*(1-clamp(vol/1.4,0,1))
    confidence=int(round(clamp(48+score*45,40,90)))
    if confidence<MIN_CONFIDENCE:
        return None
    target=round(clamp(1.55+mid*0.85+low*0.35,1.5,2.8),2)
    wait=0 if confidence>=78 else 1
    return Forecast("petit",target,confidence,wait,3,rows[0].id,f"low={low:.2f};mid={mid:.2f};vol={vol:.2f}")


def grand_forecast(rows: List[Round]) -> Optional[Forecast]:
    chrono=[r.coefficient for r in reversed(rows[:160])]
    if len(chrono)<30:
        return None
    intervals,gap10=ten_x_intervals(chrono)
    typical=mean(intervals[-12:]) if intervals else 18.0
    recent=chrono[-24:]
    low=sum(x<1.5 for x in recent)/len(recent)
    high=sum(x>=3 for x in recent)/len(recent)
    pressure=clamp(gap10/max(typical,5.0),0,1.8)/1.8
    tscore=babel_time_grid_score()
    raw=0.38*pressure+0.22*low+0.18*high+0.22*tscore
    confidence=int(round(clamp(48+raw*46,40,92)))
    if confidence<MIN_CONFIDENCE:
        return None
    target=20.0 if pressure>0.78 and tscore>=0.75 else (12.0 if pressure>0.62 else 8.0)
    wait=0 if tscore>=0.75 else (1 if confidence>=78 else 2)
    return Forecast("grand",target,confidence,wait,3,rows[0].id,f"gap10={gap10};typical={typical:.1f};time={tscore:.2f}")


def twotime_forecast(rows: List[Round]) -> Optional[Forecast]:
    vals=[r.coefficient for r in rows[:80]]
    if len(vals)<20:
        return None
    recent=vals[:20]
    around2=sum(1.8<=x<=2.5 for x in recent)/len(recent)
    lows=sum(x<1.5 for x in recent)/len(recent)
    clipped=[min(x,8.0) for x in recent]
    vol=stdev(clipped)/max(mean(clipped),1.0)
    score=0.52*around2+0.28*lows+0.20*(1-clamp(vol/1.2,0,1))
    confidence=int(round(clamp(46+score*48,40,90)))
    if confidence<MIN_CONFIDENCE:
        return None
    target=round(clamp(2.0+around2*0.28,2.0,2.3),2)
    return Forecast("twotime",target,confidence,1,3,rows[0].id,f"around2={around2:.2f};low={lows:.2f};vol={vol:.2f}")



def _rounds_since_10x(rows: List[Round]) -> int:
    """Сколько завершённых раундов прошло после последнего 10X+."""
    for i, r in enumerate(rows):
        if r.coefficient >= 10.0:
            return i
    return len(rows)



def threextime_forecast(rows: List[Round]) -> Optional[Forecast]:
    """
    BABEL 3X TIME — тестовая реконструкция по публичным сигналам 3X–4.8X.
    Точные секунды оригинального BABEL не выдумываются.
    """
    values = [r.coefficient for r in rows[:90]]
    if len(values) < 24:
        return None

    recent = values[:24]
    near3 = sum(2.5 <= x <= 5.0 for x in recent) / len(recent)
    low = sum(x < 1.5 for x in recent) / len(recent)
    mid = sum(1.5 <= x < 3.0 for x in recent) / len(recent)

    clipped = [min(x, 10.0) for x in recent]
    vol = stdev(clipped) / max(mean(clipped), 1.0)

    score = (
        0.46 * near3
        + 0.24 * mid
        + 0.18 * low
        + 0.12 * (1.0 - clamp(vol / 1.3, 0.0, 1.0))
    )

    confidence = int(round(clamp(48 + score * 44, 40, 91)))
    if confidence < MIN_CONFIDENCE:
        return None

    target = round(clamp(3.0 + near3 * 1.8, 3.0, 4.8), 2)
    wait = 1 if confidence < 80 else 0

    return Forecast(
        engine="threextime",
        target=target,
        confidence=confidence,
        wait_rounds=wait,
        validation_rounds=3,
        created_after_round_id=rows[0].id,
        reason=f"3XTIME near3={near3:.2f}; mid={mid:.2f}; low={low:.2f}; vol={vol:.2f}",
    )


def erick_forecast(rows: List[Round]) -> Optional[Forecast]:
    """
    ERICK JET SIGNAL — тестовая реконструкция target + insurance + future window.
    Страховка оценивается отдельно примерно на уровне 30% от основной цели.
    """
    values = [r.coefficient for r in rows[:100]]
    if len(values) < 30:
        return None

    recent = values[:30]
    medium = [x for x in recent if 2.0 <= x < 10.0]
    low_ratio = sum(x < 1.5 for x in recent) / len(recent)
    med_ratio = len(medium) / len(recent)

    clipped = [min(x, 12.0) for x in recent]
    vol = stdev(clipped) / max(mean(clipped), 1.0)

    score = (
        0.44 * med_ratio
        + 0.30 * low_ratio
        + 0.26 * (1.0 - clamp(vol / 1.45, 0.0, 1.0))
    )

    confidence = int(round(clamp(47 + score * 46, 40, 91)))
    if confidence < MIN_CONFIDENCE:
        return None

    if medium:
        ordered = sorted(medium)
        q = ordered[min(len(ordered) - 1, int((len(ordered) - 1) * 0.78))]
        target = round(clamp(q, 5.0, 9.0), 2)
    else:
        target = 7.0

    # Публичный пример давал окно примерно через 4 минуты.
    # В коде это выражаем как 2 раунда ожидания, а не как обещание точной минуты.
    wait = 2

    return Forecast(
        engine="erick",
        target=target,
        confidence=confidence,
        wait_rounds=wait,
        validation_rounds=3,
        created_after_round_id=rows[0].id,
        reason=f"ERICK med={med_ratio:.2f}; low={low_ratio:.2f}; vol={vol:.2f}",
    )


def calculbig_forecast(rows: List[Round]) -> Optional[Forecast]:
    """
    CALCUL DE GROSSE CÔTE — отдельный тестовый модуль для 10X–30X.
    Использует интервалы 10X+, текущий gap и BABEL time-grid.
    """
    chrono = [r.coefficient for r in reversed(rows[:180])]
    if len(chrono) < 40:
        return None

    intervals, gap10 = ten_x_intervals(chrono)
    typical = mean(intervals[-12:]) if intervals else 18.0
    recent = chrono[-30:]

    low_ratio = sum(x < 1.5 for x in recent) / len(recent)
    big_ratio = sum(x >= 5.0 for x in recent) / len(recent)
    pressure = clamp(gap10 / max(typical, 5.0), 0.0, 1.8) / 1.8
    timegrid = babel_time_grid_score()

    score = (
        0.42 * pressure
        + 0.24 * timegrid
        + 0.22 * low_ratio
        + 0.12 * big_ratio
    )

    confidence = int(round(clamp(48 + score * 45, 40, 93)))
    if confidence < MIN_CONFIDENCE:
        return None

    if confidence >= 84 and pressure >= 0.72:
        target = 30.0
    elif confidence >= 78:
        target = 20.0
    else:
        target = 10.0

    wait = 0 if timegrid >= 0.75 else 1

    return Forecast(
        engine="calculbig",
        target=target,
        confidence=confidence,
        wait_rounds=wait,
        validation_rounds=3,
        created_after_round_id=rows[0].id,
        reason=(
            f"CALCUL gap10={gap10}; typical={typical:.1f}; "
            f"pressure={pressure:.2f}; timegrid={timegrid:.2f}"
        ),
    )


def pro4_forecast(rows: List[Round]) -> Optional[Forecast]:
    """
    BABEL PRO 4 — тестовая реконструкция по публичным сигналам.
    Ключевая идея: после 5–7 игр искать область 10X–30X.
    """
    if len(rows) < 30:
        return None

    since10 = _rounds_since_10x(rows[:120])
    recent = [r.coefficient for r in rows[:24]]

    low_ratio = sum(x < 1.5 for x in recent) / len(recent)
    mid_ratio = sum(1.5 <= x < 3.0 for x in recent) / len(recent)
    high_ratio = sum(x >= 3.0 for x in recent) / len(recent)

    # Максимальный балл в "публичном" окне ожидания 5–7 раундов.
    if 5 <= since10 <= 7:
        wait_score = 1.0
    elif 4 <= since10 <= 8:
        wait_score = 0.72
    else:
        wait_score = max(0.0, 1.0 - abs(since10 - 6) / 12.0)

    timegrid = babel_time_grid_score()

    compression = min(
        low_ratio * 0.75 + mid_ratio * 0.35,
        1.0
    )

    score = (
        0.44 * wait_score
        + 0.24 * compression
        + 0.18 * timegrid
        + 0.14 * high_ratio
    )

    confidence = int(round(clamp(48 + score * 44, 40, 93)))

    if confidence < MIN_CONFIDENCE:
        return None

    # Публичные PRO4-примеры: 14X, 15X, 20X.
    if confidence >= 84 and timegrid >= 0.75:
        target = 20.0
    elif confidence >= 77:
        target = 15.0
    else:
        target = 14.0

    # Правило 5–7 игр: если сейчас 5–7, вход без ожидания.
    # Если рано — ждём до окна.
    if since10 < 5:
        wait = min(2, max(0, 5 - since10))
    else:
        wait = 0

    return Forecast(
        engine="pro4",
        target=target,
        confidence=confidence,
        wait_rounds=wait,
        validation_rounds=3,
        created_after_round_id=rows[0].id,
        reason=(
            f"PRO4 since10={since10}; wait_score={wait_score:.2f}; "
            f"timegrid={timegrid:.2f}; compression={compression:.2f}"
        ),
    )


def pro4range_forecast(rows: List[Round]) -> Optional[Forecast]:
    """
    BABEL PRO 4 RANGE — тестовая реконструкция крупных диапазонов:
    50–100X и 50–100–300X с более длинным окном.
    """
    if len(rows) < 40:
        return None

    since10 = _rounds_since_10x(rows[:160])
    recent = [r.coefficient for r in rows[:30]]

    low_ratio = sum(x < 1.5 for x in recent) / len(recent)
    big_ratio = sum(x >= 5.0 for x in recent) / len(recent)
    timegrid = babel_time_grid_score()

    # Для крупных диапазонов требуем более "созревшее" окно.
    mature = clamp((since10 - 5) / 8.0, 0.0, 1.0)

    score = (
        0.38 * mature
        + 0.28 * timegrid
        + 0.22 * low_ratio
        + 0.12 * big_ratio
    )

    confidence = int(round(clamp(46 + score * 46, 40, 92)))

    if confidence < max(MIN_CONFIDENCE, 74):
        return None

    # Два уровня RANGE
    if confidence >= 84 and mature >= 0.72:
        target = 50.0
        validation = 4
    else:
        target = 30.0
        validation = 4

    # В RANGE делаем более длинное окно.
    wait = 1 if timegrid >= 0.75 else 2

    return Forecast(
        engine="pro4range",
        target=target,
        confidence=confidence,
        wait_rounds=wait,
        validation_rounds=validation,
        created_after_round_id=rows[0].id,
        reason=(
            f"PRO4R since10={since10}; mature={mature:.2f}; "
            f"timegrid={timegrid:.2f}; low={low_ratio:.2f}; big={big_ratio:.2f}"
        ),
    )


def bigtime_forecast(rows: List[Round]) -> Optional[Forecast]:
    values=[r.coefficient for r in reversed(rows[:180])]
    if len(values)<30:
        return None
    hit_idx=[i for i,x in enumerate(values) if x>=10.0]
    if not hit_idx:
        return None
    gap_now=len(values)-1-hit_idx[-1]
    intervals=[hit_idx[i]-hit_idx[i-1] for i in range(1,len(hit_idx))]
    typical=statistics.median(intervals[-12:]) if intervals else 18.0
    recent=values[-20:]
    low=sum(x<1.5 for x in recent)/len(recent)
    mid=sum(1.5<=x<3 for x in recent)/len(recent)
    high=sum(x>=3 for x in recent)/len(recent)
    proximity=1-min(abs(gap_now-typical)/max(typical,5.0),1.0)
    pressure=min(gap_now/max(typical,5.0),1.8)/1.8
    compression=min(low*1.15+mid*0.25,1.0)
    timegrid=babel_time_grid_score()
    score=0.34*proximity+0.26*pressure+0.16*compression+0.08*high+0.16*timegrid
    confidence=int(round(max(40,min(90,45+score*45))))
    if confidence<MIN_CONFIDENCE:
        return None
    wait=0 if gap_now>=typical else (1 if gap_now>=max(0,typical-2) else 2)
    return Forecast("bigtime",10.0,confidence,wait,3,rows[0].id,f"gap10={gap_now};typical={typical:.1f};timegrid={timegrid:.2f};score={score:.2f}")


def killer_forecast(rows: List[Round]) -> Optional[Forecast]:
    # Пока подтверждённой логики ALLPREDICTOR KILLER нет.
    return None



def jokerpcs_forecast(rows: List[Round]) -> Optional[Forecast]:
    """
    Публичный JOKERPCS / Lucky jet predictor (14.02.2025).
    В найденном коде сама цель НЕ вычисляется из истории:
    random.uniform(12.25, 20.62). Поэтому этот модуль специально
    помечен как PUBLIC RANDOM и не выдаётся за настоящий предиктор.
    """
    if not rows:
        return None
    target = round(random.uniform(12.25, 20.62), 2)
    # В оригинальном публичном артефакте:
    # Assurance = target / 2; Fiable = target / 4; время ~ +1 мин.
    return Forecast(
        "jokerpcs", target, 50, 1, 3, rows[0].id,
        f"PUBLIC_RANDOM;assurance={target/2:.2f};fiable={target/4:.2f};time≈+1min"
    )


def combine50_forecast(rows: List[Round]) -> Optional[Forecast]:
    """
    LUCKYJET COMBINÉ: окно maxlen=50.
    Публичный код считает частоты/mean/median/min/max/std, затем выбирает
    значение numpy.random.choice с весами исторической частоты.
    Здесь тот же принцип реализован без обязательной зависимости numpy.
    """
    vals = [round(r.coefficient, 2) for r in rows[:50]]
    if len(vals) < 10:
        return None

    freq: Dict[float, int] = {}
    for x in vals:
        freq[x] = freq.get(x, 0) + 1

    choices = list(freq)
    weights = [freq[x] for x in choices]
    target = float(random.choices(choices, weights=weights, k=1)[0])
    future_seconds = random.randint(30, 299)

    # Это стохастический публичный алгоритм, поэтому confidence не маскируем
    # под доказанную вероятность выигрыша.
    return Forecast(
        "combine50", target, 50, 0, 3, rows[0].id,
        (
            f"PUBLIC_STOCHASTIC;window={len(vals)};"
            f"mean={mean(vals):.2f};median={statistics.median(vals):.2f};"
            f"min={min(vals):.2f};max={max(vals):.2f};std={stdev(vals):.2f};"
            f"future_seconds={future_seconds}"
        )
    )


def montantev1_forecast(rows: List[Round]) -> Optional[Forecast]:
    """
    MONTANTE BOT BABEL V1 — реконструкция найденного публичного артефакта.
    В нём фигурируют условия: после 3 violet, после 3 bleu,
    после 2 violet, violet+bleu; выбор условия и цель 1.20–2.00X случайные.
    """
    if len(rows) < 4:
        return None
    conditions = [
        "после 3 violet",
        "после 3 bleu",
        "после 2 violet",
        "violet + bleu",
    ]
    condition = random.choice(conditions)
    target = round(random.uniform(1.20, 2.00), 2)
    return Forecast(
        "montantev1", target, 50, 0, 3, rows[0].id,
        f"PUBLIC_RANDOM;condition={condition};target_range=1.20-2.00X"
    )


ANALYZERS = {
    "babel": babel_forecast,
    "petit": petit_forecast,
    "grand": grand_forecast,
    "twotime": twotime_forecast,
    "threextime": threextime_forecast,
    "erick": erick_forecast,
    "calculbig": calculbig_forecast,
    "pro4": pro4_forecast,
    "pro4range": pro4range_forecast,
    "allpredictor": allpredictor_forecast,
    "bigtime": bigtime_forecast,
    "killer": killer_forecast,
    "jokerpcs": jokerpcs_forecast,
    "combine50": combine50_forecast,
    "montantev1": montantev1_forecast,
}


def telegram_api(method: str, payload: Optional[dict] = None) -> dict:
    if not BOT_TOKEN:
        raise RuntimeError("Нужно задать TELEGRAM_BOT_TOKEN")

    url = f"https://api.telegram.org/bot{BOT_TOKEN}/{method}"
    body = urllib.parse.urlencode(payload or {}).encode("utf-8")

    req = urllib.request.Request(
        url,
        data=body,
        headers={"content-type": "application/x-www-form-urlencoded"},
    )

    with urllib.request.urlopen(req, timeout=15) as response:
        data = json.loads(response.read().decode("utf-8"))

    if not data.get("ok"):
        raise RuntimeError(f"Telegram API: {data}")

    return data


def keyboard(state: dict) -> dict:
    def title(key: str) -> str:
        flag = state["engines"].get(key, False)
        return f"{'✅' if flag else '⛔'} {ENGINE_LABELS[key]}"

    return {
        "inline_keyboard": [
            [
                {"text": title("babel"), "callback_data": "toggle:babel"},
                {"text": title("allpredictor"), "callback_data": "toggle:allpredictor"},
            ],
            [
                {"text": title("petit"), "callback_data": "toggle:petit"},
                {"text": title("grand"), "callback_data": "toggle:grand"},
            ],
            [
                {"text": title("twotime"), "callback_data": "toggle:twotime"},
                {"text": title("threextime"), "callback_data": "toggle:threextime"},
            ],
            [
                {"text": title("erick"), "callback_data": "toggle:erick"},
                {"text": title("calculbig"), "callback_data": "toggle:calculbig"},
            ],
            [
                {"text": title("pro4"), "callback_data": "toggle:pro4"},
                {"text": title("pro4range"), "callback_data": "toggle:pro4range"},
            ],
            [
                {"text": title("bigtime"), "callback_data": "toggle:bigtime"},
            ],
            [
                {"text": title("killer"), "callback_data": "toggle:killer"},
            ],
            [
                {"text": title("jokerpcs"), "callback_data": "toggle:jokerpcs"},
            ],
            [
                {"text": title("combine50"), "callback_data": "toggle:combine50"},
                {"text": title("montantev1"), "callback_data": "toggle:montantev1"},
            ],

            [
                {"text": "🟢 Только PETIT", "callback_data": "only:petit"},
                {"text": "🔴 Только GRAND", "callback_data": "only:grand"},
            ],
            [
                {"text": "🕒 Только 2X TIME", "callback_data": "only:twotime"},
                {"text": "⏱ Только 3X TIME", "callback_data": "only:threextime"},
            ],
            [
                {"text": "⚡ Только ERICK", "callback_data": "only:erick"},
                {"text": "🧮 Только CALCUL", "callback_data": "only:calculbig"},
            ],
            [
                {"text": "🧨 Только PRO 4", "callback_data": "only:pro4"},
                {"text": "🚨 Только PRO 4 RANGE", "callback_data": "only:pro4range"},
            ],
            [
                {"text": "🔥 Только 10X–100X", "callback_data": "only:bigtime"},
            ],
            [
                {"text": "🃏 Только JOKERPCS", "callback_data": "only:jokerpcs"},
                {"text": "📚 Только COMBINÉ 50", "callback_data": "only:combine50"},
            ],
            [
                {"text": "🪜 Только MONTANTE V1", "callback_data": "only:montantev1"},
            ],
            [
                {"text": "🎯 Только BABEL", "callback_data": "only:babel"},
                {"text": "🎯 Только ALLPREDICTOR", "callback_data": "only:allpredictor"},
            ],
            [
                {"text": "⛔ Выключить все", "callback_data": "only:none"},
            ],
            [
                {"text": "🚀 Получить сигнал", "callback_data": "action:signal"},
                {"text": "📊 Статистика", "callback_data": "action:stats"},
            ],
        ]
    }


def bots_text(state: dict) -> str:
    lines = ["🤖 <b>ДВИЖКИ LUCKY JET</b>", ""]

    for key, label in ENGINE_LABELS.items():
        enabled = state["engines"].get(key, False)
        if key == "killer":
            extra = " · логика пока не подтверждена"
        elif key in {"jokerpcs", "combine50", "montantev1"}:
            extra = " · публичный стохастический артефакт"
        else:
            extra = ""
        lines.append(
            f"{'✅' if enabled else '⛔'} <b>{label}</b>{extra}"
        )

    lines += [
        "",
        "Кнопками можно включать/выключать каждый движок "
        "или оставить только один.",
    ]

    return "\n".join(lines)


def send_message(
    text: str,
    chat_id: Optional[str] = None,
    with_keyboard: bool = False,
    state: Optional[dict] = None,
) -> None:
    cid = str(chat_id or CHAT_ID)

    if not cid:
        return

    payload = {
        "chat_id": cid,
        "text": text,
        "parse_mode": "HTML",
        "disable_web_page_preview": "true",
    }

    if with_keyboard and state is not None:
        payload["reply_markup"] = json.dumps(
            keyboard(state),
            ensure_ascii=False,
        )

    telegram_api("sendMessage", payload)


def answer_callback(callback_id: str, text: str = "Готово") -> None:
    try:
        telegram_api(
            "answerCallbackQuery",
            {
                "callback_query_id": callback_id,
                "text": text,
            },
        )
    except Exception:
        pass


def stats_text(state: dict) -> str:
    lines = ["📊 <b>СТАТИСТИКА ДВИЖКОВ</b>", ""]

    for key, label in ENGINE_LABELS.items():
        st = state["stats"][key]
        total = st["win"] + st["lose"]
        rate = (st["win"] / total * 100.0) if total else 0.0

        lines.append(
            f"<b>{label}</b>: "
            f"✅ {st['win']} · "
            f"❌ {st['lose']} · "
            f"{rate:.1f}%"
        )

    lines.append(f"\nАктивных проверок: {len(state.get('pending', []))}")
    lines.append(f"Порог уверенности: {MIN_CONFIDENCE}%")
    lines.append(f"Антиспам: {ANTI_SPAM_SECONDS} сек.")

    return "\n".join(lines)


def signal_text(f: Forecast, rows: Optional[List[Round]] = None) -> str:
    timing = "в следующий раунд" if f.wait_rounds == 0 else f"через {f.wait_rounds} раунд(а)"

    if f.engine == "jokerpcs":
        assurance = f.target / 2.0
        fiable = f.target / 4.0
        return (
            "🃏 <b>JOKERPCS GROSSE CÔTE — PUBLIC RANDOM</b>\n"
            f"🎯 Случайная цель найденного кода: <b>{f.target:.2f}X</b>\n"
            f"🛡 Assurance: <b>{assurance:.2f}X</b>\n"
            f"✅ Fiable: <b>{fiable:.2f}X</b>\n"
            "⏱ Формат источника: примерно <b>+1 минута</b>\n"
            "⚠️ Это воспроизведение публичного random.uniform, не доказанный прогноз."
        )

    if f.engine == "combine50":
        future = "30–299 сек."
        m = re.search(r"future_seconds=(\\d+)", f.reason)
        if m:
            future = f"{m.group(1)} сек."
        return (
            "📚 <b>LUCKYJET COMBINÉ 50 — PUBLIC STOCHASTIC</b>\n"
            f"🎯 Выбранный коэффициент: <b>{f.target:.2f}X</b>\n"
            "📊 Анализ: <b>последние 50 коэффициентов</b> + частоты/среднее/медиана/min/max/std\n"
            f"⏱ Случайное будущее окно: <b>{future}</b>\n"
            "⚠️ Выбор сделан по исторической частоте, это не подтверждённый API-предиктор."
        )

    if f.engine == "montantev1":
        condition = "публичное условие BABEL V1"
        m = re.search(r"condition=([^;]+)", f.reason)
        if m:
            condition = m.group(1)
        return (
            "🪜 <b>MONTANTE BOT BABEL V1 — PUBLIC RANDOM</b>\n"
            f"🔎 Условие: <b>{condition}</b>\n"
            f"🎯 Цель: <b>{f.target:.2f}X</b> (диапазон 1.20–2.00X)\n"
            "⚠️ В найденной версии условие и цель выбираются случайно; "
            "это артефакт формата BABEL, а не доказанная логика V2."
        )

    if f.engine == "threextime":
        return (
            "⏱ <b>BABEL 3X TIME</b>\n"
            f"🎯 Цель: <b>{f.target:.2f}X</b>\n"
            f"🧠 Уверенность: <b>{f.confidence}%</b>\n"
            f"⏱ Вход: <b>{timing}</b>\n"
            "🎮 До 3 попыток по проверке сигнала.\n"
            "ℹ️ Точные секунды оригинального BABEL не выдумываются."
        )

    if f.engine == "erick":
        insurance = round(max(1.5, min(3.5, f.target * 0.30)), 2)
        return (
            "⚡ <b>ERICK JET SIGNAL</b>\n"
            f"🎯 Цель: <b>{f.target:.2f}X</b>\n"
            f"🛡 Страховка: <b>{insurance:.2f}X</b>\n"
            f"🧠 Уверенность: <b>{f.confidence}%</b>\n"
            f"⏱ Будущее окно: <b>{timing}</b>\n"
            "🎮 Проверка: <b>до 3 попыток</b>\n"
            "ℹ️ Тестовая реконструкция по публичному формату ERICK."
        )

    if f.engine == "calculbig":
        return (
            "🧮 <b>CALCUL DE GROSSE CÔTE</b>\n"
            f"🎯 Цель: <b>{f.target:.2f}X</b>\n"
            f"🧠 Уверенность: <b>{f.confidence}%</b>\n"
            f"⏱ Окно: <b>{timing}</b>\n"
            "🎮 Диапазон расчёта: <b>10X–30X</b>\n"
            "🔎 Проверка: <b>до 3 раундов</b>\n"
            "ℹ️ История 10X+ + текущий gap + BABEL time-grid."
        )

    if f.engine == "pro4":
        insurance = round(max(3.0, min(4.0, f.target * 0.20)), 2)
        return (
            "🧨 <b>BABEL PRO 4</b>\n"
            f"🎯 Основная цель: <b>{f.target:.2f}X</b>\n"
            f"🛡 Страховка: <b>{insurance:.2f}X</b>\n"
            f"🧠 Уверенность: <b>{f.confidence}%</b>\n"
            f"⏱ Вход: <b>{timing}</b>\n"
            "🎮 Правило окна: <b>5–7 игр после 10X+</b>\n"
            f"🔎 Проверка: <b>до {f.validation_rounds} раундов</b>\n"
            "ℹ️ Тестовая реконструкция по публичным сигналам PRO 4."
        )

    if f.engine == "pro4range":
        # Для диапазонной ветки страховка 10–20X,
        # а при самых сильных окнах можно трактовать как 10–20–30X.
        if f.confidence >= 84:
            insurance_text = "10–20–30X"
            range_text = "50–100–300X"
        else:
            insurance_text = "10–20X"
            range_text = "50–100X"

        return (
            "🚨 <b>BABEL PRO 4 RANGE</b>\n"
            f"🎯 Диапазон: <b>{range_text}</b>\n"
            f"🛡 Страховка: <b>{insurance_text}</b>\n"
            f"🧠 Уверенность: <b>{f.confidence}%</b>\n"
            f"⏱ Расширенное окно: <b>{timing}</b>\n"
            f"🔎 Контроль: <b>до {f.validation_rounds} раундов</b>\n"
            "ℹ️ Тестовая реконструкция крупного режима PRO 4."
        )

    if f.engine == "bigtime":
        return (
            "🔥 <b>HEURE DE GROSSE COTE LUCKY JET PRO</b>\n"
            "🎯 Диапазон: <b>10X–100X</b>\n"
            f"🧠 Уверенность окна: <b>{f.confidence}%</b>\n"
            f"⏱ Окно входа: <b>{timing}</b>\n"
            f"🔎 Контроль: <b>до {f.validation_rounds} раундов</b>\n"
            "ℹ️ История 10X+ + BABEL time-grid."
        )

    if f.engine == "petit":
        return (
            "🟢 <b>BABEL PETIT</b>\n"
            f"🎯 Цель: <b>{f.target:.2f}X</b>\n"
            f"🧠 Уверенность: <b>{f.confidence}%</b>\n"
            f"⏱ Вход: <b>{timing}</b>\n"
            "🔎 Проверка: <b>до 3 раундов</b>"
        )

    if f.engine == "grand":
        insurance = estimate_grand_insurance(rows or [])
        return (
            "🔴 <b>BABEL GRAND</b>\n"
            f"🎯 Основная цель: <b>{f.target:.2f}X</b>\n"
            f"🛡 Страховка: <b>{insurance:.2f}X</b>\n"
            f"🧠 Уверенность: <b>{f.confidence}%</b>\n"
            f"⏱ Окно: <b>{timing}</b>\n"
            "🔎 Проверка: <b>до 3 раундов</b>"
        )

    if f.engine == "twotime":
        return (
            "🕒 <b>BABEL 2X TIME</b>\n"
            f"🎯 Цель: <b>{f.target:.2f}X</b>\n"
            f"🧠 Уверенность: <b>{f.confidence}%</b>\n"
            f"⏱ Окно: <b>{timing}</b>\n"
            "ℹ️ Тестовый режим: точные секунды оригинального BABEL не выдумываются."
        )

    note = (
        "восстановленная схема, не оригинальная формула"
        if f.engine == "allpredictor"
        else "реконструированная логика"
    )
    return (
        f"🚀 <b>{ENGINE_LABELS[f.engine]}</b>\n"
        f"🎯 Цель: <b>{f.target:.2f}X</b>\n"
        f"🧠 Уверенность: <b>{f.confidence}%</b>\n"
        f"⏱ Вход: <b>{timing}</b>\n"
        f"🔎 Проверка: <b>до {f.validation_rounds} раундов</b>\n"
        f"ℹ️ {note}"
    )

def result_text(item: dict, win: bool, actual: float, used: int) -> str:
    engine = item["engine"]

    if engine == "erick":
        target = float(item["target"])
        insurance = round(max(1.5, min(3.5, target * 0.30)), 2)

        if actual >= target:
            status = "✅ ОСНОВНАЯ ЦЕЛЬ"
        elif actual >= insurance:
            status = "🛡 СТРАХОВКА"
        else:
            status = "❌ НЕ ЗАШЛО"

        return (
            f"{status} · <b>{ENGINE_LABELS[engine]}</b>\n"
            f"🎯 Цель {target:.2f}X · 🛡 {insurance:.2f}X\n"
            f"Факт: <b>{actual:.2f}X</b> · попытка {used}/{int(item.get('validation_rounds', 3))}"
        )

    if engine == "pro4":
        target = float(item["target"])
        insurance = round(max(3.0, min(4.0, target * 0.20)), 2)
        if actual >= target:
            status = "✅ ОСНОВНАЯ ЦЕЛЬ"
        elif actual >= insurance:
            status = "🛡 СТРАХОВКА"
        else:
            status = "❌ НЕ ЗАШЛО"

        return (
            f"{status} · <b>{ENGINE_LABELS[engine]}</b>\n"
            f"🎯 Цель {target:.2f}X · 🛡 {insurance:.2f}X\n"
            f"Факт: <b>{actual:.2f}X</b> · раунд {used}/{int(item.get('validation_rounds', 3))}"
        )

    return (
        f"{'✅' if win else '❌'} <b>{ENGINE_LABELS[engine]}</b> · "
        f"цель {float(item['target']):.2f}X · "
        f"{'достигнута' if win else 'не достигнута'} за "
        f"{used}/{int(item.get('validation_rounds', 3))} раунд(а) · "
        f"последний {actual:.2f}X"
    )

def create_forecasts(
    rows: List[Round],
    state: dict,
    force: bool = False,
    chat_id: Optional[str] = None,
) -> int:
    count=0
    if not rows:
        if force:
            send_message("⚠️ LIVE-история коэффициентов сейчас недоступна.",chat_id)
        return 0
    current_id=rows[0].id
    for engine,enabled in state["engines"].items():
        if not enabled:
            continue
        if engine=="killer":
            if force:
                send_message("🧪 <b>ALLPREDICTOR KILLER</b>\nЛогика пока не подтверждена, фальшивый сигнал не генерирую.", chat_id)
            continue
        if not anti_spam_ok(state,engine):
            if force:
                send_message(f"⏳ <b>{ENGINE_LABELS[engine]}</b>: антиспам {ANTI_SPAM_SECONDS} сек.",chat_id)
            continue
        if not force and state["last_signal_round"].get(engine)==current_id:
            continue
        forecast=ANALYZERS[engine](rows)
        if forecast is None:
            if force:
                send_message(f"⏸ <b>{ENGINE_LABELS[engine]}</b>: нет сигнала с уверенностью ≥ {MIN_CONFIDENCE}%.",chat_id)
            continue
        if forecast.confidence < MIN_CONFIDENCE and engine not in {"jokerpcs", "combine50", "montantev1"}:
            continue
        item=asdict(forecast)
        item.update({"wait_left":forecast.wait_rounds,"checked":0,"best":0.0})
        state["pending"].append(item)
        state["last_signal_round"][engine]=current_id
        mark_sent(state,engine)
        send_message(signal_text(forecast,rows),chat_id)
        count+=1
    save_state(state)
    return count


def process_new_round(
    round_: Round,
    state: dict,
    chat_id: Optional[str] = None,
) -> None:
    keep = []

    for item in state.get("pending", []):
        if item.get("wait_left", 0) > 0:
            item["wait_left"] -= 1
            keep.append(item)
            continue

        item["checked"] = int(item.get("checked", 0)) + 1
        item["best"] = max(
            float(item.get("best", 0.0)),
            round_.coefficient,
        )

        win = round_.coefficient >= float(item["target"])
        engine = item["engine"]

        # Для ERICK отдельно проверяем страховку (~30% от цели).
        if engine == "erick":
            insurance = round(
                max(1.5, min(3.5, float(item["target"]) * 0.30)),
                2,
            )
            if round_.coefficient >= insurance:
                state["stats"][engine]["win"] += 1
                send_message(
                    result_text(
                        item,
                        round_.coefficient >= float(item["target"]),
                        round_.coefficient,
                        item["checked"],
                    ),
                    chat_id,
                )
                continue

        # Для PRO4 страховку считаем отдельным успешным исходом,
        # но не подменяем ею достижение основной цели.
        if engine == "pro4":
            insurance = round(
                max(3.0, min(4.0, float(item["target"]) * 0.20)),
                2,
            )
            if round_.coefficient >= insurance:
                state["stats"][engine]["win"] += 1
                send_message(
                    result_text(
                        item,
                        round_.coefficient >= float(item["target"]),
                        round_.coefficient,
                        item["checked"],
                    ),
                    chat_id,
                )
                continue

        if win:
            state["stats"][engine]["win"] += 1
            send_message(
                result_text(
                    item,
                    True,
                    round_.coefficient,
                    item["checked"],
                ),
                chat_id,
            )
            continue

        if item["checked"] >= int(
            item.get("validation_rounds", 3)
        ):
            state["stats"][item["engine"]]["lose"] += 1
            send_message(
                result_text(
                    item,
                    False,
                    round_.coefficient,
                    item["checked"],
                ),
                chat_id,
            )
            continue

        keep.append(item)

    state["pending"] = keep
    save_state(state)


def set_only(state: dict, engine: str) -> None:
    for key in ENGINE_LABELS:
        state["engines"][key] = (
            (key == engine) if engine != "none" else False
        )


def handle_callback(
    cb: dict,
    state: dict,
    rows: List[Round],
) -> None:
    data = str(cb.get("data") or "")
    cid = str(
        (cb.get("message") or {})
        .get("chat", {})
        .get("id")
        or CHAT_ID
    )
    cbid = str(cb.get("id") or "")

    if data.startswith("toggle:"):
        key = data.split(":", 1)[1]

        if key in ENGINE_LABELS:
            state["engines"][key] = not state["engines"].get(
                key,
                False,
            )
            save_state(state)

            answer_callback(
                cbid,
                f"{ENGINE_LABELS[key]}: "
                f"{'ВКЛ' if state['engines'][key] else 'ВЫКЛ'}",
            )
            send_message(
                bots_text(state),
                cid,
                True,
                state,
            )
            return

    if data.startswith("only:"):
        key = data.split(":", 1)[1]

        if key in ENGINE_LABELS or key == "none":
            set_only(state, key)
            save_state(state)

            answer_callback(cbid, "Режим переключён")
            send_message(
                bots_text(state),
                cid,
                True,
                state,
            )
            return

    if data == "action:signal":
        answer_callback(cbid, "Анализирую")
        create_forecasts(
            rows,
            state,
            force=True,
            chat_id=cid,
        )
        return

    if data == "action:stats":
        answer_callback(cbid)
        send_message(stats_text(state), cid)
        return

    answer_callback(cbid, "Неизвестная кнопка")


def source_status_text() -> str:
    parts = ["🌐 <b>LIVE-ИСТОЧНИКИ</b>", ""]
    parts.append(
        f"{'✅' if SESSION_ID and CUSTOMER_ID else '⛔'} "
        "LuckyJet GAME history (session/customer)"
    )
    parts.append(
        f"{'✅' if HISTORY_URL else '⛔'} "
        f"History URL: {HISTORY_URL}"
    )
    parts.append(
        f"{'✅' if ALLPREDICTOR_API_KEY else '⛔'} "
        "AllPredictor API"
    )
    parts.append(
        f"{'✅' if PARSE_API_KEY else '⛔'} "
        "Parse LuckyJet API"
    )
    if HISTORY_FALLBACKS:
        parts.append(f"✅ Дополнительные URL: {len(HISTORY_FALLBACKS)}")
    else:
        parts.append("⛔ Дополнительные URL: 0")
    return "\n".join(parts)


def handle_message(
    msg: dict,
    state: dict,
    rows: List[Round],
) -> None:
    text = str(msg.get("text") or "").strip()

    if not text:
        return

    text = text.split()[0].lower()
    # В группах Telegram команды часто приходят как /start@BotName.
    # Отрезаем @BotName, чтобы команды работали и в личке, и в группе.
    if text.startswith("/") and "@" in text:
        text = text.split("@", 1)[0]

    cid = str(
        (msg.get("chat") or {}).get("id")
        or CHAT_ID
    )

    if text in ("/start", "/bots"):
        send_message(
            bots_text(state),
            cid,
            True,
            state,
        )

    elif text == "/test":
        send_message(
            "✅ Бот отвечает. Telegram-связь работает.\n"
            f"🆔 Чат: <code>{cid}</code>\n"
            f"📡 LIVE-история: {'доступна' if rows else 'сейчас недоступна'}",
            cid,
        )

    elif text == "/signal":
        if (
            create_forecasts(
                rows,
                state,
                force=True,
                chat_id=cid,
            )
            == 0
        ):
            send_message(
                "⏸ Активные движки не дали сигнал.",
                cid,
            )

    elif text in ("/stats", "/status"):
        send_message(
            stats_text(state),
            cid,
        )

    elif text in ("/coef", "/lastcoef"):
        send_message(
            last_coefficient_text(rows),
            cid,
        )

    elif text in ("/source", "/sources", "/live"):
        send_message(
            source_status_text(),
            cid,
        )


def poll_telegram(
    state: dict,
    rows: List[Round],
) -> None:
    if not BOT_TOKEN:
        return

    try:
        data = telegram_api(
            "getUpdates",
            {
                "offset": int(
                    state.get("telegram_offset", 0)
                ),
                "timeout": 0,
                "allowed_updates": json.dumps(
                    ["message", "callback_query"]
                ),
            },
        )
    except Exception as exc:
        print(f"[Telegram getUpdates] {exc}", flush=True)
        return

    changed = False

    for update in data.get("result", []):
        uid = int(update.get("update_id", 0))

        state["telegram_offset"] = max(
            int(state.get("telegram_offset", 0)),
            uid + 1,
        )

        changed = True

        if update.get("callback_query"):
            handle_callback(
                update["callback_query"],
                state,
                rows,
            )

        elif update.get("message"):
            handle_message(
                update["message"],
                state,
                rows,
            )

    if changed:
        save_state(state)


def new_rounds_since(
    rows: List[Round],
    last_id: Optional[str],
) -> List[Round]:
    if not last_id:
        return []

    fresh = []

    for r in rows:
        if r.id == last_id:
            break
        fresh.append(r)

    return list(reversed(fresh))


def main() -> None:
    state = load_state()

    if not BOT_TOKEN:
        raise SystemExit("TELEGRAM_BOT_TOKEN не задан")

    # Telegram должен работать независимо от LIVE-источника.
    # История хранится в памяти: если источник временно упал,
    # команды /start, /bots, /test и кнопки всё равно отвечают.
    rows_cache: List[Round] = []
    last_live_error = ""

    try:
        send_message(
            "✅ <b>MultiEngine RU v2 запущен</b>\n"
            "🤖 Telegram-часть активна.\n"
            "🧪 /test — проверить связь\n"
            "⚙️ /bots — управление движками\n"
            "🚀 /signal — запросить сигнал\n"
            "🎯 /coef — последний коэффициент\n"
            "🌐 /source — подключения\n"
            "♻️ АВТО: каждый новый коэффициент проверяет все включённые движки.\n"
            "📨 Сигнал и его результат отправляются автоматически."
        )
    except Exception as exc:
        # Не завершаем процесс даже если бот пока не может писать в заданную группу.
        print(f"[Telegram sendMessage startup] {exc}", flush=True)

    while True:
        # Сначала Telegram: он не должен зависеть от доступности коэффициентов.
        try:
            poll_telegram(state, rows_cache)
        except Exception as exc:
            print(f"[Telegram polling] {exc}", flush=True)

        # Затем отдельно пытаемся обновить LIVE-историю.
        try:
            rows = fetch_history()
            rows_cache = rows

            if rows:
                if not state.get("last_round_id"):
                    state["last_round_id"] = rows[0].id
                    save_state(state)
                else:
                    fresh = new_rounds_since(
                        rows,
                        state.get("last_round_id"),
                    )

                    for r in fresh:
                        # 1. Сначала автоматически проверяем уже активные сигналы.
                        # WIN / страховка / LOSE отправляются в Telegram сами.
                        process_new_round(r, state)

                    if fresh:
                        state["last_round_id"] = rows[0].id
                        save_state(state)

                        # 2. После КАЖДОГО нового полученного коэффициента
                        # автоматически запускаем все включённые движки.
                        # Как только движок набрал MIN_CONFIDENCE (70% по умолчанию),
                        # он сам отправит новый сигнал — кнопку нажимать не нужно.
                        create_forecasts(
                            rows,
                            state,
                            force=False,
                        )

            if last_live_error:
                try:
                    send_message("✅ LIVE-источник коэффициентов снова доступен.")
                except Exception as exc:
                    print(f"[Telegram live restored notice] {exc}", flush=True)
                last_live_error = ""

        except Exception as exc:
            message = str(exc)
            if message != last_live_error:
                print(f"[LIVE] {message}", flush=True)
                # Сообщаем один раз о новой ошибке, но бот продолжает работать.
                try:
                    send_message(
                        "⚠️ LIVE-источник коэффициентов недоступен, "
                        "но Telegram-бот продолжает работать.\n"
                        "Используй /test для проверки связи."
                    )
                except Exception as tg_exc:
                    print(f"[Telegram live error notice] {tg_exc}", flush=True)
                last_live_error = message

        time.sleep(POLL_SECONDS)


if __name__ == "__main__":
    main()
