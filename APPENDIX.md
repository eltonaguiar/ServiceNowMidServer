# Appendix — Real-World ARM64 Bring-Up Notes (2026-10-27)

This appendix documents an actual end-to-end bring-up of the MID Server on ARM64,
including the problems hit when **reusing an existing install** and running
**non-interactively**, and the exact fixes. Read this alongside the main README if
you are re-running setup, reusing a machine that had a prior MID, or automating it.

## Environment
- **Host:** NVIDIA GX10 (GB10 Grace Blackwell), `aarch64`, Ubuntu 24.04.5 LTS
- **Instance:** `dev296154.service-now.com` (Australia patch3 — build `australia-02-11-2026__patch3-05-25-2026_06-12-2026_1106`)
- **MID name:** `gx10-mid` · **MID user:** `mid.server` (role `mid_server` present)
- **Docker:** server `29.6.2`; the operator is in the `docker` group (docker ops require **no sudo**)

## Outcome (verified)
Container `sn-mid` running on image `moers/mid-server:latest`. `agent0.log` shows:
```
Successfully connected to instance:
MID Server is connected to instance host: dev296154.service-now.com using IPversion: IPV4
AutoUpgrade.run(), MID server Operational State=UP
```
…and **0** `UnrecoverableKeyException` after the keystore fix below.

## What was already installed (no reinstall needed)
- Docker image `moers/mid-server:latest` present.
- Volume **`mid_data`**: full agent already present (673 jars in `lib/`, `extlib/`, `config.xml`, …).
- Volume **`mid_jdk17`**: native **JDK 17** already present.

⇒ The 478 MB MID-core payload did **not** need re-downloading; only the **config
(rotated password)** and the **keystore** needed refreshing. Prefer the fast-relaunch
path (below) when the agent is already in the volume.

---

## Issues encountered and fixes

### 1) Script "echoes instead of running"
**Symptom:** `./setup-mid-arm64.sh` prints text and exits without doing work.
**Cause:** mandatory env-var guards at the top of the script:
```bash
: "${SN_HOST:?Set SN_HOST first: export SN_HOST=\"YOUR_INSTANCE.service-now.com\"}"
: "${MID_USER:?Set MID_USER first: ...}"
: "${MID_PASS:?Set MID_PASS first: ...}"
```
`${VAR:?message}` prints the message and **exits immediately** if the variable is
unset **or empty**. (Also, the `cat setup-mid-arm64.sh` line prints the whole script —
that is the "review before running" step, not execution — and the "HOW TO USE" exports
are commented out, so copying them does nothing.)
**Fix:** export the four variables in the **same shell** first:
```bash
export SN_HOST="your-instance.service-now.com"   # no https://, no trailing slash
export MID_USER="mid.server"
read -rsp "MID password: " MID_PASS; echo        # hidden; avoids shell history
export MID_NAME="gx10-mid"                        # optional, defaults to <hostname>-mid
./setup-mid-arm64.sh
```
Notes: empty string still triggers `:?`; `sudo ./setup...` drops these env vars — don't.

### 2) `sudo` password blocks non-interactive / automated runs
The script's `SUDO()` helper performs **host** file operations on the docker volume
mountpoint (`/var/lib/docker/volumes/mid_data/_data`), which needs root. Where `sudo`
requires a password, automation blocks at the prompt.
**Fix:** do those volume file operations **through Docker (root-in-container)** instead of
host sudo — no sudo needed for users in the `docker` group. Replaced the host-sudo block with:
```bash
# overlay agent files (example)
docker run --rm -v mid_data:/dest -v /tmp/mid_au/agent:/src:ro \
  --entrypoint /bin/bash moers/mid-server:latest \
  -c "mkdir -p /dest && cp -a /src/. /dest/"
# ownership
docker run --rm -v mid_data:/v --entrypoint /bin/bash moers/mid-server:latest \
  -c "chown -R 999:999 /v"
```
(config.xml generation already runs in a container with `--user root`.)

### 3) 478 MB payload download interrupted → unzip failure
**Symptom:** `unzip: cannot find or open /tmp/mid-core.zip`.
**Cause:** the MID core payload is ~478 MB (`install.service-now.com`); large and slow, and
when downloads contend or the file is removed the unzip step fails.
**Fix:** when the agent is already in the `mid_data` volume (re-run / prior install),
**skip download + unzip + overlay** and use the fast-relaunch path (Section below).

### 4) Keystore mismatch after regenerating `config.xml` → "Unable to load keystore"
**Symptom:** `agent0.log` shows
```
java.security.UnrecoverableKeyException: failed to decrypt safe contents entry:
  javax.crypto.BadPaddingException ...  (bad key used during decryption)
MID server is not yet validated.
```
and the UI/greps may report *"Unable to load key store, MID server will not be able to function."*
**Cause:** regenerating `config.xml` produces a **new keystore password**, but the **stale**
keystore from the prior install (`/opt/agent/security/agent_keystore` + `security_backup/` copies)
was encrypted with the **old** password → decryption fails → MID never validates.
**Fix:** delete the stale keystore so the MID regenerates one matching the new config, then restart:
```bash
docker exec sn-mid sh -c 'rm -f /opt/agent/security/agent_keystore /opt/agent/security_backup/agent_keystore.*'
docker restart sn-mid
```
After this: **0** `UnrecoverableKeyException`, connected, `Operational State=UP`.

