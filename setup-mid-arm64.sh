#!/usr/bin/env bash
# setup-mid-arm64.sh
# Run a ServiceNow MID Server (current release, e.g. Australia) on ARM64 Linux
# (NVIDIA GX10 / GB10, AWS Graviton, Raspberry Pi, Apple Silicon) even though
# ServiceNow publishes NO ARM64 package.
#
# MID Server is pure Java. We skip the x86-only Tanuki wrapper and x86 bundled JRE,
# install a native ARM64 JDK 17, overlay the official Australia MID core payload
# (arch-independent jars), build a valid config.xml, and launch
# com.service_now.mid.Main directly with java + required JDK17 flags.
#
# Tested on: NVIDIA GX10 (aarch64, Ubuntu 24.04.5 LTS) -> Australia patch3 instance.
#
# Usage:
#   export SN_HOST="dev213089.service-now.com"
#   export MID_USER="mid.server"
#   export MID_PASS='***PASSWORDHERE***'
#   export MID_NAME="gx10-mid"
#   # Optional overrides for other releases:
#   # export MID_BUILD="australia-02-11-2026__patch3-05-25-2026_06-12-2026_1106"
#   # export MID_DATE="2026/06/12"
#   ./setup-mid-arm64.sh
set -euo pipefail

: "${SN_HOST:?Set SN_HOST (e.g. dev213089.service-now.com)}"
: "${MID_USER:?Set MID_USER (e.g. mid.server)}"
: "${MID_PASS:?Set MID_PASS (the MID server user password)}"
: "${MID_NAME:=${HOSTNAME}-mid}"
: "${MID_BUILD:=australia-02-11-2026__patch3-05-25-2026_06-12-2026_1106}"
: "${MID_DATE:=2026/06/12}"

BASE_IMG="moers/mid-server:latest"
JDK_URL="https://corretto.aws/downloads/latest/amazon-corretto-17-aarch64-linux-jdk.tar.gz"
CORE_URL="https://install.service-now.com/glide/distribution/builds/package/app-signed/mid-core/${MID_DATE}/mid-core.${MID_BUILD}.universal.universal.zip"
AGENT_VOL="mid_data"
JDK_VOL="mid_jdk17"
CONTAINER="sn-mid"
MID_UID=999
MID_GID=999

