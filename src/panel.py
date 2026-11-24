#!/usr/bin/env python3
"""
Stationeers Control Deck
========================
A small, dependency-free web panel that runs next to Stationeers Server UI
(SSUI). It lets you upload / activate save folders and start, stop and restart
the server from any machine on your network.

It talks to SSUI through its documented v3 HTTP API and never edits SSUI's
files while SSUI is running.

Standard library only. Tested with Python 3.11 - 3.14.
"""

import base64
import glob
import hashlib
import hmac
import http.cookiejar
import json
import os
import posixpath
import re
import secrets
import shutil
import socket
import ssl
import subprocess
import tarfile
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from http.cookies import SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

APP_DIR = os.path.dirname(os.path.abspath(__file__))
CONFIG_PATH = os.environ.get("STATIONEERS_PANEL_CONFIG", "/etc/stationeers-panel/config.json")
HTML_PATH = os.path.join(APP_DIR, "panel.html")

SESSION_COOKIE = "stationeers_panel_session"
SESSION_TTL = 12 * 60 * 60
MAX_UPLOAD = 8 * 1024 * 1024 * 1024
TOKEN_NAME = "stationeers-panel"

CFG = {}
CFG_LOCK = threading.RLock()
SSUI_LOCK = threading.RLock()
BOOT = {"state": "starting", "message": "Starting panel..."}
WORKER = None
WORKER_LOCK = threading.Lock()
LOGIN_FAILS = {}


# --------------------------------------------------------------------------
# Configuration / helpers
# --------------------------------------------------------------------------
def load_config():
    global CFG
    with open(CONFIG_PATH, "r", encoding="utf-8") as fh:
        CFG = json.load(fh)
    if "panel" not in CFG or "ssui" not in CFG or "paths" not in CFG:
        raise SystemExit("Invalid panel config: %s" % CONFIG_PATH)


def save_config():
    with CFG_LOCK:
        tmp = CONFIG_PATH + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(CFG, fh, indent=2)
            fh.write("\n")
        os.chmod(tmp, 0o600)
        os.replace(tmp, CONFIG_PATH)


def b64e(raw):
    return base64.b64encode(raw).decode("ascii")


def b64d(text):
    return base64.b64decode(text.encode("ascii"))


def hash_password(password, iterations=260000, salt=None):
    salt = salt or secrets.token_bytes(16)
    digest = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, iterations)
    return "pbkdf2$%d$%s$%s" % (iterations, b64e(salt), b64e(digest))


def verify_password(password, stored):
    try:
        scheme, iterations, salt, digest = stored.split("$", 3)
        if scheme != "pbkdf2":
            return False
        candidate = hashlib.pbkdf2_hmac(
            "sha256", password.encode("utf-8"), b64d(salt), int(iterations)
        )
        return hmac.compare_digest(candidate, b64d(digest))
    except Exception:
        return False


def clean_save_name(raw, fallback="ImportedSave"):
    raw = os.path.basename(str(raw or "")).strip()
    raw = re.sub(r"(?i)\.(zip|tar\.gz|tgz|tar|gz|save)$", "", raw)
    raw = re.sub(r"[^A-Za-z0-9 _.\-]+", "", raw)
    raw = raw.strip(" ._-")[:64]
    return raw or fallback


def inside(root, path):
    try:
        root = os.path.realpath(root)
        path = os.path.realpath(path)
        return os.path.commonpath([root, path]) == root
    except Exception:
        return False


def human_size(num):
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if abs(num) < 1024.0 or unit == "TB":
            return "%.1f %s" % (num, unit)
        num /= 1024.0
    return "%.1f TB" % num


def iso_time(epoch):
    try:
        return time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(epoch))
    except Exception:
        return ""


def read_settings_cache():
    """Settings are read on every refresh; cached briefly to keep polling light."""
    now = time.time()
    cached = getattr(read_settings_cache, "cache", None)
    if cached and now - cached[0] < 3:
        return cached[1]
    data = CLIENT.api("GET", "/api/v3/settings", timeout=8)["data"]
    read_settings_cache.cache = (now, data)
    return data


# --------------------------------------------------------------------------
# SSUI API client
# --------------------------------------------------------------------------
class SSUIError(Exception):
    def __init__(self, status, message, code=""):
        super().__init__(message)
        self.status = status
        self.message = message
        self.code = code


