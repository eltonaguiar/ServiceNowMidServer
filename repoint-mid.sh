#!/usr/bin/env bash
# repoint-mid.sh
# Move an ALREADY-WORKING ARM64 MID Server (the one setup-mid-arm64.sh built) onto a
# different ServiceNow instance — e.g. your instance got refreshed/replaced and the old
# one is gone. Typical run time: ~75 seconds. No re-download, no re-install, no sudo.
#
#   export SN_HOST="dev123456.service-now.com"   # NEW instance address
#   export MID_USER="mid.server"                 # MID user on the NEW instance
#   export MID_PASS='***PASSWORDHERE***'         # that user's password (keep the quotes)
#   export MID_NAME="gx10-mid"                   # optional; defaults to current name
#   ./repoint-mid.sh
#
# What it does, in order:
#   1. verifies the new credentials authenticate (fails in ~2s, before touching anything)
#   2. rewrites config.xml (url + user + XML-escaped password) and — only when the
#      instance actually changed — clears mid_sys_id / keypairs.mid_id so the MID
#      registers FRESH instead of trying to bind the dead instance's registration
#   3. wipes the stale keystore / registration artefacts from the old instance
#   4. recreates the container with the same direct-java launch as setup-mid-arm64.sh
#   5. polls until "Successfully connected to instance:" appears, then tells you where
#      to look in ServiceNow
set -euo pipefail

: "${SN_HOST:?Set SN_HOST first: export SN_HOST=\"YOUR_INSTANCE.service-now.com\"}"
: "${MID_USER:?Set MID_USER first: export MID_USER=\"mid.server\"}"
: "${MID_PASS:?Set MID_PASS first: export MID_PASS='***PASSWORDHERE***'}"
SN_HOST="${SN_HOST#https://}"; SN_HOST="${SN_HOST#http://}"; SN_HOST="${SN_HOST%/}"

BASE_IMG="${BASE_IMG:-moers/mid-server:latest}"
AGENT_VOL="${AGENT_VOL:-mid_data}"
JDK_VOL="${JDK_VOL:-mid_jdk17}"
CONTAINER="${CONTAINER:-sn-mid}"
MID_UID=999; MID_GID=999
PASS_TIMEOUT="${PASS_TIMEOUT:-180}"

log()  { printf '[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*"; }
die()  { printf '[x] %s\n' "$*" >&2; exit 1; }

TMPDIR_RUN=$(mktemp -d)
cleanup() { rm -rf "$TMPDIR_RUN"; }
trap cleanup EXIT

# --------------------------------------------------------------- preflight -----
command -v docker >/dev/null || die "docker not found."
command -v python3 >/dev/null || die "python3 not found (apt install python3)."
command -v curl >/dev/null || die "curl not found (apt install curl)."
docker volume inspect "$AGENT_VOL" >/dev/null 2>&1 \
  || die "volume $AGENT_VOL not found — run setup-mid-arm64.sh first (this script only re-points)."

# ---------------------------------------------------- 1. credentials up front --
log "Checking credentials for '${MID_USER}' on ${SN_HOST}"
HTTP=$(curl -s -o /dev/null -m 25 -w '%{http_code}' -u "${MID_USER}:${MID_PASS}" \
  "https://${SN_HOST}/api/now/table/sys_user?sysparm_limit=1") || die "Could not reach https://${SN_HOST}"
case "$HTTP" in
  200|403) log "Credentials accepted (HTTP $HTTP)" ;;
  401) die "HTTP 401 — wrong password, user missing, or 'password needs reset'.
      Create/verify the user in User Administration -> Users with the mid_server role." ;;
  *)   warn "Unexpected HTTP $HTTP from the credential check — continuing anyway." ;;
esac

# ------------------------------------------------------- 2. rewrite config.xml --
log "Reading config.xml out of volume $AGENT_VOL"
docker run --rm -v "${AGENT_VOL}:/opt/agent" --entrypoint /bin/bash "$BASE_IMG" \
  -c 'cat /opt/agent/config.xml' > "${TMPDIR_RUN}/config.xml"
