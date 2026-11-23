#!/usr/bin/env bash
set -Eeuo pipefail
source <(sed '$d' /mnt/c/Users/Rose/src/stationprox/stationeers.sh)
trap - ERR

msg_info() { printf "INFO %s\n" "$*"; }
msg_ok()   { printf "OK %s\n" "$*"; }
msg_warn() { printf "WARN %s\n" "$*"; }
msg_error(){ printf "ERROR %s\n" "$*" >&2; }

SSUI_USER="tester"
SSUI_HOME="/tmp/ssui-test-home"
SSUI_DIR="/tmp/ssui-test"
rm -rf "$SSUI_DIR"
mkdir -p "$SSUI_DIR/steamcmd" "$SSUI_DIR/SSUI/config"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" > /tmp/ssui-steamcmd-args\n' > "$SSUI_DIR/steamcmd/steamcmd.sh"
chmod +x "$SSUI_DIR/steamcmd/steamcmd.sh"
printf '{"gameBranch":"public"}\n' > "$SSUI_DIR/SSUI/config/config.json"
runuser() {
  local arg
  for arg in "$@"; do
    if [[ "$arg" == "--" ]]; then shift; break; fi
    shift
  done
  "$@"
}

echo "--- with validation ---"
update_game_server
mapfile -t args < /tmp/ssui-steamcmd-args
printf 'args: %s\n' "${args[*]}"
[[ " ${args[*]} " == *" +force_install_dir /tmp/ssui-test "* ]]
[[ " ${args[*]} " == *" +app_update 600760 "* ]]
[[ " ${args[*]} " == *" validate "* ]]
[[ " ${args[*]} " == *" +quit "* ]]

echo "--- without validation ---"
SKIP_VALIDATE=1 update_game_server
mapfile -t args < /tmp/ssui-steamcmd-args
printf 'args: %s\n' "${args[*]}"
[[ " ${args[*]} " != *" validate "* ]]

echo "UPDATE TEST PASSED"
