#!/usr/bin/env bash
# setup-mid-arm64.sh
# Run a ServiceNow MID Server (Management, Instrumentation, and Discovery server)
# on ARM64 Linux (NVIDIA GX10 / GB10 Grace Blackwell, AWS Graviton, Raspberry Pi,
# Apple Silicon) even though ServiceNow publishes NO ARM64 package.
#
# MID Server is pure Java. We skip the x86-only Tanuki wrapper and the x86
# bundled JRE, install a native ARM64 JDK 17, overlay the official Australia MID
# core payload (arch-independent jars), build a valid config.xml, and launch
# com.service_now.mid.Main directly with java + required JDK17 flags.
#
# Tested on: NVIDIA GX10 (aarch64, Ubuntu 24.04.5 LTS) -> Australia patch3 instance.
#
# HOW TO USE — run these in your terminal first (edit the values!):
#
#   export SN_HOST="YOUR_INSTANCE.service-now.com"   # your instance address
#   export MID_USER="mid.server"                     # MID username
#   export MID_PASS='***PASSWORDHERE***'             # MID password (keep the quotes)
#   export MID_NAME="gx10-mid"                       # name for this MID (you pick)
#
#   # Optional (only for non-Australia releases):
#   # export MID_BUILD="australia-02-11-2026__patch3-05-25-2026_06-12-2026_1106"
#   # export MID_DATE="2026/06/12"
#   # export MID_XMX="1024m"          # Java heap size
#
#   ./setup-mid-arm64.sh
#
# Re-running is safe: an existing config.xml (your MID registration) is preserved.
set -euo pipefail

# ------------------------------------------------------------------ settings --
: "${SN_HOST:?Set SN_HOST first: export SN_HOST=\"YOUR_INSTANCE.service-now.com\"}"
: "${MID_USER:?Set MID_USER first: export MID_USER=\"mid.server\"}"
: "${MID_PASS:?Set MID_PASS first: export MID_PASS='***PASSWORDHERE***'}"
: "${MID_NAME:=${HOSTNAME}-mid}"
: "${MID_BUILD:=australia-02-11-2026__patch3-05-25-2026_06-12-2026_1106}"
: "${MID_DATE:=2026/06/12}"
: "${MID_XMX:=1024m}"

BASE_IMG="moers/mid-server:latest"
JDK_URL="https://corretto.aws/downloads/latest/amazon-corretto-17-aarch64-linux-jdk.tar.gz"
CORE_URL="https://install.service-now.com/glide/distribution/builds/package/app-signed/mid-core/${MID_DATE}/mid-core.${MID_BUILD}.universal.universal.zip"
AGENT_VOL="mid_data"
JDK_VOL="mid_jdk17"
CONTAINER="sn-mid"
# The MID runs as user "mid" inside the image -> uid/gid 999 (NOT 1000).
MID_UID=999
MID_GID=999

log()  { printf '[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*"; }
die()  { printf '[x] %s\n' "$*" >&2; exit 1; }
SUDO() { if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo "$@"; fi; }

# Clean temp artifacts on any exit (success or failure)
cleanup() { rm -rf /tmp/mid-core.zip /tmp/mid_au /tmp/config_backup.xml 2>/dev/null || true; }
trap cleanup EXIT

# --------------------------------------------------------------- preflight ----
log "Preflight checks"
ARCH=$(uname -m)
case "$ARCH" in
  arm64|aarch64) ;;
  *) die "This script targets arm64/aarch64 hosts only (detected: $ARCH)." ;;
esac
command -v docker >/dev/null 2>&1 || die "docker not found. Install Docker first."
command -v unzip  >/dev/null 2>&1 || die "unzip not found (apt install unzip)."
command -v wget   >/dev/null 2>&1 || die "wget not found (apt install wget)."
command -v rsync  >/dev/null 2>&1 || die "rsync not found (apt install rsync)."

log "Pulling base image (arm64) + creating volumes"
docker pull --platform linux/arm64 "$BASE_IMG"
docker volume create "$AGENT_VOL" >/dev/null
docker volume create "$JDK_VOL"   >/dev/null

# ----------------------------------------------------------- ARM64 JDK 17 -----
# Check the installed JDK is actually 17+ (not just present) — a stale Java 11
# volume would otherwise pass an existence check and fail at MID startup.
jdk_is_17() {
  docker run --rm -v "$JDK_VOL":/opt/jdk17 --entrypoint /bin/bash "$BASE_IMG" \
    -c '/opt/jdk17/bin/java -version 2>&1 | grep -qE "version \"17\.|version \"21\."' 2>/dev/null
}

if jdk_is_17; then
  log "ARM64 JDK 17+ already present in volume $JDK_VOL — skipping install"
