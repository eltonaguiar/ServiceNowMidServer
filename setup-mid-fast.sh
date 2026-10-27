#!/usr/bin/env bash
# setup-mid-fast.sh — sudo-free, idempotent, FAST ARM64 MID Server setup.
#
# Works on a FRESH instance (downloads the ~478MB payload once) OR on a re-run /
# machine that already has the agent in the mid_data volume (skips the download ->
# starts in seconds). No host `sudo` needed for users in the `docker` group.
#
# Handles the classic "Unable to load keystore" trap by clearing a stale keystore
# whenever config.xml is regenerated.
#
# Usage:
#   export SN_HOST="acme.service-now.com"
#   export MID_USER="mid.server"
#   read -rsp "MID password: " MID_PASS; echo; export MID_PASS
#   export MID_NAME="gx10-mid"          # optional
#   ./setup-mid-fast.sh
#
# Or just run ./quickstart.sh and answer the prompts.
#
# HOW TO RUN:   bash ./setup-mid-fast.sh     <-- run it as a FILE
# Do NOT paste this file's contents into an interactive shell (the checks below
# would exit your shell). Use ./quickstart.sh for a guided, prompt-driven run.
if [ "${BASH_SOURCE[0]:-}" != "$0" ]; then
  printf '[x] Do not paste or source this script. Run it as a file:  bash %s\n' "${BASH_SOURCE[0]:-$0}" >&2
  printf '    Easiest: ./quickstart.sh\n' >&2
  return 1 2>/dev/null || exit 1
fi

set -euo pipefail

# Friendly requirement checks (clear guidance instead of an abrupt set -e exit).
_missing=0
[ -n "${SN_HOST:-}" ] || { printf '[x] SN_HOST is not set.   export SN_HOST=acme.service-now.com\n' >&2; _missing=1; }
[ -n "${MID_USER:-}" ] || { printf '[x] MID_USER is not set.   export MID_USER=mid.server\n' >&2; _missing=1; }
[ -n "${MID_PASS:-}" ] || { printf '[x] MID_PASS is not set.   read -rsp "pw: " MID_PASS; export MID_PASS\n' >&2; _missing=1; }
if [ "$_missing" -eq 1 ]; then
  printf '[!] Easiest: run  ./quickstart.sh  — it prompts for host, user, password, name.\n' >&2
  exit 1
fi

MID_NAME="${MID_NAME:-$(hostname)-mid}"
MID_BUILD="${MID_BUILD:-australia-02-11-2026__patch3-05-25-2026_06-12-2026_1106}"
MID_DATE="${MID_DATE:-2026/06/12}"
MID_XMX="${MID_XMX:-1024m}"

BASE_IMG="moers/mid-server:latest"
JDK_URL="https://corretto.aws/downloads/latest/amazon-corretto-17-aarch64-linux-jdk.tar.gz"
CORE_URL="https://install.service-now.com/glide/distribution/builds/package/app-signed/mid-core/${MID_DATE}/mid-core.${MID_BUILD}.universal.universal.zip"
AGENT_VOL="mid_data"
JDK_VOL="mid_jdk17"
CONTAINER="sn-mid"
MID_UID=999
MID_GID=999
OPENS='--add-opens=java.base/java.nio=ALL-UNNAMED --add-opens=java.base/sun.nio.ch=ALL-UNNAMED --add-opens=java.base/java.lang=ALL-UNNAMED --add-opens=java.base/java.lang.invoke=ALL-UNNAMED --add-opens=java.base/java.util=ALL-UNNAMED --add-opens=java.base/java.util.concurrent=ALL-UNNAMED --add-opens=java.base/java.util.concurrent.atomic=ALL-UNNAMED --add-opens=java.base/java.text=ALL-UNNAMED --add-opens=java.base/java.io=ALL-UNNAMED --add-opens=java.base/java.net=ALL-UNNAMED --add-opens=java.base/java.security=ALL-UNNAMED --add-opens=java.base/javax.crypto=ALL-UNNAMED --add-opens=java.base/sun.security.util=ALL-UNNAMED --add-opens=java.base/java.math=ALL-UNNAMED'

