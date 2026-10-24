<img width="1348" height="128" alt="image" src="https://github.com/user-attachments/assets/df6bbc88-c6fe-48de-9ea3-2570e9a77e08" />

# ServiceNow MID Server on ARM64 (NVIDIA GX10 / Grace Blackwell)

> **Run a ServiceNow MID Server on ARM64 Linux — including the current Australia release — even though ServiceNow does not publish a single ARM64 package.**

Tested end-to-end on an **NVIDIA DGX Spark / GX10** (GB10 Grace Blackwell, `aarch64`, Ubuntu 24.04.5 LTS, kernel `7.0.0-1019-nvidia`) against an **Australia patch3** instance (`glide-australia-02-11-2026__patch3-05-25-2026`).

The MID comes up **`Up` and `Validated`**, reports the correct `australia` buildstamp, subscribes to AMB, and processes probes.

---

## Table of Contents

- [TL;DR — Quick Start](#tldr--quick-start)
- [Why This Is Hard](#why-this-is-hard)
- [The Incompatible Versions We Worked Around](#the-incompatible-versions-we-worked-around)
- [How The Solution Works](#how-the-solution-works)
- [Step-by-Step Guide](#step-by-step-guide)
- [Verify It Worked](#verify-it-worked)
- [Troubleshooting — Every Error We Hit](#troubleshooting--every-error-we-hit)
- [Operations — Restart, Logs, Teardown](#operations--restart-logs-teardown)

---

## TL;DR — Quick Start

If you just want it running, use the automated script. It pulls the base image, installs an ARM64 JDK, downloads the **Australia** MID payload, overlays it, builds a valid `config.xml`, and launches MID with all the required JVM flags.

```bash
# Set your own values, then run:
export SN_HOST="dev213089.service-now.com"
export MID_USER="mid.server"
export MID_PASS='***PASSWORDHERE***'
export MID_NAME="gx10-mid"

curl -fsSL https://raw.githubusercontent.com/eltonaguiar/ServiceNowMidServer/main/setup-mid-arm64.sh | bash
```

Or clone and run locally (recommended — you can inspect what it does):

```bash
git clone https://github.com/eltonaguiar/ServiceNowMidServer.git
cd ServiceNowMidServer
chmod +x setup-mid-arm64.sh
./setup-mid-arm64.sh
```

Watch it come up:

```bash
docker logs -f sn-mid
```

Look for:
```
Build tag: glide-australia-02-11-2026__patch3-05-25-2026
User mid.server has all necessary roles
Successfully connected to instance: dev213089.service-now.com
```

Then in ServiceNow go to **MID Server → MID Servers** and confirm `gx10-mid` shows **Status: Up**.

---

## Why This Is Hard

ServiceNow **does not ship an ARM64 MID Server**. Not as a `.deb`, not as an `.rpm`, not as a ZIP, not as a Docker image. Every official artifact is `x86-64` only. If you're on an ARM64 host — an NVIDIA GX10/GB10, an AWS Graviton, a Raspberry Pi 4/5, or Apple Silicon — the normal install path is a dead end before you start.

On a GX10 the failure modes stack on top of each other:

1. **The official `.deb` refuses to install.** `dpkg -i` rejects it with *"package architecture (amd64) does not match system (arm64)"*. `--force-architecture` unpacks x86 binaries that then can't execute.

2. **There is no ARM64 alternative on the CDN.** Probing `.../mid-linux-installer/.../…arm64.deb`, `…aarch64.deb`, etc. all return `404`. ServiceNow simply doesn't build one.

3. **The community multi-arch image is the wrong release *and* the wrong Java.** [`moers/mid-server`](https://hub.docker.com/r/moers/mid-server) does publish an `arm64` variant, but it is pinned to an older release (Zurich) and bundles **Java 11**. The current MID needs **Java 17+**.

4. **The service wrapper binary is x86-only.** The image ships `wrapper-linux-x86-64` and `libwrapper-linux-x86-64.so`. There is no `wrapper-linux-arm-64`, so the stock `mid.sh start` path dies immediately.

5. **The MID won't self-upgrade to the current release.** Auto-upgrade downloads a ~480 MB package and chokes with *"The size of uncompressed files is too big or too many entries in the zip file"* — a defensive limit inside the MID's own unzip routine.

So you can't install it, you can't run the packaged image as-is, and you can't let it fix itself. The rest of this guide is how we got a **native, current-release, ARM64 MID** running anyway.

---

## The Incompatible Versions We Worked Around

This is the crux. There are **five distinct version/architecture mismatches**, and each one fails differently. Documenting them precisely so you know which wall you just hit.

| # | Mismatch | What it looks like | The fix |
|---|----------|--------------------|---------|
| 1 | **CPU architecture**: `arm64` host vs `x86-64` packages | `dpkg: package architecture (amd64) does not match system (arm64)` | Don't install the `.deb`. Build the MID from Java jars (arch-independent) + an ARM64 JDK. |
| 2 | **MID release**: host image is `Zurich` (rel 28), instance is `Australia` (rel 29) | Instance shows `Upgrade Failed`, MID tries and fails to auto-upgrade | Manually overlay the **Australia** MID core payload (the jars are pure Java — they run on any arch). |
| 3 | **Java class-file version**: image bundles **Java 11** (class 55), MID needs **Java 17** (class 61) | `UnsupportedClassVersionError: ... class file version 61.0 ... only recognizes up to 55.0` | Install a real **ARM64 JDK 17** (Corretto) and point the launch at it. |
| 4 | **Tanuki wrapper architecture**: only an `x86-64` wrapper binary/`.so` exists | `Unable to locate ... wrapper-linux-arm-64` / `WrapperManager: ERROR - Unable to load the Wrapper's native library` | **Bypass the wrapper entirely.** Launch `com.service_now.mid.Main` directly with `java`. The wrapper warning is non-fatal. |
| 5 | **JDK 17 language/security policy**: MID's Apache Ignite + `SecurityManager` use APIs JDK 17 restricts | `InaccessibleObjectException: module java.base does not "opens java.nio"` and/or `System.setSecurityManager` abort | Pass a set of `--add-opens=...` flags **plus** `-Djava.security.manager=allow`. |

Plus two gotchas that aren't version mismatches but will still stop you cold:

- **Password special characters.** A password containing `&` (very common in generated passwords) produces **invalid XML** in `config.xml` unless you XML-encode it (`&` → `&amp;`). Invalid XML → cryptic `401 User Not Authenticated` even with the correct password.
- **Container file ownership.** The MID runs as user `mid` (**uid 999**, *not* 1000). If you overlay files as `root` and `chown 1000:1000`, the agent can't write its own logs and dies with `AccessDeniedException: logs/agent1.log.0.lck`.

---

## How The Solution Works

The key insight: **MID Server is a Java application.** The jars (`lib/*.jar`) are pure, architecture-independent bytecode. The only things that are arch-specific are:

- the **Tanuki wrapper** binary (which just starts/stops the JVM — we skip it), and
- the **bundled JRE** (we replace it with a native ARM64 JDK).

So the recipe is:

1. Start from the community `arm64` image **only** as a convenient source of the MID directory layout and config template.
2. Install a native **ARM64 JDK 17**.
3. Download the **official Australia MID core ZIP** (pure Java jars + config template).
4. **Unzip it yourself** with system `unzip` (bypassing the MID's own size limit) and overlay it onto the agent directory.
5. Build a valid `config.xml` with an **XML-encoded** password.
6. Launch `com.service_now.mid.Main` **directly with `java`** (skipping the x86 wrapper), with the `--add-opens` and `-Djava.security.manager=allow` flags.

Result: a **native ARM64 MID running the exact Australia build** your instance expects — no emulation, no x86 translation layer, full performance.

---

## Step-by-Step Guide

### Prerequisites

- ARM64 (`aarch64`) Linux host with Docker installed
- `sudo` access
- A ServiceNow **MID server user** with the `mid_server` role (e.g. `mid.server`)
- Outbound HTTPS to your instance **and** to `install.service-now.com`

Confirm your architecture:

```bash
dpkg --print-architecture   # must print: arm64
```

### Step 1 — Pull the base image and create volumes

We use the community image for its directory structure and config template. We create two volumes: one for the MID agent (persistent config/registration) and one for the ARM64 JDK (so it survives container recreation).

```bash
docker pull --platform linux/arm64 moers/mid-server:latest

docker volume create mid_data
docker volume create mid_jdk17
```

### Step 2 — Install a native ARM64 JDK 17

The bundled JRE is Java 11 (too old). Australia requires **≥ 17.0.10**. We use Amazon Corretto 17 for `aarch64`, persisted in the `mid_jdk17` volume.

```bash
docker run --rm --platform linux/arm64 --user root \
  -v mid_jdk17:/opt/jdk17 \
  --entrypoint /bin/bash moers/mid-server:latest \
  -c 'wget -q https://corretto.aws/downloads/latest/amazon-corretto-17-aarch64-linux-jdk.tar.gz -O /tmp/jdk17.tar.gz \
   && mkdir -p /opt/jdk17 \
   && tar -xzf /tmp/jdk17.tar.gz -C /opt/jdk17 --strip-components=1 \
   && rm /tmp/jdk17.tar.gz \
   && chown -R 999:999 /opt/jdk17 \
   && /opt/jdk17/bin/java -version'
```

The last line should print `openjdk version "17.0.x"` (Corretto).

> **Why 17 and not 21?** 17 works and is what the base image's tooling expects. If your instance's Australia patch requires 21, swap in `amazon-corretto-21-aarch64-linux-jdk.tar.gz` — everything else is identical.

### Step 3 — Download the official Australia MID core payload

Grab the **MID core universal ZIP** for your exact build. Get the build tag from your instance's stats page (`stats.do`) or the MID Server downloads page. Ours is `australia-02-11-2026__patch3-05-25-2026_06-12-2026_1106`.

```bash
# Adjust the date folder (…/2026/06/12/…) and the build tag to match YOUR instance
MID_BUILD="australia-02-11-2026__patch3-05-25-2026_06-12-2026_1106"
MID_DATE="2026/06/12"

wget -O /tmp/mid-core.zip \
  "https://install.service-now.com/glide/distribution/builds/package/app-signed/mid-core/${MID_DATE}/mid-core.${MID_BUILD}.universal.universal.zip"
```

> **Tip:** If you're unsure of the exact URL, the MID's own `agent0.log.0` prints the `mid-core…universal.zip` download URL right before it fails the auto-upgrade. Copy it from there.

### Step 4 — Unzip the payload to staging

We unzip with **system `unzip`**, not the MID's Java unzipper — that's what gets us past the *"too big or too many entries"* limit.

```bash
rm -rf /tmp/mid_au && mkdir -p /tmp/mid_au
unzip -q /tmp/mid-core.zip -d /tmp/mid_au
# Structure is: /tmp/mid_au/agent/...
```

Verify it's the right release (Australia = release **29**):

```bash
unzip -p /tmp/mid_au/agent/lib/mid-acc-commons.jar META-INF/MANIFEST.MF | grep Implementation-Version
# Expect: Implementation-Version: 29.xxxxx
```

### Step 5 — Overlay the Australia payload onto the live agent volume

Stop any running container first, then overlay the new jars while **preserving `config.xml`** (which holds your credentials and MID registration `sys_id`). Fix ownership to **uid 999** (`mid`), *not* 1000.

```bash
docker rm -f sn-mid 2>/dev/null

V=/var/lib/docker/volumes/mid_data/_data

# Backup current registered config
sudo cp "$V/config.xml" /tmp/config_backup.xml

# Overlay Australia agent, keeping config.xml + logs intact
sudo rsync -a --exclude 'config.xml' --exclude 'logs/' /tmp/mid_au/agent/ "$V/"

# Restore the registered config and fix ownership to mid (uid 999)
sudo cp /tmp/config_backup.xml "$V/config.xml"
sudo chown -R 999:999 "$V"
```

> **Critical:** `chown -R 999:999`, not `1000:1000`. The `mid` user inside the container is **uid 999**. Getting this wrong is the #1 cause of the mysterious `AccessDeniedException` crash.

### Step 6 — Build a valid `config.xml` (first run only)

If this is a **fresh** MID (no existing registration), generate `config.xml` from the template with an **XML-encoded** password:

```bash
docker run --rm --platform linux/arm64 --user root \
  -v mid_data:/opt/agent \
  -e SN_HOST_NAME="dev213089.service-now.com" \
  -e USER_NAME="mid.server" \
  -e PASSWORD='***PASSWORDHERE***' \
  -e MIDNAME="gx10-mid" \
  --entrypoint /bin/bash moers/mid-server:latest \
  -c '
    cd /opt/agent
    # XML-encode special chars in the password (& < > " )
    ENC_PW=$(printf %s "$PASSWORD" | sed "s/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/\"/\&quot;/g")
    cp /opt/config.xml /opt/agent/config.xml
    sed -i "s|https://YOUR_INSTANCE.service-now.com|https://${SN_HOST_NAME}|g" config.xml
    sed -i "s|YOUR_INSTANCE_USER_NAME_HERE|${USER_NAME}|g" config.xml
    sed -i "s|YOUR_INSTANCE_PASSWORD_HERE|${ENC_PW}|g" config.xml
    sed -i "s|YOUR_MIDSERVER_NAME_GOES_HERE|${MIDNAME}|g" config.xml
    # IMPORTANT: do NOT pin mid.pinned.version — we want it to run the native Australia build
    chown 999:999 config.xml
  '
```

> **Do not** add a `mid.pinned.version` parameter. Pinning forces the MID back to an older release and triggers the failed auto-upgrade loop.

If you **already have a registered MID** (like we did after the first successful auth), skip this step — Step 5 already preserved your working `config.xml`.

### Step 7 — Launch the MID (direct Java, wrapper bypassed)

This is the launch that works. Note: **no Tanuki wrapper**, direct `java … com.service_now.mid.Main start`, run in the background, container stays alive tailing the log.

```bash
docker rm -f sn-mid 2>/dev/null

docker run -d --name sn-mid \
  --platform linux/arm64 \
  --restart unless-stopped \
  --user root \
  -v mid_data:/opt/agent \
  -v mid_jdk17:/opt/jdk17 \
  --entrypoint /bin/bash \
  moers/mid-server:latest \
  -c '
    cd /opt/agent
    rm -f /opt/agent/work/mid.pid
    OPENS="--add-opens=java.base/java.nio=ALL-UNNAMED \
           --add-opens=java.base/sun.nio.ch=ALL-UNNAMED \
           --add-opens=java.base/java.lang=ALL-UNNAMED \
           --add-opens=java.base/java.lang.invoke=ALL-UNNAMED \
           --add-opens=java.base/java.util=ALL-UNNAMED \
           --add-opens=java.base/java.util.concurrent=ALL-UNNAMED \
           --add-opens=java.base/java.util.concurrent.atomic=ALL-UNNAMED \
           --add-opens=java.base/java.text=ALL-UNNAMED \
           --add-opens=java.base/java.io=ALL-UNNAMED \
           --add-opens=java.base/java.net=ALL-UNNAMED \
           --add-opens=java.base/java.security=ALL-UNNAMED \
           --add-opens=java.base/javax.crypto=ALL-UNNAMED \
           --add-opens=java.base/sun.security.util=ALL-UNNAMED \
           --add-opens=java.base/java.math=ALL-UNNAMED"
    su mid -s /bin/bash -c "cd /opt/agent && \
      nohup /opt/jdk17/bin/java -Xmx1024m -Djava.security.manager=allow $OPENS \
      -classpath \"lib/*:extlib/*\" com.service_now.mid.Main start \
      >/opt/agent/logs/console.log 2>&1 &"
    exec tail -F /opt/agent/logs/agent0.log.0 /opt/agent/logs/console.log
  '
```

**Why each flag matters:**

| Flag | Reason |
|------|--------|
| `-Djava.security.manager=allow` | Australia's code calls `System.setSecurityManager`. JDK 17 blocks it by default → without this the JVM aborts. |
| `--add-opens=java.base/java.nio=ALL-UNNAMED` (+ the rest) | MID's Apache Ignite reflects into JDK internals (`Buffer.address`). JDK 17's module system blocks it → `InaccessibleObjectException` without these. |
| `-classpath "lib/*:extlib/*"` | Loads all MID jars plus extension jars. |
| `com.service_now.mid.Main start` | The real MID entrypoint (normally invoked *by* the wrapper — we call it directly). |
| `nohup … &` + `tail -F` | `Main start` daemonizes (forks) and the parent exits. Without backgrounding + tailing, Docker sees the process exit and restart-loops the container. |

---

## Verify It Worked

```bash
# Container up and Java alive
docker ps -a --filter name=sn-mid
docker exec sn-mid bash -c "ps aux | grep \"Main start\" | grep -v grep | grep -v defunct | wc -l"   # expect >= 1

# MID reports the Australia build and connected cleanly
docker exec sn-mid bash -c "tail -100 /opt/agent/logs/agent0.log.0" | \
  grep -iE "Build tag|all necessary roles|Successfully connected|MID buildstamp"
```

Expected output:

```
User mid.server has all necessary roles
Successfully connected to instance: dev213089.service-now.com
Build tag: glide-australia-02-11-2026__patch3-05-25-2026
MID buildstamp: australia-02-11-2026__patch3-05-25-2026_06-12-2026_1106
```

You can also check from the instance side (using your MID user):

```bash
curl -s --user "mid.server:***PASSWORDHERE***" \
  "https://dev213089.service-now.com/api/now/table/ecc_agent?sysparm_query=name%3Dgx10-mid&sysparm_fields=name,status" 
```

Finally, in the ServiceNow UI: **MID Server → MID Servers → gx10-mid** should show **Status: Up**. Click **Validate** to confirm.

---

## Troubleshooting — Every Error We Hit

Each of these is a real error encountered while building this, with the fix.

### `UnsupportedClassVersionError: com/service_now/mid/Main has been compiled by a more recent version of the Java Runtime (class file version 61.0), this version of the Java Runtime only recognizes class file versions up to 55.0`

**Cause:** Running with the image's bundled **Java 11** (max class 55). MID needs **Java 17** (class 61).
**Fix:** Install the ARM64 JDK 17 (Step 2) and launch with `/opt/jdk17/bin/java`, not `jre/bin/java`.

### `Unable to locate any of the following binaries: .../wrapper-linux-arm-64`

**Cause:** The Tanuki service wrapper is only built for x86-64. `mid.sh start` can't run on ARM.
**Fix:** Bypass the wrapper — launch `com.service_now.mid.Main` directly with `java` (Step 7). You'll still see a `WrapperManager: ERROR - Unable to load the Wrapper's native library` warning; **that one is non-fatal**.

### `InaccessibleObjectException: Unable to make field long Buffer.address accessible: module java.base does not "opens java.nio" to unnamed module`

**Cause:** MID's Apache Ignite reflects into JDK internals; JDK 17's module system blocks it.
**Fix:** Add the full `--add-opens=…` flag set (Step 7).

### JVM starts then immediately dies; log shows `System::setSecurityManager has been called` then terminates

**Cause:** Australia's code calls `System.setSecurityManager`, which JDK 17 throws `UnsupportedOperationException` on unless explicitly allowed. (Zurich didn't call it — this is a *new* Australia requirement.)
**Fix:** Add `-Djava.security.manager=allow` (Step 7).

### MID auto-upgrade fails: `Unable to download package The size of uncompressed files is too big or too many entries in the zip file`

**Cause:** The MID's built-in Java unzipper has a defensive size/entry-count limit that the ~480 MB Australia package exceeds.
**Fix:** Don't let it auto-upgrade. Download the `mid-core…universal.zip` and unzip it **yourself** with system `unzip`, then overlay (Steps 3–5). System `unzip` has no such limit.

### `401 Unauthorized` / `User Not Authenticated` even though the password looks right

**Causes (check in order):**
1. **Password contains `&` and wasn't XML-encoded** in `config.xml`. Encode `&` → `&amp;`, `<` → `&lt;`, `>` → `&gt;`, `"` → `&quot;` (Step 6).
2. **The ServiceNow user has "password needs reset" enabled.** This blocks API/SOAP auth entirely. Turn it off in the user's sys_user record.
3. Wrong password or the user lacks the `mid_server` role.

Verify credentials directly against the API (no MID in the path):

```bash
curl -s -o /dev/null -w "HTTP %{http_code}\n" \
  --user "mid.server:***PASSWORDHERE***" \
  "https://YOUR_INSTANCE.service-now.com/api/now/table/sys_user?sysparm_limit=1"
# HTTP 200 = good, HTTP 401 = bad credentials/role/reset-flag
```

### `Could not write to file: /opt/agent/logs/FileHandlerReport.txt (Permission denied)` / `AccessDeniedException: logs/agent1.log.0.lck`

**Cause:** The MID runs as `mid` (**uid 999**). If you overlaid files as root and/or `chown`'d to `1000:1000`, the agent can't write its own logs.
**Fix:** `sudo chown -R 999:999 /var/lib/docker/volumes/mid_data/_data`

### Container keeps restarting; `docker logs` shows nothing useful

**Cause:** `com.service_now.mid.Main start` daemonizes — the foreground `java` process forks a child and the parent exits. Docker interprets that as the container finishing and restarts it.
**Fix:** Launch `java` with `nohup … &` in the background and `exec tail -F` the log so the container has a long-lived foreground process (Step 7).

### Instance shows `Upgrade Failed` and empty Version after a failed upgrade attempt

**Cause:** A prior failed auto-upgrade left the `ecc_agent` record stuck.
**Fix:** Clear it via API, then restart so the MID re-registers cleanly:

```bash
# Set status to Down to clear the stuck upgrade state
curl -s --user "mid.server:***PASSWORDHERE***" -X PUT \
  -H "Content-Type: application/json" -d '{"status":"Down"}' \
  "https://YOUR_INSTANCE.service-now.com/api/now/table/ecc_agent/<SYS_ID>?sysparm_fields=status"
docker restart sn-mid
```

A leftover **MID Server Issue** row (e.g. *"Aborting MID Server upgrade due to pre-upgrade check failure"*) from before the fix is **stale** — safe to close/delete. It won't regenerate once the versions match.

---

## Operations — Restart, Logs, Teardown

```bash
# Restart (re-registers with the instance)
docker restart sn-mid

# Follow logs
docker logs -f sn-mid
docker exec sn-mid bash -c "tail -f /opt/agent/logs/agent0.log.0"

# Stop
docker stop sn-mid

# Tear down completely (removes volumes = lose MID registration)
docker rm -f sn-mid
docker volume rm mid_data mid_jdk17
```

**Persistence:** `mid_data` holds your `config.xml` (credentials + MID `sys_id` registration) and `mid_jdk17` holds the JDK. Both survive container removal/recreation, so you can `docker rm` + `docker run` the same command from Step 7 without re-registering.

---

## Summary of the Hack

| Component | Official | What we did |
|-----------|----------|-------------|
| CPU package (`.deb`/`.rpm`) | x86-64 only | Skipped — build from Java jars |
| Java runtime | Bundled x86 JRE / Java 11 | Native **ARM64 Corretto JDK 17** |
| Service wrapper | x86-64 Tanuki binary | **Bypassed** — direct `java … Main start` |
| MID release | Instance is Australia (29) | Manually overlaid **Australia** core payload |
| JVM flags | Defaults | `--add-opens` (×14) + `-Djava.security.manager=allow` |
| Result | Won't install on ARM64 | **Native ARM64 MID, Australia build, Up & Validated** |

---

## Credits & References

- Community base image: [`moers/mid-server`](https://hub.docker.com/r/moers/mid-server) (multi-arch; used for layout + config template only)
- ARM64 JDK: [Amazon Corretto](https://corretto.aws/) for `aarch64`
- ServiceNow MID docs: [Build MID Server Docker image for Linux](https://www.servicenow.com/docs/r/servicenow-platform/mid-server/mid-build-docker-linux.html)

Built and verified on the NVIDIA GX10 (GB10 Grace Blackwell). No x86 emulation used — fully native ARM64.