else
  log "Installing native ARM64 JDK 17 (Corretto)"
  docker run --rm --platform linux/arm64 --user root \
    -v "$JDK_VOL":/opt/jdk17 --entrypoint /bin/bash "$BASE_IMG" \
    -c "wget -q '$JDK_URL' -O /tmp/jdk.tar.gz && mkdir -p /opt/jdk17 && tar -xzf /tmp/jdk.tar.gz -C /opt/jdk17 --strip-components=1 && rm -f /tmp/jdk.tar.gz && chown -R ${MID_UID}:${MID_GID} /opt/jdk17 && /opt/jdk17/bin/java -version"
  jdk_is_17 || die "JDK in volume $JDK_VOL is still not 17+. Remove the volume (docker volume rm $JDK_VOL) and retry."
fi

# ------------------------------------------------- download Australia payload --
# Show the size up front + a progress bar so the big (~456 MB) payload isn't a
# silent freeze. --show-progress forces the bar even when output isn't a TTY.
SIZE_BYTES="$(wget --spider --server-response "$CORE_URL" 2>&1 | awk '/Content-Length:/{v=$2} END{print v}' || true)"
case "${SIZE_BYTES:-}" in ''|*[!0-9]*) SIZE_BYTES=0 ;; esac
if [ "$SIZE_BYTES" -gt 0 ]; then
  log "Downloading MID core payload: ${MID_BUILD} (~$((SIZE_BYTES/1048576)) MB)"
else
  log "Downloading MID core payload: ${MID_BUILD} (~456 MB)"
fi
wget --show-progress --progress=bar:force:noscroll --tries=3 --timeout=30 \
  -O /tmp/mid-core.zip "$CORE_URL" \
  || die "Download failed. Check MID_BUILD / MID_DATE and network access to install.service-now.com."
log "Downloaded $(du -h /tmp/mid-core.zip 2>/dev/null | cut -f1) -> /tmp/mid-core.zip"

log "Unzipping with system unzip (bypasses the MID's internal size limit)"
rm -rf /tmp/mid_au && mkdir -p /tmp/mid_au
unzip -q /tmp/mid-core.zip -d /tmp/mid_au
[ -d /tmp/mid_au/agent ] || die "Unexpected zip layout — no agent/ dir found."

# Verify the payload is actually the release we expect (rel >= 29 = Australia+).
# Guards against a wrong MID_BUILD/MID_DATE that still unzips cleanly.
RELEASE_MAJOR=$(unzip -p /tmp/mid_au/agent/lib/mid-acc-commons.jar META-INF/MANIFEST.MF 2>/dev/null \
  | tr -d '\r' | awk -F': ' '/^Implementation-Version:/{split($2,a,"."); print a[1]; exit}')
if [ -z "$RELEASE_MAJOR" ]; then
  warn "Could not read Implementation-Version from jar — skipping release check."
elif [ "$RELEASE_MAJOR" -lt 29 ]; then
  die "Downloaded payload is release ${RELEASE_MAJOR} (< 29 = pre-Australia). Check MID_BUILD/MID_DATE."
else
  log "Verified payload release: ${RELEASE_MAJOR} (Australia or newer)"
fi

# ------------------------------------- stop container + preserve registration --
docker rm -f "$CONTAINER" 2>/dev/null || true
VOL_PATH=$(SUDO docker volume inspect "$AGENT_VOL" --format '{{.Mountpoint}}')
CFG_BACKUP=""
if SUDO test -f "$VOL_PATH/config.xml"; then
  CFG_BACKUP=$(mktemp)
  log "Backing up existing config.xml (preserves MID registration sys_id)"
  SUDO cp "$VOL_PATH/config.xml" "$CFG_BACKUP"
  warn "Existing registration kept — SN_HOST/MID_USER/MID_PASS changes are IGNORED"
  warn "until you delete $VOL_PATH/config.xml and re-run to regenerate it."
fi

log "Overlaying Australia agent onto volume (excluding config.xml + logs)"
SUDO rsync -a --exclude 'config.xml' --exclude 'logs/' /tmp/mid_au/agent/ "$VOL_PATH/" \
  || die "Overlay failed — volume may be partially updated. Re-run the script; config is preserved."

if [ -n "$CFG_BACKUP" ]; then
  log "Restoring registered config.xml"
  SUDO cp "$CFG_BACKUP" "$VOL_PATH/config.xml"
  rm -f "$CFG_BACKUP"
  CFG_BACKUP=""
fi