class SSUIClient:
    def __init__(self):
        self._reset()

    def _reset(self):
        self.jar = http.cookiejar.CookieJar()
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        self.opener = urllib.request.build_opener(
            urllib.request.HTTPCookieProcessor(self.jar),
            urllib.request.HTTPSHandler(context=ctx),
        )
        self.csrf = None
        self.session_mode = False

    def _base(self):
        return CFG["ssui"]["url"].rstrip("/")

    def _raw(self, method, path, payload=None, timeout=10, use_session=False, token=None):
        url = self._base() + path
        headers = {"Accept": "application/json"}
        data = None
        if payload is not None:
            data = json.dumps(payload).encode("utf-8")
            headers["Content-Type"] = "application/json"
        if token:
            headers["Authorization"] = "Bearer " + token
        if not token and self.csrf and method not in ("GET", "HEAD"):
            headers["X-SSUI-CSRF"] = self.csrf
        req = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            with self.opener.open(req, timeout=timeout) as resp:
                body = resp.read()
                if not body:
                    return {}
                try:
                    return json.loads(body)
                except json.JSONDecodeError:
                    return {"data": body.decode("utf-8", "replace")}
        except urllib.error.HTTPError as exc:
            body = exc.read()
            try:
                parsed = json.loads(body)
                err = parsed.get("error") or {}
                message = err.get("message") or ("HTTP %d" % exc.code)
                code = err.get("code") or ""
            except Exception:
                message = body.decode("utf-8", "replace")[:400] or ("HTTP %d" % exc.code)
                code = ""
            raise SSUIError(exc.code, message, code)
        except urllib.error.URLError as exc:
            raise SSUIError(0, "SSUI is not reachable yet: %s" % exc.reason)
        except (TimeoutError, socket.timeout):
            raise SSUIError(0, "SSUI did not answer in time")
        except ssl.SSLError as exc:
            raise SSUIError(0, "TLS error talking to SSUI: %s" % exc)

    def _clear_token(self):
        with CFG_LOCK:
            CFG["ssui"]["token"] = ""
            save_config()

    def authenticate(self, force=False):
        """Bootstrap the first owner (if needed), log in and mint a PAT."""
        with SSUI_LOCK:
            if not force:
                token = CFG["ssui"].get("token")
                if token:
                    try:
                        self._raw("GET", "/api/v3", token=token, timeout=5)
                        return
                    except SSUIError as exc:
                        if exc.status not in (401, 403):
                            raise
            self._reset()
            creds = {
                "username": CFG["ssui"]["username"],
                "password": CFG["ssui"]["password"],
            }
            setup = self._raw("GET", "/api/v3/auth/setup", timeout=8)
            setup_required = bool((setup.get("data") or {}).get("setupRequired"))
            if setup_required:
                response = self._raw(
                    "POST", "/api/v3/auth/setup/bootstrap", creds, timeout=15
                )
            else:
                response = self._raw("POST", "/api/v3/auth/login", creds, timeout=15)
            self.csrf = (response.get("data") or {}).get("csrf")
            caps = self._raw("GET", "/api/v3", use_session=True, timeout=8)
            permissions = (caps.get("data") or {}).get("permissions") or []
            try:
                created = self._raw(
                    "POST",
                    "/api/v3/auth/tokens",
                    {"name": TOKEN_NAME, "scopes": permissions},
                    timeout=10,
                    use_session=True,
                )
                secret = (created.get("data") or {}).get("secret")
                if not secret:
                    raise SSUIError(500, "SSUI did not return an API token")
                with CFG_LOCK:
                    CFG["ssui"]["token"] = secret
                    save_config()
                self.session_mode = False
                if setup_required:
                    try:
                        self._raw(
                            "POST",
                            "/api/v3/setup/finalize",
                            {},
                            timeout=15,
                            token=secret,
                        )
                    except SSUIError:
                        pass
            except SSUIError:
                # Fall back to the browser session (valid up to 30 days).
                self.session_mode = True

    def ensure_connected(self):
        with SSUI_LOCK:
            token = CFG["ssui"].get("token")
            if token:
                try:
                    self._raw("GET", "/api/v3", token=token, timeout=6)
                    return
                except SSUIError as exc:
                    if exc.status in (401, 403):
                        self._clear_token()
                    else:
                        raise
            self.authenticate(force=True)

    def api(self, method, path, payload=None, timeout=10):
        with SSUI_LOCK:
            token = CFG["ssui"].get("token")
            if token:
                try:
                    return self._raw(method, path, payload, timeout, token=token)
                except SSUIError as exc:
                    if exc.status in (401, 403):
                        self._clear_token()
                        self.authenticate(force=True)
                        token = CFG["ssui"].get("token")
                        if token:
                            return self._raw(method, path, payload, timeout, token=token)
                        return self._raw(method, path, payload, timeout, use_session=True)
                    raise
            if self.session_mode:
                try:
                    return self._raw(method, path, payload, timeout, use_session=True)
                except SSUIError as exc:
                    if exc.status in (401, 403):
                        self.authenticate(force=True)
                        return self._raw(method, path, payload, timeout, use_session=True)
                    raise
            raise SSUIError(0, "Panel is not connected to SSUI yet")


CLIENT = SSUIClient()


def bootstrap_worker():
    global BOOT
    while True:
        delay = 10
        try:
            CLIENT.ensure_connected()
            BOOT = {"state": "ready", "message": "Connected to Stationeers Server UI"}
            return
        except SSUIError as exc:
            BOOT = {"state": "waiting", "message": exc.message}
            if exc.status in (401, 403, 429):
                delay = 30
        except Exception as exc:  # pragma: no cover - defensive
            BOOT = {"state": "error", "message": str(exc)[:300]}
        time.sleep(delay)


def start_worker(force=False):
    global WORKER
    with WORKER_LOCK:
        if WORKER and WORKER.is_alive() and not force:
            return
        WORKER = threading.Thread(target=bootstrap_worker, name="ssui-bootstrap", daemon=True)
        WORKER.start()


# --------------------------------------------------------------------------
# Server helpers
# --------------------------------------------------------------------------
def server_status():
    return CLIENT.api("GET", "/api/v3/server/status", timeout=6)["data"]


