#!/usr/bin/env bash
# watch-plugin-install.sh — watch a ServiceNow plugin activation in real time.
#
# Why this exists: the three sources of "is it installing?" disagree.
#   * the PDI console badge ("Activating Plugin…") is stale by minutes, and keeps
#     showing "Activating…" even AFTER a successful install;
#   * sys_progress_worker (PluginManagerWorker) shows live file counts but the row
#     is DELETED when the job ends, and it never says WHICH plugin it is doing;
#   * sys_plugin_log is the durable record (which plugin, and the outcome).
# This script prints the last two and stops when the outcome is known.
#
# Read-only: two GETs per interval against the REST table API. No sudo, no writes.
#
# Usage:
#   SN_HOST=dev296154.service-now.com SN_USER=admin ./watch-plugin-install.sh com.snc.discovery
#   SN_HOST=... SN_USER=admin SN_PASS='...' ./watch-plugin-install.sh com.snc.discovery --interval 30
#
# Exit codes: 0 = installed, 1 = failed, 2 = usage/auth problem, 3 = timed out.
set -uo pipefail   # not -e: a failed poll should not abort the watch

[[ -n "${BASH_SOURCE[0]:-}" && "${BASH_SOURCE[0]}" != "$0" ]] && {
  echo "WARNING: this looks sourced/pasted. Run it as a file: bash ./watch-plugin-install.sh <plugin-id>" >&2
}

PLUGIN="${1:-}"
[[ "$PLUGIN" == "-h" || "$PLUGIN" == "--help" || -z "$PLUGIN" ]] && {
  cat <<'EOF'
Usage: SN_HOST=... SN_USER=... [SN_PASS=...] ./watch-plugin-install.sh <plugin-id> [options]

  --interval N   seconds between polls (default 20)
  --timeout N    give up after N seconds (default 3600)

Example: ./watch-plugin-install.sh com.snc.discovery
EOF
  exit 2
}
shift || true

INTERVAL=20
TIMEOUT=3600
while [[ $# -gt 0 ]]; do
  case "$1" in
    --interval) INTERVAL="${2:?}"; shift 2 ;;
    --timeout)  TIMEOUT="${2:?}";  shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

SN_HOST="${SN_HOST:-}"
SN_USER="${SN_USER:-}"
SN_PASS="${SN_PASS:-}"
[[ -z "$SN_HOST" ]] && read -rp "Instance host (e.g. dev296154.service-now.com): " SN_HOST
[[ -z "$SN_USER" ]] && read -rp "User (needs admin): " SN_USER
if [[ -z "$SN_PASS" ]]; then read -rsp "Password for $SN_USER: " SN_PASS; echo; fi
[[ -z "$SN_HOST" || -z "$SN_USER" || -z "$SN_PASS" ]] && { echo "ERROR: SN_HOST/SN_USER/SN_PASS required" >&2; exit 2; }

BASE="https://${SN_HOST%/}"
command -v curl >/dev/null || { echo "ERROR: curl not found" >&2; exit 2; }

get() { curl -s -u "$SN_USER:$SN_PASS" -H 'Accept: application/json' "$1"; }

echo "Watching plugin: $PLUGIN on $BASE"
echo "(Ctrl-C to stop. The console badge lies; this does not.)"
echo

start=$(date +%s)
while :; do
  now=$(date +%s)
  if (( now - start > TIMEOUT )); then
    echo "TIMEOUT after ${TIMEOUT}s — no terminal outcome seen. Check sys_plugin_log manually."
    exit 3
  fi

  worker=$(get "$BASE/api/now/table/sys_progress_worker?sysparm_query=state=running&sysparm_fields=name,message,sys_created_on" \
    | grep -o '"message":"[^"]*"' | head -1 | cut -d'"' -f4)
  log=$(get "$BASE/api/now/table/sys_plugin_log?sysparm_query=plugin=$PLUGIN%5EORDERBYDESCsys_created_on&sysparm_limit=1&sysparm_fields=log,sys_created_on")
  logline=$(printf '%s' "$log" | grep -o '"log":"[^"]*"' | head -1 | cut -d'"' -f4)
  logtime=$(printf '%s' "$log" | grep -o '"sys_created_on":"[^"]*"' | head -1 | cut -d'"' -f4)

  printf '%s | worker: %-42s | log: %s %s\n' \
    "$(date -u +%H:%M:%S)" "${worker:-(none)}" "${logtime:-—}" "${logline:-(no entries yet — likely still queued store-side)}"

  case "$logline" in
    *"successfuly"*) echo; echo "RESULT: plugin $PLUGIN installed successfully."; exit 0 ;;
    *"failed"*)      echo; echo "RESULT: install FAILED — read the log lines just above the failure."; exit 1 ;;
  esac

  sleep "$INTERVAL"
done
