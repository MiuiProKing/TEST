#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Telegram 24/7 server — paired with the iPhone app produced by the same build.
No Telegram bot token is used. This signs in as your own Telegram account via MTProto.

Security notes:
- Login code / 2FA are transported inside AES-GCM encrypted payloads.
- Code / 2FA are never written to logs or disk.
- The Telethon StringSession is stored encrypted at rest.
- The server host can still inspect a running process if the host itself is malicious;
  no client-side design can fully protect secrets from the machine executing them.
"""
import os, sys, time, json, base64, hashlib, threading, asyncio, subprocess, importlib
from pathlib import Path

CMD_TOPIC = "__TG247_CMD_TOPIC__"
EVT_TOPIC = "__TG247_EVT_TOPIC__"
PAIR_SECRET = "__TG247_PAIR_SECRET__"
NTFY_BASE = os.getenv("TG247_NTFY_BASE", "https://ntfy.sh")
SESSION_FILE = Path(os.getenv("TG247_SESSION_FILE", "telegram247_session.enc"))
SETTINGS_FILE = Path(os.getenv("TG247_SETTINGS_FILE", "telegram247_settings.json"))
SEEN_FILE = Path(os.getenv("TG247_SEEN_FILE", "telegram247_seen.json"))
ONLINE_INTERVAL = max(15, int(os.getenv("TG247_ONLINE_INTERVAL", "25")))
COMMAND_MAX_AGE = 120


def ensure(mod, package=None):
    try:
        return importlib.import_module(mod)
    except Exception:
        package = package or mod
        subprocess.check_call([sys.executable, "-m", "pip", "install", "--user", package])
        importlib.invalidate_caches()
        return importlib.import_module(mod)

requests = ensure("requests")
ensure("cryptography")
ensure("telethon")
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from telethon import TelegramClient, functions
from telethon.sessions import StringSession
from telethon.errors import SessionPasswordNeededError, PhoneCodeInvalidError, PhoneCodeExpiredError, PasswordHashInvalidError, FloodWaitError

KEY = hashlib.sha256(PAIR_SECRET.encode("utf-8")).digest()
AT_REST_KEY = hashlib.sha256(("session:" + PAIR_SECRET).encode("utf-8")).digest()
http = requests.Session()
http.headers.update({"User-Agent": "Telegram247/1.0"})


def seal_json(obj, key=KEY):
    raw = json.dumps(obj, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    nonce = os.urandom(12)
    encrypted = AESGCM(key).encrypt(nonce, raw, None)
    return base64.b64encode(nonce + encrypted).decode("ascii")


def open_json(text, key=KEY):
    raw = base64.b64decode(text)
    if len(raw) < 29:
        raise ValueError("short encrypted payload")
    clear = AESGCM(key).decrypt(raw[:12], raw[12:], None)
    return json.loads(clear.decode("utf-8"))


def emit(kind, text, state=None, **extra):
    payload = {"kind": kind, "text": text, "ts": time.time()}
    if state is not None:
        payload["state"] = state
    payload.update(extra)
    try:
        r = http.post(f"{NTFY_BASE}/{EVT_TOPIC}", data=seal_json(payload).encode("utf-8"), timeout=12)
        r.raise_for_status()
    except Exception as exc:
        print(f"EVENT ERROR: {type(exc).__name__}: {exc}", flush=True)


def save_settings(online_enabled):
    SETTINGS_FILE.write_text(json.dumps({"online_enabled": bool(online_enabled)}), encoding="utf-8")


def load_settings():
    try:
        return bool(json.loads(SETTINGS_FILE.read_text(encoding="utf-8")).get("online_enabled", False))
    except Exception:
        return False


def save_session_bundle(data):
    SESSION_FILE.write_text(seal_json(data, AT_REST_KEY), encoding="utf-8")


def load_session_bundle():
    if not SESSION_FILE.exists():
        return None
    return open_json(SESSION_FILE.read_text(encoding="utf-8"), AT_REST_KEY)


def delete_session_file():
    try:
        SESSION_FILE.unlink(missing_ok=True)
    except Exception:
        pass


def load_seen():
    try:
        rows = json.loads(SEEN_FILE.read_text(encoding="utf-8"))
        return list(rows)[-100:]
    except Exception:
        return []

_seen_ids = load_seen()
_seen_set = set(_seen_ids)


def remember_seen(request_id):
    if not request_id or request_id in _seen_set:
        return
    _seen_ids.append(request_id)
    _seen_set.add(request_id)
    while len(_seen_ids) > 100:
        old = _seen_ids.pop(0)
        _seen_set.discard(old)
    try:
        SEEN_FILE.write_text(json.dumps(_seen_ids), encoding="utf-8")
    except Exception:
        pass


loop = asyncio.new_event_loop()
telegram_thread = None
client = None
pending = None
online_task = None
online_enabled = load_settings()
last_heartbeat = None


def start_async_loop():
    global telegram_thread
    def runner():
        asyncio.set_event_loop(loop)
        loop.run_forever()
    telegram_thread = threading.Thread(target=runner, daemon=True, name="telegram247-async")
    telegram_thread.start()


def run_coro(coro, timeout=90):
    fut = asyncio.run_coroutine_threadsafe(coro, loop)
    return fut.result(timeout=timeout)


async def restore_client():
    global client
    bundle = load_session_bundle()
    if not bundle:
        return False
    try:
        c = TelegramClient(StringSession(bundle["session"]), int(bundle["api_id"]), bundle["api_hash"], device_model="Telegram 24/7 Server", app_version="1.0")
        await c.connect()
        if not await c.is_user_authorized():
            await c.disconnect()
            delete_session_file()
            return False
        client = c
        return True
    except Exception:
        return False


async def ensure_client():
    global client
    if client is not None:
        try:
            if not client.is_connected():
                await client.connect()
            if await client.is_user_authorized():
                return client
        except Exception:
            pass
    ok = await restore_client()
    if not ok:
        raise RuntimeError("Telegram ещё не авторизован")
    return client


async def finalize_login(c, api_id, api_hash, phone):
    global client, pending, online_enabled
    me = await c.get_me()
    session_string = c.session.save()
    save_session_bundle({
        "api_id": int(api_id),
        "api_hash": api_hash,
        "phone": phone,
        "session": session_string,
        "user_id": getattr(me, "id", None),
        "created_at": time.time(),
    })
    if client is not None and client is not c:
        try: await client.disconnect()
        except Exception: pass
    client = c
    pending = None
    online_enabled = True
    save_settings(True)
    await ensure_online_task()
    name = " ".join(x for x in [getattr(me, "first_name", None), getattr(me, "last_name", None)] if x) or str(getattr(me, "id", ""))
    emit("login_ok", f"✅ Вход выполнен: {name}. Онлайн 24/7 включён.", state="online")


async def login_start(api_id, api_hash, phone):
    global pending
    if pending and pending.get("client"):
        try: await pending["client"].disconnect()
        except Exception: pass
    c = TelegramClient(StringSession(), int(api_id), str(api_hash), device_model="Telegram 24/7 Server", app_version="1.0")
    await c.connect()
    sent = await c.send_code_request(str(phone))
    pending = {
        "client": c,
        "api_id": int(api_id),
        "api_hash": str(api_hash),
        "phone": str(phone),
        "phone_code_hash": sent.phone_code_hash,
        "created_at": time.time(),
    }
    emit("code_sent", "📩 Telegram отправил код. Введи его в приложении.", state="connected")


async def login_code(code):
    if not pending:
        raise RuntimeError("Сначала нажми «Получить код»")
    c = pending["client"]
    try:
        await c.sign_in(phone=pending["phone"], code=str(code), phone_code_hash=pending["phone_code_hash"])
    except SessionPasswordNeededError:
        emit("need_2fa", "🔒 На аккаунте включена двухэтапная защита. Введи пароль 2FA.", state="connected")
        return
    await finalize_login(c, pending["api_id"], pending["api_hash"], pending["phone"])


async def login_2fa(password):
    if not pending:
        raise RuntimeError("Нет ожидающего входа")
    c = pending["client"]
    await c.sign_in(password=str(password))
    await finalize_login(c, pending["api_id"], pending["api_hash"], pending["phone"])


async def heartbeat_loop():
    global last_heartbeat, online_enabled
    while online_enabled:
        try:
            c = await ensure_client()
            await c(functions.account.UpdateStatusRequest(offline=False))
            last_heartbeat = time.time()
        except FloodWaitError as exc:
            wait_for = max(int(getattr(exc, "seconds", 30)), 30)
            emit("flood_wait", f"⏳ Telegram попросил паузу {wait_for} сек.", state="authorized")
            await asyncio.sleep(wait_for)
            continue
        except Exception as exc:
            emit("heartbeat_error", f"⚠️ Ошибка поддержания онлайна: {type(exc).__name__}", state="authorized")
        await asyncio.sleep(ONLINE_INTERVAL)


async def ensure_online_task():
    global online_task
    if online_task is None or online_task.done():
        online_task = asyncio.create_task(heartbeat_loop())


async def online_start():
    global online_enabled
    await ensure_client()
    online_enabled = True
    save_settings(True)
    await ensure_online_task()
    emit("online", f"🟢 Онлайн 24/7 включён. Обновление статуса примерно каждые {ONLINE_INTERVAL} сек.", state="online")


async def online_stop():
    global online_enabled
    online_enabled = False
    save_settings(False)
    try:
        c = await ensure_client()
        await c(functions.account.UpdateStatusRequest(offline=True))
    except Exception:
        pass
    emit("offline", "⏸ Онлайн 24/7 выключен. Серверная авторизация сохранена.", state="offline")


async def status_text():
    try:
        c = await ensure_client()
        me = await c.get_me()
        name = " ".join(x for x in [getattr(me, "first_name", None), getattr(me, "last_name", None)] if x) or str(getattr(me, "id", ""))
        hb = "ещё не было"
        if last_heartbeat:
            hb = time.strftime("%H:%M:%S", time.localtime(last_heartbeat))
        emit("status", f"✅ Сервер подключён\n👤 Telegram: {name}\n🔐 Авторизация: ДА\n🟢 Онлайн 24/7: {'ВКЛ' if online_enabled else 'ВЫКЛ'}\n💓 Последнее обновление: {hb}", state="online" if online_enabled else "authorized")
    except Exception:
        emit("status", "✅ Сервер связи работает\n🔐 Telegram: ещё не авторизован", state="connected")


async def sessions_text():
    c = await ensure_client()
    result = await c(functions.account.GetAuthorizationsRequest())
    lines = [f"🔐 Активные Telegram-сессии: {len(result.authorizations)}"]
    for a in result.authorizations[:12]:
        marker = "➡️" if getattr(a, "current", False) else "•"
        device = getattr(a, "device_model", "устройство") or "устройство"
        platform = getattr(a, "platform", "") or ""
        country = getattr(a, "country", "") or ""
        lines.append(f"{marker} {device} {platform} {country}".strip())
    emit("sessions", "\n".join(lines), state="online" if online_enabled else "authorized")


async def logout_server():
    global client, pending, online_enabled
    online_enabled = False
    save_settings(False)
    if pending and pending.get("client"):
        try: await pending["client"].disconnect()
        except Exception: pass
    pending = None
    try:
        c = await ensure_client()
        await c.log_out()
        try: await c.disconnect()
        except Exception: pass
    except Exception:
        pass
    client = None
    delete_session_file()
    emit("logged_out", "🚨 Серверная Telegram-сессия отозвана и удалена. Для повторного запуска нужен новый вход.", state="logged_out")


async def bootstrap_restore():
    if SESSION_FILE.exists():
        ok = await restore_client()
        if ok:
            emit("startup", "✅ Сервер запущен. Сохранённая Telegram-сессия восстановлена.", state="online" if online_enabled else "authorized")
            if online_enabled:
                await ensure_online_task()
        else:
            emit("startup", "⚠️ Сохранённая сессия недействительна. Выполни вход заново.", state="connected")
    else:
        emit("startup", "✅ Сервер Telegram 24/7 запущен. Ожидаю вход из приложения.", state="connected")


def execute_command(cmd):
    action = cmd.get("action")
    if action == "login_start": return run_coro(login_start(cmd.get("api_id"), cmd.get("api_hash"), cmd.get("phone")))
    if action == "login_code": return run_coro(login_code(cmd.get("code")))
    if action == "login_2fa": return run_coro(login_2fa(cmd.get("password")))
    if action == "online_start": return run_coro(online_start())
    if action == "online_stop": return run_coro(online_stop())
    if action == "status": return run_coro(status_text())
    if action == "sessions": return run_coro(sessions_text())
    if action == "logout_server": return run_coro(logout_server())
    raise RuntimeError("Неизвестная команда")


def command_loop():
    print("Telegram 24/7 bridge started", flush=True)
    while True:
        try:
            r = http.get(f"{NTFY_BASE}/{CMD_TOPIC}/json", params={"poll": "1", "since": "30s"}, timeout=15)
            r.raise_for_status()
            for line in r.text.splitlines():
                try:
                    env = json.loads(line)
                    if env.get("event") != "message" or not env.get("message"): continue
                    cmd = open_json(env["message"])
                    request_id = str(cmd.get("request_id") or "")
                    if request_id and request_id in _seen_set: continue
                    ts = float(cmd.get("ts") or 0)
                    if abs(time.time() - ts) > COMMAND_MAX_AGE:
                        if request_id: remember_seen(request_id)
                        continue
                    if request_id: remember_seen(request_id)
                    execute_command(cmd)
                except (PhoneCodeInvalidError, PhoneCodeExpiredError):
                    emit("login_error", "❌ Код неверный или уже истёк. Запроси новый код.", state="connected")
                except PasswordHashInvalidError:
                    emit("login_error", "❌ Неверный пароль 2FA.", state="connected")
                except FloodWaitError as exc:
                    emit("flood_wait", f"⏳ Telegram временно ограничил запрос. Подожди {getattr(exc, 'seconds', '?')} сек.", state="connected")
                except Exception as exc:
                    emit("error", f"❌ {type(exc).__name__}: {str(exc)[:240]}", state="connected")
        except Exception as exc:
            print(f"BRIDGE ERROR: {type(exc).__name__}: {exc}", flush=True)
        time.sleep(2)


def main():
    if "__TG247_" in CMD_TOPIC or "__TG247_" in PAIR_SECRET:
        raise SystemExit("This template must be paired by the GitHub build workflow first")
    start_async_loop()
    run_coro(bootstrap_restore())
    command_loop()

if __name__ == "__main__":
    main()