def stop_and_wait():
    try:
        CLIENT.api("POST", "/api/v3/server/stop", timeout=15)
    except SSUIError as exc:
        if exc.status not in (409, 400):
            raise
    deadline = time.time() + 120
    while time.time() < deadline:
        try:
            if not server_status().get("running"):
                return
        except SSUIError:
            pass
        time.sleep(1.5)
    raise SSUIError(504, "The server did not stop within 120 seconds")


SAVE_SUBDIR_NAMES = {
    "auto",
    "autosave",
    "autosaves",
    "quick",
    "quicksave",
    "quicksaves",
    "manual",
    "manualsave",
    "manualsaves",
    "backup",
    "backups",
}


def has_station_marker(path):
    """True if this directory looks like a Stationeers station folder."""
    if not os.path.isdir(path):
        return False
    if os.path.isfile(os.path.join(path, "world.xml")):
        return True
    if os.path.isfile(os.path.join(path, "world_meta.xml")):
        return True
    try:
        entries = os.listdir(path)
    except OSError:
        return False
    for entry in entries:
        full = os.path.join(path, entry)
        if os.path.isfile(full) and entry.lower().endswith(".save"):
            return True
        if os.path.isdir(full) and entry.lower() in SAVE_SUBDIR_NAMES:
            try:
                if any(name.lower().endswith(".save") for name in os.listdir(full)):
                    return True
            except OSError:
                pass
    return False


def scan_saves(active):
    saves_dir = CFG["paths"]["savesDir"]
    result = []
    try:
        names = sorted(os.listdir(saves_dir), key=str.lower)
    except FileNotFoundError:
        return result
    for name in names:
        path = os.path.join(saves_dir, name)
        if name.startswith(".") or not os.path.isdir(path):
            continue
        if not has_station_marker(path):
            continue
        size = 0
        newest = 0
        has_save = False
        legacy = True
        try:
            for root, _dirs, files in os.walk(path):
                for filename in files:
                    fp = os.path.join(root, filename)
                    if filename.lower().endswith(".save"):
                        has_save = True
                    try:
                        stat = os.stat(fp)
                        size += stat.st_size
                        newest = max(newest, stat.st_mtime)
                    except OSError:
                        pass
        except OSError:
            pass
        legacy = not has_save
        result.append(
            {
                "name": name,
                "size": size,
                "sizeText": human_size(size),
                "modified": iso_time(newest or os.path.getmtime(path)),
                "active": name == active,
                "legacy": legacy,
            }
        )
    return result


WORLDS = {"at": 0, "items": []}


def get_worlds():
    if time.time() - WORLDS["at"] < 600:
        return WORLDS["items"]
    try:
        payload = CLIENT.api("GET", "/api/v3/worldgen/catalog", timeout=8)
    except SSUIError:
        return WORLDS["items"]
    data = payload.get("data") or payload
    items = []
    if isinstance(data, dict):
        items = data.get("worlds") or data.get("items") or data.get("catalog") or []
    elif isinstance(data, list):
        items = data
    normalized = []
    for item in items:
        if isinstance(item, str):
            normalized.append({"id": item, "name": item})
        elif isinstance(item, dict):
            ident = (
                item.get("worldId")
                or item.get("id")
                or item.get("value")
                or item.get("key")
                or item.get("name")
            )
            label = item.get("displayName") or item.get("name") or ident
            if ident:
                normalized.append({"id": str(ident), "name": str(label or ident)})
    if normalized:
        WORLDS["items"] = normalized
        WORLDS["at"] = time.time()
    return WORLDS["items"]


def read_logs(lines=250, service="ssui"):
    lines = max(10, min(int(lines), 2000))
    try:
        proc = subprocess.run(
            ["journalctl", "-u", service, "--no-pager", "-n", str(lines), "-o", "cat"],
            capture_output=True,
            text=True,
            timeout=12,
        )
        if proc.returncode == 0 and proc.stdout.strip():
            return proc.stdout
    except Exception:
        pass
    candidates = []
    ssui_dir = CFG["paths"]["ssuiDir"]
    for pattern in ("*.log", "logs/*.log", "SSUI/logs/*.log", "gameData/*.log"):
        candidates.extend(glob.glob(os.path.join(ssui_dir, pattern)))
    chunks = []
    for path in sorted(candidates)[-3:]:
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as fh:
                tail = fh.readlines()[-lines:]
            chunks.append("--- %s ---\n%s" % (os.path.basename(path), "".join(tail)))
        except OSError:
            pass
    if chunks:
        return "\n".join(chunks)
    return (
        "No SSUI log output is readable yet.\n"
        "The first start downloads SteamCMD and the Stationeers server, which can "
        "take a while. Check back shortly."
    )