log(){ printf '[+] %s\n' "$*"; }
warn(){ printf '[!] %s\n' "$*"; }
die(){ printf '[x] %s\n' "$*" >&2; exit 1; }
vol_sh(){ docker run --rm -v "$AGENT_VOL":/v --entrypoint /bin/bash "$BASE_IMG" -c "$1"; }
cleanup(){ rm -rf /tmp/mid-core.zip /tmp/mid_au 2>/dev/null || true; }
trap cleanup EXIT

# ---------------------------------------------------------------- preflight --
log "Preflight"
case "$(uname -m)" in
  arm64|aarch64) ;;
  *) die "This script targets arm64/aarch64 (detected: $(uname -m))." ;;
esac
for c in docker wget unzip; do command -v "$c" >/dev/null 2>&1 || die "$c not found. Install it first."; done
docker info >/dev/null 2>&1 || die "docker daemon not reachable — add your user to the 'docker' group or run with privileges."

log "Pulling base image + ensuring volumes"
docker pull --platform linux/arm64 "$BASE_IMG" >/dev/null
docker volume create "$AGENT_VOL" >/dev/null
docker volume create "$JDK_VOL"   >/dev/null

# --------------------------------------------------------------- JDK 17 ------
if docker run --rm -v "$JDK_VOL":/opt/jdk17 --entrypoint /bin/bash "$BASE_IMG" \
     -c '/opt/jdk17/bin/java -version 2>&1 | grep -qE "version \"(17|21)\."' 2>/dev/null; then
  log "ARM64 JDK 17+ already present — skipping"
else
  log "Installing native ARM64 JDK 17 (Corretto)"
  docker run --rm --platform linux/arm64 --user root -v "$JDK_VOL":/opt/jdk17 --entrypoint /bin/bash "$BASE_IMG" \
    -c "wget -q '$JDK_URL' -O /tmp/jdk.tgz && mkdir -p /opt/jdk17 && tar -xzf /tmp/jdk.tgz -C /opt/jdk17 --strip-components=1 && rm -f /tmp/jdk.tgz && chown -R ${MID_UID}:${MID_GID} /opt/jdk17 && /opt/jdk17/bin/java -version" \
    || die "JDK install failed"
fi

# ------------------------------------------------- agent payload (fast path) --
LIBCOUNT="$(docker run --rm -v "$AGENT_VOL":/v --entrypoint /bin/bash "$BASE_IMG" -c 'ls /v/lib 2>/dev/null | wc -l' 2>/dev/null || echo 0)"
LIBCOUNT="$(printf '%s' "${LIBCOUNT:-0}" | tr -dc '0-9')"; LIBCOUNT="${LIBCOUNT:-0}"
if [ "$LIBCOUNT" -ge 50 ]; then
  log "Agent already installed in '$AGENT_VOL' ($LIBCOUNT jars) — SKIPPING 478MB download (fast path)"
else
  # Show size up front + a forced progress bar so the big (~456 MB) payload
  # isn't a silent freeze. --show-progress works even when output isn't a TTY.
  SIZE_BYTES="$(wget --spider --server-response "$CORE_URL" 2>&1 | awk '/Content-Length:/{v=$2} END{print v}' || true)"
  case "${SIZE_BYTES:-}" in ''|*[!0-9]*) SIZE_BYTES=0 ;; esac
  if [ "$SIZE_BYTES" -gt 0 ]; then
    log "Fresh install: downloading MID core payload ($MID_BUILD) ~$((SIZE_BYTES/1048576)) MB — one-time, progress below"
  else
    log "Fresh install: downloading MID core payload ($MID_BUILD) ~456 MB — one-time, progress below"
  fi
  wget --show-progress --progress=bar:force:noscroll --tries=3 --timeout=30 \
    -O /tmp/mid-core.zip "$CORE_URL" || die "Download failed — check MID_BUILD/MID_DATE and network to install.service-now.com"
  log "Downloaded $(du -h /tmp/mid-core.zip 2>/dev/null | cut -f1) -> /tmp/mid-core.zip"
  rm -rf /tmp/mid_au && mkdir -p /tmp/mid_au
  unzip -q /tmp/mid-core.zip -d /tmp/mid_au || die "unzip failed"
  [ -d /tmp/mid_au/agent ] || die "Unexpected zip layout — no agent/ dir"
  log "Overlaying agent into volume (sudo-free, via docker)"
  docker run --rm -v "$AGENT_VOL":/dest -v /tmp/mid_au/agent:/src:ro --entrypoint /bin/bash "$BASE_IMG" \
    -c "mkdir -p /dest && cp -a /src/. /dest/" || die "Overlay failed"