### 5) Rotated MID password
The MID password was rotated on the instance. `config.xml` was regenerated with the new
value (read from a **local secrets file into an env var — never echoed to logs**). The MID
authenticated successfully on the next start.

---

## Fast relaunch (no payload download) — `mid_fast.sh`
Use when the agent is already present in `mid_data` and you only need to (re)apply the
password and relaunch. Reads credentials from a local file; never prints the password.
```bash
#!/usr/bin/env bash
set -euo pipefail
F="$HOME/dbpasses.txt"
SN_HOST="$(grep -m1 -oE 'https?://[^ ]+' "$F" | sed -E 's#^https?://##; s#/.*$##')"
MID_USER="mid.server"
MID_PASS="$(sed -n '2p' "$F")"
MID_NAME="gx10-mid"; BASE_IMG="moers/mid-server:latest"
AGENT_VOL="mid_data"; JDK_VOL="mid_jdk17"; CONTAINER="sn-mid"; MID_XMX="1024m"

# 1) regenerate config.xml with current password (XML-encoding handled inside container)
docker run --rm --platform linux/arm64 --user root -v "$AGENT_VOL":/opt/agent \
  -e SN_HOST_NAME="$SN_HOST" -e USER_NAME="$MID_USER" -e PASSWORD="$MID_PASS" -e MIDNAME="$MID_NAME" \
  --entrypoint /bin/bash "$BASE_IMG" \
  -c 'cd /opt/agent; ENC_PW=$(printf %s "$PASSWORD" | sed "s/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/\"/\&quot;/g"); SED_PW=$(printf %s "$ENC_PW" | sed "s/[\\\\&|]/\\\\&/g"); cp /opt/config.xml /opt/agent/config.xml; sed -i "s|https://YOUR_INSTANCE.service-now.com|https://${SN_HOST_NAME}|g" config.xml; sed -i "s|YOUR_INSTANCE_USER_NAME_HERE|${USER_NAME}|g" config.xml; sed -i "s|YOUR_INSTANCE_PASSWORD_HERE|${SED_PW}|g" config.xml; sed -i "s|YOUR_MIDSERVER_NAME_GOES_HERE|${MIDNAME}|g" config.xml; chown 999:999 config.xml'

# 2) ownership
docker run --rm -v "$AGENT_VOL":/v --entrypoint /bin/bash "$BASE_IMG" -c "chown -R 999:999 /v"

# 3) clear stale keystore so it regenerates against the new config, then relaunch
docker rm -f "$CONTAINER" 2>/dev/null || true
docker run -d --name "$CONTAINER" --platform linux/arm64 --restart unless-stopped --user root \
  -v "$AGENT_VOL":/opt/agent -v "$JDK_VOL":/opt/jdk17 --entrypoint /bin/bash "$BASE_IMG" \
  -c "cd /opt/agent; rm -f /opt/agent/security/agent_keystore /opt/agent/work/mid.pid; OPENS='--add-opens=java.base/java.nio=ALL-UNNAMED --add-opens=java.base/sun.nio.ch=ALL-UNNAMED --add-opens=java.base/java.lang=ALL-UNNAMED --add-opens=java.base/java.lang.invoke=ALL-UNNAMED --add-opens=java.base/java.util=ALL-UNNAMED --add-opens=java.base/java.util.concurrent=ALL-UNNAMED --add-opens=java.base/java.util.concurrent.atomic=ALL-UNNAMED --add-opens=java.base/java.text=ALL-UNNAMED --add-opens=java.base/java.io=ALL-UNNAMED --add-opens=java.base/java.net=ALL-UNNAMED --add-opens=java.base/java.security=ALL-UNNAMED --add-opens=java.base/javax.crypto=ALL-UNNAMED --add-opens=java.base/sun.security.util=ALL-UNNAMED --add-opens=java.base/java.math=ALL-UNNAMED'; su mid -s /bin/bash -c \"cd /opt/agent && nohup /opt/jdk17/bin/java -Xmx${MID_XMX} -Djava.security.manager=allow \$OPENS -classpath 'lib/*:extlib/*' com.service_now.mid.Main start >/opt/agent/logs/console.log 2>&1 &\"; exec tail -F /opt/agent/logs/agent0.log.0 /opt/agent/logs/console.log"

# 4) wait for connect
for _ in $(seq 1 60); do sleep 2;
  docker logs --tail 200 "$CONTAINER" 2>&1 | grep -q "Successfully connected to instance" && { echo CONNECTED; break; }
done
```

## Verify
```bash
docker ps --filter name=^sn-mid$ --format '{{.Status}}'
docker exec sn-mid sh -c 'grep -iE "Successfully connected to instance|Operational State" /opt/agent/logs/agent0.log.0 | tail'
docker exec sn-mid sh -c 'tail -120 /opt/agent/logs/agent0.log.0 | grep -c UnrecoverableKeyException'   # expect 0
```
Then in ServiceNow: **MID Server → Servers → `gx10-mid`** (Status: Up; Validated: Yes once the
instance-side handshake completes).

## Security notes
- Secrets were read from a local file into env vars and **never echoed**; prefer `read -rsp`
  so the password never touches shell history or process args.
- Treat any password pasted into a chat or shell as compromised and rotate it.

## Credit
- Original ARM64 approach + `setup-mid-arm64.sh`: prior agents (see README).
- This bring-up + troubleshooting notes (env guards, sudo-free volume ops, skip-payload
  fast path, keystore regeneration): GHCopilot + peer agents (opencode / freebuff), 2026-10-27.