def build_state():
    state = {
        "connected": False,
        "bootstrap": BOOT,
        "server": {"running": False, "state": "unknown", "uptimeSeconds": 0},
        "settings": {},
        "players": [],
        "saves": [],
        "worlds": get_worlds() if BOOT.get("state") == "ready" else [],
        "disk": {},
        "error": None,
    }
    try:
        state["server"] = server_status()
        state["connected"] = True
        settings = read_settings_cache()
        state["settings"] = {
            "serverName": settings.get("serverName", ""),
            "saveName": settings.get("saveName", ""),
            "worldId": settings.get("worldId", ""),
            "serverMaxPlayers": settings.get("serverMaxPlayers", ""),
            "serverPassword": settings.get("serverPassword", ""),
            "gamePort": settings.get("gamePort", "27016"),
            "autoSave": settings.get("autoSave", True),
            "saveInterval": settings.get("saveInterval", "300"),
            "autoStartServerOnStartup": settings.get("autoStartServerOnStartup", False),
            "gameBranch": settings.get("gameBranch", "public"),
        }
        try:
            players = CLIENT.api("GET", "/api/v3/server/players", timeout=6)
            state["players"] = (players.get("data") or {}).get("players") or []
        except SSUIError:
            state["players"] = []
        state["saves"] = scan_saves(state["settings"].get("saveName"))
    except SSUIError as exc:
        state["error"] = exc.message
    try:
        usage = shutil.disk_usage(CFG["paths"]["ssuiDir"])
        state["disk"] = {
            "total": usage.total,
            "free": usage.free,
            "totalText": human_size(usage.total),
            "freeText": human_size(usage.free),
        }
    except OSError:
        pass
    state["bootstrap"] = BOOT
    return state


