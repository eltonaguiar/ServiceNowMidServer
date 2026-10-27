#!/usr/bin/env bash
# check-discovery.sh — Is the ITOM Discovery plugin installed on an instance?
#
# Probes ServiceNow's REST table API with an authenticated user. A table that
# does not exist returns HTTP 400 "Invalid table <name>"; a table that exists
# but is ACL-restricted returns 403; a readable table returns 200.
#
# Usage:
#   SN_HOST=dev296154.service-now.com SN_USER=admin SN_PASS='...' ./check-discovery.sh
#   SN_HOST=... SN_USER=... ./check-discovery.sh          # prompts for password
#
# No sudo, no plugins, no writes. Read-only GETs.

set -uo pipefail   # deliberately NOT -e: we want every probe to print

[[ -n "${BASH_SOURCE[0]:-}" && "${BASH_SOURCE[0]}" != "$0" ]] && {
  echo "WARNING: this looks sourced/pasted. Run it as a file: bash ./check-discovery.sh" >&2
}

SN_HOST="${SN_HOST:-}"
SN_USER="${SN_USER:-}"
SN_PASS="${SN_PASS:-}"

if [[ -z "$SN_HOST" ]]; then
  read -rp "Instance host (e.g. dev296154.service-now.com): " SN_HOST
fi
if [[ -z "$SN_USER" ]]; then
  read -rp "User (needs read on discovery tables, e.g. admin): " SN_USER
fi
if [[ -z "$SN_PASS" ]]; then
  read -rsp "Password for $SN_USER: " SN_PASS; echo
fi

if [[ -z "$SN_HOST" || -z "$SN_USER" || -z "$SN_PASS" ]]; then
  echo "ERROR: SN_HOST, SN_USER and SN_PASS are all required." >&2
  exit 2
fi

BASE="https://${SN_HOST%/}"
command -v curl >/dev/null || { echo "ERROR: curl not found" >&2; exit 2; }

# Tables created BY the Discovery plugin (com.snc.discovery). If these are all
# "Invalid table", the plugin is not installed.
DISCOVERY_TABLES=(discovery_schedule discovery_scan discovery_range_set discovery_ip_address discovery_tcp_port)

# Tables that already exist on a base instance WITHOUT the plugin — proves the
# probe works, and reminds you not to treat them as evidence of Discovery.
BASE_TABLES=(discovery_credentials discovery_status discovery_range discovery_classy incident)

probe() {
  local t="$1" code msg
  code=$(curl -s -o /tmp/.snd_probe.$$ -w '%{http_code}' \
    -u "$SN_USER:$SN_PASS" -H 'Accept: application/json' \
    "${BASE}/api/now/table/${t}?sysparm_limit=1")
  msg=$(grep -o '"message":"[^"]*"' /tmp/.snd_probe.$$ 2>/dev/null | head -1 | cut -c12- | cut -c1-52)
  rm -f /tmp/.snd_probe.$$
  case "$code" in
    400) printf '  %-26s %s  NOT INSTALLED   %s\n' "$t" "$code" "$msg" ;;
    401|403) printf '  %-26s %s  exists (ACL)   %s\n' "$t" "$code" "$msg" ;;
    200) printf '  %-26s %s  exists (readable)\n' "$t" "$code" ;;
    *)   printf '  %-26s %s  unexpected     %s\n' "$t" "$code" "$msg" ;;
  esac
}

echo "Instance: $BASE"
echo "User:     $SN_USER"
echo
echo "Discovery-plugin tables:"

missing=0
for t in "${DISCOVERY_TABLES[@]}"; do
  probe "$t"
  code=$(curl -s -o /dev/null -w '%{http_code}' -u "$SN_USER:$SN_PASS" \
    -H 'Accept: application/json' "${BASE}/api/now/table/${t}?sysparm_limit=1")
  [[ "$code" == "400" ]] && missing=$((missing + 1))
done

echo
echo "Base-platform tables (exist even without Discovery — control group):"
for t in "${BASE_TABLES[@]}"; do probe "$t"; done

echo
if [[ "$missing" -eq "${#DISCOVERY_TABLES[@]}" ]]; then
  echo "VERDICT: Discovery is NOT installed on this instance."
  echo "         Install it as admin:"
  echo "         $BASE/now/app-manager/home/plugin/id/com.snc.discovery/details"
  echo "         (or System Definition -> Plugins -> Discovery -> Activate)"
elif [[ "$missing" -eq 0 ]]; then
  echo "VERDICT: Discovery appears INSTALLED. Open $BASE/discovery_schedule_list.do"
else
  echo "VERDICT: PARTIAL / inconclusive — some Discovery tables missing."
  echo "         Check System Definition -> Plugins for com.snc.discovery state,"
  echo "         or wait if an install is still running."
fi
