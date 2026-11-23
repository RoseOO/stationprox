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
@@PANEL_PY@@
PANEL_PY_EOF
  cat > "${PANEL_DIR}/panel.html" <<'PANEL_HTML_EOF'
@@PANEL_HTML@@
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
