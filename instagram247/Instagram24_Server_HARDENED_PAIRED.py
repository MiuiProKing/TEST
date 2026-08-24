#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Instagram 24/7 HARDENED — приватный сервер для парного iPhone IPA.

Модель защиты:
- пароль Instagram и private API session отсутствуют в исходном файле;
- команды AES-GCM зашифрованы и подписаны P-256 ключом iPhone;
- приватный ключ AES-GCM автоматически встроен только в парные IPA и Python;
- сервер закрепляет первый публичный ключ и отклоняет подмену устройства;
- request_id, timestamp и replay-cache блокируют повтор старых команд;
- логин, пароль и instagrapi settings хранятся на диске только в AES-GCM;
- vault-key существует в Keychain iPhone и не записывается сервером;
- после перезапуска хостинга нужно открыть парное IPA для разблокировки;
- одноразовый код Instagram не записывается в логи или на диск.

Ограничение: Instagram Realtime MQTT является неофициальным private transport.
Instagram самостоятельно решает, когда показывать зелёную точку «В сети».
"""

from __future__ import annotations

import base64
import hashlib
import importlib
import json
import os
import random
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


CMD_TOPIC = "ig247h-cmd-cd4f6a6f08fa8650818cb8846c4a949df59df473fa449904"
EVT_TOPIC = "ig247h-evt-cfbd5eef08a5bfd00fee593e573b746a3380dbe5b1b7a1fe"
PAIR_SECRET = "__IG247_AUTOPAIR_SECRET__"

if PAIR_SECRET.startswith("__IG247_"):
    raise RuntimeError("Это исходный шаблон. Используй собранный файл Instagram24_Server_AUTOPAIR.py")

NTFY_BASE = os.getenv("IG247_NTFY_BASE", "https://ntfy.sh").rstrip("/")
SESSION_FILE = Path(os.getenv("IG247_SESSION_FILE", "instagram247_session.enc"))
DEVICE_FILE = Path(os.getenv("IG247_DEVICE_FILE", "instagram247_device.json"))
SETTINGS_FILE = Path(os.getenv("IG247_SETTINGS_FILE", "instagram247_settings.json"))
SEEN_FILE = Path(os.getenv("IG247_SEEN_FILE", "instagram247_seen.json"))
PROXY = os.getenv("INSTAGRAM_PROXY", "").strip()

PING_MIN_SECONDS = max(20, int(os.getenv("IG247_PING_MIN", "38")))
PING_MAX_SECONDS = max(PING_MIN_SECONDS, int(os.getenv("IG247_PING_MAX", "48")))
COMMAND_MAX_AGE_MS = 120_000


def ensure(module: str, package: str | None = None):
    try:
        return importlib.import_module(module)
    except Exception:
        package = package or module
        commands = [
            [sys.executable, "-m", "pip", "install", "--user", package],
            [sys.executable, "-m", "pip", "install", package],
        ]
        last_error = None
        for command in commands:
            try:
                subprocess.check_call(command)
                importlib.invalidate_caches()
                return importlib.import_module(module)
            except Exception as exc:
                last_error = exc
        raise RuntimeError(f"Не удалось установить {package}: {last_error}")


requests = ensure("requests")
ensure("cryptography")
ensure("instagrapi", "instagrapi==2.18.17")

from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from instagrapi import Client
from instagrapi.exceptions import (
    BadPassword,
    ChallengeRequired,
    LoginRequired,
    PleaseWaitFewMinutes,
    TwoFactorRequired,
)


http = requests.Session()
http.headers.update({"User-Agent": "Instagram247-Hardened/1.0"})


def secure_write(path: Path, text: str) -> None:
    path = Path(path)
    temp = path.with_suffix(path.suffix + ".tmp")
    temp.write_text(text, encoding="utf-8")
    try:
        os.chmod(temp, 0o600)
    except OSError:
        pass
    os.replace(temp, path)
    try:
        os.chmod(path, 0o600)
    except OSError:
        pass


BRIDGE_KEY = hashlib.sha256(("bridge:" + PAIR_SECRET).encode("utf-8")).digest()


def b64d(value: str) -> bytes:
    return base64.b64decode(value.encode("ascii"), validate=True)


def b64e(value: bytes) -> str:
    return base64.b64encode(value).decode("ascii")


def seal_json(value: dict, key: bytes = BRIDGE_KEY) -> str:
    clear = json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    nonce = os.urandom(12)
    return b64e(nonce + AESGCM(key).encrypt(nonce, clear, None))


def open_json(value: str, key: bytes = BRIDGE_KEY) -> dict:
    raw = b64d(value)
    if len(raw) < 29:
        raise ValueError("короткий encrypted payload")
    clear = AESGCM(key).decrypt(raw[:12], raw[12:], None)
    return json.loads(clear.decode("utf-8"))


def vault_cipher_key(vault_key: bytes) -> bytes:
    if len(vault_key) != 32:
        raise ValueError("vault key должен быть 32 байта")
    return hashlib.sha256(b"instagram247-vault-v1\x00" + vault_key).digest()


def fingerprint(public_key_b64: str) -> str:
    return hashlib.sha256(b64d(public_key_b64)).hexdigest()


def load_device() -> dict | None:
    try:
        data = json.loads(DEVICE_FILE.read_text(encoding="utf-8"))
        if not data.get("device_id") or not data.get("public_key"):
            return None
        return data
    except Exception:
        return None


def save_device(device_id: str, public_key: str) -> dict:
    data = {
        "device_id": str(device_id),
        "public_key": str(public_key),
        "fingerprint": fingerprint(public_key),
        "paired_at": time.time(),
    }
    secure_write(DEVICE_FILE, json.dumps(data, ensure_ascii=False, separators=(",", ":")))
    return data


def public_key_from_b64(value: str):
    return ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), b64d(value))


def verify_signed_envelope(envelope: dict) -> tuple[dict, dict]:
    payload_raw = b64d(str(envelope.get("payload") or ""))
    signature = b64d(str(envelope.get("signature") or ""))
    command = json.loads(payload_raw.decode("utf-8"))
    action = str(command.get("action") or "")
    device_id = str(command.get("device_id") or "")
    fields = command.get("fields") if isinstance(command.get("fields"), dict) else {}

    if action == "pair":
        public_key_b64 = str(fields.get("public_key") or "")
        if not public_key_b64:
            raise PermissionError("public key отсутствует")
        public_key = public_key_from_b64(public_key_b64)
        public_key.verify(signature, payload_raw, ec.ECDSA(hashes.SHA256()))
        current = load_device()
        if current:
            if current["device_id"] != device_id or current["public_key"] != public_key_b64:
                raise PermissionError("сервер уже привязан к другому ключу iPhone")
        else:
            current = save_device(device_id, public_key_b64)
        return command, current

    current = load_device()
    if not current:
        raise PermissionError("сначала привяжи iPhone")
    if current["device_id"] != device_id:
        raise PermissionError("неверный идентификатор устройства")
    public_key = public_key_from_b64(current["public_key"])
    public_key.verify(signature, payload_raw, ec.ECDSA(hashes.SHA256()))
    return command, current


def emit(kind: str, text: str, state: str | None = None, **extra) -> None:
    payload = {"kind": kind, "text": text, "ts": time.time()}
    if state is not None:
        payload["state"] = state
    payload.update(extra)
    try:
        response = http.post(
            f"{NTFY_BASE}/{EVT_TOPIC}",
            data=seal_json(payload).encode("utf-8"),
            timeout=12,
        )
        response.raise_for_status()
    except Exception as exc:
        print(f"EVENT ERROR: {type(exc).__name__}: {exc}", flush=True)


def load_seen() -> list[str]:
    try:
        return list(json.loads(SEEN_FILE.read_text(encoding="utf-8")))[-200:]
    except Exception:
        return []


seen_ids = load_seen()
seen_set = set(seen_ids)


def remember_seen(request_id: str) -> None:
    if not request_id or request_id in seen_set:
        return
    seen_ids.append(request_id)
    seen_set.add(request_id)
    while len(seen_ids) > 200:
        old = seen_ids.pop(0)
        seen_set.discard(old)
    secure_write(SEEN_FILE, json.dumps(seen_ids, separators=(",", ":")))


def load_online_setting() -> bool:
    try:
        return bool(json.loads(SETTINGS_FILE.read_text(encoding="utf-8")).get("online_enabled", False))
    except Exception:
        return False


def save_online_setting(enabled: bool) -> None:
    secure_write(SETTINGS_FILE, json.dumps({"online_enabled": bool(enabled)}, separators=(",", ":")))


vault_key: bytes | None = None
instagram_client: Client | None = None
realtime_client = None
pending_login: dict | None = None
online_enabled = load_online_setting()
online_thread: threading.Thread | None = None
online_stop_event = threading.Event()
state_lock = threading.RLock()
last_heartbeat: float | None = None
last_error = ""


def set_vault_key(value_b64: str) -> None:
    global vault_key
    raw = b64d(str(value_b64))
    if len(raw) != 32:
        raise ValueError("неверный vault key")
    vault_key = raw


def clear_vault_key() -> None:
    global vault_key
    vault_key = None


def save_session_bundle(bundle: dict) -> None:
    if vault_key is None:
        raise RuntimeError("vault заблокирован")
    device = load_device()
    if not device:
        raise RuntimeError("iPhone не привязан")
    data = dict(bundle)
    data["device_fingerprint"] = device["fingerprint"]
    data["format"] = 1
    secure_write(SESSION_FILE, seal_json(data, vault_cipher_key(vault_key)))


def load_session_bundle() -> dict | None:
    if not SESSION_FILE.exists():
        return None
    if vault_key is None:
        raise RuntimeError("vault заблокирован")
    data = open_json(SESSION_FILE.read_text(encoding="utf-8"), vault_cipher_key(vault_key))
    device = load_device()
    if not device or data.get("device_fingerprint") != device.get("fingerprint"):
        raise PermissionError("ключ устройства не совпадает с зашифрованной сессией")
    return data


def make_client() -> Client:
    client = Client()
    client.delay_range = [1, 3]
    if PROXY:
        client.set_proxy(PROXY)
    return client


def disconnect_runtime() -> None:
    global realtime_client, instagram_client
    with state_lock:
        if realtime_client is not None:
            try:
                realtime_client.disconnect()
            except Exception:
                pass
        realtime_client = None
        instagram_client = None


def finish_login(client: Client, username: str, password: str) -> None:
    global instagram_client, pending_login, online_enabled, last_error
    save_session_bundle(
        {
            "username": username,
            "password": password,
            "settings": client.get_settings(),
            "saved_at": time.time(),
        }
    )
    with state_lock:
        instagram_client = client
        pending_login = None
        online_enabled = True
        last_error = ""
        save_online_setting(True)
    ensure_online_thread()
    emit(
        "login_ok",
        f"✅ Вход выполнен: @{username}. Онлайн 24/7 включён. Логин, пароль и session зашифрованы ключом iPhone.",
        state="online",
    )


def login_start(username: str, password: str) -> None:
    global pending_login
    if vault_key is None:
        raise RuntimeError("сначала разблокируй сервер из IPA")
    username = str(username or "").strip().lstrip("@")
    password = str(password or "")
    if not username or not password:
        raise ValueError("введи логин и пароль Instagram")

    client = make_client()
    pending_login = {"username": username, "password": password, "created_at": time.time()}
    try:
        client.login(username, password)
    except TwoFactorRequired:
        emit("need_2fa", "🔐 Instagram запросил одноразовый код 2FA. Введи его в приложении.", state="connected")
        return
    finish_login(client, username, password)


def login_code(code: str) -> None:
    if not pending_login:
        raise RuntimeError("сначала нажми «Войти Instagram»")
    code = str(code or "").strip().replace(" ", "")
    if not code:
        raise ValueError("введи одноразовый код")
    client = make_client()
    username = str(pending_login["username"])
    password = str(pending_login["password"])
    client.login(username, password, verification_code=code)
    finish_login(client, username, password)


def restore_account() -> bool:
    global instagram_client
    bundle = load_session_bundle()
    if not bundle:
        return False
    client = make_client()
    settings = bundle.get("settings")
    if isinstance(settings, dict):
        client.set_settings(settings)
    client.login(str(bundle["username"]), str(bundle["password"]))
    save_session_bundle(
        {
            "username": str(bundle["username"]),
            "password": str(bundle["password"]),
            "settings": client.get_settings(),
            "saved_at": time.time(),
        }
    )
    with state_lock:
        instagram_client = client
    return True


def ensure_account() -> Client:
    with state_lock:
        current = instagram_client
    if current is not None:
        return current
    if vault_key is None:
        raise RuntimeError("сервер заблокирован — открой IPA")
    if not restore_account():
        raise RuntimeError("Instagram ещё не авторизован")
    with state_lock:
        assert instagram_client is not None
        return instagram_client


def realtime_online_loop() -> None:
    global realtime_client, last_heartbeat, last_error
    reconnect_delay = 5
    while online_enabled and not online_stop_event.is_set():
        try:
            client = ensure_account()
            realtime = client.realtime_connect()
            with state_lock:
                realtime_client = realtime
                last_error = ""
            emit("online", "🟢 Instagram Realtime подключён. Поддерживаю foreground и keepalive 24/7.", state="online")
            reconnect_delay = 5

            while online_enabled and not online_stop_event.is_set():
                realtime.send_foreground_state(
                    in_foreground_app=True,
                    in_foreground_device=True,
                    keep_alive_timeout=120,
                )
                if not realtime.ping(max_packets=10):
                    raise ConnectionError("MQTT keepalive не подтверждён")
                with state_lock:
                    last_heartbeat = time.time()
                    last_error = ""
                online_stop_event.wait(random.randint(PING_MIN_SECONDS, PING_MAX_SECONDS))
        except Exception as exc:
            with state_lock:
                last_error = f"{type(exc).__name__}: {str(exc)[:160]}"
            emit("heartbeat_error", f"⚠️ Instagram Realtime: {type(exc).__name__}. Переподключаюсь.", state="authorized")
            disconnect_runtime()
            if not online_enabled or online_stop_event.wait(reconnect_delay):
                break
            reconnect_delay = min(300, reconnect_delay * 2)


def ensure_online_thread() -> None:
    global online_thread
    with state_lock:
        if online_thread is not None and online_thread.is_alive():
            return
        online_stop_event.clear()
        online_thread = threading.Thread(target=realtime_online_loop, daemon=True, name="instagram247-realtime")
        online_thread.start()


def unlock_vault(vault_key_b64: str) -> None:
    set_vault_key(vault_key_b64)
    if SESSION_FILE.exists():
        try:
            restore_account()
            if online_enabled:
                ensure_online_thread()
            emit(
                "unlocked",
                "🔓 Защищённая Instagram-сессия разблокирована этим iPhone.",
                state="online" if online_enabled else "authorized",
            )
            return
        except Exception as exc:
            clear_vault_key()
            raise RuntimeError("не удалось расшифровать/восстановить сессию: " + str(exc)[:160])
    emit("unlocked", "🔓 Сервер разблокирован. Теперь нажми «Войти Instagram».", state="connected")


def online_start() -> None:
    global online_enabled
    ensure_account()
    online_enabled = True
    save_online_setting(True)
    ensure_online_thread()
    emit("online", "🟢 Онлайн 24/7 включён.", state="online")


def online_stop() -> None:
    global online_enabled
    online_enabled = False
    save_online_setting(False)
    online_stop_event.set()
    disconnect_runtime()
    emit("offline", "⏸ Онлайн 24/7 выключен. Зашифрованная авторизация сохранена.", state="offline")


def status_text() -> None:
    device = load_device()
    paired = "НЕТ" if not device else "ДА • " + str(device.get("fingerprint", ""))[:12]
    vault = "РАЗБЛОКИРОВАН" if vault_key is not None else "ЗАБЛОКИРОВАН"
    session = "есть (AES-GCM)" if SESSION_FILE.exists() else "нет"
    heartbeat = "ещё не было" if not last_heartbeat else time.strftime("%H:%M:%S", time.localtime(last_heartbeat))
    try:
        bundle = load_session_bundle() if vault_key is not None else None
        username = "@" + str(bundle.get("username")) if bundle else "не активирован"
    except Exception:
        username = "недоступен"
    emit(
        "status",
        "✅ Сервер Instagram 24/7 работает\n"
        f"👤 Аккаунт: {username}\n"
        f"📱 Привязка iPhone: {paired}\n"
        f"🗝 Vault: {vault}\n"
        f"💾 Сессия: {session}\n"
        f"🟢 Онлайн 24/7: {'ВКЛ' if online_enabled else 'ВЫКЛ'}\n"
        f"💓 Последний keepalive: {heartbeat}\n"
        f"⚠️ Последняя ошибка: {last_error or 'нет'}",
        state="online" if online_enabled else ("authorized" if SESSION_FILE.exists() else "connected"),
    )


def security_text() -> None:
    device = load_device()
    lines = [
        "🛡 ПРОВЕРКА ЗАЩИТЫ",
        "✅ Команды подписываются P-256",
        "✅ Канал команд AES-GCM",
        "✅ Replay-защита request_id + timestamp",
        "✅ Instagram-сессия и пароль AES-GCM на диске",
        "✅ Vault-key не записывается на сервер",
        "✅ Одноразовый код не сохраняется",
        "✅ iPhone привязан: " + (str(device.get("fingerprint", ""))[:16] if device else "ещё нет"),
    ]
    emit("security", "\n".join(lines), state="authorized" if SESSION_FILE.exists() else "connected")


def logout_server() -> None:
    global instagram_client, pending_login, online_enabled
    online_enabled = False
    save_online_setting(False)
    online_stop_event.set()
    disconnect_runtime()
    pending_login = None
    instagram_client = None
    try:
        SESSION_FILE.unlink(missing_ok=True)
    except Exception:
        pass
    clear_vault_key()
    emit("logged_out", "🚨 Серверная Instagram-сессия удалена. Для нового входа снова открой IPA.", state="logged_out")


def pair_ack(device: dict) -> None:
    emit(
        "paired",
        "📱 iPhone привязан. Отпечаток: " + str(device.get("fingerprint", ""))[:16] + ". Подмена ключа запрещена.",
        state="connected",
    )


def execute_command(command: dict, device: dict) -> None:
    action = str(command.get("action") or "")
    fields = command.get("fields") if isinstance(command.get("fields"), dict) else {}
    if action == "pair":
        return pair_ack(device)
    if action == "unlock":
        return unlock_vault(str(fields.get("vault_key") or ""))
    if action == "login_start":
        return login_start(str(fields.get("username") or ""), str(fields.get("password") or ""))
    if action == "login_code":
        return login_code(str(fields.get("code") or ""))
    if action == "online_start":
        return online_start()
    if action == "online_stop":
        return online_stop()
    if action == "status":
        return status_text()
    if action == "security":
        return security_text()
    if action == "logout_server":
        return logout_server()
    raise RuntimeError("неизвестная команда")


class HealthHandler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        if self.path.split("?", 1)[0] not in {"/", "/health"}:
            self.send_error(404)
            return
        body = json.dumps(
            {
                "ok": True,
                "service": "instagram247-hardened",
                "paired": load_device() is not None,
                "vault_unlocked": vault_key is not None,
                "online_enabled": online_enabled,
            },
            separators=(",", ":"),
        ).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, _format: str, *_args) -> None:
        return


def start_health_server() -> None:
    port_value = os.getenv("PORT", "").strip()
    if not port_value:
        return
    try:
        port = int(port_value)
        server = ThreadingHTTPServer(("0.0.0.0", port), HealthHandler)
        threading.Thread(target=server.serve_forever, daemon=True, name="instagram247-health").start()
        print(f"Health HTTP listening on 0.0.0.0:{port}", flush=True)
    except Exception as exc:
        print(f"HEALTH ERROR: {type(exc).__name__}: {exc}", flush=True)


def command_loop() -> None:
    print("Instagram 24/7 HARDENED bridge started", flush=True)
    while True:
        try:
            response = http.get(
                f"{NTFY_BASE}/{CMD_TOPIC}/json",
                params={"poll": "1", "since": "30s"},
                timeout=15,
            )
            response.raise_for_status()
            for line in response.text.splitlines():
                try:
                    event = json.loads(line)
                    if event.get("event") != "message" or not event.get("message"):
                        continue
                    command, device = verify_signed_envelope(open_json(event["message"]))
                    request_id = str(command.get("request_id") or "")
                    if request_id and request_id in seen_set:
                        continue
                    timestamp_ms = int(command.get("ts_ms") or 0)
                    if abs(int(time.time() * 1000) - timestamp_ms) > COMMAND_MAX_AGE_MS:
                        if request_id:
                            remember_seen(request_id)
                        continue
                    if request_id:
                        remember_seen(request_id)
                    execute_command(command, device)
                except TwoFactorRequired:
                    emit("need_2fa", "🔐 Instagram запросил код 2FA.", state="connected")
                except BadPassword:
                    emit("login_error", "❌ Instagram отклонил пароль.", state="connected")
                except ChallengeRequired:
                    emit("login_error", "⚠️ Instagram запросил проверку входа. Подтверди её в официальном приложении и повтори.", state="connected")
                except PleaseWaitFewMinutes:
                    emit("login_error", "⏳ Instagram попросил подождать несколько минут перед новым входом.", state="connected")
                except LoginRequired:
                    emit("login_error", "❌ Instagram-сессия устарела. Выполни вход заново.", state="connected")
                except PermissionError as exc:
                    emit("security_error", "🚫 Команда отклонена: " + str(exc)[:180], state="connected")
                except Exception as exc:
                    emit("error", f"❌ {type(exc).__name__}: {str(exc)[:220]}", state="connected")
        except Exception as exc:
            print(f"BRIDGE ERROR: {type(exc).__name__}: {exc}", flush=True)
        time.sleep(2)


def main() -> None:
    start_health_server()
    print("Instagram 24/7 AUTOPAIR: код из логов не требуется", flush=True)
    if SESSION_FILE.exists():
        emit("startup", "🔒 Сервер запущен. Открой IPA для разблокировки зашифрованной Instagram-сессии.", state="connected")
    else:
        emit("startup", "✅ Сервер Instagram 24/7 запущен. Ожидаю привязку iPhone.", state="connected")
    command_loop()


if __name__ == "__main__":
    main()
