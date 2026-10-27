#!/usr/bin/env bash
# quickstart.sh — dead-simple ARM64 MID Server setup.
# Prompts for the 4 settings (password hidden, never stored), then runs the setup.
# Prefers setup-mid-fast.sh (sudo-free, idempotent) if present, else setup-mid-arm64.sh.
#
# HOW TO RUN:  ./quickstart.sh     <-- run it as a FILE, do NOT paste into a shell.
if [ "${BASH_SOURCE[0]:-}" != "$0" ]; then
  printf '[x] Do not paste or source this script. Run it as a file:  bash %s\n' "${BASH_SOURCE[0]:-$0}" >&2
  return 1 2>/dev/null || exit 1
fi
set -euo pipefail

echo "ServiceNow MID Server (ARM64) — quickstart"
echo "Password is read hidden and only exists in this shell's environment (never written to disk)."
echo

read -rp  "ServiceNow host (e.g. acme.service-now.com): " SN_HOST
read -rp  "MID user [mid.server]: " _u;   MID_USER="${_u:-mid.server}"
read -rsp "MID password: " MID_PASS; echo
read -rp  "MID name [$(hostname)-mid]: " _n; MID_NAME="${_n:-$(hostname)-mid}"

# normalize host: strip scheme + trailing path
SN_HOST="${SN_HOST#https://}"; SN_HOST="${SN_HOST#http://}"; SN_HOST="${SN_HOST%%/*}"
export SN_HOST MID_USER MID_PASS MID_NAME

echo "[+] host=$SN_HOST user=$MID_USER name=$MID_NAME pass_chars=${#MID_PASS}"
echo

if [ -f ./setup-mid-fast.sh ]; then
  exec bash ./setup-mid-fast.sh
elif [ -f ./setup-mid-arm64.sh ]; then
  exec bash ./setup-mid-arm64.sh
else
  echo "[x] setup script not found in $(pwd)" >&2; exit 1
fi