log()  { printf '[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*"; }
die()  { printf '[x] %s\n' "$*"; exit 1; }
SUDO() { if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo "$@"; fi; }

# ---- preflight ----
log "Preflight checks"
ARCH=$(dpkg --print-architecture 2>/dev/null || uname -m)
[ "$ARCH" = "arm64" ] || [ "$(uname -m)" = "aarch64" ] || die "Targets arm64/aarch64 only (found $ARCH)."
command -v docker >/dev/null 2>&1 || die "docker not found."
command -v unzip  >/dev/null 2>&1 || die "unzip not found (apt install unzip)."

log "Pulling base image (arm64) + creating volumes"
docker pull --platform linux/arm64 "$BASE_IMG"
docker volume create "$AGENT_VOL" >/dev/null
docker volume create "$JDK_VOL"   >/dev/null

# ---- install ARM64 JDK 17 ----
if docker run --rm -v "$JDK_VOL":/opt/jdk17 --entrypoint test "$BASE_IMG" -x /opt/jdk17/bin/java 2>/dev/null; then
  log "ARM64 JDK already present - skipping"
else
  log "Installing native ARM64 JDK 17 (Corretto)"
  docker run --rm --platform linux/arm64 --user root \
    -v "$JDK_VOL":/opt/jdk17 --entrypoint /bin/bash "$BASE_IMG" \
    -c "wget -q '$JDK_URL' -O /tmp/jdk.tar.gz && mkdir -p /opt/jdk17 && tar -xzf /tmp/jdk.tar.gz -C /opt/jdk17 --strip-components=1 && rm -f /tmp/jdk.tar.gz && chown -R ${MID_UID}:${MID_GID} /opt/jdk17 && /opt/jdk17/bin/java -version"
fi

# ---- download Australia MID payload ----
log "Downloading MID core payload: ${MID_BUILD}"
wget -q -O /tmp/mid-core.zip "$CORE_URL" || die "Download failed. Check MID_BUILD/MID_DATE and network to install.service-now.com."

log "Unzipping with system unzip (bypasses MID internal size limit)"
rm -rf /tmp/mid_au && mkdir -p /tmp/mid_au
unzip -q /tmp/mid-core.zip -d /tmp/mid_au
[ -d /tmp/mid_au/agent ] || die "Unexpected zip layout - no agent/ dir."

# ---- stop container + preserve registration ----
docker rm -f "$CONTAINER" 2>/dev/null || true
VOL_PATH=$(SUDO docker volume inspect "$AGENT_VOL" --format '{{.Mountpoint}}')
CFG_BACKUP=""
if SUDO test -f "$VOL_PATH/config.xml"; then
  CFG_BACKUP=$(mktemp)
  log "Backing up existing config.xml (preserves MID registration sys_id)"
  SUDO cp "$VOL_PATH/config.xml" "$CFG_BACKUP"
fi

log "Overlaying Australia agent onto volume (excluding config.xml + logs)"
SUDO rsync -a --exclude 'config.xml' --exclude 'logs/' /tmp/mid_au/agent/ "$VOL_PATH/"

if [ -n "$CFG_BACKUP" ]; then
  log "Restoring registered config.xml"
  SUDO cp "$CFG_BACKUP" "$VOL_PATH/config.xml"
  rm -f "$CFG_BACKUP"
fi

# ---- build config.xml (fresh only) ----
if ! SUDO test -f "$VOL_PATH/config.xml"; then
  log "No existing config.xml - generating from template (XML-encoding password)"
  SUDO docker run --rm --platform linux/arm64 --user root \
    -v "$AGENT_VOL":/opt/agent \
    -e SN_HOST_NAME="$SN_HOST" -e USER_NAME="$MID_USER" \
    -e PASSWORD="$MID_PASS" -e MIDNAME="$MID_NAME" \
    --entrypoint /bin/bash "$BASE_IMG" \
    -c 'cd /opt/agent; ENC_PW=$(printf %s "$PASSWORD" | sed "s/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/\"/\&quot;/g"); cp /opt/config.xml /opt/agent/config.xml; sed -i "s|https://YOUR_INSTANCE.service-now.com|https://${SN_HOST_NAME}|g" config.xml; sed -i "s|YOUR_INSTANCE_USER_NAME_HERE|${USER_NAME}|g" config.xml; sed -i "s|YOUR_INSTANCE_PASSWORD_HERE|${ENC_PW}|g" config.xml; sed -i "s|YOUR_MIDSERVER_NAME_GOES_HERE|${MIDNAME}|g" config.xml; chown 999:999 config.xml'
else
  log "Existing config.xml present - leaving untouched"
fi

# ---- ownership: uid 999 (mid), NOT 1000 ----
log "Setting ownership to mid (uid ${MID_UID})"
SUDO chown -R "${MID_UID}:${MID_GID}" "$VOL_PATH"

# ---- launch ----
log "Launching MID (direct java, wrapper bypassed, Australia build)"
docker run -d --name "$CONTAINER" \
  --platform linux/arm64 --restart unless-stopped --user root \
  -v "$AGENT_VOL":/opt/agent -v "$JDK_VOL":/opt/jdk17 \
  --entrypoint /bin/bash "$BASE_IMG" \
  -c "cd /opt/agent; rm -f /opt/agent/work/mid.pid; OPENS='--add-opens=java.base/java.nio=ALL-UNNAMED --add-opens=java.base/sun.nio.ch=ALL-UNNAMED --add-opens=java.base/java.lang=ALL-UNNAMED --add-opens=java.base/java.lang.invoke=ALL-UNNAMED --add-opens=java.base/java.util=ALL-UNNAMED --add-opens=java.base/java.util.concurrent=ALL-UNNAMED --add-opens=java.base/java.util.concurrent.atomic=ALL-UNNAMED --add-opens=java.base/java.text=ALL-UNNAMED --add-opens=java.base/java.io=ALL-UNNAMED --add-opens=java.base/java.net=ALL-UNNAMED --add-opens=java.base/java.security=ALL-UNNAMED --add-opens=java.base/javax.crypto=ALL-UNNAMED --add-opens=java.base/sun.security.util=ALL-UNNAMED --add-opens=java.base/java.math=ALL-UNNAMED'; su mid -s /bin/bash -c 'cd /opt/agent && nohup /opt/jdk17/bin/java -Xmx1024m -Djava.security.manager=allow '\$OPENS' -classpath lib/*:extlib/* com.service_now.mid.Main start >/opt/agent/logs/console.log 2>&1 &'; exec tail -F /opt/agent/logs/agent0.log.0 /opt/agent/logs/console.log"

log "Waiting for startup..."
sleep 20

log "Launched. Follow logs: docker logs -f ${CONTAINER}"
warn "Within ~60s you should see in logs:"
echo "    User ${MID_USER} has all necessary roles"
echo "    Successfully connected to instance: ${SN_HOST}"
echo "    Build tag: glide-${MID_BUILD%%_*}"
echo ""
echo "Then in ServiceNow: MID Server -> MID Servers -> ${MID_NAME} should be Status: Up."
echo ""
echo "Required JDK 17 flags (why this works on ARM64):"
echo "  -Djava.security.manager=allow       Australia calls System.setSecurityManager"
echo "  --add-opens=java.base/java.nio=...  Apache Ignite reflects into JDK internals"
echo ""
echo "If 401: check password, ensure mid_server role, and turn OFF 'password needs reset'."
