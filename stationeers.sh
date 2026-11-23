#!/usr/bin/env bash
#
# Stationeers Dedicated Server + Stationeers Server UI (SSUI) + Control Deck
# Proxmox VE / Debian 13 installer in community-scripts style.
#
# Run on a Proxmox VE host to create a ready-to-use Debian 13 LXC, or run
# inside an existing Debian 13 container/VM to install there.
#
# Ports: 27016/udp (game), 8443/tcp (SSUI), 8080/tcp (Control Deck)
#

set -Eeuo pipefail

on_error() {
  local rc=$?
  # Do not print twice when the failure happened in a subshell/command
  # substitution: let the parent shell report it once.
  if [[ "${BASHPID:-$$}" != "$$" ]]; then
    exit "$rc"
  fi
  printf "\n \033[1;91m[ERROR]\033[m Command failed (exit %s) at line %s.\n" "$rc" "${BASH_LINENO[0]:-$LINENO}" >&2
  printf " \033[1;93mRe-run with 'bash -x stationeers.sh' to see the exact command.\033[m\n\n" >&2
  exit "$rc"
}
trap on_error ERR

SSUI_USER="stationeers"
SSUI_HOME="/home/stationeers"
SSUI_DIR="${SSUI_HOME}/ssui"
SSUI_SERVICE="ssui"
PANEL_DIR="/opt/stationeers-panel"
PANEL_CONFIG_DIR="/etc/stationeers-panel"
PANEL_CONFIG="${PANEL_CONFIG_DIR}/config.json"
PANEL_TLS_DIR="${PANEL_CONFIG_DIR}/tls"
PANEL_SERVICE="stationeers-panel"
CREDS_FILE="/root/stationeers-credentials.txt"
SSUI_WEB_PORT="8443"
PANEL_PORT="8080"
GAME_PORT="27016"
REPO_RAW="https://raw.githubusercontent.com/RoseOO/stationprox/main/stationeers.sh"

# ----- colors & logging (community-scripts style) -------------------------
GN="\033[1;92m"
RD="\033[1;91m"
YW="\033[1;93m"
BL="\033[1;94m"
CL="\033[m"

msg_info()  { printf " ${BL}[INFO]${CL} %b\n" "$*"; }
msg_ok()    { printf " ${GN}[OK]${CL} %b\n" "$*"; }
msg_warn()  { printf " ${YW}[WARN]${CL} %b\n" "$*"; }
msg_error() { printf " ${RD}[ERROR]${CL} %b\n" "$*" >&2; }

die() { msg_error "$*"; exit 1; }

header_info() {
  clear 2>/dev/null || true
  cat <<'EOF'
   _____ __             __
  / ___// /_____  ____  / /____  ____  ___  _____
  \__ \/ __/ __ \/ __ \/ __/ _ \/ __ \/ _ \/ ___/
 ___/ / /_/ /_/ / /_/ / /_/  __/ / / /  __/ /
/____/\__/\____/\____/\__/\___/_/ /_/\___/_/

        Stationeers Dedicated Server  +  Control Deck
EOF
  printf "\n"
}

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "This script must run as root."
}

gen_password() {
  local length="${1:-20}"
  # cut reads the entire stream, so there is no SIGPIPE here.
  head -c 64 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | cut -c1-"$length"
}

ip_address() {
  hostname -I 2>/dev/null | awk '{print $1}'
}

write_creds_file() {
  local owner_user="$1" owner_pass="$2" panel_user="$3" panel_pass="$4"
  local host ip
  host="$(hostname -s 2>/dev/null || hostname)"
  ip="$(ip_address)"
  [[ -z "$ip" ]] && ip="<server-ip>"
  umask 077
  cat > "$CREDS_FILE" <<EOF
================================================================
 Stationeers server credentials
 Generated : $(date -u '+%Y-%m-%d %H:%M:%S UTC')
 Host      : ${host} (${ip})
================================================================

 Control Deck (saves + start/stop)
   URL      : https://${ip}:${PANEL_PORT}
   URL      : https://${host}:${PANEL_PORT}   (if the hostname resolves)
   Username : ${panel_user}
   Password : ${panel_pass}

 Stationeers Server UI (SSUI)
   URL      : https://${ip}:${SSUI_WEB_PORT}
   Username : ${owner_user}
   Password : ${owner_pass}

 Game
   Address  : ${ip}:${GAME_PORT}
   Port     : ${GAME_PORT}/udp
   Save dir : ${SSUI_DIR}/saves

 Server management
   View these credentials : stationeers-creds
   Files                  : ${CREDS_FILE}
   SSUI service           : systemctl status ${SSUI_SERVICE}
   Panel service          : systemctl status ${PANEL_SERVICE}
   Update everything      : stationeers-update
   Update panel only      : stationeers-update --panel
   Reset panel password   : stationeers-install --reset-panel-password

 Notes
   * The SSUI owner password above is also stored in ${PANEL_CONFIG}
     so the Control Deck can create its API token. Keep both files private.
   * Both web UIs use self-signed certificates. The browser warning is expected.
   * Do not expose ports ${PANEL_PORT} or ${SSUI_WEB_PORT} to the internet.
================================================================
EOF
  chmod 600 "$CREDS_FILE"
  chown root:root "$CREDS_FILE"
  umask 022
}

install_creds_helper() {
  cat > /usr/local/bin/stationeers-creds <<'EOF'
#!/usr/bin/env bash
set -e
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "Run with sudo: sudo stationeers-creds" >&2
  exit 1
fi
cat /root/stationeers-credentials.txt
EOF
  chmod 755 /usr/local/bin/stationeers-creds
}

install_self_helper() {
  local target="/usr/local/bin/stationeers-install"
  if [[ -f "$SELF_PATH" && "$(readlink -f "$SELF_PATH")" != "$(readlink -f "$target" 2>/dev/null || printf '%s' "$target")" ]]; then
    install -m 755 "$SELF_PATH" "$target"
  fi
}

install_update_helper() {
  cat > /usr/local/bin/stationeers-update <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "Run with sudo: sudo stationeers-update" >&2
  exit 1
fi
case "${1:-}" in
  --panel)
    exec /usr/local/bin/stationeers-install --update-panel
    ;;
  ""|--all)
    exec /usr/local/bin/stationeers-install --update
    ;;
  *)
    echo "Usage: stationeers-update [--panel]" >&2
    echo "  (no args)  update SSUI, Stationeers server and panel" >&2
    echo "  --panel    update only the Control Deck" >&2
    exit 1
    ;;
esac
EOF
  chmod 755 /usr/local/bin/stationeers-update
}

# ----- platform checks ----------------------------------------------------
check_platform() {
  [[ "$(uname -m)" == "x86_64" ]] || die "Stationeers servers are x86_64 only (detected $(uname -m))."

  local glibc=""
  glibc="$(getconf GNU_LIBC_VERSION 2>/dev/null | awk '{print $2}' || true)"
  if [[ -n "$glibc" ]]; then
    if [[ "$(printf '%s\n%s\n' '2.40' "$glibc" | sort -V | head -n1)" != "2.40" ]]; then
      msg_error "glibc ${glibc} is too old. The current Stationeers server needs glibc 2.40+."
      msg_error "Use Debian 13 (Trixie), Ubuntu 24.04/25.04+ or newer. Debian 12 will not work."
      exit 1
    fi
  else
    msg_warn "Could not determine the glibc version. Stationeers needs glibc 2.40+ (Debian 13)."
  fi

  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}" in
      debian)
        if [[ "${VERSION_ID:-0}" != "13" && "${VERSION_ID:-0}" != "14" ]]; then
          msg_warn "Detected Debian ${VERSION_ID:-unknown}. Debian 13 (Trixie) is the supported target."
        fi
        ;;
      ubuntu) : ;;
      *) msg_warn "Detected ${PRETTY_NAME:-unknown OS}. Debian 13 is the supported target." ;;
    esac
  fi
}

install_packages() {
  export DEBIAN_FRONTEND=noninteractive
  msg_info "Updating package lists"
  apt-get update -qq || die "apt-get update failed. Check the container's network/DNS."

  msg_info "Installing base packages"
  apt-get -y -qq -o Dpkg::Options::="--force-confold" upgrade || msg_warn "System upgrade reported errors; continuing."

  local packages=(curl ca-certificates jq unzip tar gzip xz-utils python3 openssl tzdata procps)
  if ! apt-get -y -qq install --no-install-recommends "${packages[@]}" lib32gcc-s1 lib32stdc++6; then
    msg_warn "Could not install the 32-bit SteamCMD runtime in one pass; installing the rest."
    apt-get -y -qq install --no-install-recommends "${packages[@]}" || die "Package installation failed."
    msg_warn "SteamCMD 32-bit runtime may be missing. SSUI will try to install it later."
  fi
  msg_ok "Base packages installed"
}

# ----- SSUI binary --------------------------------------------------------
get_ssui_url() {
  local api="https://api.github.com/repos/SteamServerUI/StationeersServerUI/releases/latest"
  local url=""
  url="$(curl -fsSL --max-time 30 "$api" 2>/dev/null \
    | jq -r '[.assets[] | select(.name | test("linux_amd64$")) | .browser_download_url][0] // empty' 2>/dev/null || true)"
  if [[ -z "$url" ]]; then
    local tag=""
    tag="$(curl -fsSLI -o /dev/null -w '%{url_effective}' --max-time 30 \
      "https://github.com/SteamServerUI/StationeersServerUI/releases/latest" 2>/dev/null \
      | sed -n 's#.*/tag/##p' || true)"
    if [[ -n "$tag" ]]; then
      url="https://github.com/SteamServerUI/StationeersServerUI/releases/download/${tag}/StationeersServerUI_${tag}_linux_amd64"
    fi
  fi
  [[ -n "$url" ]] || return 1
  printf '%s' "$url"
}