test -s "${TMPDIR_RUN}/config.xml" || die "config.xml is empty/missing in $AGENT_VOL."

OLD_URL=$(python3 - "${TMPDIR_RUN}/config.xml" <<'PY'
import re,sys
t=open(sys.argv[1],encoding='utf-8').read()
m=re.search(r'<parameter name="url" value="([^"]*)"',t)
print(m.group(1) if m else "")
PY
)
CHANGED=1
case "$OLD_URL" in *"${SN_HOST}"*) CHANGED=0 ;; esac
log "Instance: ${OLD_URL:-<none>}  ->  https://${SN_HOST}/  ($([ "$CHANGED" = 1 ] && echo 're-point + fresh registration' || echo 'same instance, keep registration'))"

SN_HOST="$SN_HOST" MID_USER="$MID_USER" MID_PASS="$MID_PASS" MID_NAME="${MID_NAME:-}" \
CHANGED="$CHANGED" python3 - "${TMPDIR_RUN}/config.xml" "${TMPDIR_RUN}/config.new.xml" <<'PY'
import os, re, sys

src, dst = sys.argv[1], sys.argv[2]
host, user, pw = os.environ["SN_HOST"], os.environ["MID_USER"], os.environ["MID_PASS"]
name, changed = os.environ.get("MID_NAME", ""), os.environ["CHANGED"] == "1"

# XML-encode the password. Skipping this is what breaks passwords containing & < > "
esc = pw.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")

def set_param(text, name, value, required=True):
    """Replace ONLY the first match: 'name' also appears inside XML comment examples."""
    pat = re.compile(r'(<parameter name="%s"[^>]*?value=")[^"]*(")' % re.escape(name))
    new, n = pat.subn(lambda m: m.group(1) + value + m.group(2), text, count=1)
    if n == 0 and required:
        sys.exit("config.xml is missing the '%s' parameter" % name)
    return new

t = open(src, encoding="utf-8").read()
t = set_param(t, "url", "https://%s/" % host)
t = set_param(t, "mid.instance.username", user)
t = set_param(t, "mid.instance.password", esc)
if name:
    t = set_param(t, "name", name, required=False)
if changed:
    # fresh registration against the new instance
    t = set_param(t, "mid_sys_id", "", required=False)
    t = set_param(t, "keypairs.mid_id", "", required=False)

open(dst, "w", encoding="utf-8").write(t)

import xml.dom.minidom
xml.dom.minidom.parse(dst)  # hard fail on malformed XML rather than a broken MID later
print("[+] config.xml rewritten and XML-validated")
PY

# NOTE: the stdin redirect below is load-bearing — without it `cat >` writes an empty
# config.xml and the MID dies with "config.xml may be malformed, load operation returned null".
docker run --rm -i -v "${AGENT_VOL}:/opt/agent" --entrypoint /bin/bash "$BASE_IMG" \
  -c "cat > /opt/agent/config.xml && chown ${MID_UID}:${MID_GID} /opt/agent/config.xml && chmod 644 /opt/agent/config.xml" \
  < "${TMPDIR_RUN}/config.new.xml"

# read it back and prove the MID will actually get a usable file
WRITTEN=$(docker run --rm -v "${AGENT_VOL}:/opt/agent" --entrypoint /bin/bash "$BASE_IMG" \
  -c "grep -c . /opt/agent/config.xml; grep -o 'name=\"url\" value=\"[^\"]*\"' /opt/agent/config.xml" | tr '\n' ' ')
case "$WRITTEN" in *"${SN_HOST}"*) log "Verified config.xml in volume (${WRITTEN% })" ;; esac
case "$WRITTEN" in *"${SN_HOST}"*) ;; *) die "config.xml write failed — volume file does not contain ${SN_HOST}." ;; esac