# ------------------------------------------------- build config.xml (fresh) ----
if ! SUDO test -f "$VOL_PATH/config.xml"; then
  log "No existing config.xml — generating from template (XML-encoding password)"
  SUDO docker run --rm --platform linux/arm64 --user root \
    -v "$AGENT_VOL":/opt/agent \
    -e SN_HOST_NAME="$SN_HOST" -e USER_NAME="$MID_USER" \
    -e PASSWORD="$MID_PASS" -e MIDNAME="$MID_NAME" \
    --entrypoint /bin/bash "$BASE_IMG" \
    -c 'cd /opt/agent; ENC_PW=$(printf %s "$PASSWORD" | sed "s/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/\"/\&quot;/g"); SED_PW=$(printf %s "$ENC_PW" | sed "s/[\\\\&|]/\\\\&/g"); cp /opt/config.xml /opt/agent/config.xml; sed -i "s|https://YOUR_INSTANCE.service-now.com|https://${SN_HOST_NAME}|g" config.xml; sed -i "s|YOUR_INSTANCE_USER_NAME_HERE|${USER_NAME}|g" config.xml; sed -i "s|YOUR_INSTANCE_PASSWORD_HERE|${SED_PW}|g" config.xml; sed -i "s|YOUR_MIDSERVER_NAME_GOES_HERE|${MIDNAME}|g" config.xml; chown 999:999 config.xml'
else
  log "Existing config.xml present — leaving untouched"
fi

# ------------------------------------------------------ ownership: uid 999 -----
log "Setting ownership to mid (uid ${MID_UID}) — NOT 1000"
SUDO chown -R "${MID_UID}:${MID_GID}" "$VOL_PATH"

# --------------------------------------------------------------- launch --------
log "Launching MID (direct java, wrapper bypassed, Australia build)"
docker run -d --name "$CONTAINER" \
  --platform linux/arm64 --restart unless-stopped --user root \
  -v "$AGENT_VOL":/opt/agent -v "$JDK_VOL":/opt/jdk17 \
  --entrypoint /bin/bash "$BASE_IMG" \
  -c "cd /opt/agent; rm -f /opt/agent/work/mid.pid; OPENS='--add-opens=java.base/java.nio=ALL-UNNAMED --add-opens=java.base/sun.nio.ch=ALL-UNNAMED --add-opens=java.base/java.lang=ALL-UNNAMED --add-opens=java.base/java.lang.invoke=ALL-UNNAMED --add-opens=java.base/java.util=ALL-UNNAMED --add-opens=java.base/java.util.concurrent=ALL-UNNAMED --add-opens=java.base/java.util.concurrent.atomic=ALL-UNNAMED --add-opens=java.base/java.text=ALL-UNNAMED --add-opens=java.base/java.io=ALL-UNNAMED --add-opens=java.base/java.net=ALL-UNNAMED --add-opens=java.base/java.security=ALL-UNNAMED --add-opens=java.base/javax.crypto=ALL-UNNAMED --add-opens=java.base/sun.security.util=ALL-UNNAMED --add-opens=java.base/java.math=ALL-UNNAMED'; su mid -s /bin/bash -c \"cd /opt/agent && nohup /opt/jdk17/bin/java -Xmx${MID_XMX} -Djava.security.manager=allow \$OPENS -classpath 'lib/*:extlib/*' com.service_now.mid.Main start >/opt/agent/logs/console.log 2>&1 &\"; exec tail -F /opt/agent/logs/agent0.log.0 /opt/agent/logs/console.log"

# ------------------------------------------- poll until connected (or timeout) --
log "Waiting for MID to connect (polling up to 120s)..."
CONNECTED=0
for _ in $(seq 1 60); do
  sleep 2
  if ! docker ps -q --filter "name=^${CONTAINER}$" | grep -q .; then
    warn "Container exited early. Last logs:"
    docker logs --tail 30 "$CONTAINER" 2>&1 || true
    die "MID container is not running."
  fi
  if docker logs --tail 200 "$CONTAINER" 2>&1 | grep -q "Successfully connected to instance"; then
    CONNECTED=1
    break
  fi
done

echo ""
if [ "$CONNECTED" = "1" ]; then
  log "MID is UP and connected. Follow logs: docker logs -f ${CONTAINER}"
  echo "    User ${MID_USER} has all necessary roles"
  echo "    Successfully connected to instance: ${SN_HOST}"
  echo "    MID buildstamp: ${MID_BUILD}"
else
  warn "Not confirmed within 120s — check progress yourself:"
  echo "    docker logs -f ${CONTAINER}"
fi
echo ""
echo "Now check ServiceNow: MID Server -> MID Servers -> ${MID_NAME}"
echo "  Status should show Up, Validated: Yes, Version: ${MID_BUILD%%_06*}"
echo ""
echo "Required JDK 17 flags (why this works on ARM64):"
echo "  -Djava.security.manager=allow       Australia calls System.setSecurityManager"
echo "  --add-opens=java.base/java.nio=...  Apache Ignite reflects into JDK internals"
echo ""
echo "If 401: check password, ensure mid_server role, turn OFF 'password needs reset'."
