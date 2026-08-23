#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Telegram 24/7 HARDENED server.

Security model:
- Public/source template contains no Telegram api_id/api_hash, 2FA password or user session.
- Commands are AES-GCM encrypted in transit AND signed by a P-256 device key.
- The server pins the first iPhone public key. Later key substitution is rejected.
- request_id + timestamp + persistent replay cache block replay of old commands.
- Telegram StringSession + api_id/api_hash/phone are AES-GCM encrypted at rest with a
  random vault key generated and stored only in the iPhone Keychain.
- The vault key is never written to server disk. After a server restart the iPhone must
  unlock the vault once; until then the encrypted session cannot be restored.
- The encrypted session is bound to the pinned iPhone public-key fingerprint.
- Telegram login code and 2FA password are never written to logs or disk.

Important limitation: a malicious hosting administrator who can inspect the live Python
process memory while the account is connected can still access runtime secrets. No design
can make a secret invisible to the machine that must actively use it.
"""
import os
import sys
import time
import json
import base64
import hashlib
import threading
import asyncio
import subprocess
import importlib
from pathlib import Path

CMD_TOPIC = "__TG247H_CMD_TOPIC__"
EVT_TOPIC = "__TG247H_EVT_TOPIC__"
PAIR_SECRET = "__TG247H_PAIR_SECRET__"
NTFY_BASE = os.getenv("TG247_NTFY_BASE", "https://ntfy.sh")
SESSION_FILE = Path(os.getenv("TG247_SESSION_FILE", "telegram247_session.enc"))
DEVICE_FILE = Path(os.getenv("TG247_DEVICE_FILE", "telegram247_device.json"))
SETTINGS_FILE = Path(os.getenv("TG247_SETTINGS_FILE", "telegram247_settings.json"))
SEEN_FILE = Path(os.getenv("TG247_SEEN_FILE", "telegram247_seen.json"))
ONLINE_INTERVAL = max(20, int(os.getenv("TG247_ONLINE_INTERVAL", "30")))
COMMAND_MAX_AGE_MS = 120_000


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
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives import hashes
from telethon import TelegramClient, functions
from telethon.sessions import StringSession
from telethon.errors import SessionPasswordNeededError, PhoneCodeInvalidError, PhoneCodeExpiredError, PasswordHashInvalidError, FloodWaitError

BRIDGE_KEY = hashlib.sha256(("bridge:" + PAIR_SECRET).encode("utf-8")).digest()
http = requests.Session()
http.headers.update({"User-Agent": "Telegram247-Hardened/2.0"})


def secure_write(path: Path, text: str):
    path = Path(path)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(text, encoding="utf-8")
    try: os.chmod(tmp, 0o600)
    except Exception: pass
    os.replace(tmp, path)
    try: os.chmod(path, 0o600)
    except Exception: pass


def b64d(value: str) -> bytes:
    return base64.b64decode(value.encode("ascii"), validate=True)


def b64e(value: bytes) -> str:
    return base64.b64encode(value).decode("ascii")


def seal_json(obj, key=BRIDGE_KEY):
    raw = json.dumps(obj, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    nonce = os.urandom(12)
    encrypted = AESGCM(key).encrypt(nonce, raw, None)
    return b64e(nonce + encrypted)


def open_json(text, key=BRIDGE_KEY):
    raw = b64d(text)
    if len(raw) < 29: raise ValueError("short encrypted payload")
    clear = AESGCM(key).decrypt(raw[:12], raw[12:], None)
    return json.loads(clear.decode("utf-8"))


def vault_cipher_key(vault_key: bytes) -> bytes:
    if len(vault_key) != 32: raise ValueError("vault key must be 32 bytes")
    return hashlib.sha256(b"tg247-vault-v2\x00" + vault_key).digest()


def fingerprint(pub_b64: str) -> str:
    return hashlib.sha256(b64d(pub_b64)).hexdigest()


def load_device():
    try:
        data = json.loads(DEVICE_FILE.read_text(encoding="utf-8"))
        if not data.get("device_id") or not data.get("public_key"): return None
        return data
    except Exception:
        return None


def save_device(device_id: str, public_key: str):
    data = {"device_id": str(device_id), "public_key": str(public_key), "fingerprint": fingerprint(public_key), "paired_at": time.time()}
    secure_write(DEVICE_FILE, json.dumps(data, ensure_ascii=False, separators=(",", ":")))
    return data


def public_key_from_b64(pub_b64: str):
    return ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), b64d(pub_b64))


def verify_signed_envelope(envelope):
    payload_raw = b64d(str(envelope.get("payload") or ""))
    signature = b64d(str(envelope.get("signature") or ""))
    cmd = json.loads(payload_raw.decode("utf-8"))
    action = str(cmd.get("action") or "")
    device_id = str(cmd.get("device_id") or "")
    fields = cmd.get("fields") if isinstance(cmd.get("fields"), dict) else {}
    if action == "pair":
        pub_b64 = str(fields.get("public_key") or "")
        if not pub_b64: raise PermissionError("public key missing")
        pub = public_key_from_b64(pub_b64)
        pub.verify(signature, payload_raw, ec.ECDSA(hashes.SHA256()))
        current = load_device()
        if current:
            if current["device_id"] != device_id or current["public_key"] != pub_b64:
                raise PermissionError("сервер уже привязан к другому ключу iPhone")
        else:
            current = save_device(device_id, pub_b64)
        return cmd, current
    current = load_device()
    if not current: raise PermissionError("сначала привяжи iPhone")
    if current["device_id"] != device_id: raise PermissionError("неверный идентификатор устройства")
    pub = public_key_from_b64(current["public_key"])
    pub.verify(signature, payload_raw, ec.ECDSA(hashes.SHA256()))
    return cmd, current


def emit(kind, text, state=None, **extra):
    payload = {"kind": kind, "text": text, "ts": time.time()}
    if state is not None: payload["state"] = state
    payload.update(extra)
    try:
        r = http.post(f"{NTFY_BASE}/{EVT_TOPIC}", data=seal_json(payload).encode("utf-8"), timeout=12)
        r.raise_for_status()
    except Exception as exc:
        print(f"EVENT ERROR: {type(exc).__name__}: {exc}", flush=True)


def save_settings(enabled: bool): secure_write(SETTINGS_FILE, json.dumps({"online_enabled": bool(enabled)}, separators=(",", ":")))

def load_settings():
    try: return bool(json.loads(SETTINGS_FILE.read_text(encoding="utf-8")).get("online_enabled", False))
    except Exception: return False

def delete_session_file():
    try: SESSION_FILE.unlink(missing_ok=True)
    except Exception: pass

def load_seen():
    try: return list(json.loads(SEEN_FILE.read_text(encoding="utf-8")))[-200:]
    except Exception: return []

_seen_ids = load_seen()
_seen_set = set(_seen_ids)

def remember_seen(request_id):
    if not request_id or request_id in _seen_set: return
    _seen_ids.append(request_id); _seen_set.add(request_id)
    while len(_seen_ids) > 200:
        old = _seen_ids.pop(0); _seen_set.discard(old)
    try: secure_write(SEEN_FILE, json.dumps(_seen_ids, separators=(",", ":")))
    except Exception: pass

loop = asyncio.new_event_loop()
telegram_thread = None
client = None
pending = None
online_task = None
online_enabled = load_settings()
last_heartbeat = None
_vault_key = None


def set_vault_key(raw_b64: str):
    global _vault_key
    raw = b64d(str(raw_b64))
    if len(raw) != 32: raise ValueError("неверный vault key")
    _vault_key = raw

def clear_vault_key():
    global _vault_key
    _vault_key = None

def save_session_bundle(data):
    if _vault_key is None: raise RuntimeError("vault заблокирован")
    device = load_device()
    if not device: raise RuntimeError("iPhone не привязан")
    data = dict(data); data["device_fingerprint"] = device["fingerprint"]; data["format"] = 2
    secure_write(SESSION_FILE, seal_json(data, vault_cipher_key(_vault_key)))

def load_session_bundle():
    if not SESSION_FILE.exists(): return None
    if _vault_key is None: raise RuntimeError("vault заблокирован")
    data = open_json(SESSION_FILE.read_text(encoding="utf-8"), vault_cipher_key(_vault_key))
    device = load_device()
    if not device or data.get("device_fingerprint") != device.get("fingerprint"):
        raise PermissionError("ключ устройства не совпадает с зашифрованной сессией")
    return data


def start_async_loop():
    global telegram_thread
    def runner():
        asyncio.set_event_loop(loop); loop.run_forever()
    telegram_thread = threading.Thread(target=runner, daemon=True, name="telegram247h-async")
    telegram_thread.start()

def run_coro(coro, timeout=90):
    return asyncio.run_coroutine_threadsafe(coro, loop).result(timeout=timeout)


async def restore_client():
    global client
    bundle = load_session_bundle()
    if not bundle: return False
    c = None
    try:
        c = TelegramClient(StringSession(bundle["session"]), int(bundle["api_id"]), bundle["api_hash"], device_model="Telegram 24/7 Hardened", app_version="2.0")
        await c.connect()
        if not await c.is_user_authorized():
            await c.disconnect(); delete_session_file(); return False
        client = c; return True
    except Exception:
        if c is not None:
            try: await c.disconnect()
            except Exception: pass
        return False

async def ensure_client():
    global client
    if client is not None:
        try:
            if not client.is_connected(): await client.connect()
            if await client.is_user_authorized(): return client
        except Exception: pass
    if _vault_key is None: raise RuntimeError("сервер заблокирован — открой IPA для разблокировки")
    if not await restore_client(): raise RuntimeError("Telegram ещё не авторизован")
    return client

async def unlock_vault(vault_key_b64):
    set_vault_key(vault_key_b64)
    if SESSION_FILE.exists():
        try:
            ok = await restore_client()
            if ok:
                if online_enabled: await ensure_online_task()
                emit("unlocked", "🔓 Защищённое хранилище разблокировано этим iPhone. Telegram-сессия восстановлена.", state="online" if online_enabled else "authorized")
                return
        except Exception:
            clear_vault_key(); raise RuntimeError("не удалось расшифровать сессию: неверный ключ устройства или файл изменён")
    emit("unlocked", "🔓 Сервер разблокирован этим iPhone. Сохранённой Telegram-сессии пока нет.", state="connected")

async def finalize_login(c, api_id, api_hash, phone):
    global client, pending, online_enabled
    me = await c.get_me()
    save_session_bundle({"api_id": int(api_id), "api_hash": str(api_hash), "phone": str(phone), "session": c.session.save(), "user_id": getattr(me, "id", None), "created_at": time.time()})
    if client is not None and client is not c:
        try: await client.disconnect()
        except Exception: pass
    client = c; pending = None; online_enabled = True; save_settings(True)
    await ensure_online_task()
    name = " ".join(x for x in [getattr(me, "first_name", None), getattr(me, "last_name", None)] if x) or str(getattr(me, "id", ""))
    emit("login_ok", f"✅ Вход выполнен: {name}. Онлайн 24/7 включён. Сессия на диске зашифрована ключом этого iPhone.", state="online")

async def login_start(api_id, api_hash, phone):
    global pending
    if _vault_key is None: raise RuntimeError("сначала разблокируй сервер из IPA")
    if pending and pending.get("client"):
        try: await pending["client"].disconnect()
        except Exception: pass
    c = TelegramClient(StringSession(), int(api_id), str(api_hash), device_model="Telegram 24/7 Hardened", app_version="2.0")
    await c.connect(); sent = await c.send_code_request(str(phone))
    pending = {"client": c, "api_id": int(api_id), "api_hash": str(api_hash), "phone": str(phone), "phone_code_hash": sent.phone_code_hash, "created_at": time.time()}
    emit("code_sent", "📩 Telegram отправил код. Введи его в приложении.", state="connected")

async def login_code(code):
    if not pending: raise RuntimeError("сначала нажми «Получить код»")
    c = pending["client"]
    try: await c.sign_in(phone=pending["phone"], code=str(code), phone_code_hash=pending["phone_code_hash"])
    except SessionPasswordNeededError:
        emit("need_2fa", "🔒 Двухэтапная защита включена. Введи облачный пароль 2FA.", state="connected"); return
    await finalize_login(c, pending["api_id"], pending["api_hash"], pending["phone"])

async def login_2fa(password):
    if not pending: raise RuntimeError("нет ожидающего входа")
    c = pending["client"]; await c.sign_in(password=str(password)); await finalize_login(c, pending["api_id"], pending["api_hash"], pending["phone"])

async def heartbeat_loop():
    global last_heartbeat, online_enabled
    while online_enabled:
        try:
            c = await ensure_client(); await c(functions.account.UpdateStatusRequest(offline=False)); last_heartbeat = time.time()
        except FloodWaitError as exc:
            wait_for = max(int(getattr(exc, "seconds", 30)), 30); emit("flood_wait", f"⏳ Telegram попросил паузу {wait_for} сек.", state="authorized"); await asyncio.sleep(wait_for); continue
        except Exception as exc:
            emit("heartbeat_error", f"⚠️ Ошибка поддержания онлайна: {type(exc).__name__}", state="authorized")
        await asyncio.sleep(ONLINE_INTERVAL)

async def ensure_online_task():
    global online_task
    if online_task is None or online_task.done(): online_task = asyncio.create_task(heartbeat_loop())
async def online_start():
    global online_enabled
    await ensure_client(); online_enabled = True; save_settings(True); await ensure_online_task(); emit("online", f"🟢 Онлайн 24/7 включён. Обновление статуса примерно каждые {ONLINE_INTERVAL} сек.", state="online")
async def online_stop():
    global online_enabled
    online_enabled = False; save_settings(False)
    try:
        c = await ensure_client(); await c(functions.account.UpdateStatusRequest(offline=True))
    except Exception: pass
    emit("offline", "⏸ Онлайн 24/7 выключен. Зашифрованная авторизация сохранена.", state="offline")

async def status_text():
    device = load_device(); device_line = "НЕТ" if not device else "ДА • " + device.get("fingerprint", "")[:12]
    vault_line = "РАЗБЛОКИРОВАН" if _vault_key is not None else "ЗАБЛОКИРОВАН"; session_line = "есть (AES-GCM)" if SESSION_FILE.exists() else "нет"
    try:
        c = await ensure_client(); me = await c.get_me(); name = " ".join(x for x in [getattr(me, "first_name", None), getattr(me, "last_name", None)] if x) or str(getattr(me, "id", "")); hb = "ещё не было" if not last_heartbeat else time.strftime("%H:%M:%S", time.localtime(last_heartbeat))
        emit("status", "✅ Сервер подключён\n" + f"👤 Telegram: {name}\n🔐 Авторизация: ДА\n📱 Привязка iPhone: {device_line}\n🗝 Vault: {vault_line}\n💾 Сессия на диске: {session_line}\n🟢 Онлайн 24/7: {'ВКЛ' if online_enabled else 'ВЫКЛ'}\n💓 Последнее обновление: {hb}", state="online" if online_enabled else "authorized")
    except Exception:
        emit("status", "✅ Сервер связи работает\n" + f"📱 Привязка iPhone: {device_line}\n🗝 Vault: {vault_line}\n💾 Зашифрованная сессия: {session_line}\n🔐 Telegram: не активирован/заблокирован", state="connected")

async def security_text():
    device = load_device(); lines = ["🛡 ПРОВЕРКА ЗАЩИТЫ", "✅ Команды подписываются P-256", "✅ Защита от повторных request_id + срок команды", "✅ Канал команд AES-GCM", "✅ Telegram-сессия AES-GCM на диске", "✅ Ключ сессии не записывается на сервер", "✅ Код Telegram / 2FA не записываются"]
    lines.append("✅ iPhone привязан: " + device.get("fingerprint", "")[:16] if device else "⚠️ iPhone ещё не привязан")
    lines.append("🔓 Vault: " + ("разблокирован" if _vault_key is not None else "заблокирован"))
    emit("security", "\n".join(lines), state="authorized" if SESSION_FILE.exists() else "connected")

async def sessions_text():
    c = await ensure_client(); result = await c(functions.account.GetAuthorizationsRequest()); lines = [f"🔐 Активные Telegram-сессии: {len(result.authorizations)}"]
    for a in result.authorizations[:12]:
        marker = "➡️" if getattr(a, "current", False) else "•"; device = getattr(a, "device_model", "устройство") or "устройство"; platform = getattr(a, "platform", "") or ""; country = getattr(a, "country", "") or ""; lines.append(f"{marker} {device} {platform} {country}".strip())
    emit("sessions", "\n".join(lines), state="online" if online_enabled else "authorized")

async def logout_server():
    global client, pending, online_enabled
    online_enabled = False; save_settings(False)
    if pending and pending.get("client"):
        try: await pending["client"].disconnect()
        except Exception: pass
    pending = None
    try:
        c = await ensure_client(); await c.log_out()
        try: await c.disconnect()
        except Exception: pass
    except Exception: pass
    client = None; delete_session_file(); clear_vault_key(); emit("logged_out", "🚨 Серверная Telegram-сессия отозвана и зашифрованный файл удалён. Для нового входа снова открой IPA.", state="logged_out")

async def pair_ack(device):
    emit("paired", "📱 iPhone привязан. Отпечаток ключа: " + device.get("fingerprint", "")[:16] + ". Подмена другим ключом запрещена.", state="connected")


def execute_command(cmd, device):
    action = str(cmd.get("action") or ""); fields = cmd.get("fields") if isinstance(cmd.get("fields"), dict) else {}
    if action == "pair": return run_coro(pair_ack(device))
    if action == "unlock": return run_coro(unlock_vault(fields.get("vault_key")))
    if action == "login_start": return run_coro(login_start(fields.get("api_id"), fields.get("api_hash"), fields.get("phone")))
    if action == "login_code": return run_coro(login_code(fields.get("code")))
    if action == "login_2fa": return run_coro(login_2fa(fields.get("password")))
    if action == "online_start": return run_coro(online_start())
    if action == "online_stop": return run_coro(online_stop())
    if action == "status": return run_coro(status_text())
    if action == "security": return run_coro(security_text())
    if action == "sessions": return run_coro(sessions_text())
    if action == "logout_server": return run_coro(logout_server())
    raise RuntimeError("неизвестная команда")


def command_loop():
    print("Telegram 24/7 HARDENED bridge started", flush=True)
    while True:
        try:
            r = http.get(f"{NTFY_BASE}/{CMD_TOPIC}/json", params={"poll": "1", "since": "30s"}, timeout=15); r.raise_for_status()
            for line in r.text.splitlines():
                try:
                    env = json.loads(line)
                    if env.get("event") != "message" or not env.get("message"): continue
                    cmd, device = verify_signed_envelope(open_json(env["message"]))
                    request_id = str(cmd.get("request_id") or "")
                    if request_id and request_id in _seen_set: continue
                    ts_ms = int(cmd.get("ts_ms") or 0)
                    if abs(int(time.time() * 1000) - ts_ms) > COMMAND_MAX_AGE_MS:
                        if request_id: remember_seen(request_id)
                        continue
                    if request_id: remember_seen(request_id)
                    execute_command(cmd, device)
                except (PhoneCodeInvalidError, PhoneCodeExpiredError): emit("login_error", "❌ Код неверный или уже истёк. Запроси новый код.", state="connected")
                except PasswordHashInvalidError: emit("login_error", "❌ Неверный пароль 2FA.", state="connected")
                except FloodWaitError as exc: emit("flood_wait", f"⏳ Telegram временно ограничил запрос. Подожди {getattr(exc, 'seconds', '?')} сек.", state="connected")
                except PermissionError as exc: emit("security_error", "🚫 Команда отклонена защитой: " + str(exc)[:180], state="connected")
                except Exception as exc: emit("error", f"❌ {type(exc).__name__}: {str(exc)[:220]}", state="connected")
        except Exception as exc:
            print(f"BRIDGE ERROR: {type(exc).__name__}: {exc}", flush=True)
        time.sleep(2)


def main():
    if "__TG247H_" in CMD_TOPIC or "__TG247H_" in EVT_TOPIC or "__TG247H_" in PAIR_SECRET:
        raise SystemExit("This template must be paired by the GitHub build workflow first")
    start_async_loop()
    if SESSION_FILE.exists(): emit("startup", "🔒 Сервер запущен. Сессия зашифрована и заблокирована — открой IPA для автоматической разблокировки.", state="connected")
    else: emit("startup", "✅ Сервер Telegram 24/7 HARDENED запущен. Ожидаю привязку iPhone.", state="connected")
    command_loop()

if __name__ == "__main__": main()