# ----------------------------------- 3. drop stale state from the old instance --
if [ "$CHANGED" = 1 ]; then
  log "Clearing keystore / registration artefacts left by the old instance"
  docker run --rm -v "${AGENT_VOL}:/opt/agent" --entrypoint /bin/bash "$BASE_IMG" -c "
    cd /opt/agent
    rm -f security/agent_keystore work/remote.properties
    rm -rf work/cache work/upgrade_temp
    chown -R ${MID_UID}:${MID_GID} security work 2>/dev/null || true
    rm -f logs/agent0.log.0.lck logs/*.lck 2>/dev/null || true"
fi

# ------------------------------------------------------------- 4. (re)launch ----
OPENS="--add-opens=java.base/java.nio=ALL-UNNAMED --add-opens=java.base/sun.nio.ch=ALL-UNNAMED --add-opens=java.base/java.lang=ALL-UNNAMED --add-opens=java.base/java.lang.invoke=ALL-UNNAMED --add-opens=java.base/java.util=ALL-UNNAMED --add-opens=java.base/java.util.concurrent=ALL-UNNAMED --add-opens=java.base/java.util.concurrent.atomic=ALL-UNNAMED --add-opens=java.base/java.text=ALL-UNNAMED --add-opens=java.base/java.io=ALL-UNNAMED --add-opens=java.base/java.net=ALL-UNNAMED --add-opens=java.base/java.security=ALL-UNNAMED --add-opens=java.base/javax.crypto=ALL-UNNAMED --add-opens=java.base/sun.security.util=ALL-UNNAMED --add-opens=java.base/java.math=ALL-UNNAMED"

log "Recreating container $CONTAINER"
docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
docker run -d --name "$CONTAINER" \
  --platform linux/arm64 --restart unless-stopped --user root \
  -v "${AGENT_VOL}:/opt/agent" -v "${JDK_VOL}:/opt/jdk17" \
  --entrypoint /bin/bash "$BASE_IMG" \
  -c "cd /opt/agent; rm -f /opt/agent/work/mid.pid; OPENS=\"${OPENS}\"; su mid -s /bin/bash -c \"cd /opt/agent && nohup /opt/jdk17/bin/java -Xmx\${MID_XMX:-1024m} -Djava.security.manager=allow \$OPENS -classpath 'lib/*:extlib/*' com.service_now.mid.Main start >/opt/agent/logs/console.log 2>&1 &\"; exec tail -F /opt/agent/logs/agent0.log.0 /opt/agent/logs/console.log" \
  >/dev/null

# ------------------------------------------------------------- 5. verify --------
log "Waiting for the MID to connect (up to ${PASS_TIMEOUT}s)"
CONNECTED=0; GONE=0; WARNED=0
for _ in $(seq 1 $((PASS_TIMEOUT / 3))); do
  sleep 3
  if ! docker ps -q --filter "name=^${CONTAINER}$" | grep -q .; then
    GONE=$((GONE + 1))
    # Someone else may be reinstalling/recreating the MID (the setup script also does
    # `docker rm -f sn-mid`). Don't give up: keep looking for the container by name.
    if [ "$WARNED" = 0 ]; then
      warn "Container ${CONTAINER} is not running — waiting in case another process is recreating it"
      docker logs --tail 15 "$CONTAINER" 2>&1 || true
      WARNED=1
    fi
    continue
  fi
  if docker logs "$CONTAINER" 2>&1 | grep -q "Successfully connected to instance:"; then
    CONNECTED=1; break
  fi
done

echo
if [ "$CONNECTED" = 1 ]; then
  log "MID is UP and connected to ${SN_HOST}"
  docker logs "$CONTAINER" 2>&1 | grep -aE "all necessary roles|Successfully connected|Build tag|Installed packages are up-to-date" | tail -4
  echo
  echo "Check ServiceNow:  MID Server -> MID Servers  (name: ${MID_NAME:-as shown below}, Status: Up)"
  echo "First start registers a new record automatically; 'Validated: Yes' appears within ~1 minute."
else
  warn "Not confirmed within ${PASS_TIMEOUT}s — the MID may still be starting. Watch it with:"
  echo "    docker logs -f ${CONTAINER}"
fi
echo
echo "If you see 'Unable to load key store, MID server will not able to function' and then"
echo "'Creating new keystore file' / 'Updated public key, new certificate', that is normal on a"
echo "re-point: the MID regenerates its keypair for the new instance and continues. It is only a"
echo "problem if it repeats forever — see the README appendix."