fi

# --------------------------------------------------------------- config.xml --
log "Writing config.xml (password kept in-container, XML-encoded)"
docker run --rm --platform linux/arm64 --user root -v "$AGENT_VOL":/opt/agent \
  -e SN_HOST_NAME="$SN_HOST" -e USER_NAME="$MID_USER" -e PASSWORD="$MID_PASS" -e MIDNAME="$MID_NAME" \
  --entrypoint /bin/bash "$BASE_IMG" \
  -c 'cd /opt/agent; ENC_PW=$(printf %s "$PASSWORD" | sed "s/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/\"/\&quot;/g"); SED_PW=$(printf %s "$ENC_PW" | sed "s/[\\\\&|]/\\\\&/g"); cp /opt/config.xml /opt/agent/config.xml; sed -i "s|https://YOUR_INSTANCE.service-now.com|https://${SN_HOST_NAME}|g" config.xml; sed -i "s|YOUR_INSTANCE_USER_NAME_HERE|${USER_NAME}|g" config.xml; sed -i "s|YOUR_INSTANCE_PASSWORD_HERE|${SED_PW}|g" config.xml; sed -i "s|YOUR_MIDSERVER_NAME_GOES_HERE|${MIDNAME}|g" config.xml; chown 999:999 config.xml'

# Freshly-regenerated config.xml => any pre-existing keystore won't match. Clear it
# so the MID regenerates one consistent with the new config (fixes "Unable to load keystore").
log "Clearing stale keystore (prevents 'Unable to load keystore')"
vol_sh 'rm -f /v/security/agent_keystore /v/security_backup/agent_keystore.* 2>/dev/null; true'

log "Fixing ownership (uid ${MID_UID})"
vol_sh "chown -R ${MID_UID}:${MID_GID} /v"

# ------------------------------------------------------------------ launch --
log "Launching container $CONTAINER"
docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
docker run -d --name "$CONTAINER" \
  --platform linux/arm64 --restart unless-stopped --user root \
  -v "$AGENT_VOL":/opt/agent -v "$JDK_VOL":/opt/jdk17 \
  --entrypoint /bin/bash "$BASE_IMG" \
  -c "cd /opt/agent; rm -f /opt/agent/work/mid.pid; OPENS='$OPENS'; su mid -s /bin/bash -c \"cd /opt/agent && nohup /opt/jdk17/bin/java -Xmx${MID_XMX} -Djava.security.manager=allow \$OPENS -classpath 'lib/*:extlib/*' com.service_now.mid.Main start >/opt/agent/logs/console.log 2>&1 &\"; exec tail -F /opt/agent/logs/agent0.log.0 /opt/agent/logs/console.log" >/dev/null

# ------------------------------------------------------------------- poll ---
log "Waiting for 'Successfully connected' (up to 180s)..."
CONNECTED=0
for _ in $(seq 1 90); do
  sleep 2
  if ! docker ps -q --filter "name=^${CONTAINER}$" | grep -q .; then
    warn "Container exited. Last logs:"; docker logs --tail 40 "$CONTAINER" 2>&1 || true; die "container not running"
  fi
  if docker logs --tail 400 "$CONTAINER" 2>&1 | grep -q "Successfully connected to instance"; then
    CONNECTED=1; break
  fi
done

echo
if [ "$CONNECTED" = "1" ]; then
  log "MID CONNECTED to $SN_HOST  (name: $MID_NAME)"
  echo "    Next: ServiceNow -> MID Server -> Servers -> $MID_NAME (Status: Up; Validated: Yes shortly)"
else
  warn "Not confirmed within 180s. Inspect: docker logs -f $CONTAINER"
fi