install_ssui_binary() {
  local url tmp
  url="$(get_ssui_url)" || die "Could not find the latest SSUI Linux release on GitHub (API rate limit?)."
  tmp="$(mktemp /var/tmp/ssui.XXXXXX)"
  msg_info "Downloading Stationeers Server UI"
  msg_info "  ${url}"
  if ! curl -fL --retry 3 --retry-delay 3 --connect-timeout 20 -o "$tmp" "$url"; then
    rm -f "$tmp"
    die "Failed to download SSUI."
  fi
  [[ -s "$tmp" ]] || { rm -f "$tmp"; die "Downloaded SSUI file is empty."; }
  mkdir -p "$SSUI_DIR"
  install -o "$SSUI_USER" -g "$SSUI_USER" -m 0755 "$tmp" "${SSUI_DIR}/StationeersServerUI"
  rm -f "$tmp"
  msg_ok "Stationeers Server UI installed"
}

# ----- panel files --------------------------------------------------------
write_panel_files() {
  msg_info "Writing Control Deck files"
  mkdir -p "$PANEL_DIR"
  cat > "${PANEL_DIR}/panel.py" <<'PANEL_PY_EOF'
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
        if not (
            os.path.isfile(os.path.join(path, "world.xml"))
            or os.path.isfile(os.path.join(path, "world_meta.xml"))
        ):
            continue
        size = 0
        newest = 0
        try:
            for root, _dirs, files in os.walk(path):
                for filename in files:
                    fp = os.path.join(root, filename)
                    try:
                        stat = os.stat(fp)
                        size += stat.st_size
                        newest = max(newest, stat.st_mtime)
                    except OSError:
                        pass
        except OSError:
            pass
        result.append(
            {
                "name": name,
                "size": size,
                "sizeText": human_size(size),
                "modified": iso_time(newest or os.path.getmtime(path)),
                "active": name == active,
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


def extract_archive(src, filename, target):
    lower = filename.lower()
    prefix = None
    if lower.endswith(".zip"):
        with zipfile.ZipFile(src) as archive:
            candidates = []
            for info in archive.infolist():
                rel = safe_rel(info.filename)
                if rel and not info.is_dir() and posixpath.basename(rel) == "world.xml":
                    candidates.append(rel)
            if not candidates:
                raise ApiError(
                    400,
                    "That archive has no world.xml. Zip the save folder that contains "
                    "world.xml and world_meta.xml (not just the game's .save file).",
                )
            candidates.sort(key=lambda p: (p.count("/"), len(p)))
            prefix = posixpath.dirname(candidates[0])
            for info in archive.infolist():
                rel = safe_rel(info.filename)
                if rel is None:
                    continue
                if prefix and not (rel == prefix or rel.startswith(prefix + "/")):
                    continue
                inner = rel[len(prefix):].lstrip("/") if prefix else rel
                if not inner:
                    continue
                dest = os.path.join(target, inner)
                if not inside(target, dest):
                    continue
                if info.is_dir():
                    os.makedirs(dest, exist_ok=True)
                    continue
                if info.file_size > 2 * 1024 * 1024 * 1024:
                    raise ApiError(400, "Archive member is too large: %s" % inner)
                os.makedirs(os.path.dirname(dest) or target, exist_ok=True)
                with archive.open(info) as fsrc, open(dest, "wb") as fdst:
                    shutil.copyfileobj(fsrc, fdst, 1024 * 1024)
    elif lower.endswith((".tar.gz", ".tgz", ".tar")):
        with tarfile.open(src, "r:*") as archive:
            file_members = [m for m in archive.getmembers() if m.isfile()]
            candidates = []
            for member in file_members:
                rel = safe_rel(member.name)
                if rel and posixpath.basename(rel) == "world.xml":
                    candidates.append(rel)
            if not candidates:
                raise ApiError(
                    400,
                    "That archive has no world.xml. Zip the save folder that contains "
                    "world.xml and world_meta.xml.",
                )
            candidates.sort(key=lambda p: (p.count("/"), len(p)))
            prefix = posixpath.dirname(candidates[0])
            for member in file_members:
                rel = safe_rel(member.name)
                if rel is None:
                    continue
                if prefix and not (rel == prefix or rel.startswith(prefix + "/")):
                    continue
                inner = rel[len(prefix):].lstrip("/") if prefix else rel
                if not inner:
                    continue
                dest = os.path.join(target, inner)
                if not inside(target, dest):
                    continue
                if member.size > 2 * 1024 * 1024 * 1024:
                    raise ApiError(400, "Archive member is too large: %s" % inner)
                os.makedirs(os.path.dirname(dest) or target, exist_ok=True)
                fsrc = archive.extractfile(member)
                if fsrc is None:
                    continue
                with fsrc, open(dest, "wb") as fdst:
                    shutil.copyfileobj(fsrc, fdst, 1024 * 1024)
    else:
        raise ApiError(
            400,
            "Upload a .zip (or .tar.gz) of the save folder. A Stationeers save is a "
            "folder containing world.xml and world_meta.xml.",
        )
    if not os.path.isfile(os.path.join(target, "world.xml")):
        raise ApiError(400, "Import failed: world.xml was not found after extraction")


def import_archive(src, filename, save_name, overwrite):
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
        extracted = os.path.join(staging, target_name)
        os.makedirs(extracted)
        extract_archive(src, filename, extracted)
        if os.path.exists(target):
            shutil.rmtree(target)
        shutil.move(extracted, target)
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
PANEL_PY_EOF
  cat > "${PANEL_DIR}/panel.html" <<'PANEL_HTML_EOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Stationeers Control Deck</title>
<style>
  :root {
    --bg: #0b0e11;
    --panel: #13191e;
    --panel2: #182127;
    --line: #25313a;
    --text: #e3eaef;
    --muted: #8496a4;
    --amber: #ffa02e;
    --amber-dim: #a4631a;
    --teal: #38d6c0;
    --red: #ff6262;
    --green: #63e08a;
    --mono: "Cascadia Code", "JetBrains Mono", Consolas, "Courier New", monospace;
    --sans: "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
  }
  * { box-sizing: border-box; }
  html, body { margin: 0; padding: 0; }
  body {
    background:
      radial-gradient(1100px 500px at 85% -10%, rgba(255,160,46,.09), transparent 60%),
      radial-gradient(900px 500px at -10% 110%, rgba(56,214,192,.07), transparent 60%),
      var(--bg);
    color: var(--text);
    font-family: var(--sans);
    font-size: 15px;
    line-height: 1.45;
    min-height: 100vh;
  }
  a { color: var(--teal); text-decoration: none; }
  a:hover { text-decoration: underline; }
  button, input, select { font: inherit; }
  code, .mono { font-family: var(--mono); }

  header {
    display: flex; align-items: center; gap: 18px; flex-wrap: wrap;
    padding: 18px 26px;
    border-bottom: 1px solid var(--line);
    background: rgba(10,13,16,.82);
    backdrop-filter: blur(8px);
    position: sticky; top: 0; z-index: 20;
  }
  .brand { display: flex; align-items: baseline; gap: 12px; }
  .brand h1 {
    margin: 0; font-family: var(--mono); font-size: 20px; letter-spacing: 2px;
    text-transform: uppercase;
  }
  .brand h1 span { color: var(--amber); }
  .brand small { color: var(--muted); letter-spacing: 3px; font-size: 10px; text-transform: uppercase; }
  .spacer { flex: 1; }
  .pill {
    display: inline-flex; align-items: center; gap: 8px;
    border: 1px solid var(--line); border-radius: 999px;
    padding: 6px 13px; font-family: var(--mono); font-size: 11px;
    letter-spacing: 1.5px; text-transform: uppercase; color: var(--muted);
    background: #0d1216;
  }
  .dot { width: 9px; height: 9px; border-radius: 50%; background: var(--muted); box-shadow: 0 0 8px rgba(255,255,255,.15); }
  .pill.online { color: var(--green); border-color: rgba(99,224,138,.35); }
  .pill.online .dot { background: var(--green); box-shadow: 0 0 10px var(--green); }
  .pill.offline { color: var(--red); border-color: rgba(255,98,98,.35); }
  .pill.offline .dot { background: var(--red); box-shadow: 0 0 10px var(--red); }
  .pill.busy { color: var(--amber); border-color: rgba(255,160,46,.35); }
  .pill.busy .dot { background: var(--amber); box-shadow: 0 0 10px var(--amber); }
  .head-link { font-family: var(--mono); font-size: 11px; letter-spacing: 1.5px; text-transform: uppercase; color: var(--muted); }
  .head-link:hover { color: var(--amber); }

  main { max-width: 1280px; margin: 0 auto; padding: 24px 26px 60px; }

  .banner {
    display: none; border: 1px solid rgba(255,160,46,.35); background: rgba(255,160,46,.07);
    color: #ffd8a6; border-radius: 12px; padding: 14px 18px; margin-bottom: 20px;
    display: none; align-items: flex-start; gap: 14px; flex-wrap: wrap;
  }
  .banner.show { display: flex; }
  .banner.error { border-color: rgba(255,98,98,.45); background: rgba(255,98,98,.07); color: #ffc7c7; }
  .banner strong { color: var(--amber); font-family: var(--mono); letter-spacing: 1px; }
  .banner.error strong { color: var(--red); }
  .banner .msg { flex: 1; min-width: 240px; }

  .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(330px, 1fr)); gap: 18px; align-items: start; }
  .card {
    background: linear-gradient(180deg, var(--panel2), var(--panel));
    border: 1px solid var(--line); border-radius: 14px; padding: 20px;
    box-shadow: 0 12px 30px rgba(0,0,0,.25);
  }
  .card.wide { grid-column: 1 / -1; }
  .card h2 {
    margin: 0 0 14px; font-family: var(--mono); font-size: 12px; letter-spacing: 2.5px;
    text-transform: uppercase; color: var(--muted); display: flex; align-items: center; gap: 10px;
  }
  .card h2::before { content: ""; width: 6px; height: 6px; background: var(--amber); display: inline-block; transform: rotate(45deg); }
  .card h2 .right { margin-left: auto; letter-spacing: 0; font-size: 11px; color: var(--muted); }

  .big-status { font-family: var(--mono); font-size: 28px; letter-spacing: 2px; text-transform: uppercase; margin: 2px 0 4px; }
  .big-status.online { color: var(--green); }
  .big-status.offline { color: var(--red); }
  .muted { color: var(--muted); }
  .small { font-size: 12px; }
  .kv { display: grid; grid-template-columns: 120px 1fr; gap: 7px 12px; margin: 14px 0; font-size: 14px; }
  .kv dt { color: var(--muted); font-family: var(--mono); font-size: 11px; letter-spacing: 1px; text-transform: uppercase; padding-top: 2px; }
  .kv dd { margin: 0; word-break: break-word; }

  .btn-row { display: flex; gap: 10px; flex-wrap: wrap; margin-top: 16px; }
  button {
    cursor: pointer; border-radius: 8px; border: 1px solid var(--line);
    background: #1b252c; color: var(--text); padding: 9px 15px;
    font-family: var(--mono); font-size: 12px; letter-spacing: 1px; text-transform: uppercase;
    transition: border-color .15s, background .15s, color .15s;
  }
  button:hover:not(:disabled) { border-color: var(--amber-dim); background: #202c34; }
  button:disabled { opacity: .4; cursor: not-allowed; }
  button.primary { background: var(--amber); border-color: var(--amber); color: #1a1206; font-weight: 700; }
  button.primary:hover:not(:disabled) { background: #ffb455; border-color: #ffb455; }
  button.danger { color: #ffb3b3; border-color: rgba(255,98,98,.35); }
  button.danger:hover:not(:disabled) { background: rgba(255,98,98,.12); border-color: var(--red); }
  button.ghost { background: transparent; }
  button.tiny { padding: 5px 9px; font-size: 10px; letter-spacing: .5px; }

  .address {
    display: flex; align-items: center; gap: 10px; margin-top: 10px;
    background: #0d1216; border: 1px solid var(--line); border-radius: 8px; padding: 10px 12px;
    font-family: var(--mono); font-size: 13px;
  }
  .address span { flex: 1; overflow: hidden; text-overflow: ellipsis; }

  .bar { height: 6px; background: #0d1216; border-radius: 999px; overflow: hidden; margin-top: 8px; }
  .bar > i { display: block; height: 100%; background: linear-gradient(90deg, var(--teal), var(--amber)); width: 0; }

  table { width: 100%; border-collapse: collapse; }
  th, td { text-align: left; padding: 11px 10px; border-bottom: 1px solid var(--line); font-size: 14px; vertical-align: middle; }
  th { color: var(--muted); font-family: var(--mono); font-size: 10px; letter-spacing: 1.5px; text-transform: uppercase; font-weight: 400; }
  tbody tr:hover { background: rgba(255,255,255,.02); }
  .name-cell { font-family: var(--mono); font-size: 13px; }
  .badge {
    display: inline-block; padding: 2px 8px; border-radius: 999px; font-family: var(--mono);
    font-size: 9px; letter-spacing: 1px; text-transform: uppercase; border: 1px solid var(--line); color: var(--muted);
  }
  .badge.active { color: var(--amber); border-color: rgba(255,160,46,.45); background: rgba(255,160,46,.08); }
  .row-actions { display: flex; gap: 6px; flex-wrap: wrap; justify-content: flex-end; }
  .empty { color: var(--muted); padding: 18px 4px; font-size: 14px; }

  label.field { display: block; margin-bottom: 12px; }
  label.field > span { display: block; color: var(--muted); font-family: var(--mono); font-size: 10px; letter-spacing: 1.4px; text-transform: uppercase; margin-bottom: 6px; }
  input[type=text], input[type=password], input[type=number], select {
    width: 100%; padding: 9px 11px; border-radius: 8px;
    border: 1px solid var(--line); background: #0d1216; color: var(--text);
    font-family: var(--mono); font-size: 13px;
  }
  input:focus, select:focus { outline: none; border-color: var(--amber-dim); }
  .check { display: flex; align-items: center; gap: 8px; color: var(--muted); font-size: 13px; margin: 6px 0 12px; }
  .check input { accent-color: var(--amber); }
  .two-col { display: grid; grid-template-columns: 1fr 1fr; gap: 0 14px; }
  @media (max-width: 560px) { .two-col { grid-template-columns: 1fr; } header { padding: 14px 16px; } main { padding: 16px; } }

  .dropzone {
    border: 1px dashed #34444f; border-radius: 10px; padding: 20px; text-align: center;
    color: var(--muted); margin-bottom: 14px; transition: border-color .15s, background .15s;
  }
  .dropzone.hover { border-color: var(--amber); background: rgba(255,160,46,.05); }
  .dropzone strong { color: var(--text); }
  .upload-row { display: flex; gap: 10px; align-items: center; flex-wrap: wrap; }
  .upload-row input[type=file] { color: var(--muted); font-size: 12px; max-width: 100%; }
  .progress { display: none; height: 7px; background: #0d1216; border-radius: 999px; overflow: hidden; margin-top: 12px; }
  .progress.show { display: block; }
  .progress > i { display: block; height: 100%; width: 0; background: var(--amber); transition: width .15s; }

  pre.logs {
    margin: 0; height: 340px; overflow: auto; background: #080b0d; border: 1px solid var(--line);
    border-radius: 10px; padding: 13px; font-family: var(--mono); font-size: 11.5px; line-height: 1.5;
    color: #b9c7d1; white-space: pre-wrap; word-break: break-word;
  }

  .modal {
    position: fixed; inset: 0; background: rgba(4,6,8,.82); display: none;
    align-items: center; justify-content: center; padding: 20px; z-index: 50;
  }
  .modal.show { display: flex; }
  .modal .box {
    width: 100%; max-width: 420px; background: var(--panel2); border: 1px solid var(--line);
    border-radius: 14px; padding: 24px; box-shadow: 0 30px 80px rgba(0,0,0,.6);
  }
  .modal h3 { margin: 0 0 6px; font-family: var(--mono); letter-spacing: 2px; text-transform: uppercase; font-size: 15px; }
  .modal p { color: var(--muted); font-size: 13px; margin: 0 0 18px; }
  .modal .err { color: var(--red); font-size: 12px; min-height: 16px; margin-bottom: 8px; }

  .toast {
    position: fixed; right: 22px; bottom: 22px; z-index: 80; max-width: 420px;
    background: #1a242b; border: 1px solid var(--line); border-left: 3px solid var(--teal);
    color: var(--text); border-radius: 8px; padding: 12px 16px; font-size: 13px;
    box-shadow: 0 16px 50px rgba(0,0,0,.5); opacity: 0; transform: translateY(10px);
    transition: .2s; pointer-events: none;
  }
  .toast.show { opacity: 1; transform: translateY(0); }
  .toast.error { border-left-color: var(--red); }
  .player-list { display: flex; flex-wrap: wrap; gap: 6px; }
  .player { background: #0d1216; border: 1px solid var(--line); border-radius: 999px; padding: 3px 10px; font-family: var(--mono); font-size: 11px; }
</style>
</head>
<body>
<header>
  <div class="brand">
    <h1>Stationeers <span>// Control Deck</span></h1>
    <small>dedicated server</small>
  </div>
  <div class="spacer"></div>
  <div class="pill" id="statusPill"><i class="dot"></i><span id="statusText">Connecting</span></div>
  <a class="head-link" id="ssuiLink" href="#" target="_blank" rel="noopener">SSUI &#8599;</a>
  <a class="head-link" href="#" id="logoutLink">Log out</a>
</header>

<main>
  <div class="banner" id="banner">
    <strong id="bannerTitle">Waiting</strong>
    <div class="msg" id="bannerMsg"></div>
    <button class="tiny" id="retryBtn">Retry</button>
    <button class="tiny" id="credsBtn">SSUI login</button>
  </div>

  <div class="grid">
    <section class="card">
      <h2>Server <span class="right" id="branchLabel"></span></h2>
      <div class="big-status offline" id="bigStatus">Offline</div>
      <div class="muted small" id="statusDetail">Waiting for SSUI...</div>
      <div class="address"><span id="gameAddress">...</span><button class="tiny" id="copyBtn">Copy</button></div>
      <dl class="kv">
        <dt>Uptime</dt><dd id="uptime">-</dd>
        <dt>Players</dt><dd id="players">0</dd>
        <dt>Save</dt><dd class="mono" id="activeSave">-</dd>
        <dt>Disk free</dt><dd id="disk">-</dd>
      </dl>
      <div class="bar"><i id="diskBar"></i></div>
      <div class="btn-row">
        <button class="primary" id="startBtn">Start</button>
        <button id="stopBtn">Stop</button>
        <button id="restartBtn">Restart</button>
      </div>
    </section>

    <section class="card">
      <h2>New World</h2>
      <p class="small muted" style="margin-top:-6px">Creates a fresh save folder and optionally launches it.</p>
      <label class="field"><span>Save name</span><input type="text" id="newName" placeholder="EuropaBase" autocomplete="off"></label>
      <label class="field"><span>World</span><select id="worldSelect"><option value="Moon">Moon</option><option value="Mars">Mars</option><option value="Europa">Europa</option></select></label>
      <div class="check"><input type="checkbox" id="newLaunch" checked><label for="newLaunch">Start server after creating</label></div>
      <div class="btn-row"><button class="primary" id="createBtn">Create world</button></div>
      <p class="small muted" id="worldHint" style="margin-bottom:0">World list loads from your game install when SSUI is ready.</p>
    </section>

    <section class="card wide">
      <h2>Saves <span class="right" id="saveCount"></span></h2>
      <div class="dropzone" id="dropzone">
        <strong>Drop a save archive here</strong> or use the file picker. A save is a folder containing
        <span class="mono">world.xml</span> and <span class="mono">world_meta.xml</span> &mdash; zip that folder.
      </div>
      <div class="upload-row">
        <input type="file" id="fileInput" accept=".zip,.tar,.tar.gz,.tgz">
        <input type="text" id="uploadName" placeholder="Save name (optional)" style="max-width:220px" autocomplete="off">
        <label class="check" style="margin:0"><input type="checkbox" id="overwrite"> Overwrite</label>
        <label class="check" style="margin:0"><input type="checkbox" id="uploadLaunch"> Launch after import</label>
        <button class="primary" id="uploadBtn" disabled>Upload</button>
      </div>
      <div class="progress" id="progress"><i id="progressBar"></i></div>
      <div style="overflow-x:auto;margin-top:16px">
        <table>
          <thead><tr><th>Save</th><th>Size</th><th>Modified</th><th style="text-align:right">Actions</th></tr></thead>
          <tbody id="savesBody"><tr><td colspan="4" class="empty">Loading saves...</td></tr></tbody>
        </table>
      </div>
    </section>

    <section class="card">
      <h2>Server Settings</h2>
      <form id="settingsForm">
        <label class="field"><span>Server name</span><input type="text" id="setName" autocomplete="off"></label>
        <div class="two-col">
          <label class="field"><span>Max players</span><input type="number" id="setPlayers" min="1" max="64"></label>
          <label class="field"><span>Save interval (s)</span><input type="number" id="setInterval" min="30" max="86400"></label>
        </div>
        <label class="field"><span>Server password (blank = open)</span><input type="text" id="setPassword" autocomplete="off"></label>
        <div class="check"><input type="checkbox" id="setAutoSave"><label for="setAutoSave">Automatic saves</label></div>
        <div class="check"><input type="checkbox" id="setAutoStart"><label for="setAutoStart">Start server when SSUI boots</label></div>
        <div class="btn-row"><button class="primary" type="submit">Save settings</button></div>
        <p class="small muted" style="margin-bottom:0">Password changes take effect on the next server start.</p>
      </form>
    </section>

    <section class="card">
      <h2>Logs <span class="right"><a href="#" id="refreshLogs">refresh</a></span></h2>
      <pre class="logs" id="logs">Loading...</pre>
    </section>
  </div>
</main>

<div class="modal" id="loginModal">
  <div class="box">
    <h3>Control Deck Login</h3>
    <p>Sign in with the panel credentials from <span class="mono">/root/stationeers-credentials.txt</span>.</p>
    <form id="loginForm">
      <label class="field"><span>Username</span><input type="text" id="loginUser" value="admin" autocomplete="username"></label>
      <label class="field"><span>Password</span><input type="password" id="loginPass" autocomplete="current-password"></label>
      <div class="err" id="loginErr"></div>
      <button class="primary" type="submit" style="width:100%">Sign in</button>
    </form>
  </div>
</div>

<div class="modal" id="credsModal">
  <div class="box">
    <h3>SSUI Login</h3>
    <p>Only needed if the panel cannot create or use its own SSUI owner token. These credentials are stored on this server.</p>
    <form id="credsForm">
      <label class="field"><span>SSUI username</span><input type="text" id="ssuiUser" value="admin" autocomplete="username"></label>
      <label class="field"><span>SSUI password</span><input type="password" id="ssuiPass" autocomplete="current-password"></label>
      <div class="err" id="credsErr"></div>
      <button class="primary" type="submit" style="width:100%">Connect</button>
    </form>
  </div>
</div>

<div class="toast" id="toast"></div>

<script>
(function () {
  "use strict";
  var state = null;
  var pollTimer = null;
  var logsTimer = null;
  var uploading = false;
  var settingsLoaded = false;

  function $(id) { return document.getElementById(id); }

  function api(path, opts) {
    opts = opts || {};
    opts.headers = Object.assign({ "X-Requested-With": "stationeers-panel" }, opts.headers || {});
    if (opts.json !== undefined) {
      opts.body = JSON.stringify(opts.json);
      opts.headers["Content-Type"] = "application/json";
      delete opts.json;
    }
    return fetch(path, opts).then(function (res) {
      if (res.status === 401) {
        showModal("loginModal");
        throw new Error("Please sign in");
      }
      return res.text().then(function (text) {
        var body = {};
        try { body = text ? JSON.parse(text) : {}; } catch (e) { body = { error: text }; }
        if (!res.ok) { throw new Error(body.error || ("HTTP " + res.status)); }
        return body;
      });
    });
  }

  function toast(message, isError) {
    var el = $("toast");
    el.textContent = message;
    el.className = "toast show" + (isError ? " error" : "");
    clearTimeout(el._timer);
    el._timer = setTimeout(function () { el.className = "toast"; }, 4500);
  }

  function showModal(id) { $(id).classList.add("show"); }
  function hideModal(id) { $(id).classList.remove("show"); }

  function fmtDuration(seconds) {
    seconds = Math.max(0, Math.floor(seconds || 0));
    var d = Math.floor(seconds / 86400), h = Math.floor(seconds % 86400 / 3600);
    var m = Math.floor(seconds % 3600 / 60), s = seconds % 60;
    if (d) return d + "d " + h + "h";
    if (h) return h + "h " + m + "m";
    if (m) return m + "m " + s + "s";
    return s + "s";
  }

  function esc(text) {
    return String(text == null ? "" : text).replace(/[&<>"']/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c];
    });
  }

  function setStatus(kind, label) {
    var pill = $("statusPill");
    pill.className = "pill " + kind;
    $("statusText").textContent = label;
  }

  function render(s) {
    state = s;
    var running = !!(s.server && s.server.running);
    var connected = !!s.connected;
    var bootstrap = s.bootstrap || {};

    if (!connected) {
      setStatus(bootstrap.state === "waiting" ? "busy" : "offline", bootstrap.state === "waiting" ? "Waiting for SSUI" : "Disconnected");
    } else if (running) {
      setStatus("online", "Online");
    } else {
      setStatus("offline", "Stopped");
    }

    var banner = $("banner");
    if (!connected) {
      banner.classList.add("show");
      banner.classList.toggle("error", bootstrap.state === "error");
      $("bannerTitle").textContent = bootstrap.state === "waiting" ? "SSUI starting" : "SSUI offline";
      $("bannerMsg").textContent = bootstrap.message || "Waiting for Stationeers Server UI...";
    } else if (s.error) {
      banner.classList.add("show", "error");
      $("bannerTitle").textContent = "SSUI error";
      $("bannerMsg").textContent = s.error;
    } else {
      banner.classList.remove("show", "error");
    }

    var big = $("bigStatus");
    big.textContent = running ? "Online" : (connected ? "Stopped" : "Offline");
    big.className = "big-status " + (running ? "online" : "offline");
    $("statusDetail").textContent = running
      ? ("Process state: " + (s.server.state || "running") + (s.server.startedAt ? " · since " + new Date(s.server.startedAt).toLocaleTimeString() : ""))
      : (connected ? "Server is not running. Load a save and press Start." : (bootstrap.message || "Waiting for SSUI to finish its first-time install."));

    var settings = s.settings || {};
    var port = settings.gamePort || "27016";
    $("gameAddress").textContent = location.hostname + ":" + port + " /udp";
    $("uptime").textContent = running ? fmtDuration(s.server.uptimeSeconds) : "-";
    $("activeSave").textContent = settings.saveName || "-";
    $("branchLabel").textContent = settings.gameBranch ? settings.gameBranch.toUpperCase() : "";
    $("ssuiLink").href = location.protocol + "//" + location.hostname + ":8443";

    var players = s.players || [];
    $("players").innerHTML = players.length
      ? '<span class="player-list">' + players.map(function (p) {
          var name = typeof p === "string" ? p : (p.username || p.name || "player");
          return '<span class="player">' + esc(name) + "</span>";
        }).join("") + "</span>"
      : "0";

    if (s.disk && s.disk.total) {
      var usedPct = Math.round((1 - s.disk.free / s.disk.total) * 100);
      $("diskBar").style.width = Math.max(2, usedPct) + "%";
      $("disk").textContent = s.disk.freeText + " free of " + s.disk.totalText;
    }

    $("startBtn").disabled = !connected || running;
    $("stopBtn").disabled = !connected || !running;
    $("restartBtn").disabled = !connected || !running;
    $("createBtn").disabled = !connected;

    renderSaves(s.saves || []);
    renderWorlds(s.worlds || []);
    if (!settingsLoaded && connected) fillSettings(settings);
  }

  function renderSaves(saves) {
    var body = $("savesBody");
    $("saveCount").textContent = saves.length + (saves.length === 1 ? " save" : " saves");
    if (!saves.length) {
      body.innerHTML = '<tr><td colspan="4" class="empty">No save folders yet. Upload one above or create a new world.</td></tr>';
      return;
    }
    body.innerHTML = saves.map(function (save) {
      var actions = "";
      actions += '<button class="tiny primary" data-action="launch" data-name="' + esc(save.name) + '">' + (save.active ? "Restart" : "Load &amp; launch") + "</button>";
      if (!save.active) actions += '<button class="tiny" data-action="activate" data-name="' + esc(save.name) + '">Set active</button>';
      actions += '<a href="/api/saves/' + encodeURIComponent(save.name) + '/download"><button class="tiny">Download</button></a>';
      actions += '<button class="tiny" data-action="rename" data-name="' + esc(save.name) + '">Rename</button>';
      actions += '<button class="tiny danger" data-action="delete" data-name="' + esc(save.name) + '">Delete</button>';
      return "<tr>" +
        '<td class="name-cell">' + esc(save.name) + (save.active ? ' <span class="badge active">active</span>' : "") + "</td>" +
        "<td>" + esc(save.sizeText) + "</td>" +
        "<td class=\"muted\">" + esc(save.modified) + "</td>" +
        '<td><div class="row-actions">' + actions + "</div></td>" +
      "</tr>";
    }).join("");
  }

  function renderWorlds(worlds) {
    var select = $("worldSelect");
    if (!worlds.length) return;
    var current = select.value;
    select.innerHTML = worlds.map(function (w) {
      return '<option value="' + esc(w.id) + '">' + esc(w.name) + "</option>";
    }).join("");
    var found = worlds.some(function (w) { return w.id === current; });
    if (found) select.value = current;
    $("worldHint").textContent = "World list loaded from your Stationeers install.";
  }

  function fillSettings(s) {
    $("setName").value = s.serverName || "";
    $("setPlayers").value = s.serverMaxPlayers || "8";
    $("setInterval").value = s.saveInterval || "300";
    $("setPassword").value = s.serverPassword || "";
    $("setAutoSave").checked = !!s.autoSave;
    $("setAutoStart").checked = !!s.autoStartServerOnStartup;
    settingsLoaded = true;
  }

  function refresh() {
    if (uploading) return;
    api("/api/state").then(render).catch(function (err) {
      if (err.message !== "Please sign in") {
        setStatus("offline", "Disconnected");
        toast(err.message, true);
      }
    });
  }

  function refreshLogs() {
    api("/api/logs?lines=250").then(function (body) {
      var pre = $("logs");
      var atBottom = pre.scrollTop + pre.clientHeight >= pre.scrollHeight - 30;
      pre.textContent = body.logs || "(no output)";
      if (atBottom) pre.scrollTop = pre.scrollHeight;
    }).catch(function () {});
  }

  function runServer(action) {
    var labels = { start: "Starting server...", stop: "Stopping server...", restart: "Restarting server..." };
    toast(labels[action] || "Working...");
    api("/api/server/" + action, { method: "POST", json: {} })
      .then(function (body) { toast(body.message || "Done"); setTimeout(refresh, 1200); })
      .catch(function (err) { toast(err.message, true); });
  }

  function loadSave(name) {
    if (!confirm('Load "' + name + '" and start the server?')) return;
    api("/api/saves/" + encodeURIComponent(name) + "/activate", { method: "POST", json: { launch: true } })
      .then(function (body) { toast(body.message); setTimeout(refresh, 1500); })
      .catch(function (err) { toast(err.message, true); });
  }

  function setActive(name) {
    api("/api/saves/" + encodeURIComponent(name) + "/activate", { method: "POST", json: { launch: false } })
      .then(function (body) { toast(body.message); refresh(); })
      .catch(function (err) { toast(err.message, true); });
  }

  function renameSave(name) {
    var next = prompt("New name for \"" + name + "\":", name);
    if (!next || next === name) return;
    api("/api/saves/" + encodeURIComponent(name) + "/rename", { method: "POST", json: { newName: next } })
      .then(function () { toast("Renamed to " + next); refresh(); })
      .catch(function (err) { toast(err.message, true); });
  }

  function deleteSave(name) {
    if (!confirm('Delete "' + name + '" permanently? Download a copy first if you are unsure.')) return;
    api("/api/saves/" + encodeURIComponent(name), { method: "DELETE" })
      .then(function () { toast("Deleted " + name); refresh(); })
      .catch(function (err) { toast(err.message, true); });
  }

  function uploadFile(file, name, overwrite, launch) {
    if (!file) return;
    uploading = true;
    $("uploadBtn").disabled = true;
    $("progress").classList.add("show");
    $("progressBar").style.width = "0%";
    var url = "/api/saves/upload?overwrite=" + (overwrite ? "1" : "0") + "&launch=" + (launch ? "1" : "0");
    if (name) url += "&name=" + encodeURIComponent(name);
    var xhr = new XMLHttpRequest();
    xhr.open("POST", url);
    xhr.setRequestHeader("X-Requested-With", "stationeers-panel");
    xhr.setRequestHeader("X-Filename", encodeURIComponent(file.name));
    xhr.upload.onprogress = function (ev) {
      if (ev.lengthComputable) {
        $("progressBar").style.width = Math.round(ev.loaded / ev.total * 100) + "%";
      }
    };
    xhr.onload = function () {
      uploading = false;
      $("progress").classList.remove("show");
      $("uploadBtn").disabled = false;
      var body = {};
      try { body = JSON.parse(xhr.responseText || "{}"); } catch (e) {}
      if (xhr.status === 401) { showModal("loginModal"); return; }
      if (xhr.status >= 200 && xhr.status < 300) {
        toast(body.message || "Save imported");
        $("fileInput").value = "";
        $("uploadName").value = "";
        setTimeout(refresh, 1500);
      } else {
        toast(body.error || ("Upload failed (HTTP " + xhr.status + ")"), true);
      }
    };
    xhr.onerror = function () {
      uploading = false;
      $("progress").classList.remove("show");
      $("uploadBtn").disabled = false;
      toast("Upload failed: connection error", true);
    };
    xhr.send(file);
  }

  // Events
  $("startBtn").addEventListener("click", function () { runServer("start"); });
  $("stopBtn").addEventListener("click", function () { runServer("stop"); });
  $("restartBtn").addEventListener("click", function () { runServer("restart"); });
  $("retryBtn").addEventListener("click", function () {
    api("/api/ssui/retry", { method: "POST", json: {} }).then(function () { toast("Retrying SSUI connection"); setTimeout(refresh, 2000); }).catch(function (e) { toast(e.message, true); });
  });
  $("credsBtn").addEventListener("click", function () { showModal("credsModal"); });
  $("copyBtn").addEventListener("click", function () {
    var text = $("gameAddress").textContent;
    if (navigator.clipboard) navigator.clipboard.writeText(text).then(function () { toast("Copied " + text); });
  });
  $("refreshLogs").addEventListener("click", function (e) { e.preventDefault(); refreshLogs(); });
  $("logoutLink").addEventListener("click", function (e) {
    e.preventDefault();
    fetch("/api/logout", { method: "POST", headers: { "X-Requested-With": "stationeers-panel" } }).finally(function () {
      document.cookie = "stationeers_panel_session=; Max-Age=0; path=/";
      location.reload();
    });
  });

  $("savesBody").addEventListener("click", function (ev) {
    var btn = ev.target.closest("button[data-action]");
    if (!btn) return;
    var name = btn.getAttribute("data-name");
    var action = btn.getAttribute("data-action");
    if (action === "launch") loadSave(name);
    else if (action === "activate") setActive(name);
    else if (action === "rename") renameSave(name);
    else if (action === "delete") deleteSave(name);
  });

  $("fileInput").addEventListener("change", function () {
    $("uploadBtn").disabled = !this.files.length;
  });
  $("uploadBtn").addEventListener("click", function () {
    var file = $("fileInput").files[0];
    uploadFile(file, $("uploadName").value.trim(), $("overwrite").checked, $("uploadLaunch").checked);
  });

  var dz = $("dropzone");
  ["dragenter", "dragover"].forEach(function (name) {
    dz.addEventListener(name, function (e) { e.preventDefault(); dz.classList.add("hover"); });
  });
  ["dragleave", "drop"].forEach(function (name) {
    dz.addEventListener(name, function (e) { e.preventDefault(); dz.classList.remove("hover"); });
  });
  dz.addEventListener("drop", function (e) {
    var file = e.dataTransfer.files[0];
    if (!file) return;
    uploadFile(file, $("uploadName").value.trim(), $("overwrite").checked, $("uploadLaunch").checked);
  });

  $("createBtn").addEventListener("click", function () {
    var name = $("newName").value.trim();
    if (!name) { toast("Enter a save name", true); return; }
    api("/api/worlds", { method: "POST", json: {
      saveName: name,
      worldId: $("worldSelect").value,
      launch: $("newLaunch").checked
    } }).then(function (body) {
      toast(body.message);
      $("newName").value = "";
      setTimeout(refresh, 1500);
    }).catch(function (err) { toast(err.message, true); });
  });

  $("settingsForm").addEventListener("submit", function (e) {
    e.preventDefault();
    api("/api/settings", { method: "POST", json: {
      serverName: $("setName").value,
      serverMaxPlayers: $("setPlayers").value,
      serverPassword: $("setPassword").value,
      saveInterval: $("setInterval").value,
      autoSave: $("setAutoSave").checked,
      autoStartServerOnStartup: $("setAutoStart").checked
    } }).then(function () { toast("Settings saved"); refresh(); })
      .catch(function (err) { toast(err.message, true); });
  });

  $("loginForm").addEventListener("submit", function (e) {
    e.preventDefault();
    $("loginErr").textContent = "";
    fetch("/api/login", {
      method: "POST",
      headers: { "X-Requested-With": "stationeers-panel", "Content-Type": "application/json" },
      body: JSON.stringify({ username: $("loginUser").value, password: $("loginPass").value })
    }).then(function (res) {
      return res.text().then(function (text) {
        var body = {};
        try { body = JSON.parse(text); } catch (err) {}
        if (!res.ok) throw new Error(body.error || "Login failed");
        hideModal("loginModal");
        settingsLoaded = false;
        $("loginPass").value = "";
        startPolling();
        refresh();
      });
    }).catch(function (err) { $("loginErr").textContent = err.message; });
  });

  $("credsForm").addEventListener("submit", function (e) {
    e.preventDefault();
    $("credsErr").textContent = "";
    api("/api/ssui/credentials", { method: "POST", json: {
      username: $("ssuiUser").value,
      password: $("ssuiPass").value
    } }).then(function () {
      hideModal("credsModal");
      toast("Connected to SSUI");
      settingsLoaded = false;
      refresh();
    }).catch(function (err) { $("credsErr").textContent = err.message; });
  });

  document.querySelectorAll(".modal").forEach(function (modal) {
    modal.addEventListener("click", function (e) { if (e.target === modal) modal.classList.remove("show"); });
  });

  function startPolling() {
    clearInterval(pollTimer);
    clearInterval(logsTimer);
    pollTimer = setInterval(function () { if (!document.hidden) refresh(); }, 5000);
    logsTimer = setInterval(function () { if (!document.hidden) refreshLogs(); }, 15000);
  }

  api("/api/state").then(function (s) {
    if (s) { render(s); refreshLogs(); startPolling(); }
  }).catch(function (err) {
    if (err.message === "Please sign in") showModal("loginModal");
    else { setStatus("offline", "Disconnected"); toast(err.message, true); startPolling(); }
  });
})();
</script>
</body>
</html>
PANEL_HTML_EOF
  chmod 755 "${PANEL_DIR}/panel.py"
  chmod 644 "${PANEL_DIR}/panel.html"
  chown root:root "${PANEL_DIR}/panel.py" "${PANEL_DIR}/panel.html"
}

write_tls_cert() {
  local host ip san
  host="$(hostname -s 2>/dev/null || hostname)"
  ip="$(ip_address)"
  san="DNS:${host},DNS:localhost,IP:127.0.0.1"
  [[ -n "$ip" ]] && san="${san},IP:${ip}"
  mkdir -p "$PANEL_TLS_DIR"
  if [[ ! -f "${PANEL_TLS_DIR}/server.crt" || ! -f "${PANEL_TLS_DIR}/server.key" ]]; then
    msg_info "Creating a self-signed TLS certificate for the Control Deck"
    openssl req -x509 -nodes -newkey rsa:2048 -sha256 -days 3650 \
      -keyout "${PANEL_TLS_DIR}/server.key" \
      -out "${PANEL_TLS_DIR}/server.crt" \
      -subj "/CN=${host}" \
      -addext "subjectAltName=${san}" >/dev/null 2>&1 \
      || die "openssl failed to create the panel certificate."
    chmod 600 "${PANEL_TLS_DIR}/server.key"
    chmod 644 "${PANEL_TLS_DIR}/server.crt"
    chown -R "$SSUI_USER:$SSUI_USER" "$PANEL_TLS_DIR"
  fi
}

write_panel_config() {
  mkdir -p "$PANEL_CONFIG_DIR"
  chown "$SSUI_USER:$SSUI_USER" "$PANEL_CONFIG_DIR"
  chmod 750 "$PANEL_CONFIG_DIR"

  if [[ -f "$PANEL_CONFIG" ]]; then
    msg_ok "Keeping existing Control Deck configuration"
    if [[ ! -f "$CREDS_FILE" ]]; then
      msg_warn "Credentials file was missing; resetting the Control Deck password."
      reset_panel_password_impl keep_quiet
    fi
    return
  fi

  msg_info "Generating access credentials"
  local owner_user panel_user owner_pass panel_pass hash saves_dir
  owner_user="${SSUI_OWNER_USER:-admin}"
  panel_user="${PANEL_ADMIN_USER:-admin}"
  owner_pass="$(gen_password 24)"
  panel_pass="$(gen_password 18)"
  saves_dir="${SSUI_DIR}/saves"
  hash="$(PANEL_PASS="$panel_pass" python3 -c '
import base64, hashlib, os
pw = os.environ["PANEL_PASS"].encode()
salt = os.urandom(16)
dk = hashlib.pbkdf2_hmac("sha256", pw, salt, 260000)
print("pbkdf2$260000$%s$%s" % (base64.b64encode(salt).decode(), base64.b64encode(dk).decode()))
')"

  PANEL_USER="$panel_user" PANEL_HASH="$hash" \
  OWNER_USER="$owner_user" OWNER_PASS="$owner_pass" \
  SSUI_DIR="$SSUI_DIR" SAVES_DIR="$saves_dir" \
  PANEL_CONFIG="$PANEL_CONFIG" PANEL_TLS_DIR="$PANEL_TLS_DIR" \
  PANEL_PORT="$PANEL_PORT" \
  python3 - <<'PY'
import json
import os
import time

cfg = {
    "panel": {
        "username": os.environ["PANEL_USER"],
        "passwordHash": os.environ["PANEL_HASH"],
        "port": int(os.environ["PANEL_PORT"]),
        "tls": True,
        "tlsCert": os.path.join(os.environ["PANEL_TLS_DIR"], "server.crt"),
        "tlsKey": os.path.join(os.environ["PANEL_TLS_DIR"], "server.key"),
    },
    "ssui": {
        "url": "https://127.0.0.1:8443",
        "username": os.environ["OWNER_USER"],
        "password": os.environ["OWNER_PASS"],
        "token": "",
        "tokenName": "stationeers-panel",
    },
    "paths": {
        "ssuiDir": os.environ["SSUI_DIR"],
        "savesDir": os.environ["SAVES_DIR"],
        "service": "ssui",
    },
    "meta": {
        "installedAt": int(time.time()),
        "version": 1,
    },
}
os.makedirs(os.path.dirname(os.environ["PANEL_CONFIG"]), exist_ok=True)
with open(os.environ["PANEL_CONFIG"], "w", encoding="utf-8") as fh:
    json.dump(cfg, fh, indent=2)
    fh.write("\n")
PY
  chown "$SSUI_USER:$SSUI_USER" "$PANEL_CONFIG"
  chmod 600 "$PANEL_CONFIG"
  write_creds_file "$owner_user" "$owner_pass" "$panel_user" "$panel_pass"
  msg_ok "Credentials written to ${CREDS_FILE}"
}

read_config_identity() {
  PANEL_CONFIG="$PANEL_CONFIG" python3 - <<'PY'
import json
import os

with open(os.environ["PANEL_CONFIG"], "r", encoding="utf-8") as fh:
    cfg = json.load(fh)
print(cfg["ssui"]["username"])
print(cfg["ssui"]["password"])
print(cfg["panel"]["username"])
PY
}

set_panel_password_hash() {
  local new_hash="$1"
  PANEL_CONFIG="$PANEL_CONFIG" NEW_HASH="$new_hash" python3 - <<'PY'
import json
import os

path = os.environ["PANEL_CONFIG"]
with open(path, "r", encoding="utf-8") as fh:
    cfg = json.load(fh)
cfg["panel"]["passwordHash"] = os.environ["NEW_HASH"]
with open(path, "w", encoding="utf-8") as fh:
    json.dump(cfg, fh, indent=2)
    fh.write("\n")
PY
  chown "$SSUI_USER:$SSUI_USER" "$PANEL_CONFIG"
  chmod 600 "$PANEL_CONFIG"
}

reset_panel_password_impl() {
  local quiet="${1:-}"
  [[ -f "$PANEL_CONFIG" ]] || die "No panel configuration found at ${PANEL_CONFIG}."
  local new_pass new_hash owner_user owner_pass panel_user
  new_pass="$(gen_password 18)"
  new_hash="$(PANEL_PASS="$new_pass" python3 -c '
import base64, hashlib, os
pw = os.environ["PANEL_PASS"].encode()
salt = os.urandom(16)
dk = hashlib.pbkdf2_hmac("sha256", pw, salt, 260000)
print("pbkdf2$260000$%s$%s" % (base64.b64encode(salt).decode(), base64.b64encode(dk).decode()))
')"
  set_panel_password_hash "$new_hash"
  local identity
  mapfile -t identity < <(read_config_identity)
  owner_user="${identity[0]}"
  owner_pass="${identity[1]}"
  panel_user="${identity[2]}"
  write_creds_file "$owner_user" "$owner_pass" "$panel_user" "$new_pass"
  install_creds_helper
  if [[ "$quiet" != "keep_quiet" ]]; then
    systemctl restart "$PANEL_SERVICE" 2>/dev/null || true
    msg_ok "New Control Deck password: ${new_pass}"
    msg_info "Credential file updated: ${CREDS_FILE}"
  fi
}

# ----- services -----------------------------------------------------------
write_services() {
  msg_info "Creating systemd services"
  cat > "/etc/systemd/system/${SSUI_SERVICE}.service" <<EOF
[Unit]
Description=Stationeers Server UI (SSUI)
Documentation=https://ssui.dev
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SSUI_USER}
Group=${SSUI_USER}
WorkingDirectory=${SSUI_DIR}
ExecStart=${SSUI_DIR}/StationeersServerUI
Restart=always
RestartSec=10
TimeoutStartSec=300
TimeoutStopSec=120
KillSignal=SIGTERM
Environment=HOME=${SSUI_HOME}
Environment=TERM=xterm-256color
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

  cat > "/etc/systemd/system/${PANEL_SERVICE}.service" <<EOF
[Unit]
Description=Stationeers Control Deck (save and launch panel)
After=network-online.target ${SSUI_SERVICE}.service
Wants=network-online.target

[Service]
Type=simple
User=${SSUI_USER}
Group=${SSUI_USER}
WorkingDirectory=${PANEL_DIR}
ExecStart=/usr/bin/python3 ${PANEL_DIR}/panel.py
Restart=always
RestartSec=5
TimeoutStopSec=20
Environment=PYTHONUNBUFFERED=1
Environment=HOME=${SSUI_HOME}

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable "$SSUI_SERVICE" >/dev/null 2>&1 || true
  systemctl enable "$PANEL_SERVICE" >/dev/null 2>&1 || true
}

configure_console_autologin() {
  msg_info "Enabling root auto-login on the container console"
  local dropin="/etc/systemd/system/getty@tty1.service.d"
  mkdir -p "$dropin"
  cat > "$dropin/autologin.conf" <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noreset --noclear %I $TERM
EOF
  systemctl daemon-reload
  systemctl enable getty@tty1.service >/dev/null 2>&1 || true
  systemctl restart getty@tty1.service 2>/dev/null || true
}

write_motd() {  local ip host
  ip="$(ip_address)"
  [[ -z "$ip" ]] && ip="<server-ip>"
  host="$(hostname -s 2>/dev/null || hostname)"
  cat > /etc/motd <<EOF

  Stationeers server
  ------------------
  Control Deck : https://${ip}:${PANEL_PORT}
  SSUI         : https://${ip}:${SSUI_WEB_PORT}
  Game         : ${GAME_PORT}/udp  (${host})
  Credentials  : stationeers-creds

EOF
}

wait_for_port() {
  local port="$1" tries="${2:-30}" i
  for ((i = 0; i < tries; i++)); do
    if curl -sk --max-time 2 "https://127.0.0.1:${port}/" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

print_summary() {
  local ip host
  ip="$(ip_address)"
  [[ -z "$ip" ]] && ip="<server-ip>"
  host="$(hostname -s 2>/dev/null || hostname)"

  printf "\n"
  printf "  ${GN}Installation complete${CL}\n\n"
  printf "  ${YW}Control Deck${CL}  https://%s:%s\n" "$ip" "$PANEL_PORT"
  printf "  ${YW}SSUI${CL}          https://%s:%s\n" "$ip" "$SSUI_WEB_PORT"
  printf "  ${YW}Game port${CL}     %s/udp\n" "$GAME_PORT"
  printf "  ${YW}Hostname${CL}      %s\n\n" "$host"
  printf "  ${BL}Credentials${CL}   cat %s   (or run: stationeers-creds)\n" "$CREDS_FILE"
  printf "  ${BL}First start${CL}   SSUI downloads SteamCMD + the ~10 GB game on first boot.\n"
  printf "                 The panel shows progress and connects automatically.\n\n"
  printf "  ${BL}Import a save${CL} open the Control Deck, drop a zip of the save folder\n"
  printf "                 (the folder containing world.xml) and press Load & launch.\n\n"
  printf "  ${YW}Firewall${CL}      allow %s/udp, %s/tcp and %s/tcp on your LAN.\n\n" "$GAME_PORT" "$SSUI_WEB_PORT" "$PANEL_PORT"
}

# ----- inside install -----------------------------------------------------
prepare_host_inside() {
  require_root
  check_platform

  if ! id -u "$SSUI_USER" >/dev/null 2>&1; then
    msg_info "Creating the ${SSUI_USER} service user"
    useradd -m -d "$SSUI_HOME" -s /bin/bash "$SSUI_USER"
  fi
  usermod -aG systemd-journal "$SSUI_USER" >/dev/null 2>&1 || true

  mkdir -p "$SSUI_DIR"
  chown -R "$SSUI_USER:$SSUI_USER" "$SSUI_HOME"
  chmod 750 "$SSUI_HOME"
}

install_inside() {
  header_info
  msg_info "Installing Stationeers dedicated server stack on $(hostname)"
  prepare_host_inside
  install_packages

  systemctl stop "$PANEL_SERVICE" 2>/dev/null || true
  systemctl stop "$SSUI_SERVICE" 2>/dev/null || true

  install_ssui_binary
  write_tls_cert
  write_panel_files
  write_panel_config
  install_creds_helper
  install_self_helper
  install_update_helper
  write_services
  configure_console_autologin
  write_motd

  msg_info "Starting services"
  systemctl restart "$SSUI_SERVICE"
  systemctl restart "$PANEL_SERVICE"

  if wait_for_port "$PANEL_PORT" 30; then
    msg_ok "Control Deck is listening on port ${PANEL_PORT}"
  else
    msg_warn "Control Deck did not open port ${PANEL_PORT} yet. Check: journalctl -u ${PANEL_SERVICE} -n 50"
  fi

  sleep 2
  if ! systemctl is-active --quiet "$SSUI_SERVICE"; then
    msg_warn "SSUI is not active. Check: journalctl -u ${SSUI_SERVICE} -n 100"
  fi

  print_summary
  printf "  ${GN}Credentials:${CL}\n\n"
  sed 's/^/    /' "$CREDS_FILE"
  printf "\n"
}

update_game_server() {
  local steamcmd="${SSUI_DIR}/steamcmd/steamcmd.sh"
  local branch="public"
  if [[ ! -x "$steamcmd" ]]; then
    msg_warn "SteamCMD is not installed yet. SSUI will install it and the game on next start."
    return 0
  fi
  if [[ -f "${SSUI_DIR}/SSUI/config/config.json" ]]; then
    branch="$(jq -r '.gameBranch // "public"' "${SSUI_DIR}/SSUI/config/config.json" 2>/dev/null || printf 'public')"
  fi
  [[ -n "$branch" ]] || branch="public"

  local -a args=(+force_install_dir "$SSUI_DIR" +login anonymous +app_update 600760 -beta "$branch")
  if [[ "${SKIP_VALIDATE:-0}" != "1" ]]; then
    args+=(validate)
  fi
  args+=(+quit)

  msg_info "Updating the Stationeers dedicated server (branch: ${branch})"
  if command -v runuser >/dev/null 2>&1; then
    if runuser -u "$SSUI_USER" -- env HOME="$SSUI_HOME" "$steamcmd" "${args[@]}"; then
      msg_ok "Stationeers server files updated"
    else
      msg_warn "SteamCMD reported an error. SSUI can retry the update when it starts."
    fi
  else
    msg_warn "runuser is unavailable; skipping the SteamCMD update."
  fi
}

update_inside() {
  header_info
  require_root
  check_platform
  msg_info "Updating SSUI, the Stationeers server and the Control Deck"
  systemctl stop "$PANEL_SERVICE" 2>/dev/null || true
  systemctl stop "$SSUI_SERVICE" 2>/dev/null || true
  install_ssui_binary
  update_game_server
  write_panel_files
  write_tls_cert
  [[ -f "$PANEL_CONFIG" ]] || write_panel_config
  install_creds_helper
  install_self_helper
  install_update_helper
  write_services
  configure_console_autologin
  systemctl restart "$SSUI_SERVICE"
  systemctl restart "$PANEL_SERVICE"
  msg_ok "Updated. Saves and configuration were kept."
  print_summary
}

update_panel_only() {
  header_info
  require_root
  msg_info "Updating the Control Deck only (SSUI and its download keep running)"
  write_panel_files
  write_tls_cert
  [[ -f "$PANEL_CONFIG" ]] || write_panel_config
  install_creds_helper
  install_self_helper
  install_update_helper
  configure_console_autologin
  systemctl restart "$PANEL_SERVICE"
  if systemctl is-active --quiet "$PANEL_SERVICE"; then
    msg_ok "Control Deck updated and restarted on port ${PANEL_PORT}"
  else
    msg_error "Control Deck failed to start. Check: journalctl -u ${PANEL_SERVICE} -n 50"
    exit 1
  fi
}

reset_panel_password() {
  header_info
  require_root
  reset_panel_password_impl
  systemctl restart "$PANEL_SERVICE" 2>/dev/null || true
  printf "\n"
  sed 's/^/    /' "$CREDS_FILE"
  printf "\n"
}

# ----- Proxmox VE host flow ----------------------------------------------
is_pve_host() {
  [[ -d /etc/pve ]] && command -v pct >/dev/null 2>&1 && command -v pveam >/dev/null 2>&1
}

select_template() {
  local storage line available seen=" "
  local arch="${TEMPLATE_ARCH:-amd64}"
  local re="debian-13-standard_.*_${arch}[.]tar[.]zst$"
  local -a storages=()

  # Reuse a Debian 13 template that is already downloaded. This also keeps
  # working when the appliance index cannot be refreshed (offline, mirror,
  # subscription/SSL trouble), which is where the old lookup died silently.
  [[ -n "${TEMPLATE_STORAGE:-}" ]] && storages+=("$TEMPLATE_STORAGE")
  while IFS= read -r storage; do
    [[ -n "$storage" ]] || continue
    [[ "$seen" == *" $storage "* ]] && continue
    seen+="$storage "
    storages+=("$storage")
  done < <(pvesm status --content vztmpl 2>/dev/null | awk 'NR>1 {print $1}' || true)

  for storage in "${storages[@]:-}"; do
    [[ -n "$storage" ]] || continue
    line="$(pveam list "$storage" 2>/dev/null | awk -v re="$re" '$1 ~ re {print $1; exit}' || true)"
    if [[ -n "$line" ]]; then
      TEMPLATE="${line##*/}"
      TEMPLATE_STORAGE="$storage"
      msg_ok "Using existing template ${TEMPLATE} on ${TEMPLATE_STORAGE}"
      return 0
    fi
  done

  # pveam list without a storage argument lists every storage; use it as a
  # fallback in case pvesm did not report a vztmpl storage above.
  line="$(pveam list 2>/dev/null | awk -v re="$re" '$1 ~ re {print $1; exit}' || true)"
  if [[ -n "$line" ]]; then
    TEMPLATE="${line##*/}"
    TEMPLATE_STORAGE="${line%%:*}"
    msg_ok "Using existing template ${TEMPLATE} on ${TEMPLATE_STORAGE}"
    return 0
  fi

  # No local template: refresh the appliance index and look again.
  msg_info "Updating the Proxmox appliance index"
  if ! pveam update >/tmp/pveam-update.log 2>&1; then
    msg_warn "pveam update failed: $(tail -n 2 /tmp/pveam-update.log 2>/dev/null | tr '\n' ' ')"
  fi
  if ! available="$(pveam available --section system 2>&1)"; then
    msg_error "pveam available failed:"
    printf '%s\n' "$available" | sed 's/^/    /' >&2
    die "Could not read the Proxmox appliance index. Download a Debian 13 template manually, then re-run."
  fi

  TEMPLATE="$(printf '%s\n' "$available" | awk -v re="^debian-13-standard.*_${arch}[.]tar[.]zst$" '$NF ~ re {print $NF}' | sort -V | tail -n1)"
  if [[ -z "$TEMPLATE" ]]; then
    msg_error "No ${arch} Debian 13 template was found."
    msg_error "This host is ${arch}. Stationeers/SteamCMD need an amd64 container,"
    msg_error "so arm64 templates cannot be used even though Proxmox downloaded them."
    msg_error "Templates already downloaded on this host:"
    for storage in "${storages[@]:-}"; do
      [[ -n "$storage" ]] || continue
      pveam list "$storage" 2>/dev/null | sed 's/^/    /' >&2 || true
    done
    msg_error "Download one with:"
    msg_error "  pveam available --section system | grep 'debian-13.*amd64'"
    msg_error "  pveam download <storage> <that-filename>"
    die "Cannot continue without a Debian 13 amd64 template."
  fi

  if [[ -z "${TEMPLATE_STORAGE:-}" ]]; then
    for storage in "${storages[@]:-}"; do
      [[ -n "$storage" ]] || continue
      TEMPLATE_STORAGE="$storage"
      break
    done
  fi
  TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"
  msg_ok "Selected ${TEMPLATE} on ${TEMPLATE_STORAGE}"
}

pve_flow() {
  require_root
  header_info

  local HOST_ARCH TEMPLATE_ARCH
  HOST_ARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"
  case "$HOST_ARCH" in
    amd64|x86_64) TEMPLATE_ARCH="amd64" ;;
    arm64|aarch64)
      die "This Proxmox host is ARM64 (${HOST_ARCH}), but the Stationeers dedicated server and SteamCMD are x86_64-only. Use an x86_64 Proxmox host (or an x86_64 VM on another machine)."
      ;;
    *)
      die "Unsupported host architecture: ${HOST_ARCH}. The Stationeers server requires x86_64."
      ;;
  esac

  msg_info "Proxmox VE detected: this will create a Debian 13 LXC for the server."
  printf "\n"

  local CTID="${CTID:-$(pvesh get /cluster/nextid 2>/dev/null || echo 100)}"
  local HN="${HN:-stationeers}"
  local CORES="${CORES:-8}"
  local RAM="${RAM:-16384}"
  local DISK="${DISK:-50}"
  local BRIDGE="${BRIDGE:-vmbr0}"
  local CT_IP="${CT_IP:-}"
  local CT_GW="${CT_GW:-}"
  local CT_DNS="${CT_DNS:-1.1.1.1}"
  local ROOTPW
  local TEMPLATE="${TEMPLATE:-}"
  local TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-}"
  local ROOTFS_STORAGE
  local NET0

  if [[ "${UNATTENDED:-0}" != "1" ]]; then
    read -r -p "  Container ID [${CTID}]: " _v; CTID="${_v:-$CTID}"
    read -r -p "  Hostname [${HN}]: " _v; HN="${_v:-$HN}"
    read -r -p "  CPU cores [${CORES}]: " _v; CORES="${_v:-$CORES}"
    read -r -p "  RAM in MB [${RAM}]: " _v; RAM="${_v:-$RAM}"
    read -r -p "  Disk in GB [${DISK}]: " _v; DISK="${_v:-$DISK}"
    read -r -p "  Bridge [${BRIDGE}]: " _v; BRIDGE="${_v:-$BRIDGE}"
    read -r -p "  Static IP/CIDR (blank = DHCP): " _v; CT_IP="${_v:-$CT_IP}"
    if [[ -n "$CT_IP" ]]; then
      read -r -p "  Gateway: " _v; CT_GW="${_v:-$CT_GW}"
      read -r -p "  DNS [${CT_DNS}]: " _v; CT_DNS="${_v:-$CT_DNS}"
      [[ -n "$CT_GW" ]] || die "A gateway is required for a static IP."
    fi
    printf "\n"
  fi

  [[ "$CTID" =~ ^[0-9]+$ ]] || die "Container ID must be numeric."
  [[ "$CORES" =~ ^[0-9]+$ && "$RAM" =~ ^[0-9]+$ && "$DISK" =~ ^[0-9]+$ ]] || die "Cores/RAM/disk must be numbers."
  if pct status "$CTID" >/dev/null 2>&1; then
    die "CT ${CTID} already exists. Pick another ID or remove it first."
  fi

  msg_info "Finding a Debian 13 template"
  select_template
  ROOTFS_STORAGE="${ROOTFS_STORAGE:-$(pvesm status --content rootdir 2>/dev/null | awk 'NR>1 {print $1; exit}' || true)}"
  ROOTFS_STORAGE="${ROOTFS_STORAGE:-local-lvm}"

  local have
  have="$(pveam list "$TEMPLATE_STORAGE" 2>/dev/null | grep -F "$TEMPLATE" || true)"
  if [[ -z "$have" ]]; then
    msg_info "Downloading ${TEMPLATE} to ${TEMPLATE_STORAGE}"
    pveam download "$TEMPLATE_STORAGE" "$TEMPLATE" || die "Template download failed."
  fi

  NET0="name=eth0,bridge=${BRIDGE}"
  if [[ -n "$CT_IP" ]]; then
    NET0="${NET0},ip=${CT_IP},gw=${CT_GW},dns=${CT_DNS}"
  else
    NET0="${NET0},ip=dhcp"
  fi

  ROOTPW="$(gen_password 20)"
  msg_info "Creating LXC ${CTID} (${CORES} cores, ${RAM} MB RAM, ${DISK} GB disk)"
  pct create "$CTID" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}" \
    --hostname "$HN" \
    --cores "$CORES" \
    --memory "$RAM" \
    --swap 2048 \
    --rootfs "${ROOTFS_STORAGE}:${DISK}" \
    --net0 "$NET0" \
    --unprivileged 1 \
    --features nesting=1 \
    --onboot 1 \
    --ostype debian \
    --password "$ROOTPW" \
    --description "Stationeers dedicated server, SSUI and Control Deck" \
    >/dev/null || die "Failed to create the container."

  pct set "$CTID" --tags "stationeers,game-server,community-scripts" >/dev/null 2>&1 || true

  msg_info "Starting container"
  pct start "$CTID" || die "Failed to start the container."

  msg_info "Waiting for the container to boot"
  local i
  for ((i = 0; i < 60; i++)); do
    pct exec "$CTID" -- true >/dev/null 2>&1 && break
    sleep 2
  done
  pct exec "$CTID" -- true >/dev/null 2>&1 || die "Container did not become reachable."

  pct exec "$CTID" -- bash -c 'for i in $(seq 1 30); do getent hosts deb.debian.org >/dev/null 2>&1 && exit 0; sleep 2; done; exit 1' \
    || msg_warn "DNS inside the container looks slow; apt may still work."

  msg_info "Copying the installer into the container"
  pct push "$CTID" "$SELF_PATH" /root/stationeers-install.sh --perms 755 \
    || die "Could not copy the installer into the container."

  msg_info "Running the installer inside CT ${CTID} (this can take a few minutes)"
  pct exec "$CTID" -- bash /root/stationeers-install.sh --inside \
    || die "Installation inside the container failed. Inspect it with: pct enter ${CTID}"

  local CTIP
  CTIP="$(pct exec "$CTID" -- hostname -I 2>/dev/null | awk '{print $1}')"
  printf "\n"
  printf "  ${GN}Container ready${CL}\n\n"
  printf "  ${YW}CT${CL}           %s (%s)\n" "$CTID" "$HN"
  printf "  ${YW}Control Deck${CL} https://%s:8080\n" "${CTIP:-<container-ip>}"
  printf "  ${YW}SSUI${CL}         https://%s:8443\n" "${CTIP:-<container-ip>}"
  printf "  ${YW}Game${CL}         %s:27016/udp\n" "${CTIP:-<container-ip>}"
  printf "  ${YW}Root password${CL} %s\n" "$ROOTPW"
  printf "  ${YW}Enter${CL}        pct enter %s\n\n" "$CTID"
  printf "  ${BL}Credentials${CL}  pct exec %s -- cat /root/stationeers-credentials.txt\n\n" "$CTID"
  printf "  ${YW}Next${CL}         allow 27016/udp, 8443/tcp and 8080/tcp through your firewall,\n"
  printf "                 then open the Control Deck from another machine.\n\n"
}

# ----- entrypoint ---------------------------------------------------------
ensure_self_file() {
  local candidate base
  candidate="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"
  base="$(basename "$candidate")"
  case "$base" in
    bash|sh|dash|-|-bash) candidate="" ;;
  esac
  if [[ -z "$candidate" || ! -f "$candidate" || ! -s "$candidate" ]]; then
    SELF_PATH="/root/stationeers-install.sh"
    msg_info "Saving the installer to ${SELF_PATH}"
    curl -fsSL --retry 3 -o "$SELF_PATH" "$REPO_RAW" \
      || die "Could not download the installer from ${REPO_RAW}."
    chmod 755 "$SELF_PATH"
  else
    SELF_PATH="$candidate"
  fi
}

usage() {
  cat <<'EOF'
Stationeers Dedicated Server installer (Proxmox VE / Debian 13)

Install straight from GitHub (Proxmox VE host):
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/RoseOO/stationprox/main/stationeers.sh)"

Usage on a Proxmox VE host:
  bash stationeers.sh                 Interactive: create a Debian 13 LXC and install
  UNATTENDED=1 bash stationeers.sh    Use defaults (DHCP, 8 cores, 16 GB, 50 GB)

Usage inside a Debian 13 container or VM:
  bash stationeers.sh --inside        Install or update in place
  bash stationeers.sh --update        Update SSUI + panel (restarts SSUI)
  bash stationeers.sh --update-panel  Update only the Control Deck + console autologin
  bash stationeers.sh --reset-panel-password
  bash stationeers.sh --help

Environment overrides for the Proxmox flow:
  CTID, HN, CORES, RAM, DISK, BRIDGE, CT_IP, CT_GW, CT_DNS, UNATTENDED

Ports: 27016/udp game, 8443/tcp SSUI, 8080/tcp Control Deck.
Credentials: /root/stationeers-credentials.txt (run: stationeers-creds)
EOF
}

main() {
  local mode="auto"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --inside) mode="inside" ;;
      --update) mode="update" ;;
      --update-panel) mode="update-panel" ;;
      --reset-panel-password) mode="reset-password" ;;
      --unattended) UNATTENDED=1 ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unknown argument: $1 (try --help)" ;;
    esac
    shift
  done

  ensure_self_file

  case "$mode" in
    inside) install_inside ;;
    update) update_inside ;;
    update-panel) update_panel_only ;;
    reset-password) reset_panel_password ;;
    auto)
      if is_pve_host; then
        pve_flow
      else
        install_inside
      fi
      ;;
  esac
}

main "$@"
