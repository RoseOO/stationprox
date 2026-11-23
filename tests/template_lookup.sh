#!/usr/bin/env bash
set -Eeuo pipefail
# Load installer functions without running main()
source <(sed '$d' /mnt/c/Users/Rose/src/stationprox/src/install.sh)

msg_info() { printf "INFO %s\n" "$*"; }
msg_ok()   { printf "OK %s\n" "$*"; }
msg_warn() { printf "WARN %s\n" "$*"; }
msg_error(){ printf "ERROR %s\n" "$*" >&2; }
die() { msg_error "$*"; exit 1; }

TEMPLATE=""
TEMPLATE_STORAGE=""
TEMPLATE_ARCH="amd64"
mode="local"

pvesm() { printf "Name Type Status Total Used Available %%\nlocal dir active 1 1 1 1\n"; }
pveam() {
  if [[ "$1" == "list" ]]; then
    if [[ "$mode" == "both" ]]; then
      printf "local:vztmpl/debian-13-standard_13.6-1_arm64.tar.zst 500.00MB\n"
      printf "local:vztmpl/debian-13-standard_13.6-1_amd64.tar.zst 500.00MB\n"
    elif [[ "$mode" == "local" ]]; then
      printf "local:vztmpl/debian-13-standard_13.6-1_amd64.tar.zst 500.00MB\n"
    elif [[ "$mode" == "armonly" ]]; then
      printf "local:vztmpl/debian-13-standard_13.6-1_arm64.tar.zst 500.00MB\n"
    elif [[ "$mode" == "old" ]]; then
      printf "local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst 500.00MB\n"
    fi
    return 0
  elif [[ "$1" == "update" ]]; then
    return 1
  elif [[ "$1" == "available" ]]; then
    return 2
  fi
  return 0
}

echo "--- gen_password ---"
pw="$(gen_password 20)"
echo "password length=${#pw} value=$pw"
[[ ${#pw} -eq 20 ]]

echo "--- case 1: downloaded amd64 template, broken index ---"
select_template
echo "template=$TEMPLATE storage=$TEMPLATE_STORAGE"
[[ "$TEMPLATE" == "debian-13-standard_13.6-1_amd64.tar.zst" ]]
[[ "$TEMPLATE_STORAGE" == "local" ]]

echo "--- case 2: arm64 listed first but amd64 also present ---"
TEMPLATE=""; TEMPLATE_STORAGE=""; mode="both"
select_template
[[ "$TEMPLATE" == "debian-13-standard_13.6-1_amd64.tar.zst" ]]

echo "--- case 3: only arm64, broken index (must refuse) ---"
TEMPLATE=""; TEMPLATE_STORAGE=""; mode="armonly"
trap - ERR
set +e
( select_template ) 2>/tmp/template-test.err
rc=$?
set -e
echo "rc=$rc"
grep -q "arm64" /tmp/template-test.err || true
[[ $rc -ne 0 ]]

echo "--- case 4: no local template, broken index (must show an error) ---"
mode="old"
set +e
( select_template ) 2>/tmp/template-test2.err
rc=$?
set -e
echo "rc=$rc"
grep -q "pveam available failed" /tmp/template-test2.err
[[ $rc -ne 0 ]]

echo "TEST PASSED"