# --------------------------------------------------------------------------
# Save import / export
# --------------------------------------------------------------------------
class ApiError(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status
        self.message = message


def safe_rel(name):
    name = str(name or "").replace("\\", "/")
    name = posixpath.normpath(name)
    if name in ("", ".", "..") or name.startswith("/") or name.startswith("../"):
        return None
    if name.startswith(".import-") or name.startswith(".upload-"):
        return None
    return name


def is_save_file_archive(src):
    """A .save file is itself a zip with world.xml/world_meta.xml at its root."""
    try:
        with zipfile.ZipFile(src) as archive:
            names = set(archive.namelist())
            return "world.xml" in names and "world_meta.xml" in names
    except Exception:
        return False


def extract_archive(src, filename, target):
    lower = filename.lower()
    if zipfile.is_zipfile(src):
        with zipfile.ZipFile(src) as archive:
            for info in archive.infolist():
                rel = safe_rel(info.filename)
                if rel is None:
                    continue
                dest = os.path.join(target, rel)
                if not inside(target, dest):
                    continue
                if info.is_dir():
                    os.makedirs(dest, exist_ok=True)
                    continue
                if info.file_size > 2 * 1024 * 1024 * 1024:
                    raise ApiError(400, "Archive member is too large: %s" % rel)
                os.makedirs(os.path.dirname(dest) or target, exist_ok=True)
                with archive.open(info) as fsrc, open(dest, "wb") as fdst:
                    shutil.copyfileobj(fsrc, fdst, 1024 * 1024)
    elif lower.endswith((".tar.gz", ".tgz", ".tar")):
        with tarfile.open(src, "r:*") as archive:
            for member in archive.getmembers():
                if not member.isfile():
                    continue
                rel = safe_rel(member.name)
                if rel is None:
                    continue
                dest = os.path.join(target, rel)
                if not inside(target, dest):
                    continue
                if member.size > 2 * 1024 * 1024 * 1024:
                    raise ApiError(400, "Archive member is too large: %s" % rel)
                os.makedirs(os.path.dirname(dest) or target, exist_ok=True)
                fsrc = archive.extractfile(member)
                if fsrc is None:
                    continue
                with fsrc, open(dest, "wb") as fdst:
                    shutil.copyfileobj(fsrc, fdst, 1024 * 1024)
    else:
        raise ApiError(
            400,
            "Upload the station's .save file, or a .zip/.tar.gz of the whole "
            "station folder (containing <name>.save and/or world.xml).",
        )


def find_station_root(staging):
    """Find the folder that represents one station inside an extracted archive."""
    entries = [
        entry
        for entry in os.listdir(staging)
        if entry not in ("__MACOSX", ".DS_Store")
    ]
    dirs = [entry for entry in entries if os.path.isdir(os.path.join(staging, entry))]
    files = [entry for entry in entries if os.path.isfile(os.path.join(staging, entry))]

    if has_station_marker(staging) and (files or not dirs):
        return staging

    candidates = [
        os.path.join(staging, entry)
        for entry in dirs
        if has_station_marker(os.path.join(staging, entry))
    ]
    if len(candidates) == 1:
        return candidates[0]
    if len(candidates) > 1:
        raise ApiError(
            400,
            "That archive contains more than one Stationeers save. Upload one "
            "station folder or one .save file at a time.",
        )
    if len(dirs) == 1 and not files:
        return os.path.join(staging, dirs[0])
    return None


def import_save_file(src, filename, save_name, overwrite):
    saves_dir = CFG["paths"]["savesDir"]
    os.makedirs(saves_dir, exist_ok=True)
    if not zipfile.is_zipfile(src):
        try:
            size = os.path.getsize(src)
            with open(src, "rb") as fh:
                magic = fh.read(4).hex() or "empty"
        except OSError:
            size = -1
            magic = "unreadable"
        raise ApiError(
            400,
            "That .save file is not a zip archive (size %s bytes, starts with %s). "
            "A Stationeers .save is a zip; re-upload it and make sure the transfer "
            "was not truncated." % (size, magic),
        )
    if not is_save_file_archive(src):
        raise ApiError(
            400,
            "That zip is missing world.xml/world_meta.xml at its root, so it is not "
            "a Stationeers .save. If it is a zip of the station folder, upload it as "
            "a .zip so it can be unpacked.",
        )
    target_name = clean_save_name(save_name or filename)
    target = os.path.join(saves_dir, target_name)
    if not inside(saves_dir, target):
        raise ApiError(400, "Invalid save name")
    if os.path.exists(target) and not overwrite:
        raise ApiError(409, 'Save "%s" already exists. Enable overwrite to replace it.' % target_name)
    staging = tempfile.mkdtemp(prefix=".import-", dir=saves_dir)
    try:
        folder = os.path.join(staging, target_name)
        os.makedirs(folder)
        shutil.copyfile(src, os.path.join(folder, target_name + ".save"))
        if os.path.exists(target):
            shutil.rmtree(target)
        shutil.move(folder, target)
        os.chmod(target, 0o775)
    finally:
        shutil.rmtree(staging, ignore_errors=True)
    return target_name


def import_archive(src, filename, save_name, overwrite):
    lower = filename.lower()
    # Sniff the content, not just the extension: a .save is a zip, and some
    # browsers/OSes hand it over with a different name.
    if zipfile.is_zipfile(src):
        if is_save_file_archive(src):
            return import_save_file(src, filename, save_name, overwrite)
        # A zip of a station folder (even if it was named .save) falls through.
    elif lower.endswith(".save"):
        return import_save_file(src, filename, save_name, overwrite)

    saves_dir = CFG["paths"]["savesDir"]
    os.makedirs(saves_dir, exist_ok=True)
    target_name = clean_save_name(save_name or filename)
    target = os.path.join(saves_dir, target_name)
    if not inside(saves_dir, target):
        raise ApiError(400, "Invalid save name")
    if os.path.exists(target) and not overwrite:
        raise ApiError(409, 'Save "%s" already exists. Enable overwrite to replace it.' % target_name)
    staging = tempfile.mkdtemp(prefix=".import-", dir=saves_dir)
    try:
        raw = os.path.join(staging, "raw")
        os.makedirs(raw)
        extract_archive(src, filename, raw)
        root = find_station_root(raw)
        if root is None:
            raise ApiError(
                400,
                "No Stationeers save found in that archive. It must contain a "
                ".save file or world.xml for one station.",
            )
        if os.path.exists(target):
            shutil.rmtree(target)
        shutil.move(root, target)
        os.chmod(target, 0o775)
    finally:
        shutil.rmtree(staging, ignore_errors=True)
    return target_name


def zip_save(name):
    saves_dir = CFG["paths"]["savesDir"]
    src = os.path.join(saves_dir, name)
    if not inside(saves_dir, src) or not os.path.isdir(src):
        raise ApiError(404, "Save not found")
    fd, tmp = tempfile.mkstemp(prefix="stationeers-save-", suffix=".zip")
    os.close(fd)
    with zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
        for root, _dirs, files in os.walk(src):
            for filename in files:
                path = os.path.join(root, filename)
                rel = os.path.relpath(path, src)
                archive.write(path, arcname=os.path.join(name, rel))
    return tmp


def delete_save(name):
    saves_dir = CFG["paths"]["savesDir"]
    path = os.path.join(saves_dir, name)
    if not inside(saves_dir, path) or not os.path.isdir(path):
        raise ApiError(404, "Save not found")
    if name.startswith("."):
        raise ApiError(400, "Refusing to delete a hidden directory")
    shutil.rmtree(path)


def rename_save(name, new_name):
    saves_dir = CFG["paths"]["savesDir"]
    src = os.path.join(saves_dir, name)
    dst = os.path.join(saves_dir, new_name)
    if not inside(saves_dir, src) or not os.path.isdir(src):
        raise ApiError(404, "Save not found")
    if not inside(saves_dir, dst):
        raise ApiError(400, "Invalid new save name")
    if os.path.exists(dst):
        raise ApiError(409, 'A save named "%s" already exists' % new_name)
    os.rename(src, dst)
    return new_name


def patch_settings(payload):
    result = CLIENT.api("PATCH", "/api/v3/settings", payload, timeout=15)
    read_settings_cache.cache = None
    return result


# --------------------------------------------------------------------------
# HTTP handler
# --------------------------------------------------------------------------
class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "StationeersControlDeck"

    def log_message(self, fmt, *args):
        # Keep the journal readable: only log failures.
        if args and str(args[1]).startswith(("4", "5")):
            super().log_message(fmt, *args)

    # -- response helpers -------------------------------------------------
    def send_json(self, status, obj):
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def send_text(self, status, text, content_type="text/plain; charset=utf-8", extra=None):
        body = text.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        for key, value in (extra or {}).items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(body)

    def send_empty(self, status):
        self.send_response(status)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def read_body(self, limit):
        try:
            length = int(self.headers.get("Content-Length") or "0")
        except ValueError:
            raise ApiError(400, "Invalid Content-Length")
        if length <= 0:
            return b""
        if length > limit:
            raise ApiError(413, "Request body is too large")
        return self.rfile.read(length)

    def read_json(self):
        raw = getattr(self, "_body", None)
        if raw is None:
            raw = self.read_body(1024 * 1024)
        if not raw:
            return {}
        try:
            return json.loads(raw)
        except json.JSONDecodeError:
            raise ApiError(400, "Invalid JSON body")

    # -- auth ------------------------------------------------------------
    def session_secret(self):
        return CFG["panel"].get("sessionSecret") or ""

    def make_session(self, username):
        expires = int(time.time()) + SESSION_TTL
        payload = "%s|%d" % (username, expires)
        sig = hmac.new(self.session_secret().encode(), payload.encode(), hashlib.sha256).hexdigest()
        return b64e(("%s|%s" % (payload, sig)).encode())

    def read_session(self):
        cookie = SimpleCookie()
        try:
            cookie.load(self.headers.get("Cookie") or "")
        except Exception:
            return None
        morsel = cookie.get(SESSION_COOKIE)
        if not morsel:
            return None
        try:
            raw = b64d(morsel.value).decode()
            username, expires, sig = raw.rsplit("|", 2)
            expected = hmac.new(
                self.session_secret().encode(),
                ("%s|%s" % (username, expires)).encode(),
                hashlib.sha256,
            ).hexdigest()
            if not hmac.compare_digest(sig, expected):
                return None
            if int(expires) < time.time():
                return None
            if username != CFG["panel"]["username"]:
                return None
            return username
        except Exception:
            return None

    def authed(self):
        return self.read_session() is not None

    def check_origin(self):
        origin = self.headers.get("Origin")
        if origin:
            host = self.headers.get("Host")
            if urllib.parse.urlparse(origin).netloc != host:
                raise ApiError(403, "Cross-origin request blocked")
        if self.headers.get("X-Requested-With") != "stationeers-panel":
            raise ApiError(403, "Missing panel request header")

    # -- routing ---------------------------------------------------------
    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        query = urllib.parse.parse_qs(parsed.query)
        try:
            if path in ("/", "/index.html"):
                with open(HTML_PATH, "r", encoding="utf-8") as fh:
                    self.send_text(200, fh.read(), "text/html; charset=utf-8")
                return
            if path == "/favicon.ico":
                self.send_empty(204)
                return
            if not self.authed():
                self.send_json(401, {"error": "login_required"})
                return
            if path == "/api/state":
                self.send_json(200, build_state())
                return
            if path == "/api/logs":
                lines = (query.get("lines") or ["250"])[0]
                self.send_json(200, {"logs": read_logs(int(lines) if str(lines).isdigit() else 250)})
                return
            match = re.fullmatch(r"/api/saves/([^/]+)/download", path)
            if match:
                name = urllib.parse.unquote(match.group(1))
                if clean_save_name(name) != name:
                    raise ApiError(400, "Invalid save name")
                tmp = zip_save(name)
                try:
                    size = os.path.getsize(tmp)
                    self.send_response(200)
                    self.send_header("Content-Type", "application/zip")
                    self.send_header(
                        "Content-Disposition",
                        'attachment; filename="%s.zip"' % urllib.parse.quote(name),
                    )
                    self.send_header("Content-Length", str(size))
                    self.send_header("Cache-Control", "no-store")
                    self.end_headers()
                    with open(tmp, "rb") as fh:
                        shutil.copyfileobj(fh, self.wfile, 1024 * 1024)
                finally:
                    try:
                        os.unlink(tmp)
                    except OSError:
                        pass
                return
            self.send_json(404, {"error": "not_found"})
        except ApiError as exc:
            self.send_json(exc.status, {"error": exc.message})
        except BrokenPipeError:
            pass
        except Exception as exc:  # pragma: no cover - defensive
            self.send_json(500, {"error": str(exc)[:400]})

    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        query = urllib.parse.parse_qs(parsed.query)
        try:
            if path == "/api/saves/upload":
                self.handle_upload(query)
                return
            # Consume the request body even for handlers that ignore it.
            # Otherwise HTTP/1.1 keep-alive reads the leftover body as the
            # method of the next request (e.g. "{}GET" -> 501).
            self._body = self.read_body(1024 * 1024)
            self.check_origin()
            if path == "/api/login":
                self.handle_login()
                return
            if not self.authed():
                self.send_json(401, {"error": "login_required"})
                return
            if path == "/api/logout":
                cookie = "%s=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0" % SESSION_COOKIE
                if CFG["panel"].get("tls", True):
                    cookie += "; Secure"
                body = json.dumps({"ok": True}).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Set-Cookie", cookie)
                self.end_headers()
                self.wfile.write(body)
                return
            if path in ("/api/server/start", "/api/server/stop", "/api/server/restart"):
                self.handle_server(path.rsplit("/", 1)[-1])
                return
            if path == "/api/settings":
                self.handle_settings()
                return
            if path == "/api/worlds":
                self.handle_new_world()
                return
            if path == "/api/ssui/credentials":
                self.handle_ssui_credentials()
                return
            if path == "/api/ssui/retry":
                start_worker(force=True)
                self.send_json(200, {"ok": True})
                return
            match = re.fullmatch(r"/api/saves/([^/]+)/activate", path)
            if match:
                self.handle_activate(urllib.parse.unquote(match.group(1)))
                return
            match = re.fullmatch(r"/api/saves/([^/]+)/rename", path)
            if match:
                self.handle_rename(urllib.parse.unquote(match.group(1)))
                return
            self.send_json(404, {"error": "not_found"})
        except ApiError as exc:
            self.send_json(exc.status, {"error": exc.message})
        except SSUIError as exc:
            self.send_json(502, {"error": exc.message})
        except BrokenPipeError:
            pass
        except Exception as exc:  # pragma: no cover - defensive
            self.send_json(500, {"error": str(exc)[:400]})

    def do_DELETE(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        query = urllib.parse.parse_qs(parsed.query)
        try:
            self._body = self.read_body(1024 * 1024)
            self.check_origin()
            if not self.authed():
                self.send_json(401, {"error": "login_required"})
                return
            match = re.fullmatch(r"/api/saves/([^/]+)", path)
            if not match:
                self.send_json(404, {"error": "not_found"})
                return
            name = urllib.parse.unquote(match.group(1))
            if clean_save_name(name) != name:
                raise ApiError(400, "Invalid save name")
            force = (query.get("force") or ["0"])[0] == "1"
            try:
                settings = read_settings_cache()
                active = settings.get("saveName")
                running = server_status().get("running")
            except SSUIError:
                active = None
                running = False
            if name == active and running:
                raise ApiError(409, "Stop the server and switch worlds before deleting the active save.")
            if name == active and not force:
                raise ApiError(409, "This is the active save. Switch worlds first, or force the delete.")
            delete_save(name)
            self.send_json(200, {"ok": True})
        except ApiError as exc:
            self.send_json(exc.status, {"error": exc.message})
        except SSUIError as exc:
            self.send_json(502, {"error": exc.message})
        except BrokenPipeError:
            pass
        except Exception as exc:  # pragma: no cover
            self.send_json(500, {"error": str(exc)[:400]})

    # -- action handlers --------------------------------------------------
    def handle_login(self):
        ip = self.client_address[0]
        info = LOGIN_FAILS.get(ip)
        if info and info[1] > time.time():
            raise ApiError(429, "Too many failed logins. Try again in a minute.")
        body = self.read_json()
        username = str(body.get("username") or "")
        password = str(body.get("password") or "")
        if username != CFG["panel"]["username"] or not verify_password(
            password, CFG["panel"]["passwordHash"]
        ):
            count, _until = LOGIN_FAILS.get(ip, (0, 0))
            until = time.time() + 60 if count + 1 >= 5 else 0
            LOGIN_FAILS[ip] = (count + 1, until)
            time.sleep(0.5)
            raise ApiError(401, "Incorrect username or password")
        LOGIN_FAILS.pop(ip, None)
        token = self.make_session(username)
        cookie = "%s=%s; Path=/; HttpOnly; SameSite=Lax; Max-Age=%d" % (
            SESSION_COOKIE,
            token,
            SESSION_TTL,
        )
        if CFG["panel"].get("tls", True):
            cookie += "; Secure"
        self.send_response(200)
        body_out = json.dumps({"ok": True}).encode()
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body_out)))
        self.send_header("Set-Cookie", cookie)
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body_out)

    def handle_server(self, action):
        if action == "start":
            CLIENT.api("POST", "/api/v3/server/start", timeout=20)
            message = "Start requested"
        elif action == "stop":
            CLIENT.api("POST", "/api/v3/server/stop", timeout=20)
            message = "Stop requested"
        else:
            stop_and_wait()
            CLIENT.api("POST", "/api/v3/server/start", timeout=20)
            message = "Server restarted"
        self.send_json(200, {"ok": True, "message": message})

    def handle_settings(self):
        body = self.read_json()
        allowed = {
            "serverName",
            "serverMaxPlayers",
            "serverPassword",
            "autoSave",
            "saveInterval",
            "autoStartServerOnStartup",
        }
        payload = {}
        for key in allowed:
            if key not in body:
                continue
            value = body[key]
            if key in ("serverMaxPlayers", "saveInterval"):
                payload[key] = str(value).strip()
            elif key in ("autoSave", "autoStartServerOnStartup"):
                payload[key] = bool(value)
            else:
                payload[key] = str(value)
        if not payload:
            raise ApiError(400, "Nothing to update")
        response = patch_settings(payload)
        self.send_json(200, {"ok": True, "ssui": response.get("data") or {}})

    def handle_activate(self, name):
        if clean_save_name(name) != name:
            raise ApiError(400, "Invalid save name")
        saves_dir = CFG["paths"]["savesDir"]
        if not os.path.isdir(os.path.join(saves_dir, name)):
            raise ApiError(404, "Save not found")
        body = self.read_json()
        launch = bool(body.get("launch", True))
        if body.get("launch") is None:
            launch = True
        running = False
        try:
            running = bool(server_status().get("running"))
        except SSUIError:
            pass
        if running:
            stop_and_wait()
        patch_settings({"saveName": name})
        if launch:
            time.sleep(1)
            CLIENT.api("POST", "/api/v3/server/start", timeout=20)
        self.send_json(
            200,
            {
                "ok": True,
                "message": ('Loaded "%s" and starting the server' % name)
                if launch
                else ('"%s" is now the active save' % name),
            },
        )

    def handle_new_world(self):
        body = self.read_json()
        name = clean_save_name(body.get("saveName"))
        world = str(body.get("worldId") or "").strip()
        if not world:
            raise ApiError(400, "Choose a world")
        if not re.fullmatch(r"[A-Za-z0-9 _.\-]{1,64}", name):
            raise ApiError(400, "Save name may only contain letters, numbers, spaces, _ . and -")
        if not world.isprintable() or len(world) > 80:
            raise ApiError(400, "Invalid world id")
        if any(ch in world for ch in "<>\"'`\\"):
            raise ApiError(400, "Invalid world id")
        if os.path.isdir(os.path.join(CFG["paths"]["savesDir"], name)):
            raise ApiError(409, 'A save named "%s" already exists. Load it from the saves list instead.' % name)
        launch = bool(body.get("launch", True))
        try:
            if server_status().get("running"):
                stop_and_wait()
        except SSUIError:
            pass
        payload = {"saveName": name, "worldId": world}
        difficulty = str(body.get("difficulty") or "").strip()
        if difficulty:
            payload["difficulty"] = difficulty
        patch_settings(payload)
        if launch:
            time.sleep(1)
            CLIENT.api("POST", "/api/v3/server/start", timeout=20)
        self.send_json(
            200,
            {
                "ok": True,
                "message": 'Created "%s" on %s%s'
                % (name, world, " and starting the server" if launch else ""),
            },
        )

    def handle_rename(self, name):
        body = self.read_json()
        new_name = clean_save_name(body.get("newName"))
        if not re.fullmatch(r"[A-Za-z0-9 _.\-]{1,64}", new_name):
            raise ApiError(400, "Invalid new save name")
        if new_name == name:
            raise ApiError(400, "The new name is the same as the old name")
        try:
            settings = read_settings_cache()
            active = settings.get("saveName")
            running = bool(server_status().get("running"))
        except SSUIError:
            active = None
            running = False
        if name == active and running:
            raise ApiError(409, "Stop the server before renaming the active save.")
        rename_save(name, new_name)
        if active == name:
            patch_settings({"saveName": new_name})
        self.send_json(200, {"ok": True, "name": new_name})

    def handle_ssui_credentials(self):
        global BOOT
        body = self.read_json()
        username = str(body.get("username") or "").strip()
        password = str(body.get("password") or "")
        if not username or not password:
            raise ApiError(400, "SSUI username and password are required")
        with CFG_LOCK:
            CFG["ssui"]["username"] = username
            CFG["ssui"]["password"] = password
            CFG["ssui"]["token"] = ""
            save_config()
        CLIENT._reset()
        try:
            CLIENT.authenticate(force=True)
        except SSUIError as exc:
            raise ApiError(502, "SSUI rejected those credentials: %s" % exc.message)
        BOOT = {"state": "ready", "message": "Connected to Stationeers Server UI"}
        self.send_json(200, {"ok": True, "message": "Connected"})

    def handle_upload(self, query):
        self.check_origin()
        if not self.authed():
            self.send_json(401, {"error": "login_required"})
            return
        try:
            length = int(self.headers.get("Content-Length") or "0")
        except ValueError:
            raise ApiError(400, "Invalid Content-Length")
        if length <= 0:
            raise ApiError(400, "Empty upload")
        if length > MAX_UPLOAD:
            raise ApiError(413, "Upload is larger than 8 GB")
        filename = self.headers.get("X-Filename") or "save.zip"
        filename = os.path.basename(urllib.parse.unquote(filename))
        save_name = (query.get("name") or [""])[0]
        overwrite = (query.get("overwrite") or ["0"])[0] == "1"
        saves_dir = CFG["paths"]["savesDir"]
        os.makedirs(saves_dir, exist_ok=True)
        hint_name = clean_save_name(save_name or filename)
        if os.path.isdir(os.path.join(saves_dir, hint_name)):
            try:
                settings = read_settings_cache()
                if settings.get("saveName") == hint_name and server_status().get("running"):
                    raise ApiError(
                        409,
                        "That save is active and the server is running. Stop the server "
                        "before overwriting it.",
                    )
            except SSUIError:
                pass
        fd, tmp = tempfile.mkstemp(prefix=".upload-", suffix=".bin", dir=saves_dir)
        try:
            remaining = length
            with os.fdopen(fd, "wb") as out:
                while remaining > 0:
                    chunk = self.rfile.read(min(1024 * 1024, remaining))
                    if not chunk:
                        raise ApiError(400, "Upload ended early")
                    out.write(chunk)
                    remaining -= len(chunk)
            name = import_archive(tmp, filename, save_name, overwrite)
            launch = (query.get("launch") or ["0"])[0] == "1"
            if launch:
                if server_status().get("running"):
                    stop_and_wait()
                patch_settings({"saveName": name})
                CLIENT.api("POST", "/api/v3/server/start", timeout=20)
            self.send_json(
                200,
                {
                    "ok": True,
                    "name": name,
                    "message": 'Imported "%s"%s'
                    % (name, " and starting the server" if launch else ""),
                },
            )
        finally:
            try:
                os.unlink(tmp)
            except OSError:
                pass


def main():
    load_config()
    panel = CFG["panel"]
    if not panel.get("sessionSecret"):
        with CFG_LOCK:
            panel["sessionSecret"] = secrets.token_hex(32)
            save_config()
    os.makedirs(CFG["paths"]["savesDir"], exist_ok=True)
    start_worker()
    port = int(panel.get("port", 8080))
    httpd = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    scheme = "http"
    if panel.get("tls", True):
        try:
            ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            ctx.load_cert_chain(panel["tlsCert"], panel["tlsKey"])
            httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
            scheme = "https"
        except Exception as exc:
            print("WARNING: TLS setup failed (%s); serving plain HTTP" % exc, flush=True)
    print(
        "Stationeers Control Deck listening on %s://0.0.0.0:%d" % (scheme, port),
        flush=True,
    )
    httpd.serve_forever()


if __name__ == "__main__":
    main()
